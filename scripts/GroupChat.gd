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
## `entry` is {speaker_id, text, kind}; speaker_id "" means the detective, and
## kind is "say" for spoken lines or "stage" for italic narration.
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

## How many of a suspect's own lines from the current scene get replayed into
## their turn prompt so they don't contradict themselves mid-confrontation.
const OWN_LINE_RECAP := 3

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
var _last_player_line: String = "" # what the detective last said aloud, for transcript entries
var _gm: Node = null

## Every request gets a unique token; only a reply carrying the token we're
## currently waiting on is accepted. Requests already in Ollama's queue can't
## be cancelled, so this is how a reply from a closed scene - or from a suspect
## who has since been sent out of the room - gets dropped. GameManager still
## records it into that suspect's memory and the transcript either way; it just
## never reaches the room.
var _next_token: int = 0
var _pending_token: int = -1 # -1 means "not waiting on anything"


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
	_queue.clear()
	_speaking_id = ""
	_round_start = 0
	_direct_round = false
	_last_player_line = ""
	_pending_token = -1
	active = true

	_prime_attendees()

	var names := _display_names(attendees)
	_add_line("", "%s are gathered in the hall, waiting for you to speak." % _join_names(names), "stage")
	_add_line("", "Speak to the room, or start with a name to address one of them. \"Marcus, be quiet\" silences someone; \"Marcus, go ahead\" gives them the floor.", "stage")
	_set_state("awaiting_player")


## Ends the confrontation. Safe to call when no session is open.
func stop() -> void:
	active = false
	attendees.clear()
	muted.clear()
	_queue.clear()
	_speaking_id = ""
	_direct_round = false
	# Anything still in flight belongs to a scene that no longer exists.
	_pending_token = -1
	_set_state("idle")


## Appends the one-time group-scene instruction to each attendee's private
## memory. This is what actually produces suspects turning on each other -
## left to itself a small model has everyone in the room politely agree.
func _prime_attendees() -> void:
	if _gm == null:
		return
	var present := _join_names(_display_names(attendees))
	for id in attendees:
		var text := "[GROUP SCENE - the Hall] The detective has gathered several guests together in the hall. "
		text += "Present with you: %s. " % present
		text += "You are all speaking out loud, in front of each other - anything you say here is heard by everyone in the room. "
		if id == _gm.murderer_id:
			text += "Attention on you is dangerous. You may deflect suspicion onto someone else, question another guest's "
			text += "account of the evening, or point out inconsistencies in what they say - but never confess."
		else:
			text += "If another guest says something you know to be false, or that contradicts what they said earlier, "
			text += "say so plainly and in front of everyone."
		_gm.note_to_character(id, text)


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
	attendees.erase(id)
	muted.erase(id)
	_queue.erase(id)
	if _round_start >= attendees.size():
		_round_start = 0
	_add_line("", "%s leaves the hall." % _short_name(id), "stage")
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

	_add_line("", text, "say")
	_last_player_line = text
	# Everyone present hears the detective, including anyone who won't reply
	# this round - being silenced doesn't make you deaf.
	var heard := "[In the hall] The detective says to the room: \"%s\"" % text
	if direct_id != "":
		heard = "[In the hall] The detective says to %s: \"%s\"" % [_speaker_label(direct_id), text]
	for id in attendees:
		_gm.note_to_character(id, heard)

	_begin_round(direct_id)


## Builds this round's speaking order: every un-muted attendee once, rotated by
## one each round so the same suspect isn't always first to answer (whoever
## speaks first shapes the whole round, so a fixed order would quietly make
## one suspect the room's spokesperson). A direct address collapses the round
## to the one suspect who was named.
func _begin_round(direct_id: String = "") -> void:
	_queue.clear()
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


## The instruction handed to one attendee when it's their turn. Deliberately
## short and content-free: what was just said in the room is already sitting in
## their history as notes (see GameManager.note_to_character), immediately
## before this, so repeating it here would both waste context and duplicate the
## conversation. This prompt is ephemeral - GameManager sends it but never
## stores it.
func _build_turn_prompt(id: String) -> String:
	var c: Dictionary = _gm.get_character(id)
	var text := "[The hall is waiting for you to answer.]\n"

	# Their own earlier account, replayed here rather than left buried under
	# everyone else's hall chatter. This is the difference between a suspect who
	# holds their story under pressure and one who quietly drifts off it.
	var recap: String = _gm.private_recap(id)
	if recap != "":
		text += "\nWhat you have already told the detective in private:\n"
		text += recap

	# And what they've said in THIS room, in this scene. Just as important:
	# without it a suspect will cheerfully contradict a line they gave two
	# turns ago, because by then it's several messages back behind three other
	# people talking. Their own words are the last thing they should be losing
	# track of.
	var said: String = _own_recent_lines(id)
	if said != "":
		text += "\nWhat you have already said out loud in this room:\n"
		text += said

	if recap != "" or said != "":
		text += "All of the above is your own account. Stay consistent with it - do not deny or "
		text += "reword something you already said. If someone in this room contradicts it, challenge them.\n"

	text += "\nYou are %s. Say ONE short line out loud to the room - 1 to 2 sentences. " % String(c.get("name", ""))
	text += "Answer the detective, respond to what someone just said, disagree with them, "
	text += "or call someone out if you believe they are lying. "
	text += "Only refer to things you actually remember - if the detective describes an event you have "
	text += "no memory of, say so plainly rather than playing along. "
	text += "Do not narrate actions. Do not speak for anyone else. Do not write your own name before your line."
	return text


## This suspect's own spoken lines from the current scene, oldest first, capped
## to the most recent few. Pulled from scene_log rather than the transcript
## because it's already scene-scoped - what they said in a meetup an hour ago
## isn't what they're at risk of contradicting right now.
func _own_recent_lines(id: String) -> String:
	var mine := []
	for e in scene_log:
		if e["kind"] == "say" and String(e["speaker_id"]) == id:
			mine.append(String(e["text"]))
	if mine.is_empty():
		return ""
	if mine.size() > OWN_LINE_RECAP:
		mine = mine.slice(mine.size() - OWN_LINE_RECAP)
	var out := ""
	for line in mine:
		out += "- %s\n" % line
	return out


# ------------------------------------------------------ response handling --
# Connected to GameManager.group_response / group_error from GameManager._ready().

func _on_group_response(character_id: String, text: String, token: int) -> void:
	if not active or token != _pending_token or character_id != _speaking_id:
		return
	_pending_token = -1
	_speaking_id = ""
	_add_line(character_id, text, "say")

	# Everyone else in the room heard it, whether or not they reply this round.
	var c: Dictionary = _gm.get_character(character_id)
	var heard := "[In the hall] %s said out loud: \"%s\"" % [String(c.get("name", "")), text]
	for other in attendees:
		if other != character_id:
			_gm.note_to_character(other, heard)

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
