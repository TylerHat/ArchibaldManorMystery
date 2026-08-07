extends Node
# GameManager (autoload singleton)
# Holds the 8 suspects, randomizes the murderer each playthrough, talks to a
# local Ollama server running llama3.2:3b to generate in-character responses,
# and checks the player's final accusation at the front door.

const DialogueLogScript = preload("res://Scripts/DialogueLog.gd")

const OLLAMA_URL := "http://127.0.0.1:11434/api/chat"
const OLLAMA_MODEL := "huihui_ai/llama3.2-abliterate:3b"
const MAX_RESPONSE_TOKENS := 300 # hard safety cap - the prompt aims well under this so it's rarely hit mid-sentence
const SUMMARY_MAX_TOKENS := 340 # four labeled sections need a bit more room
# Group-scene lines are capped much harder than one-on-one answers: a Hall
# meetup costs one sequential request PER attendee for every line the
# detective says, so per-reply length is the entire latency budget. Short,
# sharp interruptions are better drama than paragraphs anyway.
const GROUP_MAX_TOKENS := 90

# How much conversation the model is allowed to keep in view. This MUST be set
# explicitly: Ollama's default context is small (2048 on older builds, 4096 on
# newer ones), and when a conversation outgrows it the oldest messages are
# silently dropped. A suspect's private interview is the oldest thing in their
# history after the system prompt, so it is the first thing evicted - which is
# exactly the wrong thing to forget when you've hauled them into the hall to be
# confronted with what they told you earlier. A group scene fills the window
# several times faster than a private one, because every attendee's line is
# written into every other attendee's history.
const OLLAMA_NUM_CTX := 8192

# How much of a suspect's private interview gets replayed into their group-scene
# turn prompt. See private_recap() for why this exists at all.
const RECAP_MAX_ITEMS := 4
const RECAP_MAX_CHARS := 160

const VICTIM_NAME := "Lord Reginald Archibald"

## The forensic pathologist. She is the only character who can narrow the
## body's time of death from a 90-minute window to a single half-hour slot -
## and the only one who can lie about it convincingly. See
## CaseGenerator.expert_claim_slot().
const EXPERT_ID := "blackwood"

## Used only if CaseGenerator somehow fails to produce a case - the game falls
## back to the original fixed scenario rather than crashing. Everything real
## now comes from case_data; see CaseGenerator.gd.
const FALLBACK_MURDER_ROOM := "the Billiard Room"

const FALLBACK_WEAPONS := [
	"a silver letter opener",
	"a heavy brass candlestick",
	"an antique dueling pistol",
	"a length of garden wire",
	"a vial of poison slipped into his brandy",
]

const FALLBACK_TIMES := [
	"around 11:30 last night",
	"just before midnight",
	"in the early hours of the morning",
	"sometime after the other guests had gone to bed",
]

# The 8 suspects (from the uploaded character sheet). The player (the
# detective) is not one of these - they are the one asking the questions.
const CHARACTERS := [
	{
		"id": "blackwood",
		"name": "Dr. Evelyn Blackwood",
		"short": "Evelyn",
		"first_name": "Evelyn",
		"job": "Forensic Pathologist",
		"personality": "Calm, analytical, observant, and emotionally reserved. She notices details others miss but can come across as cold or judgmental.",
		"flavor": "Has an unsettlingly detailed knowledge of how someone could have died.",
		"room": "Library",
	},
	{
		"id": "sterling",
		"name": "Marcus Sterling",
		"short": "Marcus",
		"first_name": "Marcus",
		"job": "Investment Banker",
		"personality": "Charismatic, ambitious, competitive, and polished. He is used to getting his way and becomes defensive when questioned about money.",
		"flavor": "Recently lost a fortune - or secretly gained one.",
		"room": "Study",
	},
	{
		"id": "ashford",
		"name": "Victoria Ashford",
		"short": "Victoria",
		"first_name": "Victoria",
		"job": "Art Dealer",
		"personality": "Sophisticated, charming, and cultured, but manipulative beneath the surface. She always seems to know more than she says.",
		"flavor": "One of her prized paintings may be a forgery - or worth enough to kill for.",
		"room": "Conservatory",
	},
	{
		"id": "carter",
		"name": 'Samuel "Sam" Carter',
		"short": "Sam",
		"first_name": "Samuel",
		"job": "Private Investigator",
		"personality": "Cynical, perceptive, and suspicious of everyone. He has a dry sense of humor and rarely trusts people's motives.",
		"flavor": "Has been investigating someone in the group before the murder occurred.",
		"room": "Billiard Room",
	},
	{
		"id": "whitmore",
		"name": "Eleanor Whitmore",
		"short": "Eleanor",
		"first_name": "Eleanor",
		"job": "Political Consultant",
		"personality": "Intelligent, persuasive, and socially graceful. She is excellent at controlling conversations and deflecting uncomfortable questions.",
		"flavor": "Knows a secret that could destroy someone's career.",
		"room": "Lounge",
	},
	{
		"id": "reeves",
		"name": 'Thomas "Tom" Reeves',
		"short": "Tom",
		"first_name": "Thomas",
		"job": "Estate Manager",
		"personality": "Dependable, quiet, and seemingly loyal. He knows the property and everyone's routines better than anyone else.",
		"flavor": "His innocent appearance may hide years of resentment toward the household.",
		"room": "Dining Room",
	},
	{
		"id": "cross_natalie",
		"name": "Natalie Cross",
		"short": "Natalie",
		"first_name": "Natalie",
		"job": "Investigative Journalist",
		"personality": "Fearless, curious, and relentless. She asks uncomfortable questions and is willing to take risks to uncover the truth.",
		"flavor": "Was about to publish a story that could expose one of the other guests.",
		"room": "Ballroom",
	},
	{
		"id": "cross_eugene",
		"name": "Eugene Cross",
		"short": "Eugene",
		"first_name": "Eugene",
		"job": "Butler",
		"personality": "Stern, dependable, and quick to anger.",
		"flavor": "Rumored to be the illegitimate son of the manor's previous owner - vengeful, or simply doing his duty?",
		"room": "Kitchen",
	},
]

signal ollama_response(character_id, text)
signal ollama_error(character_id, message)
signal summary_ready(character_id, text)
signal summary_error(character_id, message)
# Group signals carry the token GroupChat tagged the request with, so a reply
# that arrives after its scene was closed (or after the turn moved on) can be
# recognised as stale and dropped instead of being spoken by someone who has
# left the room.
signal group_response(character_id, text, token)
signal group_error(character_id, message, token)

## Turn engine for Hall meetups (see Scripts/GroupChat.gd). Created as a child
## in _ready() so it rides on the same request queue as everything else.
var group_chat: Node = null

## When true, every group-scene request prints the exact message list it's
## sending to the Godot console. Toggled with Ctrl+2 in-game. Worth reaching for
## whenever a suspect seems to have forgotten something - it shows at a glance
## whether the information is missing from the payload (a bug) or present but
## buried far from the generation point (a prompting problem). Testing aid only.
var debug_dump_group: bool = false

## Testing aid, toggled on the suspect-selection screen. When on, every line
## any suspect says is written to a markdown file (see Scripts/DialogueLog.gd)
## for reviewing hallucinations afterwards. The whole file is rewritten on each
## new line rather than appended to, so it's always complete even if the game
## is closed mid-session - the transcript is small enough that the cost doesn't
## matter next to an Ollama round-trip.
var dialogue_log_enabled: bool = false
var dialogue_log_path: String = "" # res:// or user:// path for this session, "" when off

## Seed for this playthrough's case. Set from the selection screen to replay a
## specific mystery; 0 means "pick a fresh one". Kept small (under a million)
## purely so the shareable code is short enough to read aloud or type from a
## screenshot - a million cases per cast is far more than anyone will play.
const MAX_SEED := 1000000
var case_seed: int = 0
var requested_seed: int = 0 # 0 = generate a new one

var murderer_id: String = ""
var murder_weapon: String = ""
var murder_time: String = ""
var murder_room: String = "" # "the Conservatory" - includes the article

## Everything the detective has examined at (or around) the crime scene, in the
## order they found it: [{id, title, text}]. Deduplicated by id, so walking
## back over the body doesn't fill the notes with copies.
var evidence_found: Array = []

## The full generated case for this playthrough: schedules for every suspect
## and the victim, the weapon and its home room, the murderer's lie and who can
## disprove it. See CaseGenerator.generate() for the shape. Empty only if
## generation failed and the fallback scenario is in use.
var case_data: Dictionary = {}

## Every line a suspect has given the detective, in the order it happened.
## Entries are {character_id, question, answer}; lines spoken during a Hall
## meetup add two more keys:
##   "scene": "group"   - said out loud in front of other suspects
##   "heard_by": [ids]  - who else was in the room at the time
## One-on-one entries simply omit both, so anything reading this array can
## treat a missing "scene" as a private interview.
var transcript: Array = []

# Which of the 8 CHARACTERS are actually in the mansion this game, chosen on
# the pre-game selection screen. Defaults to all 8 if start_new_game() is
# ever called without an explicit list (e.g. old save/dev code paths).
var active_character_ids: Array = []

var _histories: Dictionary = {} # character_id -> Array[{role, content}] (in-character roleplay memory)
var _summaries: Dictionary = {} # character_id -> {timeline, motive, slipups} (empty {} = none yet / parse failed)
var _summarized_at: Dictionary = {} # character_id -> transcript entry count included in that summary

# A tiny request queue sits in front of the single HTTPRequest node, since
# Ollama/HTTPRequest can only have one request in flight at a time. Both
# in-character dialogue (ask_character) and case-notes summarization
# (request_summary) go through this same queue so they never collide - a
# summary request will simply wait its turn behind a dialogue request, or
# vice versa.
var _request_queue: Array = [] # [{kind, character_id, body, ...}]
var _busy: bool = false
var _current_request: Dictionary = {}
var _http: HTTPRequest


func _ready() -> void:
	_setup_input_map()
	_http = HTTPRequest.new()
	_http.use_threads = true
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)

	group_chat = load("res://Scripts/GroupChat.gd").new()
	group_chat.name = "GroupChat"
	add_child(group_chat)
	# Connected from this side rather than inside GroupChat._ready(), which runs
	# before the GameManager autoload name is resolvable.
	group_response.connect(group_chat._on_group_response)
	group_error.connect(group_chat._on_group_error)


func _setup_input_map() -> void:
	_add_key_action("move_forward", KEY_W)
	_add_key_action("move_back", KEY_S)
	_add_key_action("move_left", KEY_A)
	_add_key_action("move_right", KEY_D)
	_add_key_action("interact", KEY_E)
	_add_key_action("toggle_notes", KEY_TAB)
	_add_key_action("jump", KEY_SPACE)
	# Ctrl-modified so they can't be hit by accident, and so the plain number
	# keys stay free for anything later.
	_add_key_action("toggle_debug", KEY_1, true)
	_add_key_action("toggle_prompt_dump", KEY_2, true)


func _add_key_action(action_name: String, keycode: int, ctrl: bool = false) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	if InputMap.action_get_events(action_name).is_empty():
		var ev := InputEventKey.new()
		ev.physical_keycode = keycode
		ev.ctrl_pressed = ctrl
		InputMap.action_add_event(action_name, ev)


## Call this once when a fresh game (or a restart) begins. `character_ids` is
## the list of suspect ids chosen on the pre-game selection screen (2-8 of
## them); if left empty, all 8 CHARACTERS are used. Picks a new random
## murderer from among only the active suspects, and resets every active
## character's conversation memory.
func start_new_game(character_ids: Array = []) -> void:
	randomize()
	if character_ids.is_empty():
		active_character_ids = []
		for c in CHARACTERS:
			active_character_ids.append(c["id"])
	else:
		active_character_ids = character_ids.duplicate()

	var pool := active_characters()

	# The whole case - who, where, when, with what, and every suspect's
	# movements through the evening - comes from CaseGenerator now. See
	# PLAN_ProceduralCases.md; run Scenes/CaseGeneratorTest.tscn to validate it
	# in bulk. Falling back to the old fixed scenario if generation somehow
	# fails is deliberate: a broken case should degrade to a playable game
	# rather than a crash.
	var ids := []
	for c in pool:
		ids.append(String(c["id"]))

	# Same seed + same cast = the same mystery, because the generator draws
	# every decision from this one RNG. The cast is part of it: change who's in
	# the house and the same seed produces something different, which is why
	# the shareable code carries both (see case_code()).
	case_seed = requested_seed if requested_seed > 0 else (randi() % MAX_SEED) + 1
	requested_seed = 0 # one-shot; a later restart re-rolls unless asked again
	var rng := RandomNumberGenerator.new()
	rng.seed = case_seed
	case_data = CaseGenerator.generate(ids, rng)

	if case_data.is_empty():
		push_warning("CaseGenerator failed - falling back to the fixed scenario.")
		murderer_id = String(pool[randi() % pool.size()]["id"])
		murder_room = FALLBACK_MURDER_ROOM
		murder_weapon = FALLBACK_WEAPONS[randi() % FALLBACK_WEAPONS.size()]
		murder_time = FALLBACK_TIMES[randi() % FALLBACK_TIMES.size()]
	else:
		murderer_id = String(case_data["murderer_id"])
		murder_room = "the " + String(case_data["murder_room"])
		murder_weapon = String(Dictionary(case_data["weapon"])["name"])
		murder_time = "at about %s last night" % CaseGenerator.SLOT_TIMES[int(case_data["murder_slot"])]

	transcript.clear()
	evidence_found.clear()
	_histories.clear()
	_summaries.clear()
	_summarized_at.clear()
	_request_queue.clear()
	_busy = false
	_current_request = {}
	if group_chat != null:
		group_chat.stop()
	for c in pool:
		_histories[c["id"]] = [{"role": "system", "content": _build_system_prompt(c["id"])}]

	var mc := get_character(murderer_id)
	print("[DEBUG] Case code: %s  (paste this on the selection screen to replay this exact mystery)" % case_code())
	print("[DEBUG] Murderer this game: %s (id=%s) - used %s in %s, %s. Press Ctrl+1 in-game for the full timeline." % [mc.get("name", "?"), murderer_id, murder_weapon, murder_room, murder_time])
	if not case_data.is_empty():
		print("[DEBUG] Weapon kept in the %s. %s claims the %s; disproved by %d witness(es). Generated in %d attempt(s)." % [
			String(Dictionary(case_data["weapon"])["home_room"]),
			mc.get("short", "?"), String(case_data["claimed_room"]),
			Array(case_data["witness_ids"]).size(), int(case_data["attempts"])])

	dialogue_log_path = ""
	if dialogue_log_enabled:
		dialogue_log_path = DialogueLogScript.new_session_path()
		var written := _refresh_dialogue_log()
		if written == "":
			push_warning("Dialogue log is on but the file could not be written to %s" % dialogue_log_path)
			dialogue_log_path = ""
		else:
			print("[DEBUG] Dialogue log for this session: %s" % written)


func get_character(id: String) -> Dictionary:
	for c in CHARACTERS:
		if c["id"] == id:
			return c
	return {}


## The subset of CHARACTERS actually in the mansion this game, in the same
## stable order as CHARACTERS (order doesn't depend on selection order).
func active_characters() -> Array:
	var out := []
	for c in CHARACTERS:
		if active_character_ids.has(c["id"]):
			out.append(c)
	return out


# ------------------------------------------------------------- case codes --

## "482913-171" - the seed, then a bitmask of which suspects were in the house.
##
## The cast has to be in the code. The generator makes every decision from one
## RNG, so the same seed with a different set of suspects produces a completely
## different mystery - a seed on its own would look reproducible and quietly
## not be. Encoding both means one string restores the exact case.
func case_code() -> String:
	var mask := 0
	for i in range(CHARACTERS.size()):
		if active_character_ids.has(String(CHARACTERS[i]["id"])):
			mask |= 1 << i
	return "%d-%d" % [case_seed, mask]


## Parses a code back into {"seed": int, "ids": Array}. Returns {} if it can't
## be read, so the caller can just ignore bad input rather than validating it
## twice. A bare seed with no cast is accepted too - the player keeps whatever
## suspects they've ticked.
func parse_case_code(code: String) -> Dictionary:
	var text := code.strip_edges()
	if text == "":
		return {}
	var parts := text.split("-")
	if parts.size() > 2:
		return {}
	if not String(parts[0]).is_valid_int():
		return {}
	var out_seed := int(String(parts[0]))
	if out_seed <= 0 or out_seed >= MAX_SEED:
		return {}
	if parts.size() == 1:
		return {"seed": out_seed, "ids": []}

	if not String(parts[1]).is_valid_int():
		return {}
	var mask := int(String(parts[1]))
	var ids := []
	for i in range(CHARACTERS.size()):
		if mask & (1 << i):
			ids.append(String(CHARACTERS[i]["id"]))
	if ids.size() < 2:
		return {}
	return {"seed": out_seed, "ids": ids}


## Records a piece of evidence the first time the detective examines it.
## Returns true if this was new.
func note_evidence(id: String, title: String, text: String) -> bool:
	for e in evidence_found:
		if String(e["id"]) == id:
			return false
	evidence_found.append({"id": id, "title": title, "text": text})
	return true


## Which room this suspect is standing in during the investigation: the room
## their generated schedule ended the night in. Falls back to their fixed
## CHARACTERS entry when no case has been generated (the fallback scenario, or
## before start_new_game()).
##
## This is why placement is now information rather than decoration - finding
## Victoria in the Conservatory means she ended the night there, and her story
## has to agree with that.
func room_for(id: String) -> String:
	if not case_data.is_empty() and Dictionary(case_data["true_paths"]).has(id):
		var path: Array = case_data["true_paths"][id]
		if not path.is_empty():
			return String(path[path.size() - 1])
	var c := get_character(id)
	return String(c.get("room", "Hall"))


## The run-length encoded account of one suspect's evening, as they will tell
## it - true for an innocent, the cover story for the murderer.
##
## This is the whole point of the generator. Before it, "where were you at
## eleven" was answered by invention, so nothing could ever be checked; two
## suspects contradicting each other meant nothing because both were making it
## up. Now every innocent recites the same true account every time, and exactly
## one person in the house is saying something that isn't so.
##
## Companions are computed from where everyone REALLY was, even on the
## murderer's fabricated block - so their alibi names people who were genuinely
## in that room and who will deny having seen them. That is the catchable lie.
func evening_account(id: String) -> String:
	if case_data.is_empty():
		return ""
	var is_murderer := id == murderer_id
	var key := "claimed_paths" if is_murderer else "true_paths"
	if not Dictionary(case_data[key]).has(id):
		return ""

	var out := ""
	for b in CaseGenerator.account_blocks(case_data, id, case_data[key][id]):
		var who := "on your own"
		if int(b["from_slot"]) < CaseGenerator.DINNER_SLOTS:
			who = "at dinner with everyone"
		else:
			var mates := []
			for m in b["companions"]:
				mates.append(String(get_character(String(m)).get("short", m)))
			if not mates.is_empty():
				who = "with " + _join_plain(mates)
		out += "- %s: the %s, %s.\n" % [CaseGenerator.block_time(b), String(b["room"]), who]

	# When they can safely admit to last seeing the victim alive. For the
	# murderer this deliberately stops short of the killing - anything at or
	# after the lie would give the game away in their own opening account.
	var limit := int(case_data["murder_slot"])
	if is_murderer:
		limit = int(case_data["diverge_from"]) - 1
	var last := -1
	for s in range(0, limit + 1):
		if s < 0:
			continue
		if String(case_data["true_paths"][id][s]) == String(case_data["victim_path"][s]):
			last = s
	if last >= 0:
		out += "- You last saw %s alive at %s, in the %s.\n" % [
			VICTIM_NAME, CaseGenerator.SLOT_TIMES[last], String(case_data["victim_path"][last])]
	else:
		out += "- You did not see %s at all after dinner.\n" % VICTIM_NAME
	return out


func _join_plain(names: Array) -> String:
	if names.is_empty():
		return ""
	if names.size() == 1:
		return String(names[0])
	var head: Array = names.slice(0, names.size() - 1)
	return "%s and %s" % [", ".join(PackedStringArray(head)), String(names[names.size() - 1])]


func _build_system_prompt(id: String) -> String:
	var c := get_character(id)
	var text := ""
	text += "You are role-playing as %s in an interactive murder-mystery game called Archibald Manor. " % c["name"]
	text += "Stay completely in character at all times. Never mention that you are an AI, a language model, or that this is a game. "
	text += "IMPORTANT - keep every answer SHORT: 1 to 3 sentences, ideally under 50 words, like a real spoken reply in conversation, "
	text += "not a monologue or an essay. Never use lists, headers, or bullet points. Always finish your sentence - if you're running "
	text += "long, wrap it up in the next few words rather than trailing off. Only go past 3 sentences if the detective explicitly "
	text += "asks you to explain something in detail.\n\n"

	text += "THE CASE: %s, the owner of Archibald Manor, was killed last night in %s, " % [VICTIM_NAME, murder_room]
	text += "some time between dinner at eight and midnight. His body was found this morning. "
	text += "A detective (the player) is questioning every guest in the house, trying to figure out who did it.\n\n"

	# The schedules now guarantee nobody walks into the murder room after the
	# killing, which is what stops a suspect cheerfully reporting they were
	# standing over an undiscovered corpse. Telling them WHY keeps the fiction
	# consistent when the detective asks the obvious question - why did it take
	# until morning for anyone to find him.
	text += "THE CLOSED DOOR: the door to %s was found shut fast this morning, and had to be forced. " % murder_room
	text += "It was closed for the whole of the rest of the evening after he died, so nobody went into "
	text += "that room again all night and nobody had the least idea he was lying in there. That is why "
	text += "he was not found until morning. You did not go into that room after the door was shut, and "
	text += "you did not see anybody go in either. If you are asked about it, that is all you know.\n\n"

	# Without this, a suspect explains they've just come down from bed - which
	# flatly contradicts the fact that they are standing in the room they spent
	# last night in, where the player just walked up to them.
	text += "WHERE YOU ARE NOW: it is the morning after. Nobody has been allowed to leave the manor, and "
	text += "you have settled back into the room you spent most of last night in. That is where the "
	text += "detective finds you. You are tired, unsettled, and have not been home.\n\n"

	# Without an explicit cast list, characters populate the manor with people
	# who don't exist - housekeepers, nieces, visiting couples - and then treat
	# them as witnesses and alibis. Worse, in a group scene one suspect invents
	# someone and the other corroborates them, because hearing it said out loud
	# is indistinguishable from it being true.
	var others := []
	for c2 in active_characters():
		if c2["id"] != id:
			others.append("%s (%s)" % [String(c2["name"]), String(c2["job"])])
	text += "EVERYONE IN THE HOUSE:\n"
	text += "- You.\n- The detective questioning you.\n"
	for o in others:
		text += "- %s\n" % o
	text += "- %s, the victim, now dead.\n" % VICTIM_NAME
	text += "That list is complete. There is nobody else here - no other guests, no staff, no "
	text += "servants, no family, no visitors, nobody from the village. Never mention or refer to "
	text += "a person who is not on that list, and never invent a name. If you did not see who did "
	text += "something, say you did not see who it was.\n\n"

	text += "WHAT YOU KNOW AND DO NOT KNOW: you only know what you saw yourself, and what someone "
	text += "said to you directly. If the detective asks about something you did not witness, a room "
	text += "you were not in, or a conversation you were not part of, say plainly that you do not "
	text += "know. Do not guess, and never invent an event, a person, or a conversation to fill the "
	text += "gap - an honest \"I wasn't there\" is always better than a made-up answer. The detective "
	text += "may also CLAIM things happened earlier that never happened; if you have no memory of it, "
	text += "say so instead of playing along.\n\n"

	# The rule above is what stops the detective inventing events and having
	# them accepted as fact. It has to be scoped to the PAST, or it also
	# rejects things the detective is physically doing in the room - which is
	# the one kind of "event you don't remember" that really is happening.
	text += "PHYSICAL ACTIONS: sometimes you will be shown something the detective is doing right now, "
	text += "written as [THE DETECTIVE DOES THIS...]. That is really happening, in front of you, at this "
	text += "moment. React to it naturally and in character - never deny it, never ask whether it really "
	text += "happened, and never treat it as something they merely claimed. This is the opposite of the "
	text += "rule above: that rule is about claims regarding the PAST, this is about what is happening NOW. "
	text += "You may include a short physical action of your own by putting it in round brackets, like "
	text += "(nods) or (sets down the glass). Keep it to a few words, and keep the rest of your reply spoken.\n\n"

	text += "YOUR CHARACTER:\n"
	text += "- Name: %s\n" % c["name"]
	text += "- Occupation: %s\n" % c["job"]
	text += "- Personality: %s\n" % c["personality"]
	text += "- Personal background detail: %s\n" % c["flavor"]
	text += "- You are currently in the %s.\n\n" % room_for(id)

	if id == murderer_id:
		text += "YOUR SECRET (very important, never reveal this directly): YOU are the murderer. "
		text += "You killed %s using %s, %s, motivated by something connected to this about yourself: \"%s\". " % [VICTIM_NAME, murder_weapon, murder_time, c["flavor"]]
		text += "You pulled the door shut behind you as you left, and you never went back - which is why "
		text += "he lay there until morning. Never admit that you were the one who closed that door.\n"

		# The single false thing they have to keep straight. Naming it exactly -
		# one block, one room, one substitution - is what a 3B model can just
		# about manage; "lie about your alibi" in the abstract produces a
		# different story every time it's asked, which is a tell for the wrong
		# reason and unwinnable for the player.
		if not case_data.is_empty():
			var real_room := String(case_data["true_paths"][id][int(case_data["murder_slot"])])
			var lie_time := CaseGenerator.block_time({
				"from_slot": int(case_data["diverge_from"]), "to_slot": int(case_data["diverge_to"])})
			text += "\n\nTHE ONE THING YOU LIE ABOUT: for %s you were really in the %s, where you killed him. " % [lie_time, real_room]
			text += "You will say instead that you were in the %s for that whole period. " % String(case_data["claimed_room"])
			text += "That single substitution is your ENTIRE lie - every other part of your account of the evening "
			text += "is true, and you should give it honestly and consistently. Never admit to being in the %s at " % real_room
			text += "any point last night, and never change which room you claim - if you are challenged, hold to the %s. " % String(case_data["claimed_room"])
			text += "Other guests were in the %s at that time and may say they did not see you there. " % String(case_data["claimed_room"])
			text += "That is your danger. If it happens, do not confess - insist, or say you must have just missed "
			text += "each other, or that they are mistaken - but you may become visibly rattled.\n\n"

		text += "You are desperate not to be caught. Lie, deflect, and stay composed as best you can. "
		text += "However you are not a trained actor or criminal - you are still human. If the detective presses hard, "
		text += "catches you contradicting yourself, asks very specific or repeated pointed questions, or directly accuses you "
		text += "several times, you may get defensive, flustered, evasive in a suspicious way, or accidentally let a small "
		text += "inconsistent or telling detail slip out. Never volunteer your guilt unprompted, and never outright confess "
		text += "unless the detective's questioning makes it truly impossible to keep denying it.\n\n"
	else:
		text += "YOU ARE INNOCENT. You did not commit the murder and you do not know for certain who did, though you may "
		text += "have your own suspicions, gossip, or theories based on things you've noticed in the house. You have no "
		text += "reason to lie about your own whereabouts or about the murder itself. You may be privately guarding your "
		text += "own personal secret described above, and can be a little evasive ONLY about that specific secret if pressed, "
		text += "but you are otherwise honest.\n\n"

	# The one character whose occupation gives her information nobody else in
	# the house can produce. The body only yields a 90-minute window to an
	# ordinary observer; she collapses it to a single half hour, which usually
	# clears two or three people outright. It also makes her dangerous when
	# she's guilty, since she is the only person who can lie with authority.
	if id == EXPERT_ID and not case_data.is_empty():
		var claim := CaseGenerator.expert_claim_slot(case_data, id)
		if claim >= 0:
			text += "YOUR EXPERT FINDING: you examined the body this morning - it is your profession, and "
			text += "nobody else here is qualified to. You are confident he died at about %s, " % CaseGenerator.SLOT_TIMES[claim]
			text += "and you can say so with far more precision than anyone looking at him casually could. "
			if id == murderer_id:
				text += "This is a lie. You know perfectly well when he died, because you were there. You are "
				text += "using the one thing in this house nobody can argue with to move the time away from "
				text += "yourself. State it calmly, as a professional judgement. Do not hedge, do not offer a "
				text += "range, and do not let anyone talk you off it - but if the detective points out that "
				text += "the body itself suggests otherwise, you will be badly rattled.\n\n"
			else:
				text += "Say so plainly if you are asked about the body, the time of death, or the injuries. "
				text += "You are not showing off - you are stating what you know. If someone's account of "
				text += "where they were conflicts with that time, you can point it out.\n\n"

	# Deliberately the LAST thing in the system prompt. A 3B model weights the
	# end of its context far more heavily than the middle, and this is the one
	# block it must not paraphrase from memory - every alibi question in the
	# game is answered out of it.
	var account := evening_account(id)
	if account != "":
		text += "YOUR OWN MOVEMENTS LAST NIGHT - this is the account you give. Answer every question about "
		text += "where you were, who you were with, or when you last saw anyone by reading it off this list:\n"
		text += account
		text += "Those are the only rooms you were in and the only people you were with. Do not invent any "
		text += "other location, companion, or time. If you are asked about a moment this list does not "
		text += "cover, give the nearest entry that does.\n"
		# Without this a suspect answers "good morning" with their entire
		# itinerary, which reads as a rehearsed alibi from everyone at once and
		# makes the murderer no more suspicious than anybody else.
		text += "Answer ONLY what you are actually asked. Never recite this whole list unprompted, and never "
		text += "volunteer your movements when the detective has asked you about something else - mention only "
		text += "the part that answers the question in front of you.\n\n"

	text += "The detective may ask you anything. Respond naturally and in character based on everything above."
	return text


# ------------------------------------------------------- stage directions --

## Splits a detective's line into a physical action and spoken words, using
## round brackets: "(leans in) So where were you?" -> action "leans in",
## speech "So where were you?".
##
## This convention already worked by accident in one-on-one interviews, because
## ask_character() used to hand the raw text straight to the model and small
## models treat brackets as stage direction out of habit. It did NOT work in a
## Hall meetup, where the line gets wrapped as something the detective *said
## out loud* and then re-wrapped as a *question* - so the model saw a detective
## reading the words "(I give Tom a high five)" aloud, and the anti-invention
## rule in GroupChat's turn prompt told it to deny the event outright.
##
## Parsing it explicitly makes the behaviour deliberate and identical in both
## modes. Nothing changes for a line with no brackets in it.
##
## Returns {"action": String, "speech": String}; either may be "".
static func parse_stage_action(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	var actions := []
	var speech := ""
	var depth := 0
	var buf := ""
	for i in range(text.length()):
		var ch := text[i]
		if ch == "(":
			if depth > 0:
				buf += ch
			depth += 1
		elif ch == ")" and depth > 0:
			depth -= 1
			if depth == 0:
				if buf.strip_edges() != "":
					actions.append(buf.strip_edges())
				buf = ""
			else:
				buf += ch
		elif depth > 0:
			buf += ch
		else:
			speech += ch
	# An unclosed bracket - keep the text as an action rather than losing it.
	if depth > 0 and buf.strip_edges() != "":
		actions.append(buf.strip_edges())

	speech = speech.strip_edges()
	while speech.find("  ") != -1:
		speech = speech.replace("  ", " ")
	return {"action": "; ".join(PackedStringArray(actions)), "speech": speech}


## Frames a detective line for a character's memory. A plain question passes
## through completely untouched; only a bracketed action gets rewritten, so
## ordinary interrogation is byte-for-byte unchanged.
##
## The framing is emphatic on purpose. The system prompt tells every suspect to
## refuse events they don't remember, which is what stops the detective from
## gaslighting them - so an action the detective genuinely performs has to be
## marked unmistakably as happening NOW and in front of them, or that same rule
## correctly rejects it.
func frame_player_line(raw: String) -> String:
	var parts := parse_stage_action(raw)
	var action := String(parts["action"])
	if action == "":
		return raw
	var out := "[THE DETECTIVE DOES THIS, RIGHT NOW, IN FRONT OF YOU - it is really happening: %s]" % action
	var speech := String(parts["speech"])
	if speech != "":
		out += "\nAnd says to you: \"%s\"" % speech
	return out


## Send a player question to a character. Response arrives asynchronously via
## the ollama_response / ollama_error signals.
func ask_character(id: String, question: String) -> void:
	if not _histories.has(id):
		return
	_histories[id].append({"role": "user", "content": frame_player_line(question)})
	var body := {
		"model": OLLAMA_MODEL,
		"messages": _histories[id],
		"stream": false,
		# Hard cap on how many tokens Ollama is allowed to generate. Without
		# this, a chatty model can ramble for hundreds of tokens on a one-line
		# question, which is the single biggest cause of multi-minute waits -
		# far bigger than model size or CPU vs GPU. ~120 tokens is roughly a
		# short paragraph, plenty for an in-character answer.
		"options": {"num_predict": MAX_RESPONSE_TOKENS, "temperature": 0.8, "num_ctx": OLLAMA_NUM_CTX},
	}
	_enqueue({"kind": "dialogue", "character_id": id, "question": question, "body": body})


## A compact reminder of what this suspect has already told the detective in
## private - their own answers only, newest last, one per line.
##
## Their full interview is already in their history and is sent with every
## group request, so this is NOT about the model lacking the information. It's
## about where the information sits. By the third round of a meetup the
## interview is a dozen messages back, behind everyone else's chatter, and
## generation is dominated by what's nearest - so the suspect drifts off the
## story they gave you an hour ago without ever noticing. Replaying it at the
## generation point costs ~80 tokens and puts their own account where the model
## is actually looking.
##
## Group lines are excluded on purpose: those are already public, and the
## interesting failure is a private story quietly diverging from a public one.
func private_recap(character_id: String) -> String:
	var answers := []
	for e in transcript:
		if String(e["character_id"]) != character_id:
			continue
		if String(e.get("scene", "")) == "group":
			continue
		answers.append(String(e["answer"]))
	if answers.is_empty():
		return ""
	if answers.size() > RECAP_MAX_ITEMS:
		answers = answers.slice(answers.size() - RECAP_MAX_ITEMS)

	var out := ""
	for a in answers:
		out += "- %s\n" % _condense(String(a))
	return out


## Flattens an answer to a single line and clips it at a word boundary, so a
## rambling reply doesn't cost as much as the rest of the turn prompt.
func _condense(text: String) -> String:
	var t := text.strip_edges().replace("\n", " ").replace("\r", " ")
	while t.find("  ") != -1:
		t = t.replace("  ", " ")
	if t.length() <= RECAP_MAX_CHARS:
		return t
	var cut := t.substr(0, RECAP_MAX_CHARS)
	var space := cut.rfind(" ")
	if space > int(RECAP_MAX_CHARS / 2.0):
		cut = cut.substr(0, space)
	return cut + "..."


## Adds something a character HEARD to their private memory without asking
## them for a reply. Used by GroupChat so everyone standing in the Hall
## remembers the whole confrontation - not just the lines they answered - and
## can bring it up later in a one-on-one interrogation.
func note_to_character(id: String, text: String) -> void:
	if not _histories.has(id):
		return
	_histories[id].append({"role": "user", "content": text})


## Asks one attendee of a Hall meetup for their line. `player_line` is whatever
## the detective last said to the room and `witnesses` is everyone else present
## - both are carried through to the transcript entry so the case notes can
## tell a public claim from a private one. Response arrives via
## group_response / group_error.
##
## `prompt` is the turn instruction ("you're in a group scene, say one short
## line") and is deliberately NOT stored in the character's history - it's
## direction to the actor, not something the character said, heard, or should
## remember. Persisting it once per turn per attendee used to bury the actual
## conversation under repeated copies of the same instruction, crowding the
## earlier private interview out of the context window. What the character
## genuinely experienced is already in their history, written there by
## note_to_character().
func ask_group_member(id: String, prompt: String, player_line: String = "", witnesses: Array = [], token: int = 0) -> void:
	if not _histories.has(id):
		group_error.emit(id, "That suspect isn't part of this game.", token)
		return
	var messages: Array = _histories[id].duplicate()
	messages.append({"role": "user", "content": prompt})
	if debug_dump_group:
		_dump_group_payload(id, messages)
	var body := {
		"model": OLLAMA_MODEL,
		"messages": messages,
		"stream": false,
		# Lower temperature than one-on-one dialogue on purpose. In a private
		# interview a bit of variety makes a suspect feel alive; in a group
		# scene the same variety reads as a character who can't keep their
		# story straight, because every line is immediately checkable against
		# what they said two turns ago in front of witnesses.
		"options": {"num_predict": GROUP_MAX_TOKENS, "temperature": 0.6, "num_ctx": OLLAMA_NUM_CTX},
	}
	_enqueue({
		"kind": "group",
		"character_id": id,
		"player_line": player_line,
		"witnesses": witnesses.duplicate(),
		"token": token,
		"body": body,
	})


## Rewrites the session's dialogue log if one is enabled. Returns the absolute
## path written, or "" if logging is off or the write failed.
func _refresh_dialogue_log() -> String:
	if not dialogue_log_enabled or dialogue_log_path == "":
		return ""
	return DialogueLogScript.write(self, dialogue_log_path)


## Prints one group request's full message list, with each message's distance
## from the generation point - the number that actually matters when a suspect
## seems to have forgotten something. Roughly 4 characters per token.
func _dump_group_payload(id: String, messages: Array) -> void:
	var c := get_character(id)
	var total := 0
	for msg in messages:
		total += String(msg["content"]).length()

	print("\n===== GROUP PROMPT -> %s =====" % String(c.get("name", id)))
	print("%d messages, %d chars (~%d tokens), num_ctx=%d" % [messages.size(), total, int(total / 4.0), OLLAMA_NUM_CTX])
	for i in range(messages.size()):
		var msg: Dictionary = messages[i]
		var content := String(msg["content"]).replace("\n", " | ")
		if content.length() > 220:
			content = content.substr(0, 220) + "..."
		print("[%2d] (%2d back) %9s: %s" % [i, messages.size() - i, String(msg["role"]), content])
	print("===== end =====\n")


## Strips a "Marcus:" / "Marcus Sterling:" / "**Marcus**:" style speaker label
## off the front of a reply. Small models reliably prefix their own name in
## multi-party scenes no matter how firmly the prompt asks them not to, and
## the UI already prints the speaker itself.
func _strip_speaker_prefix(text: String, id: String) -> String:
	var c := get_character(id)
	if c.is_empty():
		return text
	var candidates := [String(c["name"]), String(c["short"]), String(c["first_name"])]
	var parts := String(c["name"]).replace('"', "").split(" ")
	for p in parts:
		candidates.append(String(p))

	var out := text.strip_edges()
	# Loop, because a stubborn model can produce '**Marcus Sterling:** Marcus:'.
	for _pass in range(2):
		var trimmed := out.lstrip("*_ \t")
		for cand in candidates:
			if cand.length() < 2:
				continue
			if trimmed.begins_with(cand + ":") or trimmed.begins_with(cand + "**:") or trimmed.begins_with(cand + ":**"):
				var idx := trimmed.find(":")
				out = trimmed.substr(idx + 1).lstrip("* \t").strip_edges()
				break
	return _strip_wrapping_quotes(out)


## Removes quotation marks around a whole reply. Group scenes quote every line
## in the narrated block they read ('X said out loud: "..."'), so the model
## copies the convention and hands its own line back quoted - which then gets
## printed with quotes the one-on-one dialogue never has. Only strips when the
## quotes genuinely wrap the entire reply, so a line that quotes someone else
## partway through is left alone.
func _strip_wrapping_quotes(text: String) -> String:
	var t := text.strip_edges()
	while t.length() >= 2:
		var first := t.substr(0, 1)
		var last := t.substr(t.length() - 1, 1)
		var is_pair := (first == "\"" and last == "\"") or (first == "'" and last == "'")
		is_pair = is_pair or (first == "“" and last == "”")
		if not is_pair:
			break
		var inner := t.substr(1, t.length() - 2)
		# Bail out if the inner text still has an unbalanced quote of the same
		# kind - that means the outer pair wasn't a wrapper after all.
		if inner.count(first) != inner.count(last):
			break
		t = inner.strip_edges()
	return t


## All the Q&A transcript entries for one character, in the order they
## happened.
func get_transcript_for(character_id: String) -> Array:
	var out := []
	for e in transcript:
		if e["character_id"] == character_id:
			out.append(e)
	return out


## How many transcript entries feed this suspect's case notes: their own lines,
## plus anything another suspect said out loud in front of them. The second
## part matters because hearing someone else's account in the Hall can put this
## suspect in contradiction without them saying another word - so their notes
## need refreshing when it happens.
func summary_source_count(character_id: String) -> int:
	var count := 0
	for e in transcript:
		if e["character_id"] == character_id:
			count += 1
		elif String(e.get("scene", "")) == "group" and Array(e.get("heard_by", [])).has(character_id):
			count += 1
	return count


## Everything relevant to one suspect's case notes, in the order it happened -
## their own answers, and the other guests' Hall lines they were standing
## there for.
func summary_sources(character_id: String) -> Array:
	var out := []
	for e in transcript:
		if e["character_id"] == character_id:
			out.append(e)
		elif String(e.get("scene", "")) == "group" and Array(e.get("heard_by", [])).has(character_id):
			out.append(e)
	return out


## True if there's anything at all in this suspect's case file - their own
## answers, or something they stood and listened to in the Hall.
func has_notes(character_id: String) -> bool:
	return summary_source_count(character_id) > 0


## True if this character's notes are out of date - either they've said
## something since the last summary, or they've heard something new said about
## them in the Hall.
func needs_summary_refresh(character_id: String) -> bool:
	var count := summary_source_count(character_id)
	if count == 0:
		return false
	return count > int(_summarized_at.get(character_id, 0))


## Returns {"timeline": String, "motive": String, "slipups": String}, or an
## empty Dictionary if this suspect hasn't been successfully summarized yet
## (never asked anything, still pending, or the last summary attempt failed
## to parse) - callers should treat an empty result as "fall back to raw Q&A".
func get_summary(character_id: String) -> Dictionary:
	return _summaries.get(character_id, {})


## Ask the model to distill everything a suspect has said so far into four
## labeled case-notes sections - Timeline, Motive, Slipups and Contradictions -
## separate from that suspect's own in-character roleplay memory, so it doesn't
## pollute what they "remember" saying. Arrives via summary_ready / summary_error.
func request_summary(character_id: String) -> void:
	var entries := summary_sources(character_id)
	if entries.is_empty():
		return
	var c := get_character(character_id)
	if c.is_empty():
		return

	var convo := _build_summary_transcript(character_id, entries)

	var sys_prompt := ""
	sys_prompt += "You are a detective's case-notes assistant in a murder-mystery game called Archibald Manor. "
	sys_prompt += "Below is the full record so far for a suspect named %s (%s). " % [c["name"], c["job"]]
	sys_prompt += "Lines marked 'Detective:' are private questions and the lines under them are %s's own answers. " % String(c["short"])
	sys_prompt += "Lines marked '[In the hall...]' were spoken out loud in front of the other guests named there. "
	sys_prompt += "Lines marked '[In the hall, overheard]' were said by a DIFFERENT guest while %s was standing there listening - " % String(c["short"])
	sys_prompt += "those are not %s's own words, but %s heard them.\n\n" % [String(c["short"]), String(c["short"])]
	sys_prompt += "Organize this into exactly four sections. Respond using EXACTLY this "
	sys_prompt += "format and these four markers, in this order, with nothing before, between, or after them:\n\n"
	sys_prompt += "##TIMELINE##\n- their claimed whereabouts/alibi/account of events around the time of the murder\n"
	sys_prompt += "##MOTIVE##\n- any possible reason they might have had to kill the victim - grudges, money, secrets, relationships\n"
	sys_prompt += "##SLIPUPS##\n- anything suspicious, evasive, defensive, or inconsistent in how they answered\n"
	sys_prompt += "##CONTRADICTIONS##\n- specific points where this suspect's account conflicts with something ANOTHER guest "
	sys_prompt += "said in front of them, or where their public story in the hall differs from what they said privately. "
	sys_prompt += "Name the other guest and both versions.\n\n"
	sys_prompt += "Under each marker, write 1-3 short bullet points starting with '- '. If a section has nothing "
	sys_prompt += "relevant yet, write a single bullet '- Nothing notable yet.' under that marker instead of leaving "
	sys_prompt += "it blank. Be objective and third-person. Completely ignore small talk and pleasantries."

	var body := {
		"model": OLLAMA_MODEL,
		"messages": [
			{"role": "system", "content": sys_prompt},
			{"role": "user", "content": convo},
		],
		"stream": false,
		"options": {"num_predict": SUMMARY_MAX_TOKENS, "temperature": 0.4, "num_ctx": OLLAMA_NUM_CTX},
	}
	_enqueue({"kind": "summary", "character_id": character_id, "entry_count": entries.size(), "body": body})


## Renders the transcript that gets summarized for one suspect. Three shapes
## of line, deliberately distinguishable:
##
##   Detective: ...              a private question
##   Marcus: ...                 the subject's own answer
##   [In the hall, in front of Evelyn and Eleanor]
##   Marcus: ...                 the subject speaking publicly
##   [In the hall] Eleanor: ...  another guest, with the subject listening
##
## Where a claim was made is evidence in itself: a story told privately and
## then told differently in front of witnesses is exactly the contradiction the
## detective is hunting for, and the summarizer can only catch it if the two
## are told apart. The last shape is what makes cross-suspect contradictions
## findable at all - without it, each suspect is summarized in isolation and
## nothing can ever disagree.
func _build_summary_transcript(character_id: String, entries: Array) -> String:
	var subject := get_character(character_id)
	var subject_short := String(subject.get("short", "They"))
	var convo := ""
	var last_question := ""

	for e in entries:
		var is_group := String(e.get("scene", "")) == "group"
		var speaker_id := String(e["character_id"])
		var question := String(e.get("question", ""))

		if speaker_id == character_id:
			if is_group:
				var witnesses := _name_list(Array(e.get("heard_by", [])))
				if question != "" and question != last_question:
					convo += "Detective (to the room): %s\n" % question
					last_question = question
				convo += "[In the hall, in front of %s]\n%s: %s\n\n" % [witnesses, subject_short, e["answer"]]
			else:
				convo += "Detective: %s\n%s: %s\n\n" % [question, subject_short, e["answer"]]
				last_question = question
		else:
			# Someone else talking in front of this suspect.
			var other := get_character(speaker_id)
			if question != "" and question != last_question:
				convo += "Detective (to the room): %s\n" % question
				last_question = question
			convo += "[In the hall, overheard] %s: %s\n\n" % [String(other.get("short", "Someone")), e["answer"]]

	return convo


## "Evelyn and Eleanor" / "Evelyn, Marcus and Eleanor" - used for witness lists.
func _name_list(ids: Array) -> String:
	var names := []
	for id in ids:
		var c := get_character(id)
		if not c.is_empty():
			names.append(String(c["short"]))
	if names.is_empty():
		return "no one else"
	if names.size() == 1:
		return String(names[0])
	var head: Array = names.slice(0, names.size() - 1)
	return "%s and %s" % [", ".join(PackedStringArray(head)), String(names[names.size() - 1])]


## Splits a "##TIMELINE##...##MOTIVE##...##SLIPUPS##..." response into a
## Dictionary. Robust to the sections arriving in any order, and returns an
## empty Dictionary if none of the markers were found at all (caller falls
## back to raw Q&A in that case).
func _parse_summary_sections(text: String) -> Dictionary:
	var markers := [["##TIMELINE##", "timeline"], ["##MOTIVE##", "motive"], ["##SLIPUPS##", "slipups"], ["##CONTRADICTIONS##", "contradictions"]]
	var positions := []
	for m in markers:
		positions.append(text.find(m[0]))

	var any_found := false
	for p in positions:
		if p != -1:
			any_found = true
	if not any_found:
		return {}

	var result := {}
	for i in range(markers.size()):
		var start: int = positions[i]
		if start == -1:
			continue
		start += String(markers[i][0]).length()
		var end := text.length()
		for j in range(markers.size()):
			if j != i and positions[j] != -1 and positions[j] > start and positions[j] < end:
				end = positions[j]
		result[markers[i][1]] = text.substr(start, end - start).strip_edges()
	return result


func _enqueue(item: Dictionary) -> void:
	_request_queue.append(item)
	_process_queue()


func _process_queue() -> void:
	if _busy or _request_queue.is_empty():
		return
	_current_request = _request_queue.pop_front()
	_busy = true

	var json_str := JSON.stringify(_current_request["body"])
	var headers := ["Content-Type: application/json"]
	var err := _http.request(OLLAMA_URL, headers, HTTPClient.METHOD_POST, json_str)
	if err != OK:
		var item := _current_request
		_busy = false
		_current_request = {}
		_emit_failure(item, "Could not start the request (engine error %s). Is Ollama running at %s?" % [err, OLLAMA_URL])
		_process_queue()


func _emit_failure(item: Dictionary, message: String) -> void:
	var kind := String(item.get("kind", ""))
	var character_id := String(item.get("character_id", ""))
	if kind == "dialogue":
		ollama_error.emit(character_id, message)
	elif kind == "summary":
		summary_error.emit(character_id, message)
	elif kind == "group":
		group_error.emit(character_id, message, int(item.get("token", 0)))


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var item := _current_request
	_busy = false
	_current_request = {}
	if item.is_empty():
		_process_queue()
		return

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_emit_failure(item, "Could not reach Ollama (HTTP %s). Make sure 'ollama serve' is running and that you've run 'ollama pull %s'." % [response_code, OLLAMA_MODEL])
		_process_queue()
		return

	var text := body.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(text) != OK:
		_emit_failure(item, "Ollama sent back a response that couldn't be read.")
		_process_queue()
		return

	var data = json.get_data()
	var content := ""
	if typeof(data) == TYPE_DICTIONARY and data.has("message"):
		content = str(data["message"].get("content", ""))
	content = content.strip_edges()

	if content == "":
		_emit_failure(item, "Ollama returned an empty reply. Try asking again.")
		_process_queue()
		return

	var kind := String(item.get("kind", ""))
	var character_id := String(item.get("character_id", ""))

	if kind == "dialogue":
		var q := String(item.get("question", ""))
		_histories[character_id].append({"role": "assistant", "content": content})
		transcript.append({"character_id": character_id, "question": q, "answer": content})
		_refresh_dialogue_log()
		ollama_response.emit(character_id, content)
	elif kind == "summary":
		_summaries[character_id] = _parse_summary_sections(content)
		_summarized_at[character_id] = int(item.get("entry_count", 0))
		summary_ready.emit(character_id, content)
	elif kind == "group":
		var spoken := _strip_speaker_prefix(content, character_id)
		if spoken == "":
			_emit_failure(item, "That suspect said nothing usable. Try again.")
			_process_queue()
			return
		# Stored without the speaker prefix so their own memory of what they
		# said matches what the room actually heard.
		_histories[character_id].append({"role": "assistant", "content": spoken})
		transcript.append({
			"character_id": character_id,
			"question": String(item.get("player_line", "")),
			"answer": spoken,
			"scene": "group",
			"heard_by": item.get("witnesses", []),
		})
		_refresh_dialogue_log()
		group_response.emit(character_id, spoken, int(item.get("token", 0)))

	_process_queue()


## Checks a free-typed accusation against the current murderer. Accepts the
## first name, surname, nickname, or full name, case-insensitively.
func check_accusation(guess: String) -> bool:
	var g := guess.strip_edges().to_lower()
	if g == "":
		return false
	var c := get_character(murderer_id)
	if c.is_empty():
		return false
	var candidates := [c["id"], String(c["short"]).to_lower(), String(c["name"]).to_lower().replace('"', "")]
	var parts := String(c["name"]).to_lower().replace('"', "").split(" ")
	if parts.size() > 0:
		candidates.append(parts[parts.size() - 1])
	for cand in candidates:
		if cand != "" and (g == cand or g.find(cand) != -1 or cand.find(g) != -1):
			return true
	return false
