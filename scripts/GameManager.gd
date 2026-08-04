extends Node
# GameManager (autoload singleton)
# Holds the 8 suspects, randomizes the murderer each playthrough, talks to a
# local Ollama server running llama3.2:3b to generate in-character responses,
# and checks the player's final accusation at the front door.

const OLLAMA_URL := "http://127.0.0.1:11434/api/chat"
const OLLAMA_MODEL := "huihui_ai/llama3.2-abliterate:3b"
const MAX_RESPONSE_TOKENS := 300 # hard safety cap - the prompt aims well under this so it's rarely hit mid-sentence
const SUMMARY_MAX_TOKENS := 260 # three labeled sections need a bit more room

const VICTIM_NAME := "Lord Reginald Archibald"
const MURDER_ROOM := "the Billiard Room"

const WEAPON_OPTIONS := [
	"a silver letter opener",
	"a heavy brass candlestick",
	"an antique dueling pistol",
	"a length of garden wire",
	"a vial of poison slipped into his brandy",
]

const TIME_OPTIONS := [
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

var murderer_id: String = ""
var murder_weapon: String = ""
var murder_time: String = ""
var transcript: Array = [] # [{character_id, question, answer}]

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


func _setup_input_map() -> void:
	_add_key_action("move_forward", KEY_W)
	_add_key_action("move_back", KEY_S)
	_add_key_action("move_left", KEY_A)
	_add_key_action("move_right", KEY_D)
	_add_key_action("interact", KEY_E)
	_add_key_action("toggle_notes", KEY_TAB)
	_add_key_action("jump", KEY_SPACE)
	_add_key_action("toggle_debug", KEY_F1)


func _add_key_action(action_name: String, keycode: int) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	if InputMap.action_get_events(action_name).is_empty():
		var ev := InputEventKey.new()
		ev.physical_keycode = keycode
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
	var idx := randi() % pool.size()
	murderer_id = pool[idx]["id"]
	murder_weapon = WEAPON_OPTIONS[randi() % WEAPON_OPTIONS.size()]
	murder_time = TIME_OPTIONS[randi() % TIME_OPTIONS.size()]
	transcript.clear()
	_histories.clear()
	_summaries.clear()
	_summarized_at.clear()
	_request_queue.clear()
	_busy = false
	_current_request = {}
	for c in pool:
		_histories[c["id"]] = [{"role": "system", "content": _build_system_prompt(c["id"])}]

	var mc := get_character(murderer_id)
	print("[DEBUG] Murderer this game: %s (id=%s) - used %s %s. Press F1 in-game to show/hide this on screen." % [mc.get("name", "?"), murderer_id, murder_weapon, murder_time])


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


func _build_system_prompt(id: String) -> String:
	var c := get_character(id)
	var text := ""
	text += "You are role-playing as %s in an interactive murder-mystery game called Archibald Manor. " % c["name"]
	text += "Stay completely in character at all times. Never mention that you are an AI, a language model, or that this is a game. "
	text += "IMPORTANT - keep every answer SHORT: 1 to 3 sentences, ideally under 50 words, like a real spoken reply in conversation, "
	text += "not a monologue or an essay. Never use lists, headers, or bullet points. Always finish your sentence - if you're running "
	text += "long, wrap it up in the next few words rather than trailing off. Only go past 3 sentences if the detective explicitly "
	text += "asks you to explain something in detail.\n\n"

	text += "THE CASE: %s, the owner of Archibald Manor, was found dead last night in %s. " % [VICTIM_NAME, MURDER_ROOM]
	text += "A detective (the player) is questioning every guest in the house, one on one, trying to figure out who did it.\n\n"

	text += "YOUR CHARACTER:\n"
	text += "- Name: %s\n" % c["name"]
	text += "- Occupation: %s\n" % c["job"]
	text += "- Personality: %s\n" % c["personality"]
	text += "- Personal background detail: %s\n" % c["flavor"]
	text += "- You are currently in the %s.\n\n" % c["room"]

	if id == murderer_id:
		text += "YOUR SECRET (very important, never reveal this directly): YOU are the murderer. "
		text += "You killed %s using %s, %s, motivated by something connected to this about yourself: \"%s\". " % [VICTIM_NAME, murder_weapon, murder_time, c["flavor"]]
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

	text += "The detective may ask you anything. Respond naturally and in character based on everything above."
	return text


## Send a player question to a character. Response arrives asynchronously via
## the ollama_response / ollama_error signals.
func ask_character(id: String, question: String) -> void:
	if not _histories.has(id):
		return
	_histories[id].append({"role": "user", "content": question})
	var body := {
		"model": OLLAMA_MODEL,
		"messages": _histories[id],
		"stream": false,
		# Hard cap on how many tokens Ollama is allowed to generate. Without
		# this, a chatty model can ramble for hundreds of tokens on a one-line
		# question, which is the single biggest cause of multi-minute waits -
		# far bigger than model size or CPU vs GPU. ~120 tokens is roughly a
		# short paragraph, plenty for an in-character answer.
		"options": {"num_predict": MAX_RESPONSE_TOKENS, "temperature": 0.8},
	}
	_enqueue({"kind": "dialogue", "character_id": id, "question": question, "body": body})


## All the Q&A transcript entries for one character, in the order they
## happened.
func get_transcript_for(character_id: String) -> Array:
	var out := []
	for e in transcript:
		if e["character_id"] == character_id:
			out.append(e)
	return out


## True if this character has been talked to since their case-notes summary
## was last generated (or has never been summarized at all).
func needs_summary_refresh(character_id: String) -> bool:
	var count := get_transcript_for(character_id).size()
	if count == 0:
		return false
	return count > int(_summarized_at.get(character_id, 0))


## Returns {"timeline": String, "motive": String, "slipups": String}, or an
## empty Dictionary if this suspect hasn't been successfully summarized yet
## (never asked anything, still pending, or the last summary attempt failed
## to parse) - callers should treat an empty result as "fall back to raw Q&A".
func get_summary(character_id: String) -> Dictionary:
	return _summaries.get(character_id, {})


## Ask the model to distill everything a suspect has said so far into three
## labeled case-notes sections - Timeline, Motive, and Slipups - separate
## from that suspect's own in-character roleplay memory, so it doesn't
## pollute what they "remember" saying. Arrives via summary_ready / summary_error.
func request_summary(character_id: String) -> void:
	var entries := get_transcript_for(character_id)
	if entries.is_empty():
		return
	var c := get_character(character_id)
	if c.is_empty():
		return

	var convo := ""
	for e in entries:
		convo += "Detective: %s\n%s: %s\n\n" % [e["question"], c["short"], e["answer"]]

	var sys_prompt := ""
	sys_prompt += "You are a detective's case-notes assistant in a murder-mystery game called Archibald Manor. "
	sys_prompt += "Below is the full interview transcript so far between the detective and a suspect named %s (%s). " % [c["name"], c["job"]]
	sys_prompt += "Organize what this suspect has revealed into exactly three sections. Respond using EXACTLY this "
	sys_prompt += "format and these three markers, in this order, with nothing before, between, or after them:\n\n"
	sys_prompt += "##TIMELINE##\n- their claimed whereabouts/alibi/account of events around the time of the murder\n"
	sys_prompt += "##MOTIVE##\n- any possible reason they might have had to kill the victim - grudges, money, secrets, relationships\n"
	sys_prompt += "##SLIPUPS##\n- anything suspicious, evasive, defensive, inconsistent, or contradictory in how they answered\n\n"
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
		"options": {"num_predict": SUMMARY_MAX_TOKENS, "temperature": 0.4},
	}
	_enqueue({"kind": "summary", "character_id": character_id, "entry_count": entries.size(), "body": body})


## Splits a "##TIMELINE##...##MOTIVE##...##SLIPUPS##..." response into a
## Dictionary. Robust to the sections arriving in any order, and returns an
## empty Dictionary if none of the markers were found at all (caller falls
## back to raw Q&A in that case).
func _parse_summary_sections(text: String) -> Dictionary:
	var markers := [["##TIMELINE##", "timeline"], ["##MOTIVE##", "motive"], ["##SLIPUPS##", "slipups"]]
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
		ollama_response.emit(character_id, content)
	elif kind == "summary":
		_summaries[character_id] = _parse_summary_sections(content)
		_summarized_at[character_id] = int(item.get("entry_count", 0))
		summary_ready.emit(character_id, content)

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
