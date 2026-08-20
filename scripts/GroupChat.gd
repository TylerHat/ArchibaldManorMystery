extends Node
# Turn engine for a Hall meetup - the group confrontation the detective runs
# after ordering suspects into the Hall one at a time.
#
# Lives as a child of the GameManager autoload (GameManager.group_chat) and
# holds no UI of its own; Main builds the panel and listens to the signals
# below. Every request it makes goes through GameManager's existing single
# HTTPRequest queue, so a group turn can never collide with a one-on-one
# question or a Case Notes summary - the queue already serializes all three.
#
# The one rule the whole design hangs off: nothing is ever enqueued except
# from submit_player_line(). Suspects can stand in the Hall indefinitely and
# not a single token is generated until the detective says something.

## Emitted for every line that belongs in the on-screen log, whether it came
## from the detective, a suspect, or the engine itself (stage directions).
## `entry` is {speaker_id, text, kind}; speaker_id "" means the detective.
## kind is "say" for spoken lines, "stage" for the engine's own italic
## narration, "command" for an order the detective typed, and "action" for a
## physical thing the detective did (typed in round brackets).
signal line_added(entry)

## Emitted when the engine changes phase so the UI can enable/disable input:
## "idle", "awaiting_player", or "responding".
signal state_changed(new_state)

## Emitted just before a suspect's turn goes out to the model, so the UI can
## show "<name> is thinking...".
signal turn_started(character_id)

## Emitted when a round is abandoned because a request failed. The remaining
## speakers are dropped and control returns to the detective.
signal round_failed(message)

## Emitted when the guest list or the mute list changes, so the UI can redraw
## the roster.
signal roster_changed()

## Emitted when the confrontation stops being a confrontation - `remaining` is
## how many suspects are left. 1 means it has quietly become a private
## conversation; 0 means there's no one left to talk to.
signal quorum_lost(remaining)

## How many spoken lines of the current scene get replayed into a turn prompt.
##
## This is a straight latency dial and the most expensive number in the file.
## The scene is rendered fresh on every turn, so unlike the history it is NOT
## cached - every line here is re-read by the model for every attendee, every
## time the detective says anything. At ~40 tokens a line and ~1,150 tokens/sec
## of prefill, each 10 lines costs roughly a third of a second per turn, which
## in a four-handed room is 1.4 seconds per line the player types.
##
## 16 is about three rounds of a four-handed scene or five of a two-hander -
## enough for a suspect to stay consistent with what they just said, which is
## all this needs to do. Anything older that still matters is in their schedule
## and their private recap, both of which are also in the prompt.
const SCENE_RENDER_MAX_LINES := 16

## How many of a suspect's own lines survive into the one digest written to
## their permanent memory when the scene ends.
const DIGEST_OWN_LINES := 4

## How many lines said BY OTHERS survive into that digest. Kept smaller than
## their own: what matters afterwards is what they committed to in public, plus
## enough of the accusations to know what they were answering.
const DIGEST_OTHER_LINES := 4

var active: bool = false
var attendees: Array = [] # character_ids, snapshotted when the scene opens
var scene_log: Array = [] # [{speaker_id, text, kind}]
var state: String = "idle" # idle | awaiting_player | responding

## Suspects the detective has told to keep quiet. Only muted ids are present -
## absence means "free to speak". A muted suspect still HEARS everything (see
## note_to_character calls below), which is the whole point: letting someone
## stew through two rounds and then giving them the floor is a real move.
var muted: Dictionary = {} # character_id -> true

var _queue: Array = [] # ids still owed a turn this round
var _speaking_id: String = "" # whose turn is currently in flight ("" if none)
var _round_start: int = 0 # rotates each round so the same suspect doesn't always open
var _direct_round: bool = false # this round was aimed at one named suspect

## Who has already answered the CURRENT question, in order, as [{id, text}].
## Cleared at the start of every round.
##
## Without this a suspect has no idea whether they are first to speak or last,
## and will confidently refer to what another guest "already said" when that
## guest hasn't spoken yet - inventing the reply and then contradicting itself
## about it in the same sentence. Stating the round position explicitly is much
## more reliable than hoping the model infers it from message order.
var _round_replies: Array = []
var _last_player_line: String = "" # raw text of the detective's last line, for transcript entries

## The same line split into what the detective DID and what they SAID (see
## GameManager.parse_stage_action). Held separately from _last_player_line
## because the transcript wants the raw text the player typed, while the turn
## prompt has to present an action and a question completely differently - one
## is a fact of the scene, the other is something to answer.
var _last_player_action: String = ""
var _last_player_speech: String = ""
var _gm: Node = null

## Every request gets a unique token; only a reply carrying the token we're
## currently waiting on is accepted. Requests already in Ollama's queue can't
## be cancelled, so this is how a reply from a closed scene - or from a suspect
## who has since been sent out of the room - gets dropped. GameManager still
## records it into that suspect's memory and the transcript either way; it just
## never reaches the room.
var _next_token: int = 0
var _pending_token: int = -1 # -1 means "not waiting on anything"

## Where in scene_log each departed attendee stopped hearing things.
##
## Someone sent out of the Hall mid-scene should remember the argument up to the
## moment they left and nothing after it. Absent from this dictionary means
## "still here", i.e. heard everything.
var _left_at: Dictionary = {} # character_id -> scene_log index at departure

## Where in scene_log the CURRENT round began - i.e. the index of the
## detective's latest line. _render_scene_for() stops here, because everything
## from this point on is presented separately at the end of the turn prompt.
var _round_log_start: int = 0


# --- How the room reaches the model -----------------------------------------
#
# Everything a character hears has to be sent under the "user" role - the chat
# API has no third role for "someone else in the room". Writing each line as its
# own user message made the user role mean the detective on one line and another
# guest on the next, and a small model reading that history has no way to tell
# which of them is now talking to it. That produced suspects calling the
# detective by another suspect's name and answering remarks nobody had made.
#
# So the whole scene is rendered as ONE narrated block, on demand, per turn (see
# _render_scene_for). The user role then always means the same thing - the
# narrator relaying the room - and other guests appear only as quoted,
# clearly-attributed speech inside it.
#
# That block is EPHEMERAL. It used to be written permanently into every
# attendee's history by note_to_character() as the scene went along, which cost
# more than it looked:
#
#   - Storage was O(N^2) per round. Every line spoken was copied into all N-1
#     other attendees' histories, so a 4-handed scene deposited ~600 tokens of
#     duplicated text per round and an 8-handed one ~2,800.
#   - It landed in the MIDDLE of each history, where compaction can't reach it
#     without invalidating the model's cached prefix.
#   - Repeat meetups stacked up: three scenes with the same suspect left three
#     priming blocks and three scene-enders permanently in their memory.
#
# Rendering instead of storing fixes all three, and puts the volatile text at
# the very end of the prompt where it costs a few hundred tokens of prefill
# rather than invalidating everything before it. What survives the scene is one
# digest written by _note_scene_ended().


func _ready() -> void:
	# Deliberately get the parent rather than the GameManager autoload name:
	# this node is created inside GameManager._ready(), and the autoload
	# singleton isn't guaranteed to be resolvable by name that early.
	_gm = get_parent()


# ----------------------------------------------------------- session setup --

## Opens a confrontation with `ids` (the suspects standing in the Hall).
## Snapshots the guest list, primes each attendee with a short group-scene
## instruction, and then waits - no request goes out until the detective
## speaks.
func start(ids: Array) -> void:
	if active:
		stop()
	attendees = ids.duplicate()
	scene_log.clear()
	muted.clear()
	_left_at.clear()
	_queue.clear()
	_speaking_id = ""
	_round_start = 0
	_round_log_start = 0
	_direct_round = false
	_last_player_line = ""
	_last_player_action = ""
	_last_player_speech = ""
	_pending_token = -1
	active = true

	# Nothing is written to anyone's memory here any more. The group-scene
	# instruction that used to be primed in is rendered into each turn prompt
	# instead - see _group_role_instruction().

	var names := _display_names(attendees)
	_add_line("", "%s are gathered in the hall, waiting for you to speak." % _join_names(names), "stage")
	_add_line("", "Speak to the room, or start with a name to address one of them. \"Marcus, be quiet\" silences someone; \"Marcus, go ahead\" gives them the floor; \"Marcus, go to the library\" sends him there. \"Everyone, back to your rooms\" clears the hall.", "stage")
	_set_state("awaiting_player")


## Ends the confrontation. Safe to call when no session is open.
func stop() -> void:
	# Close the scene out in everyone's memory before the guest list is thrown
	# away - anyone still in the room needs telling that it's over.
	if active:
		for id in attendees:
			_note_scene_ended(String(id))
	active = false
	attendees.clear()
	muted.clear()
	_left_at.clear()
	_queue.clear()
	_speaking_id = ""
	_direct_round = false
	# Anything still in flight belongs to a scene that no longer exists.
	_pending_token = -1
	_set_state("idle")


## How much of scene_log this character heard: everything, unless they were sent
## out of the room, in which case everything up to the moment they left.
func _heard_upto(id: String) -> int:
	return int(_left_at.get(id, scene_log.size()))


## One spoken line of the scene, written as this character experienced it.
## Returns "" for entries that should never reach the model - engine stage
## directions and the echo of orders the detective typed.
##
## Uses short tags (DETECTIVE / GUEST / YOU) rather than spelling out who is who
## on every line. The convention is explained once in the block header instead,
## which is worth doing carefully: the long form cost about fourteen tokens of
## framing per line, and this block is re-read on every attendee's turn, so on a
## sixteen-line scene that framing alone was ~220 tokens of prefill per turn -
## paid four times over in a four-handed room, for every line the player types.
##
## A bracketed gesture is still split out as something they SAW rather than
## words they heard; otherwise the next suspect reads "(nods)" as speech and
## starts answering the stage direction.
func _render_line_for(id: String, entry: Dictionary) -> String:
	var kind := String(entry["kind"])
	if kind != "say" and kind != "action":
		return "" # "stage" is UI narration, "command" is deliberately never sent

	var speaker := String(entry["speaker_id"])
	var text := String(entry["text"])

	if speaker == "":
		if kind == "action":
			return "DETECTIVE (does this, really happening): %s" % text
		return "DETECTIVE: \"%s\"" % text

	if speaker == id:
		return "YOU: \"%s\"" % text

	var who := String(_gm.get_character(speaker).get("name", "someone"))
	var parts: Dictionary = _gm.parse_stage_action(text)
	var act := String(parts["action"])
	var said := String(parts["speech"])
	if act != "":
		var out := "GUEST %s (does this): %s" % [who, act]
		if said != "":
			out += " and says: \"%s\"" % said
		return out
	return "GUEST %s: \"%s\"" % [who, text]


## The confrontation so far, as one narrated block, from this character's point
## of view. Built fresh every turn and never stored - see the note above
## _left_at.
##
## Stops BEFORE the detective's current line. That line and any replies to it
## already appear at the very end of the turn prompt, where they have to be so
## the model answers the right thing; including them here as well would send the
## same text twice on every single turn.
##
## Returns "" before anyone has said anything, so the opening turn of a scene
## isn't preceded by an empty transcript header.
func _render_scene_for(id: String) -> String:
	var limit: int = min(_heard_upto(id), _round_log_start)
	var rendered := []
	for i in range(min(limit, scene_log.size())):
		var line := _render_line_for(id, scene_log[i])
		if line != "":
			rendered.append(line)
	if rendered.is_empty():
		return ""

	var dropped := 0
	if rendered.size() > SCENE_RENDER_MAX_LINES:
		dropped = rendered.size() - SCENE_RENDER_MAX_LINES
		rendered = rendered.slice(dropped)

	var others := []
	for other in attendees:
		if other != id:
			others.append(String(_gm.get_character(other).get("name", "")))

	var text := "[THE HALL - you are in a group conversation."
	if others.is_empty():
		text += " Everyone else has left; only the detective is still with you.]\n"
	else:
		text += " Also present: %s.\n" % _join_names(others)
	text += "DETECTIVE is the person questioning you. GUEST lines are other guests in this room, "
	text += "never the detective. YOU lines are your own words, said out loud in front of everyone.]\n"
	if dropped > 0:
		text += "Earlier, %d line(s) not repeated. Most recently:\n" % dropped
	else:
		text += "Said in this room so far:\n"
	for line in rendered:
		text += "  %s\n" % line
	return text


## Writes the ONE thing a Hall meetup leaves behind in a suspect's permanent
## memory: a digest of what they committed to in public, what was said about
## them, and an explicit marker that the room has emptied.
##
## The end-of-scene marker matters more than it looks. Everything a suspect is
## told arrives with role "user" - the detective's questions AND every other
## guest's line, since there's no third role to put them in. Without something
## saying where the scene stopped, the next private question looks like more of
## the same and the model starts addressing the detective by another guest's
## name.
##
## The digest matters for a different reason: it is what makes the confrontation
## still count an hour later. A suspect who insisted on something in front of
## witnesses should not be able to quietly drop it once the room clears, and the
## detective should be able to press them on it privately afterwards.
func _note_scene_ended(id: String) -> void:
	if _gm == null:
		return

	var limit := _heard_upto(id)
	var mine := []
	var theirs := []
	for i in range(min(limit, scene_log.size())):
		var e: Dictionary = scene_log[i]
		if String(e["kind"]) != "say":
			continue
		var speaker := String(e["speaker_id"])
		if speaker == id:
			mine.append(String(e["text"]))
		elif speaker != "":
			var who := String(_gm.get_character(speaker).get("name", "someone"))
			theirs.append("%s said: \"%s\"" % [who, _gm._condense(String(e["text"]))])

	var present := []
	for other in attendees:
		if other != id:
			present.append(String(_gm.get_character(other).get("name", "")))

	var text := "[THE GATHERING IN THE HALL IS OVER."
	if not present.is_empty():
		text += " You were questioned in front of %s.]" % _join_names(present)
	else:
		text += "]"
	text += "\n"

	if not mine.is_empty():
		if mine.size() > DIGEST_OWN_LINES:
			mine = mine.slice(mine.size() - DIGEST_OWN_LINES)
		text += "What YOU said out loud, in front of them - these are your own words and they still stand:\n"
		for line in mine:
			text += "  - \"%s\"\n" % _gm._condense(line)
	if not theirs.is_empty():
		if theirs.size() > DIGEST_OTHER_LINES:
			theirs = theirs.slice(theirs.size() - DIGEST_OTHER_LINES)
		text += "What the others said while you were standing there:\n"
		for line in theirs:
			text += "  - %s\n" % line

	text += "The other guests have left and gone back to their own rooms. You are alone with the "
	text += "detective again. Everything said to you from this point on is the detective speaking to you "
	text += "privately - no other guest is present, and nothing you are told now comes from one of them. "
	text += "Never address the detective by another guest's name, and do not reply to the other guests: "
	text += "they cannot hear you."

	_gm.note_to_character(id, text)


## The standing instruction for how to behave in a confrontation. This is what
## actually produces suspects turning on each other - left to itself a small
## model has everyone in the room politely agree.
##
## Rendered into each turn prompt rather than written once into memory. Written
## once, it sat further and further back in the context as the scene went on,
## precisely as the scene got heated enough to need it; and it accumulated a
## fresh permanent copy every time a new meetup opened.
func _group_role_instruction(id: String) -> String:
	var present := _join_names(_display_names(attendees))
	var text := "[GROUP SCENE - the Hall] The detective has gathered several guests together in the hall. "
	text += "Present with you: %s. " % present
	text += "You are all speaking out loud, in front of each other - anything you say here is heard by everyone in the room. "
	if id == _gm.murderer_id:
		text += "Attention on you is dangerous. You may deflect suspicion onto someone else, question another guest's "
		text += "account of the evening, or point out inconsistencies in what they say - but never confess."
	else:
		text += "If another guest says something you know to be false, or that contradicts what they said earlier, "
		text += "say so plainly and in front of everyone."
	return text + "\n\n"


# --------------------------------------------------------- floor control --
# Who is allowed to speak. None of these send anything to the model - they only
# change who the next round will call on, and drop a stage direction into the
# log. Main drives them from both typed commands and the roster buttons, so the
# two are always equivalent.

func is_muted(id: String) -> bool:
	return muted.has(id)


## The attendees currently free to answer, in seating order.
func speakers() -> Array:
	var out := []
	for id in attendees:
		if not muted.has(id):
			out.append(id)
	return out


## Silences or un-silences one suspect. `announce` is false when the caller is
## about to log something better itself - e.g. "Marcus, go ahead" reads fine as
## the detective's line followed by Marcus answering, without a redundant
## "Marcus is free to speak again." in between.
func set_muted(id: String, silent: bool, announce: bool = true) -> void:
	if not active or not attendees.has(id):
		return
	if silent == muted.has(id):
		return
	var short := _short_name(id)
	if silent:
		muted[id] = true
		if announce:
			_add_line("", "%s falls silent." % short, "stage")
	else:
		muted.erase(id)
		if announce:
			_add_line("", "%s is free to speak again." % short, "stage")
	roster_changed.emit()


## Silences the whole room, optionally leaving one suspect the floor.
func silence_all(except_id: String = "") -> void:
	if not active:
		return
	muted.clear()
	for id in attendees:
		if id != except_id:
			muted[id] = true
	if except_id != "" and attendees.has(except_id):
		_add_line("", "The room goes quiet - only %s may speak." % _short_name(except_id), "stage")
	else:
		_add_line("", "The room falls silent.", "stage")
	roster_changed.emit()


func allow_all() -> void:
	if not active:
		return
	muted.clear()
	_add_line("", "You let the room speak freely again.", "stage")
	roster_changed.emit()


## Removes a suspect from the confrontation. Main handles actually walking them
## out of the Hall; this just drops them from the guest list. Returns false if
## they weren't an attendee.
func dismiss(id: String) -> bool:
	if not active or not attendees.has(id):
		return false
	# Freeze what they heard at the moment they walked out, before the exit line
	# and anything the remaining guests go on to say. Someone sent out of the
	# room should not remember being talked about behind their back.
	_left_at[id] = scene_log.size()
	attendees.erase(id)
	muted.erase(id)
	_queue.erase(id)
	if _round_start >= attendees.size():
		_round_start = 0
	_add_line("", "%s leaves the hall." % _short_name(id), "stage")
	_note_scene_ended(id)
	roster_changed.emit()

	# Sending someone out while the room is waiting on their answer: discard
	# that answer and carry on down the queue, rather than having a line
	# arrive from someone who has already walked out.
	if _speaking_id == id:
		_speaking_id = ""
		_pending_token = -1
		_next_turn()

	_check_quorum()
	return true


## Ends the confrontation by sending everyone out at once. Returns the ids that
## were dismissed so the caller can actually walk them out of the room - this
## only clears the guest list. Done in one shot rather than by looping dismiss()
## so the log reads as one exit rather than a countdown with a stray "only
## Evelyn is left" in the middle of it.
func dismiss_all() -> Array:
	if not active:
		return []
	var leaving: Array = attendees.duplicate()
	if leaving.is_empty():
		return []
	for id in leaving:
		_note_scene_ended(String(id))
	attendees.clear()
	muted.clear()
	_queue.clear()
	_round_start = 0
	_speaking_id = ""
	_pending_token = -1
	_add_line("", "The guests file out of the hall.", "stage")
	roster_changed.emit()
	quorum_lost.emit(0)
	return leaving


## A confrontation needs at least two people to confront each other. Dropping
## below that isn't an error - it just quietly stops being a group scene, and
## the detective should be told rather than left wondering why nobody argues.
func _check_quorum() -> void:
	if not active or attendees.size() >= 2:
		return
	if attendees.size() == 1:
		_add_line("", "Only %s is left in the hall - you're speaking privately now." % _short_name(String(attendees[0])), "stage")
	else:
		_add_line("", "The hall is empty.", "stage")
	quorum_lost.emit(attendees.size())


## Echoes an order the detective typed (mute, dismiss, ...) into the log so
## they can see what they typed. Logged as "command" rather than "say" so it
## never reaches the model - these are stage directions to the player, not
## things the suspects need to reason about.
func log_player_command(text: String) -> void:
	_add_line("", text, "command")


# ---------------------------------------------------------------- the turn --

## The detective says something to the room. This is the only entry point that
## can start a round of replies.
##
## If `direct_id` is set, only that suspect answers this round - and being
## addressed by name un-mutes them, since telling someone to shut up and then
## asking them a direct question should obviously get an answer.
func submit_player_line(raw: String, direct_id: String = "") -> void:
	if not active or state != "awaiting_player":
		return
	var text := raw.strip_edges()
	if text == "":
		return

	if direct_id != "" and not attendees.has(direct_id):
		direct_id = ""
	if direct_id != "" and muted.has(direct_id):
		muted.erase(direct_id)
		roster_changed.emit()

	# A bracketed action is something the detective DOES, not something they
	# say. Quoting it as speech is what used to make suspects respond to the
	# literal words "(I give Tom a high five)" - or, following the
	# don't-play-along rule in _build_turn_prompt(), flatly deny it happened.
	var parts: Dictionary = _gm.parse_stage_action(text)
	_last_player_action = String(parts["action"])
	_last_player_speech = String(parts["speech"])
	# "()" and friends parse to nothing at all. Bail before _begin_round(),
	# which would otherwise spend one Ollama request per attendee having them
	# react to silence.
	if _last_player_action == "" and _last_player_speech == "":
		return
	_last_player_line = text

	# Everything from here on belongs to the round that is about to start, and is
	# shown at the END of each turn prompt rather than in the room transcript.
	_round_log_start = scene_log.size()

	if _last_player_action != "":
		_add_line("", _last_player_action, "action")
	if _last_player_speech != "":
		_add_line("", _last_player_speech, "say")

	# Everyone present hears the detective, including anyone who won't reply this
	# round - being silenced doesn't make you deaf. Nothing needs broadcasting to
	# make that true any more: the two _add_line() calls above put it in
	# scene_log, and _render_scene_for() reads the whole room out of scene_log on
	# each attendee's turn. A muted suspect is therefore deaf to nothing.

	_begin_round(direct_id)


## Builds this round's speaking order: every un-muted attendee once, rotated by
## one each round so the same suspect isn't always first to answer (whoever
## speaks first shapes the whole round, so a fixed order would quietly make
## one suspect the room's spokesperson). A direct address collapses the round
## to the one suspect who was named.
func _begin_round(direct_id: String = "") -> void:
	_queue.clear()
	_round_replies.clear()
	_direct_round = direct_id != ""

	if _direct_round:
		_queue.append(direct_id)
	else:
		var n := attendees.size()
		if n > 0:
			for i in range(n):
				var id := String(attendees[(_round_start + i) % n])
				if not muted.has(id):
					_queue.append(id)
			_round_start = (_round_start + 1) % n

	if _queue.is_empty():
		_add_line("", "No one answers - you've told them all to keep quiet.", "stage")
		_set_state("awaiting_player")
		return

	_set_state("responding")
	_next_turn()


func _next_turn() -> void:
	if not active:
		return
	if _queue.is_empty():
		_speaking_id = ""
		_direct_round = false
		_set_state("awaiting_player")
		return

	var id := String(_queue.pop_front())
	# A suspect who left the Hall (or was never valid) forfeits their turn
	# rather than stalling the round. Silencing someone mid-round takes effect
	# immediately for the same reason - "be quiet" should mean now, not next
	# time round. A direct address ignores the mute list by design.
	if not attendees.has(id) or _gm.get_character(id).is_empty():
		_next_turn()
		return
	if muted.has(id) and not _direct_round:
		_next_turn()
		return

	_speaking_id = id
	turn_started.emit(id)
	# Witnesses are everyone else in the room right now, muted or not - being
	# told to keep quiet doesn't stop you being a witness to what was said.
	var witnesses := []
	for other in attendees:
		if other != id:
			witnesses.append(other)
	_next_token += 1
	_pending_token = _next_token
	_gm.ask_group_member(id, _build_turn_prompt(id), _last_player_line, witnesses, _pending_token)


## The whole of one attendee's turn: the standing group-scene instruction, their
## own account, everything the room has said, and finally the detective's line.
## Ephemeral - GameManager sends it and never stores it.
##
## It now carries the scene itself, which it did not used to. Previously each
## line was written permanently into every attendee's history as it happened;
## rendering it here instead keeps stored memory small, keeps the volatile text
## at the end of the prompt where it doesn't invalidate the cached prefix, and
## stops repeat meetups piling up in everyone's memory. See the note above
## _left_at for the full reasoning.
##
## Order here is the whole point, and it is easy to get backwards.
##
## Reference material (their own past claims) goes FIRST; the question they
## have to answer goes LAST, immediately before generation. An earlier version
## had it the other way round - the recap was appended at the end to keep their
## story in view - and the result was suspects who answered a question nobody
## asked and repeated their previous line word for word. They weren't
## forgetting anything: the last thing they read was their own prior answer, so
## that is what they produced again. Whatever sits closest to the generation
## point is what gets answered, so the detective's line must be closest.
func _build_turn_prompt(id: String) -> String:
	var c: Dictionary = _gm.get_character(id)
	var text := ""

	# How to behave in a confrontation. Re-stated every turn rather than primed
	# once at the start of the scene, so it doesn't recede into the distance
	# exactly as the argument gets heated enough to need it.
	text += _group_role_instruction(id)

	# Their movements, replayed at the generation point. It is already in their
	# system prompt, but by the third round of a meetup that prompt is a dozen
	# messages back behind everyone else's chatter, and generation is dominated
	# by what's nearest - so a suspect drifts off the account they gave an hour
	# ago without ever noticing. A confrontation is precisely where drifting is
	# fatal: the murderer is supposed to be the only one whose story moves.
	var account: String = _gm.evening_account(id)
	if account != "":
		text += "[WHERE YOU WERE LAST NIGHT - your account, unchanged]\n"
		text += account
		text += "\n"

	# What they told the detective privately, before this scene. Kept at the top
	# as background they must not contradict, not as the thing to respond to.
	# Their public lines from THIS scene are no longer duplicated here - they
	# appear in the room transcript below, labelled "YOU said", which is both
	# fewer tokens and a truer account of the order things happened in.
	var recap: String = _gm.private_recap(id)
	if recap != "":
		text += "[YOUR OWN ACCOUNT SO FAR - background only, not the question]\n"
		text += "Told to the detective in private:\n" + recap
		# These two rules have to be separated carefully or they fight, and the
		# model resolves the fight in the worst possible way.
		#
		# "Do not contradict this" + "what you say next must be new" reads as
		# permission - even pressure - to invent a NEW ACCOUNT. Observed live:
		# a suspect's alibi went garden walk, garden walk, "I never said that",
		# asleep in my room. She was obeying "say something new".
		#
		# So the novelty rule must be scoped explicitly to WORDING, and the
		# consistency rule to SUBSTANCE.
		text += "Those are your own words and they still stand. Never reverse, deny, or replace "
		text += "an account you have already given - if you are challenged about it, hold to it. "
		text += "You may add new detail or say it a different way; just do not repeat a line "
		text += "word for word.\n\n"

	# The room itself, as this character heard it.
	var scene: String = _render_scene_for(id)
	if scene != "":
		text += scene
		text += "Anything above marked YOU said is your own words, in front of witnesses - they still "
		text += "stand, and you must not reverse or deny them. Do not repeat a line word for word.\n\n"

	var here := _display_names(attendees)
	text += "You are %s. Reply out loud to the room in ONE short line of 1 to 2 sentences. " % String(c.get("name", ""))
	# The one-on-one prompt has carried this instruction for a while; the group
	# prompt never did, which left the token cap as the only thing bounding
	# length - and a cap can only ever truncate mid-word. Asking the model to
	# land the sentence itself is what actually fixes a clipped line; the
	# raised GROUP_MAX_TOKENS is just the headroom to do it in.
	text += "Always finish your sentence - if you are running long, close it off in the next "
	text += "few words rather than trailing off mid-thought. "
	text += "You may disagree with what another guest just said, or call them out if you believe they "
	text += "are lying. "
	# The whole reason a meetup is worth the extra requests: an innocent who
	# knows for a fact where they were is the mechanism that catches the one
	# person whose account is false. Left unprompted they politely let it pass.
	text += "In particular, if another guest claims to have been somewhere you were yourself and you did "
	text += "not see them there, SAY SO plainly and immediately - that is exactly the kind of thing you "
	text += "would notice and speak up about. "
	text += "Only refer to things you actually remember - if the detective CLAIMS some earlier "
	text += "event that you have no memory of, say so plainly rather than playing along. "
	# That guard is why a bracketed action used to fail here and not in a
	# private interview: a high five is, strictly, "an event you have no memory
	# of". It has to be scoped to claims about the past, or it correctly
	# rejects things that are genuinely happening in the room.
	text += "That applies to the PAST only - anything shown to you below as something the detective is "
	text += "DOING is happening right now in front of you and really is happening, so react to it and "
	text += "never deny it or ask whether it took place. "
	# The detective can address someone who isn't here, either by mistake or to
	# see what happens. Left unguarded, everyone invents that person's
	# whereabouts and testimony out of nothing.
	text += "The only people in this room are %s and the detective. " % _join_names(here)
	text += "If the detective names anyone else, say that person is not here - never answer for them "
	text += "and never claim to have heard them speak. "
	text += "Do not use asterisks, do not wrap your reply in quotation marks, "
	text += "do not speak for anyone else, and do not write your own name before your line. "
	# Asterisks stay banned - small models spray them everywhere and they read
	# as formatting noise - but a short bracketed gesture is worth allowing, so
	# a suspect can return a handshake instead of only describing one.
	text += "You may add ONE short physical action of your own in round brackets, like (nods) or "
	text += "(pushes the glass away) - a few words at most, with the rest of your line spoken.\n\n"

	text += "-----\n"
	if _last_player_speech == "" and _last_player_action == "":
		return text + "The room is waiting. Speak now."

	if _last_player_action != "":
		text += "THE DETECTIVE HAS JUST DONE THIS, IN FRONT OF YOU - it really happened, just now: %s\n\n" % _last_player_action

	if _last_player_speech != "":
		if _direct_round:
			text += "THE DETECTIVE HAS JUST ASKED YOU DIRECTLY: \"%s\"\n\n" % _last_player_speech
		else:
			text += "THE DETECTIVE HAS JUST ASKED THE ROOM: \"%s\"\n\n" % _last_player_speech

	# Exactly who has answered this question so far, so nobody has to guess.
	if _round_replies.is_empty():
		text += "Nobody has reacted yet - you are the first to speak. Do not refer to what "
		text += "anyone else said about this; they have not said anything yet.\n\n"
	else:
		text += "Already reacted since the detective spoke:\n"
		for r in _round_replies:
			text += "  %s said: \"%s\"\n" % [_speaker_label(String(r["id"])), String(r["text"])]
		text += "Those are the only replies so far. Do not invent anything else anyone said.\n\n"

	if _last_player_speech != "":
		text += "Answer the detective's question now, in your own words."
	else:
		text += "React to what the detective just did, in one short line, in your own words."
	return text


# ------------------------------------------------------ response handling --
# Connected to GameManager.group_response / group_error from GameManager._ready().

func _on_group_response(character_id: String, text: String, token: int) -> void:
	if not active or token != _pending_token or character_id != _speaking_id:
		return
	_pending_token = -1
	_speaking_id = ""
	# Everyone else in the room heard it, whether or not they reply this round.
	# One _add_line() is all that takes now: it lands in scene_log, and
	# _render_scene_for() reads each attendee's view out of scene_log on their
	# turn - including splitting a bracketed gesture out as something they SAW
	# rather than words they heard.
	_add_line(character_id, text, "say")
	_round_replies.append({"id": character_id, "text": text})

	_next_turn()


func _on_group_error(character_id: String, message: String, token: int) -> void:
	if not active or token != _pending_token or character_id != _speaking_id:
		return
	_pending_token = -1
	_speaking_id = ""
	# Drop the rest of the round rather than firing the remaining requests into
	# what is almost certainly the same failure, and hand control back.
	_queue.clear()
	_direct_round = false
	_add_line("", "The room falls silent - something went wrong.", "stage")
	_set_state("awaiting_player")
	round_failed.emit(message)


# ------------------------------------------------------------------ helpers --

func _add_line(speaker_id: String, text: String, kind: String) -> void:
	var entry := {"speaker_id": speaker_id, "text": text, "kind": kind}
	scene_log.append(entry)
	line_added.emit(entry)


func _set_state(new_state: String) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(state)


func _short_name(id: String) -> String:
	return String(_gm.get_character(id).get("short", "They"))


func _speaker_label(speaker_id: String) -> String:
	if speaker_id == "":
		return "Detective"
	return String(_gm.get_character(speaker_id).get("name", "Someone"))


func _display_names(ids: Array) -> Array:
	var out := []
	for id in ids:
		out.append(String(_gm.get_character(id).get("name", "")))
	return out


## "Evelyn, Marcus and Eleanor" - reads better than a bare comma list in both
## the on-screen stage direction and the priming prompt.
func _join_names(names: Array) -> String:
	if names.is_empty():
		return "No one"
	if names.size() == 1:
		return String(names[0])
	var head: Array = names.slice(0, names.size() - 1)
	return "%s and %s" % [", ".join(PackedStringArray(head)), String(names[names.size() - 1])]
