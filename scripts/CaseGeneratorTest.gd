extends Node
# Phase 1 test harness for Scripts/CaseGenerator.gd.
#
# Run Scenes/CaseGeneratorTest.tscn (open it and hit F6) and read the Godot
# output panel. Nothing about the actual game is touched by this scene.
#
# What you should see:
#   - "1000/1000 valid" - every generated case satisfies every design rule
#   - stats that look like people rather than random walks
#   - three sample cases printed in full, for eyeballing
#
# If a case fails, the exact failure and the case that produced it are printed,
# along with the seed so it can be reproduced.

const CASES := 1000
const SAMPLES := 3

## Must match GameManager.CHARACTERS. Duplicated so this scene can run without
## booting the autoload; _check_roster() reads GameManager.gd's constant map
## and fails loudly if the two ever drift apart.
##
## That check exists because they already drifted once: the roster grew from 8
## to 12 and this list did not, so the suite went on reporting 1000/1000 while
## silently never testing four of the suspects. A duplicated constant with no
## guard is a test that quietly stops covering things.
const IDS := [
	"blackwood", "sterling", "ashford", "carter", "whitmore", "reeves",
	"cross_natalie", "cross_eugene", "moreau", "varga", "pike", "thorne",
]

## Mirrors GameManager.MAX_ACTIVE_SUSPECTS. The roster is deliberately larger
## than this, so casts must be drawn as a subset - generating a case for all 12
## would test a night the game will never actually run.
const MAX_ACTIVE := 8

const SHORT := {
	"blackwood": "Evelyn", "sterling": "Marcus", "ashford": "Victoria",
	"carter": "Sam", "whitmore": "Eleanor", "reeves": "Tom",
	"cross_natalie": "Natalie", "cross_eugene": "Eugene",
	"moreau": "Emma", "varga": "Lucian", "pike": "Desmond",
	"thorne": "Agnes",
}


func _ready() -> void:
	print("\n================ CaseGenerator self-test ================\n")
	_check_layout()
	_check_roster()
	_check_case_codes()
	var stats := _run_bulk()
	_print_stats(stats)
	_print_samples()
	print("\n================ end of self-test ================\n")


## The one assumption CaseGenerator makes about the rest of the project: its
## GRID must match the mansion Main.gd actually builds.
func _check_layout() -> void:
	var main_script: GDScript = load("res://Scripts/Main.gd")
	var main_grid = main_script.get_script_constant_map().get("GRID", [])
	if str(main_grid) == str(CaseGenerator.GRID):
		print("room grid matches Main.gd  OK")
	else:
		push_error("CaseGenerator.GRID does not match Main.gd GRID")
		print("!! ROOM GRID MISMATCH")
		print("   Main.gd:         %s" % str(main_grid))
		print("   CaseGenerator:   %s" % str(CaseGenerator.GRID))
	print("")


## The other cross-file assumption: this scene's duplicated IDS/MAX_ACTIVE must
## still describe the roster GameManager actually ships. Read out of the script
## constant map rather than the autoload, the same trick _check_layout() uses,
## so the suite stays runnable on its own.
func _check_roster() -> void:
	var gm: GDScript = load("res://Scripts/GameManager.gd")
	var consts := gm.get_script_constant_map()

	var real_ids := []
	for c in consts.get("CHARACTERS", []):
		real_ids.append(String(Dictionary(c)["id"]))

	if real_ids == IDS:
		print("roster matches GameManager.gd  OK  (%d suspects)" % IDS.size())
	else:
		push_error("CaseGeneratorTest.IDS does not match GameManager.CHARACTERS")
		print("!! ROSTER MISMATCH - this suite is not testing the real cast")
		print("   in GameManager only: %s" % str(real_ids.filter(func(i): return not IDS.has(i))))
		print("   in this test only:   %s" % str(IDS.filter(func(i): return not real_ids.has(i))))

	var real_cap: int = consts.get("MAX_ACTIVE_SUSPECTS", MAX_ACTIVE)
	if real_cap == MAX_ACTIVE:
		print("cast cap matches GameManager.gd  OK  (max %d in the house)" % MAX_ACTIVE)
	else:
		push_error("CaseGeneratorTest.MAX_ACTIVE (%d) != GameManager.MAX_ACTIVE_SUSPECTS (%d)" % [
			MAX_ACTIVE, real_cap,
		])
		print("!! CAST CAP MISMATCH - test %d, game %d" % [MAX_ACTIVE, real_cap])

	var missing_short := IDS.filter(func(i): return not SHORT.has(i))
	if not missing_short.is_empty():
		print("!! no SHORT name for: %s" % str(missing_short))
	print("")


## Case codes have to survive roster edits, because the whole promise of a code
## is that it reproduces a case exactly. They are keyed on permanent per-character
## slots for that reason. This checks the two ways that can silently break:
## a duplicated slot (two suspects sharing a bit) and a cast that does not
## survive a round trip through encode and decode.
func _check_case_codes() -> void:
	var gm: GDScript = load("res://Scripts/GameManager.gd")
	var chars: Array = gm.get_script_constant_map().get("CHARACTERS", [])

	var seen := {}
	var dupes := []
	for c in chars:
		var sl := int(Dictionary(c)["slot"])
		if seen.has(sl):
			dupes.append("slot %d: %s and %s" % [sl, String(seen[sl]), String(Dictionary(c)["id"])])
		seen[sl] = String(Dictionary(c)["id"])
	if dupes.is_empty():
		print("character slots unique  OK  (%d slots, highest %d)" % [seen.size(), seen.keys().max()])
	else:
		push_error("Duplicate character slots: %s" % str(dupes))
		print("!! DUPLICATE SLOTS - case codes will decode to the wrong cast")
		for d in dupes:
			print("   %s" % d)

	# Round trip every cast size the game allows, on the real GameManager.
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var bad := 0
	for trial in range(200):
		var n := 2 + rng.randi() % (MAX_ACTIVE - 1)
		var cast := IDS.duplicate()
		cast.shuffle()
		cast = cast.slice(0, n)

		GameManager.active_character_ids = cast.duplicate()
		GameManager.case_seed = 1 + rng.randi() % 999999
		var code := GameManager.case_code()
		var back: Dictionary = GameManager.parse_case_code(code)

		var want := IDS.filter(func(i): return cast.has(i))
		if back.has("error"):
			bad += 1
			if bad <= 3:
				print("   %s did not parse: %s" % [code, String(back["error"])])
		elif int(back["seed"]) != GameManager.case_seed or Array(back["ids"]) != want:
			bad += 1
			if bad <= 3:
				print("   %s round-tripped to %s, expected %s" % [code, str(back.get("ids")), str(want)])
	if bad == 0:
		print("case codes round-trip  OK  (200 casts)")
	else:
		push_error("%d/200 case codes failed to round-trip" % bad)
		print("!! %d/200 CASE CODES FAILED TO ROUND-TRIP" % bad)

	# A code pointing at a retired slot must be refused, not quietly decoded
	# into whoever happens to sit there now.
	var live := {}
	for c in chars:
		live[int(Dictionary(c)["slot"])] = true
	var retired := -1
	for sl in range(int(gm.get_script_constant_map().get("NEXT_FREE_SLOT", 0))):
		if not live.has(sl):
			retired = sl
			break
	if retired >= 0:
		var two := 0
		var mask := 1 << retired
		for c in chars:
			if two < 2:
				mask |= 1 << int(Dictionary(c)["slot"])
				two += 1
		var res: Dictionary = GameManager.parse_case_code("123456-%d" % mask)
		if res.has("error"):
			print("retired slot %d refused  OK  (\"%s\")" % [retired, String(res["error"])])
		else:
			push_error("A code referencing retired slot %d was accepted" % retired)
			print("!! RETIRED SLOT %d ACCEPTED - decoded to %s" % [retired, str(res.get("ids"))])
	print("")


func _run_bulk() -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var valid := 0
	var failures := []
	var attempts := 0
	var block_total := 0
	var block_count := 0
	var block_max := 0
	var unalibied := 0
	var victim_rooms := 0
	var share_max := 0
	var murder_rooms := {}
	var murder_slots := {}
	var weapons := {}
	# Who actually ends up guilty, against how often they were in the house at
	# all. The ratio is what matters - a suspect picked into more games will
	# naturally be the murderer in more games.
	var murderers := {}
	var appearances := {}
	var elapsed := Time.get_ticks_msec()

	for i in range(CASES):
		# 2 to MAX_ACTIVE, drawn from the full roster - never the whole roster,
		# because the game caps the house at MAX_ACTIVE however many suspects
		# exist. Casts are subsets now, so this also exercises the far larger
		# number of distinct casts a 12-strong roster produces.
		var n := 2 + rng.randi() % (MAX_ACTIVE - 1)
		var active := IDS.duplicate()
		active.shuffle()
		active = active.slice(0, n)

		var case_rng := RandomNumberGenerator.new()
		case_rng.seed = rng.randi()
		var c := CaseGenerator.generate(active, case_rng)
		var errs := CaseGenerator.validate(c, active)

		if not errs.is_empty():
			failures.append({"seed": case_rng.seed, "active": active, "errors": errs, "case": c})
			continue

		valid += 1
		attempts += int(c["attempts"])
		murderers[c["murderer_id"]] = int(murderers.get(c["murderer_id"], 0)) + 1
		for pid in active:
			appearances[pid] = int(appearances.get(pid, 0)) + 1
		murder_rooms[c["murder_room"]] = int(murder_rooms.get(c["murder_room"], 0)) + 1
		murder_slots[c["murder_slot"]] = int(murder_slots.get(c["murder_slot"], 0)) + 1
		var wname := String(Dictionary(c["weapon"])["name"])
		weapons[wname] = int(weapons.get(wname, 0)) + 1
		victim_rooms += _distinct(Array(c["victim_path"]).slice(0, int(c["murder_slot"]) + 1))

		for pid in active:
			# account_blocks, not blocks: the prompt splits on companionship
			# changes too, so this is the real line count a suspect is given.
			var b := CaseGenerator.account_blocks(c, String(pid), c["true_paths"][pid]).size()
			block_total += b
			block_count += 1
			block_max = maxi(block_max, b)

		var ms := int(c["murder_slot"])
		for pid in active:
			if String(pid) == String(c["murderer_id"]):
				continue
			var alone := true
			for other in active:
				if String(other) != String(pid) and String(c["true_paths"][other][ms]) == String(c["true_paths"][pid][ms]):
					alone = false
			if alone:
				unalibied += 1

		for s in range(CaseGenerator.DINNER_SLOTS, CaseGenerator.SLOT_COUNT):
			var head := {}
			for pid in active:
				var r := String(c["true_paths"][pid][s])
				head[r] = int(head.get(r, 0)) + 1
			for v in head.values():
				share_max = maxi(share_max, int(v))

	elapsed = Time.get_ticks_msec() - elapsed

	print("%d/%d valid   (%d ms total, %.2f ms per case)" % [valid, CASES, elapsed, float(elapsed) / CASES])
	if failures.is_empty():
		print("no constraint violations\n")
	else:
		print("\n!!! %d FAILURES !!!\n" % failures.size())
		for f in failures.slice(0, 5):
			print("  seed %d  suspects %s" % [int(f["seed"]), str(f["active"])])
			for e in f["errors"]:
				print("    - %s" % String(e))
			if not Dictionary(f["case"]).is_empty():
				_print_case(f["case"], f["active"])
			print("")

	return {
		"valid": valid, "attempts": attempts, "block_total": block_total,
		"block_count": block_count, "block_max": block_max, "unalibied": unalibied,
		"victim_rooms": victim_rooms, "share_max": share_max,
		"murder_rooms": murder_rooms, "murder_slots": murder_slots, "weapons": weapons,
		"murderers": murderers, "appearances": appearances,
	}


func _print_stats(s: Dictionary) -> void:
	var valid := int(s["valid"])
	if valid == 0:
		return
	print("--- quality ---")
	print("retries before a valid case:        %.2f avg" % (float(s["attempts"]) / valid))
	print("schedule lines per suspect:         %.2f avg, %d max   (this is the prompt cost)" % [
		float(s["block_total"]) / max(1, int(s["block_count"])), int(s["block_max"])])
	print("victim's rooms before he died:      %.2f avg" % (float(s["victim_rooms"]) / valid))
	print("innocents with no alibi at the murder slot: %.2f avg   (these are your red herrings)" % (float(s["unalibied"]) / valid))
	print("most suspects ever in one room:     %d   (cap is %d)" % [int(s["share_max"]), CaseGenerator.MAX_PER_ROOM])

	# If one suspect is guilty far more often than the others relative to how
	# often they're in the house, the murderer draw is biased. Expect every
	# "guilty when present" figure to sit near 1/(cast size) - with mixed cast
	# sizes that averages out around 25-30%.
	print("\nwho ends up guilty (guilty / times in the house):")
	var flagged := false
	var ids: Array = s["appearances"].keys()
	ids.sort()
	for id in ids:
		var seen := int(s["appearances"][id])
		var guilty := int(s["murderers"].get(id, 0))
		var pct := 100.0 * guilty / maxi(1, seen)
		var note := ""
		if pct > 45.0 or pct < 12.0:
			note = "   <-- SKEWED"
			flagged = true
		print("   %-14s %5d / %5d  = %5.1f%%%s" % [String(id), guilty, seen, pct, note])
	if flagged:
		print("   !! murderer selection looks biased - report this")
	else:
		print("   all within normal range - murderer draw is uniform")

	print("\nmurder room spread:")
	var rooms: Array = s["murder_rooms"].keys()
	rooms.sort()
	for r in rooms:
		print("   %-14s %s" % [String(r), _bar(int(s["murder_rooms"][r]), valid)])
	print("\nmurder time spread:")
	var slots: Array = s["murder_slots"].keys()
	slots.sort()
	for sl in slots:
		print("   %-14s %s" % [CaseGenerator.SLOT_TIMES[int(sl)], _bar(int(s["murder_slots"][sl]), valid)])
	print("\nweapon spread:")
	var ws: Array = s["weapons"].keys()
	ws.sort()
	for w in ws:
		print("   %-34s %s" % [String(w), _bar(int(s["weapons"][w]), valid)])


func _bar(n: int, total: int) -> String:
	var pct := 100.0 * n / total
	return "%s %4.1f%% (%d)" % ["#".repeat(int(pct / 1.5)), pct, n]


func _print_samples() -> void:
	print("\n--- %d sample cases, read these like a detective would ---" % SAMPLES)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	for i in range(SAMPLES):
		var n := 4 + rng.randi() % (MAX_ACTIVE - 3)
		var active := IDS.duplicate()
		active.shuffle()
		active = active.slice(0, n)
		var case_rng := RandomNumberGenerator.new()
		case_rng.seed = rng.randi()
		var c := CaseGenerator.generate(active, case_rng)
		if c.is_empty():
			continue
		print("\n=========================================================")
		_print_case(c, active)


func _print_case(c: Dictionary, active: Array) -> void:
	var w: Dictionary = c["weapon"]
	var ms := int(c["murder_slot"])
	print("seed %d" % int(c["seed"]))
	print("MURDER : %s at %s" % [String(c["murder_room"]), CaseGenerator.SLOT_TIMES[ms]])
	print("WEAPON : %s  (normally kept in the %s)" % [String(w["name"]), String(w["home_room"])])
	print("METHOD : %s - %s" % [String(c["method"]), String(CaseGenerator.METHODS[c["method"]])])
	print("KILLER : %s" % _n(String(c["murderer_id"])))
	print("THE LIE: claims the %s for %s (really: %s)" % [
		String(c["claimed_room"]),
		CaseGenerator.block_time({"from_slot": int(c["diverge_from"]), "to_slot": int(c["diverge_to"])}),
		String(c["true_paths"][c["murderer_id"]][ms])])
	var wits := []
	for wid in c["witness_ids"]:
		wits.append(_n(String(wid)))
	print("CAUGHT BY: %s - actually in the %s at the time" % [", ".join(PackedStringArray(wits)), String(c["claimed_room"])])

	var body := CaseGenerator.death_window(c)
	print("BODY SAYS: death between %s and %s (Evelyn narrows this to %s)" % [
		CaseGenerator.SLOT_TIMES[int(body[0])], CaseGenerator.SLOT_END_TIMES[int(body[1])],
		CaseGenerator.SLOT_TIMES[ms]])

	print("")
	var header := "".rpad(14)
	for t in CaseGenerator.SLOT_TIMES:
		header += String(t).rpad(15)
	print(header)
	print("%s%s" % ["VICTIM".rpad(14), _row(c["victim_path"], ms)])
	for pid in active:
		var label := _n(String(pid))
		if String(pid) == String(c["murderer_id"]):
			label += " *"
		print("%s%s" % [label.rpad(14), _row(c["true_paths"][pid], -1)])
		if String(pid) == String(c["murderer_id"]):
			print("%s%s" % ["  -> claims".rpad(14), _row(c["claimed_paths"][pid], -1)])

	# The murderer's cover story next to the account of someone who can break
	# it - the two blocks that have to visibly disagree for the case to be
	# winnable. Read these side by side.
	print("\n  COVER STORY - what %s will say:" % _n(String(c["murderer_id"])))
	_print_evening(c, String(c["murderer_id"]), true)
	for wid in c["witness_ids"]:
		print("\n  THE WITNESS - what %s will say:" % _n(String(wid)))
		_print_evening(c, String(wid), false)
		break


## Previews the run-length encoded schedule block that Phase 2b will drop into
## the system prompt - the real point of the whole generator.
func _print_evening(c: Dictionary, id: String, use_claimed: bool) -> void:
	var key := "claimed_paths" if use_claimed else "true_paths"
	var ms := int(c["murder_slot"])
	for b in CaseGenerator.account_blocks(c, id, c[key][id]):
		var mates := []
		for m in b["companions"]:
			mates.append(_n(String(m)))
		var who := "alone"
		if int(b["from_slot"]) < CaseGenerator.DINNER_SLOTS:
			who = "at dinner with everyone"
		elif not mates.is_empty():
			who = "with " + ", ".join(PackedStringArray(mates))
		# Mark the line that covers the moment of the murder - for the murderer
		# it's the lie, for a witness it's the line that disproves it.
		var mark := "  <-- at the murder" if int(b["from_slot"]) <= ms and int(b["to_slot"]) >= ms else ""
		print("    - %-18s %-15s %s%s" % [CaseGenerator.block_time(b), String(b["room"]), who, mark])
	var last := CaseGenerator.last_saw_victim(c, id)
	if last >= 0:
		print("    (last saw the victim at %s in the %s)" % [
			CaseGenerator.SLOT_TIMES[last], String(c["victim_path"][last])])


func _row(path: Array, mark_slot: int) -> String:
	var out := ""
	for i in range(path.size()):
		var cell := String(path[i])
		if i == mark_slot:
			cell = "[" + cell + "]"
		out += cell.rpad(15)
	return out


func _n(id: String) -> String:
	return String(SHORT.get(id, id))


func _distinct(path: Array) -> int:
	var seen := {}
	for r in path:
		seen[r] = true
	return seen.size()
