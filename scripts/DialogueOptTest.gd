extends Node
# Regression test for the dialogue-memory optimizations. Not part of the game.
#
# Open Scenes/DialogueOptTest.tscn and press F6, or run headless:
#   godot --headless --path . Scenes/DialogueOptTest.tscn
#
# It makes no network calls - every check inspects prompt construction and
# memory bookkeeping directly, so it runs in a second and does not need Ollama.
# Playing the game normally is completely unaffected by this scene.
#
# What it guards, and why each one is worth guarding:
#   1. All eight suspects share a byte-identical system-prompt prefix. Slip a
#      character-specific detail into _shared_case_preamble() and this fails -
#      which is the whole point, because the failure is otherwise invisible and
#      just makes every Hall meetup slower.
#   2. A group scene writes NOTHING to anyone's permanent memory while it runs.
#   3. The room reaches the model, correctly labelled, without sending the
#      current round twice.
#   4. Ending a scene leaves exactly one digest per attendee.
#   5. Compaction never evicts the system prompt (the schedule block lives at
#      the end of it, and losing it silently un-fixes the whole CaseGenerator).
#   6. Request bodies carry stop sequences and the lowered token cap at the top
#      level (llama-server's OpenAI shape, not Ollama's "options"), and sending
#      one leaves the character's history alone until the reply arrives.
#   7. The token budgets still fit the window a single conversation actually
#      gets. --ctx-size is shared across --parallel slots, so this is the check
#      that would have caught every suspect silently running in 2048 tokens
#      while the budgets here were written against 8192.

var fails := 0

func ok(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("  PASS  %s" % label)
	else:
		fails += 1
		print("  FAIL  %s   %s" % [label, detail])


func _ready() -> void:
	var ids := ["blackwood", "sterling", "ashford", "carter"]
	GameManager.start_new_game(ids)
	var gm = GameManager
	var gc = gm.group_chat

	print("\n=== 1. shared system-prompt prefix ===")
	var preamble: String = gm._shared_case_preamble()
	print("  preamble length: %d chars (~%d tokens)" % [preamble.length(), int(preamble.length() / 3.6)])
	var all_share := true
	var min_common := 999999
	for id in ids:
		var sp: String = gm._build_system_prompt(id)
		if not sp.begins_with(preamble):
			all_share = false
		# longest common prefix against the first suspect
		var other: String = gm._build_system_prompt(ids[0])
		var n := 0
		while n < min(sp.length(), other.length()) and sp[n] == other[n]:
			n += 1
		min_common = min(min_common, n)
	ok("every suspect's prompt starts with the identical preamble", all_share)
	ok("shared prefix >= preamble length (%d vs %d)" % [min_common, preamble.length()],
		min_common >= preamble.length(),
		"prompts diverge at char %d" % min_common)
	var no_names := true
	for id in ids:
		var nm := String(gm.get_character(id)["name"])
		# The cast list legitimately names everyone; check the OPENING instead.
		if preamble.substr(0, 200).find(nm) != -1:
			no_names = false
	ok("no suspect name in the first 200 chars", no_names)

	print("\n=== 2. group scene does not touch permanent memory ===")
	var before := {}
	for id in ids:
		before[id] = gm._histories[id].size()
	gc.start(ids)
	var after_start := {}
	for id in ids:
		after_start[id] = gm._histories[id].size()
	var unchanged := true
	for id in ids:
		if before[id] != after_start[id]:
			unchanged = false
	ok("gc.start() writes nothing to any history", unchanged,
		str(before) + " -> " + str(after_start))

	# Simulate three rounds: detective speaks, each attendee replies. Mirrors what
	# submit_player_line() does, including stamping the round boundary.
	for round_i in range(3):
		gc._round_log_start = gc.scene_log.size()
		gc._add_line("", "Where were you at half past ten?", "say")
		gc._last_player_speech = "Where were you at half past ten?"
		gc._last_player_action = ""
		for id in ids:
			gc._add_line(id, "I was in the library, round %d." % round_i, "say")
	var after_scene := {}
	for id in ids:
		after_scene[id] = gm._histories[id].size()
	var still_unchanged := true
	for id in ids:
		if before[id] != after_scene[id]:
			still_unchanged = false
	ok("3 rounds x 4 attendees writes nothing to any history", still_unchanged,
		str(before) + " -> " + str(after_scene))

	print("\n=== 3. the rendered scene reaches the turn prompt ===")
	var tp: String = gc._build_turn_prompt("sterling")
	ok("turn prompt contains the room transcript", tp.find("THE HALL") != -1)
	ok("their own lines are labelled YOU:", tp.find("YOU: \"") != -1)
	ok("other guests are labelled GUEST", tp.find("GUEST Dr. Evelyn Blackwood:") != -1)
	ok("the tag convention is explained once", tp.find("never the detective") != -1)
	ok("the group-role instruction is present", tp.find("GROUP SCENE") != -1)
	ok("the detective's question is LAST", tp.find("Answer the detective's question now") > tp.find("THE HALL"))
	ok("sterling is never tagged GUEST in his own prompt",
		tp.find("GUEST Marcus Sterling") == -1)
	# The current round is presented at the end of the prompt, so the transcript
	# must stop before it or every turn sends the same lines twice.
	var head := tp.substr(0, tp.find("-----"))
	ok("transcript excludes the current round (no round-2 lines above the fold)",
		head.find("round 2") == -1, "round 2 leaked into the transcript")
	ok("transcript includes earlier rounds", head.find("round 0") != -1)
	print("  turn prompt: %d chars (~%d tokens)" % [tp.length(), int(tp.length() / 3.6)])

	print("\n=== 4. scene end writes exactly one digest each ===")
	gc.stop()
	var grew_by_one := true
	var digest_ok := true
	for id in ids:
		var delta: int = gm._histories[id].size() - before[id]
		if delta != 1:
			grew_by_one = false
		var last: String = String(gm._histories[id][gm._histories[id].size() - 1]["content"])
		if last.find("THE GATHERING IN THE HALL IS OVER") == -1:
			digest_ok = false
		if last.find("What YOU said out loud") == -1:
			digest_ok = false
	ok("each attendee gained exactly 1 message", grew_by_one)
	ok("that message is the digest, with their own words in it", digest_ok)
	print("  digest sample:\n" + String(gm._histories["sterling"][gm._histories["sterling"].size() - 1]["content"]))

	print("\n=== 5. compaction protects the system prompt ===")
	var sysmsg = gm._histories["carter"][0]
	for i in range(60):
		gm._histories["carter"].append({"role": "user", "content": "Detective question number %d, padded out to a realistic length so the budget is actually reached." % i})
		gm._histories["carter"].append({"role": "assistant", "content": "I have told you already, I was in the Conservatory the whole evening, answer %d." % i})
	var big := gm._approx_tokens(gm._histories["carter"])
	gm._compact_history_if_needed("carter")
	var small := gm._approx_tokens(gm._histories["carter"])
	print("  %d tokens -> %d tokens, %d messages" % [big, small, gm._histories["carter"].size()])
	ok("compaction fired", small < big)
	ok("result is under budget", small <= gm.HISTORY_TOKEN_BUDGET)
	ok("system prompt is still message 0 and untouched",
		gm._histories["carter"][0] == sysmsg)
	ok("schedule block survived",
		String(gm._histories["carter"][0]["content"]).find("YOUR OWN MOVEMENTS LAST NIGHT") != -1)
	ok("older answers were folded into a summary",
		String(gm._histories["carter"][1]["content"]).find("EARLIER IN THIS INVESTIGATION") != -1)
	ok("recent messages kept verbatim",
		String(gm._histories["carter"][gm._histories["carter"].size() - 1]["content"]).find("answer 59") != -1)

	print("\n=== 6. request bodies ===")
	# llama-server speaks the OpenAI chat-completions shape, so generation
	# settings sit at the top level rather than under Ollama's "options", and
	# there is no keep_alive - the model stays resident for the life of the
	# process. See the notes above MAX_RESPONSE_TOKENS in GameManager.
	var history_before: int = gm._histories["ashford"].size()
	gm.ask_character("ashford", "Good morning.")
	var body: Dictionary = gm._current_request["body"]
	ok("stop sequences present", Array(body["stop"]).size() > 0)
	ok("max_tokens lowered to 140", int(body["max_tokens"]) == 140)
	ok("the question is in the outgoing messages",
		String((body["messages"] as Array)[-1]["content"]).find("Good morning") != -1)

	# The history must not move until a reply comes back. It used to gain the
	# player's line here, and nothing removed it when the request failed - so
	# every failed retry sent a longer history than the one just rejected, and
	# an interview that hit the context limit once could never recover.
	ok("history is untouched until the reply lands",
		gm._histories["ashford"].size() == history_before)
	ok("the outgoing copy is not the history itself",
		not (body["messages"] as Array).is_empty() and body["messages"] != gm._histories["ashford"])

	print("\n=== 7. token budgets fit the window the engine actually gives us ===")
	# --ctx-size is divided across --parallel slots, so a conversation gets
	# CTX_PER_SLOT, not NUM_CTX. Getting this backwards is what made every
	# suspect run in a 2048-token window while these budgets assumed 8192.
	ok("--ctx-size is the per-slot window times the slot count",
		gm.LLAMA_SERVER_NUM_CTX == gm.LLAMA_SERVER_CTX_PER_SLOT * gm.LLAMA_SERVER_SLOTS)
	ok("history budget plus request overhead fits one slot",
		gm.HISTORY_TOKEN_BUDGET + gm.REQUEST_OVERHEAD_TOKENS < gm.LLAMA_SERVER_CTX_PER_SLOT,
		"%d + %d vs %d" % [gm.HISTORY_TOKEN_BUDGET, gm.REQUEST_OVERHEAD_TOKENS, gm.LLAMA_SERVER_CTX_PER_SLOT])
	# The failure that started all this: message 0 alone nearly filling the slot,
	# so an interview died after one or two questions. The murderer's prompt is
	# the big one - it carries the secret and the lie on top of everything else -
	# so check every suspect and say which is worst.
	#
	# "Room to talk" is the point, not merely fitting: the prompt has to leave
	# space for a real interview after the per-request overhead is paid. 2000
	# tokens is roughly a dozen exchanges, which is past where compaction starts
	# carrying the memory anyway.
	const MIN_CONVERSATION_TOKENS := 2000
	var worst := 0
	var worst_who := ""
	for who in gm.active_characters():
		var id := String(who["id"])
		var sys_tokens: int = gm._approx_tokens([{"content": gm._build_system_prompt(id)}])
		if sys_tokens > worst:
			worst = sys_tokens
			worst_who = id
		ok("%s's system prompt leaves room to talk%s" % [id, " (murderer)" if id == gm.murderer_id else ""],
			sys_tokens + gm.REQUEST_OVERHEAD_TOKENS + MIN_CONVERSATION_TOKENS <= gm.LLAMA_SERVER_CTX_PER_SLOT,
			"~%d tokens + %d overhead + %d to talk exceeds the %d-token slot" % [
				sys_tokens, gm.REQUEST_OVERHEAD_TOKENS, MIN_CONVERSATION_TOKENS, gm.LLAMA_SERVER_CTX_PER_SLOT])
	print("  largest system prompt: %s at ~%d tokens, in a %d-token slot" % [
		worst_who, worst, gm.LLAMA_SERVER_CTX_PER_SLOT])

	print("\n%s  (%d failure(s))" % ["ALL CHECKS PASSED" if fails == 0 else "FAILURES", fails])
	get_tree().quit(1 if fails > 0 else 0)
