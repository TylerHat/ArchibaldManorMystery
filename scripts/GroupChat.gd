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

## How many of the most recent lines get replayed into a suspect's turn prompt
## for immediate salience. The full scene is already in their private history
## (see GameManager.note_to_character), so this is about what's freshest in
## mind, not about what they know.
const RECENT_CONTEXT_LINES := 4

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

var active: bool = false
var attendees: Array = [] # character_ids, snapshotted when the scene opens
var scene_log: Array = [] # [{speaker_id, text, kind}]
var state: String = "idle" # idle | awaiting_player | responding

var _queue: Array = [] # ids still owed a turn this round
var _speaking_id: String = "" # whose turn is currently in flight ("" if none)
var _round_start: int = 0 # rotates each round so the same suspect doesn't always open
var _gm: Node = null


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
	_queue.clear()
	_speaking_id = ""
	_round_start = 0
	active = true

	_prime_attendees()

	var names := _display_names(attendees)
	_add_line("", "%s are gathered in the hall, waiting for you to speak." % _join_names(names), "stage")
	_set_state("awaiting_player")


## Ends the confrontation. Safe to call when no session is open.
func stop() -> void:
	active = false
	attendees.clear()
	_queue.clear()
	_speaking_id = ""
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


# ---------------------------------------------------------------- the turn --

## The detective says something to the room. This is the only entry point that
## can start a round of replies.
func submit_player_line(raw: String) -> void:
	if not active or state != "awaiting_player":
		return
	var text := raw.strip_edges()
	if text == "":
		return

	_add_line("", text, "say")
	# Everyone present hears the detective, including anyone who won't reply
	# this round.
	for id in attendees:
		_gm.note_to_character(id, "[In the hall] The detective says to the room: \"%s\"" % text)

	_begin_round()


## Builds this round's speaking order: every attendee once, rotated by one
## each round so the same suspect isn't always first to answer (whoever
## speaks first shapes the whole round, so a fixed order would quietly make
## one suspect the room's spokesperson).
func _begin_round() -> void:
	_queue.clear()
	var n := attendees.size()
	if n == 0:
		_set_state("awaiting_player")
		return
	for i in range(n):
		_queue.append(attendees[(_round_start + i) % n])
	_round_start = (_round_start + 1) % n
	_set_state("responding")
	_next_turn()


func _next_turn() -> void:
	if not active:
		return
	if _queue.is_empty():
		_speaking_id = ""
		_set_state("awaiting_player")
		return

	var id := String(_queue.pop_front())
	# A suspect who left the Hall (or was never valid) forfeits their turn
	# rather than stalling the round.
	if not attendees.has(id) or _gm.get_character(id).is_empty():
		_next_turn()
		return

	_speaking_id = id
	turn_started.emit(id)
	_gm.ask_group_member(id, _build_turn_prompt(id))


func _build_turn_prompt(id: String) -> String:
	var c: Dictionary = _gm.get_character(id)
	var text := "[The hall is waiting for you.]\n"

	var recent := _recent_spoken_lines()
	if not recent.is_empty():
		text += "Just said out loud:\n"
		for e in recent:
			text += "%s: %s\n" % [_speaker_label(e["speaker_id"]), e["text"]]
		text += "\n"

	text += "You are %s. Say ONE short line out loud to the room - 1 to 2 sentences. " % String(c.get("name", ""))
	text += "Answer the detective, respond to what someone just said, disagree with them, "
	text += "or call someone out if you believe they are lying. "
	text += "Do not narrate actions. Do not speak for anyone else. Do not write your own name before your line."
	return text


## The last few genuinely spoken lines, oldest first - stage directions are
## skipped since they're UI flavor, not something anyone in the room heard.
func _recent_spoken_lines() -> Array:
	var spoken := []
	for e in scene_log:
		if e["kind"] == "say":
			spoken.append(e)
	if spoken.size() <= RECENT_CONTEXT_LINES:
		return spoken
	return spoken.slice(spoken.size() - RECENT_CONTEXT_LINES)


# ------------------------------------------------------ response handling --
# Connected to GameManager.group_response / group_error from GameManager._ready().

func _on_group_response(character_id: String, text: String) -> void:
	if not active or character_id != _speaking_id:
		return
	_speaking_id = ""
	_add_line(character_id, text, "say")

	# Everyone else in the room heard it, whether or not they reply this round.
	var c: Dictionary = _gm.get_character(character_id)
	var heard := "[In the hall] %s said out loud: \"%s\"" % [String(c.get("name", "")), text]
	for other in attendees:
		if other != character_id:
			_gm.note_to_character(other, heard)

	_next_turn()


func _on_group_error(character_id: String, message: String) -> void:
	if not active or character_id != _speaking_id:
		return
	_speaking_id = ""
	# Drop the rest of the round rather than firing the remaining requests into
	# what is almost certainly the same failure, and hand control back.
	_queue.clear()
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
