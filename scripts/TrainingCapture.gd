extends RefCounted
# Turns a play session into fine-tuning data, in the two shapes a trainer wants:
# `sft.jsonl` (imitate these good replies) and `dpo.jsonl` (prefer this reply
# over that one).
#
# Two sources feed it, and the automatic one is the better one:
#
# 1. The character guard, for free. `_reply_breaks_character()` already catches
#    a reply that has left the fiction, throws it away and re-asks. That
#    discarded reply and its clean replacement are exactly a preference pair -
#    same prompt, one wrong answer, one right one - so they get written out with
#    no effort from whoever is playing. This is the highest quality data in the
#    file, because the rejected half is a failure the model really produced
#    rather than one somebody sat down and imagined.
#
# 2. F9 and F10 while playing. The guard is a keyword list, so it is blind to a
#    refusal, a moralising aside, or a suspect who has quietly started talking
#    like a chatbot without ever saying "as an AI". Those are the ones worth
#    pressing a key for.
#
# Rows are appended the moment they happen, which is the opposite of
# DialogueLog's rebuild-in-full approach and deliberately so: a log only has to
# be correct when you read it, but a session that ends in a crash should still
# keep every pair it earned.
#
# What goes in a row is the exact `messages` array that was sent to Ollama,
# system prompt and all. That means the data is tied to the prompt that produced
# it - if the system prompt is rewritten later, rows captured before the rewrite
# are training the model on a prompt it will never see again. Recapture after
# any significant prompt change.

const DATA_DIR := "res://TrainingData"
const FALLBACK_DIR := "user://TrainingData"


## Prefers the project folder so the files sit next to the game, and falls back
## to the user data folder when res:// is read-only (an exported build).
## Same resolution DialogueLog uses, kept as a local copy so neither script
## depends on the other's private helpers.
static func _resolve_dir() -> String:
	if DirAccess.open("res://") != null:
		var err := DirAccess.make_dir_recursive_absolute(DATA_DIR)
		if err == OK or err == ERR_ALREADY_EXISTS:
			var probe := FileAccess.open(DATA_DIR + "/.probe", FileAccess.WRITE)
			if probe != null:
				probe.close()
				DirAccess.remove_absolute(DATA_DIR + "/.probe")
				return DATA_DIR
	DirAccess.make_dir_recursive_absolute(FALLBACK_DIR)
	return FALLBACK_DIR


## Two fresh timestamped paths for one play session, as {"sft": ..., "dpo": ...}.
## Both share a stamp so a session's pair of files is obvious at a glance.
static func new_session_paths() -> Dictionary:
	var now := Time.get_datetime_dict_from_system()
	var stamp := "%04d-%02d-%02d_%02d%02d%02d" % [
		now["year"], now["month"], now["day"], now["hour"], now["minute"], now["second"]]
	var dir := _resolve_dir()
	return {
		"sft": "%s/sft_%s.jsonl" % [dir, stamp],
		"dpo": "%s/dpo_%s.jsonl" % [dir, stamp],
	}


## Appends one JSON object as a line. Returns false if the file could not be
## opened, which the caller should report once rather than per row.
static func append_row(path: String, row: Dictionary) -> bool:
	if path == "":
		return false
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.seek_end()
	f.store_line(JSON.stringify(row))
	f.close()
	return true


## One imitation example: the prompt as sent, with the reply appended as the
## assistant turn. `sent` is duplicated because the caller's copy is usually
## `_histories[id]`, which keeps being appended to after this returns.
static func sft_row(sent: Array, reply: String, meta: Dictionary = {}) -> Dictionary:
	var msgs: Array = sent.duplicate(true)
	msgs.append({"role": "assistant", "content": reply})
	var row := {"messages": msgs}
	for k in meta:
		row[k] = meta[k]
	return row


## One preference example. `chosen` is left empty for rows that need a human to
## write the better reply; build_dataset.py refuses to train on those until it
## is filled in, which is what stops a half-labelled session poisoning a run.
static func dpo_row(sent: Array, chosen: String, rejected: String, meta: Dictionary = {}) -> Dictionary:
	var row := {
		"messages": sent.duplicate(true),
		"chosen": chosen,
		"rejected": rejected,
	}
	for k in meta:
		row[k] = meta[k]
	return row
