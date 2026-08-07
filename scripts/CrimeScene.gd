extends Node
# Builds the physical crime scene for the generated case: the body where it
# fell, the weapon beside it, whatever the killing left behind, and the gap in
# the room the weapon was taken from.
#
# Everything here is derived from GameManager.case_data - the room, the weapon,
# the method and the time all come from CaseGenerator, so the scene rearranges
# itself every playthrough along with the rest of the mystery.
#
# Called from Main._build_world() after the mansion exists. Owns no input:
# every object it spawns is an Evidence node, which Player.gd's existing
# raycast already knows how to talk to.

const EvidenceScript = preload("res://Scripts/Evidence.gd")

const BODY_COLOR := Color(0.62, 0.15, 0.18)
const WEAPON_COLOR := Color(0.85, 0.8, 0.5)
const TRACE_COLOR := Color(0.35, 0.12, 0.12)
const ITEM_COLOR := Color(0.9, 0.85, 0.7)
const GAP_COLOR := Color(0.55, 0.5, 0.45)

## A personal possession per suspect, chosen to point at a person without
## naming them outright. Finding Eleanor's cigarette case at the scene should
## send the detective to ask Eleanor what it was doing there - not hand them
## the answer, since an innocent may have a perfectly good reason.
const PERSONAL_ITEMS := {
	"blackwood": "a pair of thin surgical gloves, folded",
	"sterling": "a gold cufflink, monogrammed",
	"ashford": "a jeweller's loupe on a chain",
	"carter": "a cheap notebook, several pages torn out",
	"whitmore": "a silver cigarette case",
	"reeves": "a heavy ring of house keys",
	"cross_natalie": "a shorthand pad, half filled",
	"cross_eugene": "a folded white serving glove",
}


## Builds everything and returns the Node3D holding it, so Main can free the
## whole scene on a restart with one call.
static func build(main: Node3D, parent: Node3D) -> Node3D:
	var root := Node3D.new()
	root.name = "CrimeScene"
	parent.add_child(root)

	var case: Dictionary = GameManager.case_data
	if case.is_empty():
		return root # fallback scenario - no generated case to dress

	var weapon: Dictionary = case["weapon"]
	var room := String(case["murder_room"])
	var centre: Vector3 = main.room_centers.get(room, Vector3.ZERO)

	# Pushed into a corner of the room, not the middle. Rooms are CELL (12)
	# across, so ~4 from centre is comfortably clear of the walls - and, more
	# importantly, outside the ~3-unit ring _spawn_npcs() fans suspects onto.
	# A suspect whose schedule ended in the murder room would otherwise spawn
	# standing on the body, or get wedged against it while wandering.
	var spot := centre + Vector3(3.9, 0, -3.9)

	_build_body(main, root, case, spot)
	_build_weapon(main, root, case, weapon, spot + Vector3(-1.3, 0, 0.5))
	_build_trace(main, root, case, weapon, spot + Vector3(0.9, 0, 0.9))
	_build_weapon_gap(main, root, case, weapon)
	_build_personal_item(main, root, case, spot + Vector3(-0.2, 0, 1.5))
	if String(case["method"]) == "struggle":
		_build_disturbance(main, root, spot + Vector3(-1.9, 0, -0.9))
	return root


# ------------------------------------------------------------------ pieces --

static func _build_body(main: Node3D, root: Node3D, case: Dictionary, pos: Vector3) -> void:
	var body: StaticBody3D = main.add_solid_box(root, "Victim", Vector3(1.8, 0.45, 0.6), pos + Vector3(0, 0.22, 0), BODY_COLOR)
	_make_evidence(body, "body", "body", "Examine",
		"%s lies where he fell.\n\n%s" % [GameManager.VICTIM_NAME, _body_text(case)])

	var label := Label3D.new()
	label.text = GameManager.VICTIM_NAME
	label.position = Vector3(0, 1.1, 0)
	label.font_size = 32
	label.outline_size = 10
	label.modulate = Color(1, 0.75, 0.75)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	body.add_child(label)


static func _body_text(case: Dictionary) -> String:
	var weapon: Dictionary = case["weapon"]
	var window: Array = CaseGenerator.death_window(case)
	var t := "%s\n\n" % String(weapon["wound"])
	t += "%s\n\n" % String(CaseGenerator.METHODS[case["method"]])
	# Deliberately a 90-minute range rather than the true half-hour slot.
	# Narrowing it is Dr Blackwood's job - she is the only character whose
	# occupation makes her able to, which is what turns her from another
	# suspect into someone worth seeking out. (Phase 4.)
	t += "He has been dead since some time last night. Going by the body alone you would put it "
	t += "between %s and %s - no closer than that. " % [
		CaseGenerator.SLOT_TIMES[int(window[0])], CaseGenerator.SLOT_END_TIMES[int(window[1])]]
	t += "Someone who actually knows what they are looking at could probably narrow it."
	return t


static func _build_weapon(main: Node3D, root: Node3D, case: Dictionary, weapon: Dictionary, pos: Vector3) -> void:
	var node: StaticBody3D = main.add_solid_box(root, "Weapon", Vector3(0.5, 0.14, 0.5), pos + Vector3(0, 0.07, 0), WEAPON_COLOR)
	var t := "%s, discarded beside the body.\n\n" % _capitalise(String(weapon["name"]))
	# The single most useful clue the generator produces: the weapon lives
	# somewhere, so whoever used it passed through that room first. The
	# generator guarantees the murderer did (constraint 6).
	t += "It is not kept in this room. It belongs in the %s - which means whoever used it " % String(weapon["home_room"])
	t += "went there first, and then came here."
	_make_evidence(node, "weapon", "weapon", "Examine", t)


static func _build_trace(main: Node3D, root: Node3D, case: Dictionary, weapon: Dictionary, pos: Vector3) -> void:
	var node: StaticBody3D = main.add_solid_box(root, "Trace", Vector3(1.1, 0.03, 1.1), pos + Vector3(0, 0.02, 0), TRACE_COLOR)
	_make_evidence(node, "trace", "marks on the floor", "Look closer",
		"%s.\n\nWhatever happened here happened in this room. He was not moved." % _capitalise(String(weapon["trace"])))


## The other half of the weapon clue, left in the room the weapon was taken
## from - so a detective who never finds the body can still work out that
## something is missing from the Study, and start asking who was in it.
static func _build_weapon_gap(main: Node3D, root: Node3D, case: Dictionary, weapon: Dictionary) -> void:
	var home := String(weapon["home_room"])
	var centre: Vector3 = main.room_centers.get(home, Vector3.ZERO)
	# Opposite corner from where a crime scene would sit, and again outside the
	# suspect spawn ring - the weapon's home room is usually occupied.
	var node: StaticBody3D = main.add_solid_box(root, "WeaponGap", Vector3(0.8, 0.9, 0.8), centre + Vector3(-4.1, 0.45, -4.1), GAP_COLOR)
	var t := "A side table, and a clean patch in the dust the shape of something that is no longer here.\n\n"
	t += "This is where %s is normally kept. It is not here now." % String(weapon["name"])
	_make_evidence(node, "weapon_gap", "empty table", "Inspect", t)


## Somebody's belonging, at the scene. Half the time it is the murderer's; the
## rest of the time it belongs to an innocent who genuinely was in this room
## earlier in the evening and can say so truthfully. That ambiguity is the
## point - physical evidence should start a conversation, not end the game.
static func _build_personal_item(main: Node3D, root: Node3D, case: Dictionary, pos: Vector3) -> void:
	var murderer := String(case["murderer_id"])
	var owner_id := murderer

	var innocents_seen := []
	for pid in case["true_paths"].keys():
		if String(pid) == murderer:
			continue
		if Array(case["true_paths"][pid]).has(String(case["murder_room"])):
			innocents_seen.append(String(pid))

	# Coin flip, but only when there's an innocent whose presence in this room
	# is genuine - planting an item belonging to someone who was never here
	# would be a lie the game itself is telling.
	if not innocents_seen.is_empty() and randi() % 2 == 0:
		owner_id = String(innocents_seen[randi() % innocents_seen.size()])

	var item := String(PERSONAL_ITEMS.get(owner_id, "a personal effect"))
	var node: StaticBody3D = main.add_solid_box(root, "PersonalItem", Vector3(0.32, 0.1, 0.32), pos + Vector3(0, 0.05, 0), ITEM_COLOR)
	var t := "%s, on the floor near the body.\n\n" % _capitalise(item)
	t += "It belongs to one of the guests. It does not tell you when it was dropped - only that "
	t += "its owner was in this room at some point last night. Worth asking them about."
	_make_evidence(node, "personal_item", "dropped item", "Pick up", t)


static func _build_disturbance(main: Node3D, root: Node3D, pos: Vector3) -> void:
	var node: StaticBody3D = main.add_solid_box(root, "Disturbance", Vector3(0.6, 0.6, 0.6), pos + Vector3(0, 0.3, 0), Color(0.5, 0.38, 0.28))
	node.rotation_degrees = Vector3(0, 25, 74)
	_make_evidence(node, "disturbance", "overturned chair", "Examine",
		"A chair on its side, and a rug rucked up against the leg.\n\nHe fought. Whoever did this did not "
		+ "catch him unawares, and may not have come away from it unmarked.")


# ------------------------------------------------------------------ helpers --

static func _make_evidence(node: StaticBody3D, id: String, title: String, prompt: String, text: String) -> void:
	node.set_script(EvidenceScript)
	node.evidence_id = id
	node.title = title
	node.prompt = prompt
	node.examine_text = text


static func _capitalise(s: String) -> String:
	if s == "":
		return s
	return s.substr(0, 1).to_upper() + s.substr(1)
