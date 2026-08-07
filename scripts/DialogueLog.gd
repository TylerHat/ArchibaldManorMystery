extends RefCounted
# Writes a readable markdown record of everything every suspect has said, for
# spotting hallucinations and prompt failures after a play session.
#
# Deliberately includes the game's ground truth at the top and each suspect's
# real briefing in their section header. A reply can only be judged a
# hallucination against what that character was actually told - "Marcus
# threatened me" is a flaw if the two never shared a scene, and perfectly good
# play if they did. The Full Timeline at the end is where cross-character bleed
# shows up: a suspect referring to something only another suspect was told, or
# answering a question that was never put to them.
#
# Regenerated in full on every new line rather than appended to, so the file on
# disk is always complete even if the game is closed mid-session.

const LOG_DIR := "res://DialogueLogs"
const FALLBACK_DIR := "user://DialogueLogs"


## Picks the directory to write into. Prefers the project folder so the file
## sits next to the game where it's easy to find, and falls back to the user
## data folder if that isn't writable (which is the case in an exported build).
static func _resolve_dir() -> String:
	if DirAccess.open("res://") != null:
		var err := DirAccess.make_dir_recursive_absolute(LOG_DIR)
		if err == OK or err == ERR_ALREADY_EXISTS:
			var probe := FileAccess.open(LOG_DIR + "/.probe", FileAccess.WRITE)
			if probe != null:
				probe.close()
				DirAccess.remove_absolute(LOG_DIR + "/.probe")
				return LOG_DIR
	DirAccess.make_dir_recursive_absolute(FALLBACK_DIR)
	return FALLBACK_DIR


## A fresh timestamped path for one play session. Held for the whole session so
## every rewrite lands on the same file.
static func new_session_path() -> String:
	var now := Time.get_datetime_dict_from_system()
	var stamp := "%04d-%02d-%02d_%02d%02d%02d" % [now["year"], now["month"], now["day"], now["hour"], now["minute"], now["second"]]
	return "%s/dialogue_%s.md" % [_resolve_dir(), stamp]


## Writes the log. Returns the absolute path on success, or "" on failure.
static func write(gm, path: String) -> String:
	if path == "":
		return ""
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(build(gm))
	f.close()
	return ProjectSettings.globalize_path(path)


static func build(gm) -> String:
	var out := ""
	out += _header(gm)
	out += _per_character(gm)
	out += _timeline(gm)
	return out


static func _header(gm) -> String:
	var private_count := 0
	var group_count := 0
	for e in gm.transcript:
		if String(e.get("scene", "")) == "group":
			group_count += 1
		else:
			private_count += 1

	var murderer = gm.get_character(gm.murderer_id)
	var names := []
	for c in gm.active_characters():
		names.append(String(c["name"]))

	var out := "# Archibald Manor - Dialogue Log\n\n"
	out += "- **Generated:** %s\n" % Time.get_datetime_string_from_system(false, true)
	out += "- **Case code:** `%s` (paste on the selection screen to replay this exact case)\n" % gm.case_code()
	out += "- **Model:** `%s`\n" % gm.OLLAMA_MODEL
	out += "- **Context window:** %d tokens\n" % gm.OLLAMA_NUM_CTX
	out += "- **Murderer (ground truth):** %s\n" % String(murderer.get("name", "?"))
	out += "- **Weapon / time:** %s, %s\n" % [gm.murder_weapon, gm.murder_time]
	out += "- **Victim:** %s, in %s\n" % [gm.VICTIM_NAME, gm.murder_room]
	out += "- **Suspects in play:** %s\n" % ", ".join(PackedStringArray(names))
	out += "- **Exchanges recorded:** %d (%d private, %d in the hall)\n\n" % [gm.transcript.size(), private_count, group_count]
	out += "> Ground truth is listed above, and each suspect's real briefing appears in their\n"
	out += "> section header, because a line can only be called a hallucination against what\n"
	out += "> that character was actually told. Check every claim against the briefing and\n"
	out += "> against who was present.\n\n"
	out += _truth_table(gm)
	out += "---\n\n"
	return out


## The generated timeline, written out in full alongside the transcript.
##
## Without it a log is only half useful: you can see a suspect said they were
## in the Study at ten, but not whether that was true, so there's no way to
## tell a hallucination from an accurate answer weeks later. With it, every
## claim in the transcript below can be checked against a single table.
static func _truth_table(gm) -> String:
	var case: Dictionary = gm.case_data
	if case.is_empty():
		return "_No generated case (fallback scenario in use)._\n\n"

	var weapon: Dictionary = case["weapon"]
	var ms := int(case["murder_slot"])
	var out := "## Ground truth - what actually happened\n\n"
	out += "- **Killed:** in the %s at %s, with %s\n" % [
		String(case["murder_room"]), CaseGenerator.SLOT_TIMES[ms], String(weapon["name"])]
	out += "- **Weapon normally kept in:** the %s\n" % String(weapon["home_room"])
	out += "- **Method:** %s\n" % String(case["method"])
	out += "- **The lie:** %s claims the %s for %s (really the %s)\n" % [
		String(gm.get_character(String(case["murderer_id"])).get("short", "?")),
		String(case["claimed_room"]),
		CaseGenerator.block_time({"from_slot": int(case["diverge_from"]), "to_slot": int(case["diverge_to"])}),
		String(case["true_paths"][case["murderer_id"]][ms])]
	var wits := []
	for wid in case["witness_ids"]:
		wits.append(String(gm.get_character(String(wid)).get("short", wid)))
	out += "- **Disproved by:** %s\n\n" % ", ".join(PackedStringArray(wits))

	# Grid first - fastest way to check "was anyone else in that room?" - then
	# the per-suspect account, which is the exact wording they were given and
	# therefore what their answers should be compared against.
	out += "### Where everyone was\n\n"
	out += "| | %s |\n" % " | ".join(PackedStringArray(CaseGenerator.SLOT_TIMES))
	out += "|---|%s\n" % "---|".repeat(CaseGenerator.SLOT_COUNT)
	out += "| **%s** (victim) | %s |\n" % [gm.VICTIM_NAME, " | ".join(PackedStringArray(_cells(Array(case["victim_path"]), ms)))]
	for id in gm.active_character_ids:
		var sid := String(id)
		var label := String(gm.get_character(sid).get("short", sid))
		if sid == String(case["murderer_id"]):
			label += " **(murderer)**"
		out += "| %s | %s |\n" % [label, " | ".join(PackedStringArray(_cells(Array(case["true_paths"][sid]), -1)))]
		if sid == String(case["murderer_id"]):
			out += "| _...claims_ | %s |\n" % " | ".join(PackedStringArray(_cells(Array(case["claimed_paths"][sid]), -1)))
	out += "\n"

	out += "### The account each suspect was given\n\n"
	out += "Anything they said that isn't in here is invented.\n\n"
	for id in gm.active_character_ids:
		var sid2 := String(id)
		out += "**%s**\n\n```\n%s```\n\n" % [
			String(gm.get_character(sid2).get("name", sid2)), gm.evening_account(sid2)]
	return out


static func _cells(path: Array, mark_slot: int) -> Array:
	var out := []
	for i in range(path.size()):
		var cell := String(path[i])
		out.append("**%s**" % cell if i == mark_slot else cell)
	return out


static func _per_character(gm) -> String:
	var out := "# By character\n\n"
	for c in gm.active_characters():
		var id: String = c["id"]
		var entries: Array = gm.get_transcript_for(id)
		var priv := 0
		var grp := 0
		for e in entries:
			if String(e.get("scene", "")) == "group":
				grp += 1
			else:
				priv += 1

		out += "## %s\n\n" % String(c["name"])
		out += "*%s - found in the %s - **%s***\n\n" % [
			String(c["job"]),
			gm.room_for(id),
			"THE MURDERER" if id == gm.murderer_id else "innocent",
		]
		out += "- **Personality briefed:** %s\n" % String(c["personality"])
		out += "- **Secret briefed:** %s\n" % String(c["flavor"])
		out += "- **Lines:** %d (%d private, %d in the hall)\n\n" % [entries.size(), priv, grp]

		if entries.is_empty():
			out += "_Never questioned._\n\n---\n\n"
			continue

		var n := 0
		for e in entries:
			n += 1
			out += _exchange(gm, e, n, String(c["short"]))
		out += "---\n\n"
	return out


## The whole conversation in the order it actually happened. This is the view
## that exposes bleed between characters, which a per-character section can't
## show by construction.
static func _timeline(gm) -> String:
	var out := "# Full timeline\n\n"
	out += "Every line in the order it happened. Cross-character bleed shows up here:\n"
	out += "a suspect referring to something only another suspect was told, answering a\n"
	out += "question that was never put to them, or addressing the detective by another\n"
	out += "suspect's name.\n\n"
	if gm.transcript.is_empty():
		out += "_Nothing recorded._\n"
		return out

	var n := 0
	for e in gm.transcript:
		n += 1
		var c = gm.get_character(String(e["character_id"]))
		out += _exchange(gm, e, n, String(c.get("short", "?")), String(c.get("name", "?")))
	return out


## One question-and-answer pair. `owner_label` prefixes the reply; `speaker` is
## only passed in the timeline, where it's ambiguous who is talking.
static func _exchange(gm, e: Dictionary, n: int, owner_label: String, speaker: String = "") -> String:
	var is_group := String(e.get("scene", "")) == "group"
	var where := "private"
	if is_group:
		var witnesses := _witness_names(gm, Array(e.get("heard_by", [])))
		where = "in the hall, in front of %s" % witnesses

	var out := "**%d - %s" % [n, where]
	if speaker != "":
		out += " - %s" % speaker
	out += "**\n\n"

	var question := _flatten(String(e.get("question", "")))
	if question != "":
		out += "> **Detective%s:** %s\n>\n" % [" (to the room)" if is_group else "", question]
	out += "> **%s:** %s\n\n" % [owner_label, _flatten(String(e["answer"]))]
	return out


## "Evelyn" / "Evelyn and Tom" - who else was standing there when a line was
## said.
##
## A local copy rather than a call to GameManager's own _name_list(): an
## exporter shouldn't depend on another script's private helpers, and because
## `gm` is untyped, calling across scripts returns an untyped value that `:=`
## can't infer a type from. Declaring a return type here fixes both.
static func _witness_names(gm, ids: Array) -> String:
	var names := []
	for id in ids:
		var c = gm.get_character(String(id))
		if not c.is_empty():
			names.append(String(c["short"]))
	if names.is_empty():
		return "no one else"
	if names.size() == 1:
		return String(names[0])
	var head: Array = names.slice(0, names.size() - 1)
	return "%s and %s" % [", ".join(PackedStringArray(head)), String(names[names.size() - 1])]


## Collapses a reply onto one line so it sits inside a markdown blockquote
## without breaking out of it.
static func _flatten(text: String) -> String:
	var t := text.strip_edges().replace("\r", " ").replace("\n", " ")
	while t.find("  ") != -1:
		t = t.replace("  ", " ")
	return t
