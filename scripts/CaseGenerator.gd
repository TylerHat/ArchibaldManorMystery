class_name CaseGenerator
extends RefCounted
# Procedural murder-case generator.
#
# Builds the *ground truth* for one playthrough: who killed the victim, where,
# when, with what, and - the part that matters most - exactly which room every
# suspect and the victim was standing in for each half-hour slot of the
# evening. Everything the game says about alibis is read out of this table, so
# a suspect can no longer improvise a whereabouts and quietly contradict
# themselves an hour later.
#
# This file is deliberately pure data: no scene tree, no Ollama, no signals,
# no autoload references. That's what makes it testable in bulk - see
# Scripts/CaseGeneratorTest.gd, which generates thousands of cases and asserts
# every constraint below still holds.
#
# The generator is generate-then-validate with retry: it builds a candidate,
# checks it, and throws it away if anything is off. Roughly 4 attempts on
# average, so the whole thing finishes in well under a frame.

# ------------------------------------------------------------- the evening --

## 8 slots of 30 minutes, 8:00pm to midnight.
const SLOT_COUNT := 8
const SLOT_TIMES := ["8:00", "8:30", "9:00", "9:30", "10:00", "10:30", "11:00", "11:30"]
const SLOT_END_TIMES := ["8:30", "9:00", "9:30", "10:00", "10:30", "11:00", "11:30", "12:00"]

## Slot 0 is dinner: every suspect AND the victim are in the Dining Room. It
## gives the whole house one shared, agreed reference point ("we all rose from
## dinner at half past"), guarantees the murder can't happen before the party
## has assembled, and starts everyone with one corroborated block.
const DINNER_ROOM := "Dining Room"
const DINNER_SLOTS := 1

## The murder never happens during dinner, and never in the final slot - there
## always has to be a before and an after to reason about.
const MURDER_SLOT_MIN := 2
const MURDER_SLOT_MAX := 6

## Chance a suspect stays put rather than moving on. Guests settle into a room
## for a while; they don't drift every half hour. This is also what keeps the
## prompt small - a schedule is run-length encoded before it's shown to anyone,
## so three slots in the Library become one line, not three. Raise this if the
## model starts struggling to recite schedules; lower it for busier evenings.
const INERTIA := 0.55

## Soft cap on how many suspects occupy one room in one slot (dinner exempt).
## Without it, random walks pool everyone into the same two rooms and half the
## cast ends up with identical evenings.
const MAX_PER_ROOM := 3

const MAX_ATTEMPTS := 400

# --------------------------------------------------------------- the house --

## Must stay in sync with Main.gd's GRID. Duplicated rather than imported
## because this file deliberately has no scene dependencies; the test scene
## asserts the two agree.
const GRID := [
	["Kitchen", "Ballroom", "Conservatory"],
	["Lounge", "Study", "Dining Room"],
	["Billiard Room", "Hall", "Library"],
]

## Rooms the murder can't happen in. The Hall is the meetup room, the front
## door and the player spawn; the Dining Room is where the entire party is
## sitting when the night starts.
const NO_MURDER_ROOMS := ["Hall", "Dining Room"]

# -------------------------------------------------------------- the weapons --

## Each weapon lives somewhere specific. That `home_room` is the single most
## useful clue the generator produces: whoever used it had to have passed
## through that room earlier in the evening, and constraint 6 in generate()
## guarantees the murderer did. It turns "who was in the Study before ten?"
## into a real question with a real answer.
##
## `methods` gates the circumstances a weapon can produce - you can't have a
## struggle with poison, and you can't stage a fall with a duelling pistol.
const WEAPONS := [
	{
		"name": "a carving knife from the block", "home_room": "Kitchen",
		"methods": ["ambush", "struggle"], "strength": "low",
		"wound": "a deep wound below the ribs", "trace": "a smear of blood along the doorframe",
	},
	{
		"name": "a vial of poison in his brandy", "home_room": "Kitchen",
		"methods": ["poison"], "strength": "low",
		"wound": "no wound at all - his face is grey and his lips are blue",
		"trace": "a brandy glass, drained, set down neatly",
	},
	{
		"name": "a length of curtain cord", "home_room": "Ballroom",
		"methods": ["ambush", "struggle"], "strength": "medium",
		"wound": "a thin livid line across the throat", "trace": "a curtain hanging untied",
	},
	{
		"name": "a length of garden wire", "home_room": "Conservatory",
		"methods": ["ambush", "struggle"], "strength": "medium",
		"wound": "a thin livid line across the throat", "trace": "a coil of wire cut short",
	},
	{
		"name": "a heavy stone planter", "home_room": "Conservatory",
		"methods": ["ambush", "staged"], "strength": "high",
		"wound": "a crushing injury to the skull", "trace": "spilled earth and a broken rim",
	},
	{
		"name": "the fireplace poker", "home_room": "Lounge",
		"methods": ["ambush", "struggle", "staged"], "strength": "medium",
		"wound": "a heavy blow to the back of the head", "trace": "soot trodden into the rug",
	},
	{
		"name": "a silver letter opener", "home_room": "Study",
		"methods": ["ambush", "struggle"], "strength": "low",
		"wound": "a single narrow puncture", "trace": "a scatter of opened correspondence",
	},
	{
		"name": "a marble paperweight", "home_room": "Study",
		"methods": ["ambush", "struggle", "staged"], "strength": "medium",
		"wound": "a heavy blow to the temple", "trace": "papers swept off the desk",
	},
	{
		"name": "a heavy brass candlestick", "home_room": "Dining Room",
		"methods": ["ambush", "struggle", "staged"], "strength": "medium",
		"wound": "a heavy blow to the back of the head", "trace": "wax spattered across the floor",
	},
	{
		"name": "an antique duelling pistol", "home_room": "Billiard Room",
		"methods": ["ambush", "struggle"], "strength": "low",
		"wound": "a single gunshot wound", "trace": "the smell of powder still hanging in the air",
	},
	{
		"name": "a billiard cue", "home_room": "Billiard Room",
		"methods": ["struggle", "staged"], "strength": "medium",
		"wound": "a heavy blow across the temple", "trace": "a cue snapped in two",
	},
	{
		"name": "a heavy bronze bookend", "home_room": "Library",
		"methods": ["ambush", "struggle", "staged"], "strength": "medium",
		"wound": "a crushing injury to the skull", "trace": "books pulled down from a shelf",
	},
]

## How the killing went, which drives the body description and which evidence
## gets scattered at the scene in Phase 3.
const METHODS := {
	"ambush": "struck from behind, without warning - he never saw who it was",
	"struggle": "there was a fight; the room is disturbed and his hands are marked",
	"poison": "no violence at all - he simply stopped, sitting down, glass in hand",
	"staged": "arranged afterwards to look like an accident, and not quite convincingly",
}

# ------------------------------------------------------------- house layout --

static var _adjacency: Dictionary = {}


## room -> Array of rooms reachable in one slot (itself, plus orthogonal
## neighbours on the 3x3 grid). Built once, lazily.
static func adjacency() -> Dictionary:
	if not _adjacency.is_empty():
		return _adjacency
	var pos := {}
	for r in range(GRID.size()):
		for c in range(GRID[r].size()):
			pos[GRID[r][c]] = Vector2i(r, c)
	for room in pos.keys():
		var p: Vector2i = pos[room]
		var out := [room]
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = p + d
			if n.x >= 0 and n.x < GRID.size() and n.y >= 0 and n.y < GRID[n.x].size():
				out.append(GRID[n.x][n.y])
		_adjacency[room] = out
	return _adjacency


static func all_rooms() -> Array:
	return adjacency().keys()


## Shortest room-by-room route from `a` to `b` inclusive, or [] if unreachable.
static func route(a: String, b: String) -> Array:
	if a == b:
		return [a]
	var adj := adjacency()
	var queue := [[a]]
	var seen := {a: true}
	while not queue.is_empty():
		var path: Array = queue.pop_front()
		for n in adj.get(path[path.size() - 1], []):
			if seen.has(n):
				continue
			if n == b:
				return path + [n]
			seen[n] = true
			queue.append(path + [n])
	return []


# ---------------------------------------------------------------- the walk --

## One suspect's evening. Starts at `start`, produces SLOT_COUNT rooms.
##
## `forbid` is a Dictionary of "slot:room" -> true, used to keep innocents out
## of the murder room from the murder slot onwards. `census` is an Array of SLOT_COUNT
## Dictionaries of {room: headcount}, used to spread the cast out; pass an
## empty Array to skip the cap. (Empty rather than null because GDScript typed
## parameters reject null.)
static func _walk(rng: RandomNumberGenerator, start: String, forbid: Dictionary, census: Array) -> Array:
	var adj := adjacency()
	var path := [start]
	for i in range(1, SLOT_COUNT):
		var cur: String = path[i - 1]
		var opts: Array = adj[cur]
		var chosen := ""
		for _try in range(24):
			var cand: String = cur if rng.randf() < INERTIA else String(opts[rng.randi() % opts.size()])
			if _blocked(cand, i, forbid, census):
				continue
			chosen = cand
			break
		if chosen == "":
			# Every random draw was blocked. Falling back to `cur` is NOT safe:
			# if cur happens to be the forbidden room, staying put walks this
			# suspect straight into the murder and the case fails validation.
			# Prefer any fully unblocked neighbour; failing that, at least
			# respect `forbid` and let the headcount cap slide.
			var allowed := []
			for o in opts:
				if not _blocked(String(o), i, forbid, census):
					allowed.append(o)
			if not allowed.is_empty():
				chosen = String(allowed[rng.randi() % allowed.size()])
			elif forbid.has("%d:%s" % [i, cur]):
				var soft := []
				for o in opts:
					if not forbid.has("%d:%s" % [i, String(o)]):
						soft.append(o)
				chosen = String(soft[rng.randi() % soft.size()]) if not soft.is_empty() else cur
			else:
				chosen = cur
		path.append(chosen)
	if not census.is_empty():
		for i in range(path.size()):
			var slot: Dictionary = census[i]
			slot[path[i]] = int(slot.get(path[i], 0)) + 1
	return path


static func _blocked(room: String, slot: int, forbid: Dictionary, census: Array) -> bool:
	if forbid.has("%d:%s" % [slot, room]):
		return true
	if not census.is_empty() and int(Dictionary(census[slot]).get(room, 0)) >= MAX_PER_ROOM:
		return true
	return false


## A path that visits `stops` in order and is exactly `end_slot + 1` long,
## padded out by repeating rooms (i.e. lingering) at random points. Returns []
## if the stops can't be reached in that many slots.
static func _padded_route(rng: RandomNumberGenerator, stops: Array, end_slot: int) -> Array:
	var core := [String(stops[0])]
	for i in range(1, stops.size()):
		var leg := route(String(stops[i - 1]), String(stops[i]))
		if leg.is_empty():
			return []
		for j in range(1, leg.size()):
			core.append(leg[j])
	var need := end_slot + 1
	if core.size() > need:
		return []
	while core.size() < need:
		var at := rng.randi() % core.size()
		core.insert(at, core[at])
	return core


# ------------------------------------------------------------- generation --

## Builds one complete case for the given suspect ids. Returns {} if it somehow
## can't (should never happen - it retries MAX_ATTEMPTS times and converges in
## about 4). Pass an `rng` with a set seed to reproduce a specific case.
##
## The returned Dictionary:
##   murderer_id     String
##   murder_slot     int  (index into SLOT_TIMES)
##   murder_room     String
##   weapon          Dictionary (an entry from WEAPONS)
##   method          String (key of METHODS)
##   victim_path     Array[String], SLOT_COUNT long
##   true_paths      { id: Array[String] }  what actually happened
##   claimed_paths   { id: Array[String] }  what they'll tell you
##   diverge_from/to int  the slots where the murderer's story is false
##   claimed_room    String  where the murderer says they were instead
##   witness_ids     Array[String]  innocents who can contradict that claim
##   seed            int
static func generate(active_ids: Array, rng: RandomNumberGenerator = null) -> Dictionary:
	if active_ids.size() < 2:
		return {}
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	var used_seed := rng.seed

	for _attempt in range(MAX_ATTEMPTS):
		var murderer := String(active_ids[rng.randi() % active_ids.size()])
		var innocents := []
		for id in active_ids:
			if String(id) != murderer:
				innocents.append(String(id))

		var murder_slot := MURDER_SLOT_MIN + rng.randi() % (MURDER_SLOT_MAX - MURDER_SLOT_MIN + 1)
		# Duplicated because const containers are read-only in Godot 4.4+, and
		# this dictionary is handed out to the rest of the game.
		var weapon: Dictionary = Dictionary(WEAPONS[rng.randi() % WEAPONS.size()]).duplicate(true)
		var methods: Array = weapon["methods"]
		var method := String(methods[rng.randi() % methods.size()])

		# The murder room is never the weapon's home room - that would make
		# constraint 6 vacuous and throw away the best clue in the case.
		var room_pool := []
		for r in all_rooms():
			if NO_MURDER_ROOMS.has(r) or r == weapon["home_room"]:
				continue
			room_pool.append(r)
		if room_pool.is_empty():
			continue
		var murder_room := String(room_pool[rng.randi() % room_pool.size()])

		# --- the victim ---
		# Dinner, then a detour, then the room he dies in. The detour is the
		# point: "when did you last see Lord Archibald" is only interesting if
		# he was seen in more than one place over the evening.
		var detour_pool := []
		for r in all_rooms():
			if r != DINNER_ROOM and r != murder_room:
				detour_pool.append(r)
		var detour := String(detour_pool[rng.randi() % detour_pool.size()])
		var victim_path := _padded_route(rng, [DINNER_ROOM, detour, murder_room], murder_slot)
		if victim_path.is_empty():
			victim_path = _padded_route(rng, [DINNER_ROOM, murder_room], murder_slot)
		if victim_path.is_empty() or _distinct(victim_path) < 2:
			continue
		# After he's killed he stays exactly where he fell.
		while victim_path.size() < SLOT_COUNT:
			victim_path.append(murder_room)

		# Once the killing is done the murderer shuts the door on the way out,
		# and it stays shut until the body is found in the morning. Nobody -
		# including the murderer - sets foot in that room again for the rest of
		# the night. Without this the schedules produce guests strolling in and
		# out of a room with a corpse on the floor, saying nothing about it,
		# which reads as a bug to any player who checks the timeline.
		var sealed := {}
		for s in range(murder_slot, SLOT_COUNT):
			sealed["%d:%s" % [s, murder_room]] = true

		# --- the murderer ---
		# Dinner, through the room the weapon lives in, to the murder room -
		# then a free walk once it's done.
		var m_path := _padded_route(rng, [DINNER_ROOM, String(weapon["home_room"]), murder_room], murder_slot)
		if m_path.is_empty():
			continue
		# The tail is offset so tail[i] lands on slot murder_slot + i; blocking
		# index 1 upwards is what stops the murderer wandering back in later.
		var tail_forbid := {}
		for i in range(1, SLOT_COUNT):
			tail_forbid["%d:%s" % [i, murder_room]] = true
		var tail := _walk(rng, murder_room, tail_forbid, [])
		if Array(tail).slice(1).has(murder_room):
			continue
		for i in range(1, SLOT_COUNT - murder_slot):
			m_path.append(tail[i])
		if m_path.size() != SLOT_COUNT:
			continue

		# --- everyone else ---
		var true_paths := {murderer: m_path}
		var census := []
		for i in range(SLOT_COUNT):
			census.append({})
		for i in range(SLOT_COUNT):
			var slot: Dictionary = census[i]
			slot[m_path[i]] = int(slot.get(m_path[i], 0)) + 1

		var spoiled := false
		for pid in innocents:
			var p := _walk(rng, DINNER_ROOM, sealed, census)
			if _distinct(p) < 2: # nobody sits in one room the entire night
				spoiled = true
				break
			# _walk's last-resort fallback can ignore `forbid` in a corner case;
			# rather than trust it, throw the case away and try again.
			for s in range(murder_slot, SLOT_COUNT):
				if String(p[s]) == murder_room:
					spoiled = true
					break
			if spoiled:
				break
			true_paths[pid] = p
		if spoiled:
			continue

		# --- the lie ---
		# One contiguous block covering the murder slot, 1 or 2 slots long. The
		# room they claim must be somewhere an innocent actually was, or nobody
		# in the house can contradict them and the case is unwinnable.
		var block_len := 1 + rng.randi() % 2
		var b_start := murder_slot
		if block_len == 2 and rng.randi() % 2 == 0:
			b_start = murder_slot - 1
		b_start = maxi(DINNER_SLOTS, b_start)
		var b_end := mini(SLOT_COUNT - 1, b_start + block_len - 1)

		var before := String(m_path[b_start - 1])
		var after := String(m_path[b_end + 1]) if b_end + 1 < SLOT_COUNT else ""
		var adj := adjacency()

		# The claimed room must be somewhere an innocent stood AT THE MURDER
		# SLOT specifically - not merely somewhere in the lie block.
		#
		# Anywhere-in-the-block looks equivalent and isn't. The murderer often
		# walks into the room they're claiming later in the same block, quite
		# innocently, once the killing is done. A witness who only overlaps
		# that tail saw them exactly where they said they were, and confirms
		# the alibi instead of breaking it. Pinning the witness to the murder
		# slot - the one moment the murderer provably cannot have been there -
		# takes the guarantee from 98% to 100%.
		var candidates := {}
		for pid in innocents:
			var r := String(true_paths[pid][murder_slot])
			if r == murder_room:
				continue
			if not adj[before].has(r):
				continue
			if after != "" and not adj[after].has(r):
				continue
			candidates[r] = true
		if candidates.is_empty():
			continue
		var keys := candidates.keys()
		var claimed_room := String(keys[rng.randi() % keys.size()])

		var claimed_paths := {}
		for pid in active_ids:
			claimed_paths[String(pid)] = Array(true_paths[String(pid)]).duplicate()
		for s in range(b_start, b_end + 1):
			claimed_paths[murderer][s] = claimed_room

		# Who can actually call them a liar: whoever was standing in the claimed
		# room at the exact moment of the murder.
		var witnesses := []
		for pid in innocents:
			if String(true_paths[pid][murder_slot]) == claimed_room:
				witnesses.append(pid)
		if witnesses.is_empty():
			continue

		# Whose belonging is found at the scene. Half the time the murderer's;
		# otherwise an innocent who genuinely passed through that room, so
		# their explanation checks out and the item is a red herring rather
		# than a lie the game is telling.
		#
		# Drawn from the case RNG rather than a global one on purpose: this is
		# a fact of the mystery, not set dressing, so replaying a case code has
		# to produce the same item. Anything the player reasons about belongs
		# in here.
		var item_candidates := []
		for pid in innocents:
			if Array(true_paths[pid]).has(murder_room):
				item_candidates.append(pid)
		# Weighted 4-in-5 toward the innocent, not a straight coin flip. An
		# innocent only passes through the murder room in about half of cases
		# (the sealed-room rule cut this further, since they can now only do it
		# BEFORE the killing), so every time there's no candidate this falls
		# back to the murderer - an even flip on top of that lands high, which
		# makes the item close to a pointer at the killer. Leaning the other
		# way brings it back to roughly 50/50, which is what a red herring
		# needs to be: informative, but not something you can act on alone.
		var evidence_owner := murderer
		if not item_candidates.is_empty() and rng.randi() % 5 != 0:
			evidence_owner = String(item_candidates[rng.randi() % item_candidates.size()])

		return {
			"murderer_id": murderer,
			"evidence_owner_id": evidence_owner,
			"murder_slot": murder_slot,
			"murder_room": murder_room,
			"weapon": weapon,
			"method": method,
			"victim_path": victim_path,
			"true_paths": true_paths,
			"claimed_paths": claimed_paths,
			"diverge_from": b_start,
			"diverge_to": b_end,
			"claimed_room": claimed_room,
			"witness_ids": witnesses,
			"seed": used_seed,
			"attempts": _attempt + 1,
		}

	return {}


static func _distinct(path: Array) -> int:
	var seen := {}
	for r in path:
		seen[r] = true
	return seen.size()


# ------------------------------------------------------------- validation --

## Returns an Array of human-readable problems - empty means the case is sound.
## Every rule the design depends on is checked here rather than assumed, so the
## test scene can hammer the generator and catch a regression the moment one
## appears.
static func validate(c: Dictionary, active_ids: Array) -> Array:
	var errs := []
	if c.is_empty():
		return ["generation returned nothing"]

	var adj := adjacency()
	var ms := int(c["murder_slot"])
	var mr := String(c["murder_room"])
	var mu := String(c["murderer_id"])

	if ms < MURDER_SLOT_MIN or ms > MURDER_SLOT_MAX:
		errs.append("murder slot %d out of range" % ms)
	if NO_MURDER_ROOMS.has(mr):
		errs.append("murder happened in %s" % mr)
	if mr == String(Dictionary(c["weapon"])["home_room"]):
		errs.append("murder room is the weapon's home room")
	if not Array(Dictionary(c["weapon"])["methods"]).has(String(c["method"])):
		errs.append("method %s impossible with that weapon" % String(c["method"]))

	# Everyone's evening must be physically walkable and start at dinner.
	for id in active_ids:
		var pid := String(id)
		if not c["true_paths"].has(pid):
			errs.append("%s has no path" % pid)
			continue
		var p: Array = c["true_paths"][pid]
		if p.size() != SLOT_COUNT:
			errs.append("%s path is %d slots" % [pid, p.size()])
			continue
		for i in range(DINNER_SLOTS):
			if String(p[i]) != DINNER_ROOM:
				errs.append("%s missed dinner" % pid)
		for i in range(1, SLOT_COUNT):
			if not adj[p[i - 1]].has(p[i]):
				errs.append("%s teleported %s -> %s at slot %d" % [pid, p[i - 1], p[i], i])
		if _distinct(p) < 2:
			errs.append("%s never left one room all night" % pid)

	# The victim.
	var vp: Array = c["victim_path"]
	if vp.size() != SLOT_COUNT:
		errs.append("victim path is %d slots" % vp.size())
	else:
		if String(vp[0]) != DINNER_ROOM:
			errs.append("victim missed dinner")
		for i in range(1, SLOT_COUNT):
			if not adj[vp[i - 1]].has(vp[i]):
				errs.append("victim teleported at slot %d" % i)
		if String(vp[ms]) != mr:
			errs.append("victim wasn't in the murder room when he died")
		if _distinct(vp.slice(0, ms + 1)) < 2:
			errs.append("victim never moved before he died")

	# Opportunity: the murderer alone with him, nobody else in the room.
	if String(c["true_paths"][mu][ms]) != mr:
		errs.append("murderer wasn't at the scene")
	for id in active_ids:
		var pid2 := String(id)
		if pid2 != mu and String(c["true_paths"][pid2][ms]) == mr:
			errs.append("%s was standing in the murder room" % pid2)

	# The sealed room: the killer shuts the door behind him and the body isn't
	# found until morning, so NOBODY - not even the killer - is in that room
	# again for the rest of the night. A suspect whose schedule walks them past
	# a corpse without remarking on it is the single most obvious way for the
	# timeline to look broken to a player reading it back.
	for id in active_ids:
		var pid4 := String(id)
		for s in range(ms + 1, SLOT_COUNT):
			if String(c["true_paths"][pid4][s]) == mr:
				errs.append("%s entered the murder room at slot %d, after the killing" % [pid4, s])

	# Means: they must have passed through the room the weapon lives in.
	var home := String(Dictionary(c["weapon"])["home_room"])
	if not Array(c["true_paths"][mu]).slice(0, ms).has(home):
		errs.append("murderer never went near the weapon")

	# The solvability rule: innocents tell the truth, the murderer doesn't.
	for id in active_ids:
		var pid3 := String(id)
		if pid3 == mu:
			continue
		if c["claimed_paths"][pid3] != c["true_paths"][pid3]:
			errs.append("innocent %s is lying about their evening" % pid3)

	var cp: Array = c["claimed_paths"][mu]
	for i in range(1, SLOT_COUNT):
		if not adj[cp[i - 1]].has(cp[i]):
			errs.append("murderer's story teleports at slot %d" % i)
	var bs := int(c["diverge_from"])
	var be := int(c["diverge_to"])
	if bs > ms or be < ms:
		errs.append("the lie doesn't cover the murder slot")
	if String(cp[ms]) == mr:
		errs.append("murderer admits to being at the scene")
	for i in range(SLOT_COUNT):
		var differs := String(cp[i]) != String(c["true_paths"][mu][i])
		if differs and (i < bs or i > be):
			errs.append("murderer's story differs outside the lie block at slot %d" % i)

	# And the guarantee that makes every case winnable.
	if Array(c["witness_ids"]).is_empty():
		errs.append("NOBODY can contradict the murderer - case is unwinnable")
	for wid in c["witness_ids"]:
		# Must be there at the murder slot itself, not merely somewhere in the
		# lie block - see the comment in generate(). A witness who only
		# overlaps the tail of the block corroborates the alibi instead of
		# breaking it, and the case becomes unwinnable in play while still
		# looking sound on paper.
		if String(c["true_paths"][String(wid)][ms]) != String(c["claimed_room"]):
			errs.append("%s listed as a witness but wasn't in the %s at the murder slot" % [String(wid), String(c["claimed_room"])])

	# And the account the witness will actually give must visibly disagree:
	# their run-length block covering the murder slot has to place them in the
	# claimed room WITHOUT the murderer.
	var disproved := false
	for wid in c["witness_ids"]:
		for b in account_blocks(c, String(wid), Array(c["true_paths"][String(wid)])):
			if String(b["room"]) != String(c["claimed_room"]):
				continue
			if int(b["from_slot"]) > ms or int(b["to_slot"]) < ms:
				continue
			if not Array(b["companions"]).has(mu):
				disproved = true
	if not disproved:
		errs.append("no witness's spoken account actually contradicts the alibi")

	return errs


# ------------------------------------------------------------ presentation --

## Run-length encodes a path into [{room, from_slot, to_slot}, ...]. This is
## what gets shown to a suspect: three slots in the Library become one line,
## which is why an 8-slot grid still fits in a handful of prompt lines.
static func blocks(path: Array) -> Array:
	var out := []
	for i in range(path.size()):
		var room := String(path[i])
		if not out.is_empty() and String(out[out.size() - 1]["room"]) == room:
			out[out.size() - 1]["to_slot"] = i
		else:
			out.append({"room": room, "from_slot": i, "to_slot": i})
	return out


## "8:30 to 9:30" for a run-length block.
static func block_time(b: Dictionary) -> String:
	return "%s to %s" % [SLOT_TIMES[int(b["from_slot"])], SLOT_END_TIMES[int(b["to_slot"])]]


## Splits `path` into the blocks a suspect would actually narrate: a new block
## whenever the room changes OR the set of people with them changes.
##
## Splitting on room alone is not enough, and the failure is subtle enough to
## be worth spelling out. Suppose the murderer claims the Kitchen for the half
## hour she was really killing him, and an innocent walks into that same
## Kitchen an hour later. Collapsed by room, the innocent's account reads "the
## Kitchen, 10:30 to midnight, with Victoria" - and the one witness who is
## supposed to break her alibi ends up confirming it, because the block hides
## when he actually arrived. Every case would look solvable to the generator
## and be unwinnable in play.
##
## Returns [{room, from_slot, to_slot, companions: Array[id]}].
static func account_blocks(c: Dictionary, id: String, path: Array) -> Array:
	var out := []
	for s in range(path.size()):
		var room := String(path[s])
		var mates := []
		for pid in c["true_paths"].keys():
			if String(pid) == id:
				continue
			if String(c["true_paths"][pid][s]) == room:
				mates.append(String(pid))
		mates.sort()

		var extend := false
		if not out.is_empty():
			var last: Dictionary = out[out.size() - 1]
			extend = String(last["room"]) == room and Array(last["companions"]) == mates
		if extend:
			out[out.size() - 1]["to_slot"] = s
		else:
			out.append({"room": room, "from_slot": s, "to_slot": s, "companions": mates})
	return out


## Everyone (other suspects only) sharing a room with `id` during a block.
## Prefer account_blocks() for anything a character will say out loud - this
## reports anyone present for ANY part of the block, which is the right answer
## for a summary and the wrong one for an alibi.
static func companions(c: Dictionary, id: String, b: Dictionary) -> Array:
	var out := []
	for pid in c["true_paths"].keys():
		if String(pid) == id:
			continue
		for s in range(int(b["from_slot"]), int(b["to_slot"]) + 1):
			if String(c["true_paths"][pid][s]) == String(b["room"]) and not out.has(pid):
				out.append(String(pid))
	return out


## The last slot at which `id` was in the same room as the victim while he was
## still alive, or -1. Drives "when did you last see Lord Archibald".
static func last_saw_victim(c: Dictionary, id: String) -> int:
	var latest := -1
	for s in range(0, int(c["murder_slot"]) + 1):
		if s == int(c["murder_slot"]) and String(id) != String(c["murderer_id"]):
			continue
		if String(c["true_paths"][id][s]) == String(c["victim_path"][s]):
			latest = s
	return latest


## The half-hour slot the house's forensic expert will state as the time of
## death, having examined the body herself.
##
## Innocent, she simply reports the truth, which collapses the body's 90-minute
## window to a single slot and eliminates whoever was accounted for then.
##
## Guilty, she has the one qualification in the house that lets her be believed
## about this, and every reason to use it. Her false time is chosen to be
## - outside the window the body itself suggests, so a detective who examined
##   the body can catch the discrepancy without needing anyone's help, and
## - a slot where she was genuinely with somebody, so her expert opinion hands
##   her a corroborated alibi.
##
## Returns the slot index, or -1 if there is no expert in play.
static func expert_claim_slot(c: Dictionary, expert_id: String) -> int:
	if c.is_empty() or not Dictionary(c["true_paths"]).has(expert_id):
		return -1
	var ms := int(c["murder_slot"])
	if expert_id != String(c["murderer_id"]):
		return ms

	var window := death_window(c)
	var outside := []
	var outside_and_alibied := []
	for s in range(DINNER_SLOTS, SLOT_COUNT):
		if s >= int(window[0]) and s <= int(window[1]):
			continue
		outside.append(s)
		for pid in c["true_paths"].keys():
			if String(pid) == expert_id:
				continue
			if String(c["true_paths"][pid][s]) == String(c["true_paths"][expert_id][s]):
				if not outside_and_alibied.has(s):
					outside_and_alibied.append(s)
	if not outside_and_alibied.is_empty():
		return int(outside_and_alibied[0])
	if not outside.is_empty():
		return int(outside[0])
	# Nowhere outside the window works; any slot but the real one still lies.
	for s in range(DINNER_SLOTS, SLOT_COUNT):
		if s != ms:
			return s
	return ms


## The coarse time-of-death window shown when the body is examined: 3 slots
## (90 minutes) containing the truth but not pinning it. Evelyn Blackwood's
## job is to narrow this to the single true slot.
static func death_window(c: Dictionary) -> Array:
	var ms := int(c["murder_slot"])
	var from := maxi(0, mini(ms - 1, SLOT_COUNT - 3))
	var to := mini(SLOT_COUNT - 1, from + 2)
	return [from, to]
