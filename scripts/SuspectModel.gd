extends RefCounted
# Builds the visual body that stands under each suspect's CharacterBody3D.
#
# Reached by path, not by class_name: Main.gd and NPCCharacter.gd each hold a
# `const SuspectModel = preload("res://Scripts/SuspectModel.gd")`. A class_name
# here works most of the time, but Godot registers global classes during a
# filesystem scan that can run *after* it parses the scripts using them - so
# the first launch after adding this file, or a fresh clone, fails with
# 'Identifier "SuspectModel" not declared in the current scope'. preload
# resolves at parse time from the path and cannot lose that race.
#
# Drop a model file (.blend, .glb, .gltf or .fbx) into
#     res://Models/Suspects/<character_id>/
# and that suspect stops being a colored capsule and starts being that model.
# The filename does not matter - only which folder it is in. Suspects whose
# folder is still empty keep the original capsule, so the game runs normally
# at any point in the middle of swapping the cast over one at a time.
#
# Per-suspect tweaks (height, facing, scale) live in
#     res://Models/Suspects/suspect_models.cfg
# and none of them are required. See Models/Suspects/README.md.


const SUSPECTS_DIR := "res://Models/Suspects"
const CONFIG_PATH := "res://Models/Suspects/suspect_models.cfg"

## Extensions Godot can import as a 3D scene. .obj and .dae are accepted for
## completeness but carry no skeleton, so a suspect using one will never
## animate no matter what else is set up.
const MODEL_EXTENSIONS := [
	"blend", "glb", "gltf", "fbx", "dae", "escn", "obj", "tscn", "scn", "res"
]

## Matches the capsule that used to stand in for every suspect, and the
## CollisionShape3D in Main._spawn_npcs() that is still the real collider.
## Models are fitted to this height so what you see lines up with what the
## player actually bumps into.
const BODY_HEIGHT := 1.8
const BODY_RADIUS := 0.4

## Clip names looked for inside an imported model, best match first. Matching
## ignores case and any "Armature|" style prefix, so "Armature|walk_a" here
## matches "Walk_A" below.
const IDLE_ANIMATIONS := ["Idle", "Idle_A", "Idle_Loop", "Stand", "Breathing Idle"]
const WALK_ANIMATIONS := ["Walk", "Walk_A", "Walk_Loop", "Walking", "Run", "Running"]


## Absolute res:// path of the model file sitting in this suspect's folder, or
## "" when the folder is missing or holds no model. If more than one model is
## in there the alphabetically first one wins, so the answer is never
## ambiguous and never depends on filesystem ordering.
static func find_model_path(character_id: String) -> String:
	var dir_path := "%s/%s" % [SUSPECTS_DIR, character_id]
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return ""

	var found: Array[String] = []
	for file_name in dir.get_files():
		# In an exported build the source file is replaced by .import/.remap
		# siblings, so strip those suffixes before reading the real extension.
		var clean := file_name
		if clean.ends_with(".import") or clean.ends_with(".remap"):
			clean = clean.get_basename()
		if not MODEL_EXTENSIONS.has(clean.get_extension().to_lower()):
			continue
		if not found.has(clean):
			found.append(clean)

	if found.is_empty():
		return ""
	found.sort()
	return "%s/%s" % [dir_path, found[0]]


## True when this suspect has a model waiting for them. Handy for a quick
## audit of who is still a capsule.
static func has_model(character_id: String) -> bool:
	return find_model_path(character_id) != ""


## The node to parent under a suspect's CharacterBody3D: their imported model
## if one has been dropped in, otherwise the colored capsule the game shipped
## with. Never returns null - a bad or unloadable file falls back to the
## capsule with a warning rather than leaving an invisible suspect.
static func build_visual(character_id: String, fallback_color: Color) -> Node3D:
	var path := find_model_path(character_id)
	if path == "":
		return _build_capsule(fallback_color)

	var res := load(path)
	var model: Node3D = null

	if res is PackedScene:
		var inst := (res as PackedScene).instantiate()
		if inst is Node3D:
			model = inst as Node3D
		else:
			inst.free()
	elif res is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = res
		model = mi

	if model == null:
		push_warning(
			"SuspectModel: could not use '%s' as a 3D model - '%s' stays a capsule."
			% [path, character_id]
		)
		return _build_capsule(fallback_color)

	model.name = "Model"
	_apply_tuning(model, character_id)
	return model


# ------------------------------------------------------------- animation --

## First AnimationPlayer anywhere under `root`, or null. Godot's glTF/.blend
## importer puts one directly under the imported scene root, but FBX rigs
## sometimes bury it a level deeper, so this searches rather than assuming.
static func find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root as AnimationPlayer
	for child in root.get_children():
		var found := find_animation_player(child)
		if found != null:
			return found
	return null


## First clip on `player` matching one of `candidates`, case-insensitively and
## ignoring any "Armature|" prefix. Returns "" when the model has no matching
## clip; callers treat that as "do not animate", not as an error, because the
## Quaternius base characters ship with no animations at all.
static func pick_animation(player: AnimationPlayer, candidates: Array) -> String:
	if player == null:
		return ""
	var available := player.get_animation_list()
	for wanted in candidates:
		var wanted_lower := String(wanted).to_lower()
		for clip in available:
			if _bare_name(String(clip)).to_lower() == wanted_lower:
				return String(clip)
	return ""


static func _bare_name(clip: String) -> String:
	var bar := clip.rfind("|")
	return clip.substr(bar + 1) if bar != -1 else clip


# ---------------------------------------------------------------- private --

static func _build_capsule(color: Color) -> Node3D:
	var mesh := MeshInstance3D.new()
	mesh.name = "Model"
	var cap := CapsuleMesh.new()
	cap.height = BODY_HEIGHT
	cap.radius = BODY_RADIUS
	mesh.mesh = cap
	mesh.position.y = BODY_HEIGHT * 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	return mesh


## Applies suspect_models.cfg to a freshly instantiated model. With no config
## file present every value falls back to a sensible default, which is why
## dropping a .blend in and doing nothing else works.
static func _apply_tuning(model: Node3D, character_id: String) -> void:
	var cfg := ConfigFile.new()
	var has_cfg := cfg.load(CONFIG_PATH) == OK

	var auto_fit := bool(_cfg_value(cfg, has_cfg, character_id, "auto_fit_height", true))
	var scale_mult := float(_cfg_value(cfg, has_cfg, character_id, "scale", 1.0))
	var y_offset := float(_cfg_value(cfg, has_cfg, character_id, "y_offset", 0.0))
	var rot_y := float(_cfg_value(cfg, has_cfg, character_id, "rot_y", 0.0))

	var final_scale := scale_mult
	var feet_correction := 0.0

	if auto_fit:
		var bounds := _model_bounds(model)
		if bounds.size.y > 0.001:
			# Whatever units the artist worked in, end up 1.8m tall so the
			# model matches its own collision capsule and the doorways.
			final_scale = (BODY_HEIGHT / bounds.size.y) * scale_mult
			# Sit the lowest point on the floor, so a model whose origin is at
			# the hips (or anywhere but the soles) still stands on the ground
			# instead of sinking into it or hovering above it.
			feet_correction = -bounds.position.y * final_scale

	model.scale = Vector3.ONE * final_scale
	model.rotation_degrees = Vector3(0.0, rot_y, 0.0)
	model.position.y = feet_correction + y_offset


## Looks up `key` in the suspect's own section first, then [default], then the
## hardcoded fallback - so one line in [default] can fix all twelve at once
## while a single odd model can still override it.
static func _cfg_value(
	cfg: ConfigFile, has_cfg: bool, character_id: String, key: String, fallback: Variant
) -> Variant:
	if not has_cfg:
		return fallback
	if cfg.has_section_key(character_id, key):
		return cfg.get_value(character_id, key)
	if cfg.has_section_key("default", key):
		return cfg.get_value("default", key)
	return fallback


## Union of every mesh bounding box in the model, in the model root's own
## space. Used only to work out how tall the thing actually is.
static func _model_bounds(model: Node3D) -> AABB:
	var acc := {"found": false, "aabb": AABB()}
	# Starts from IDENTITY rather than model.transform: this measures the model
	# in its own space, because its transform is exactly what we are about to
	# overwrite.
	_collect_bounds(model, Transform3D.IDENTITY, acc)
	return acc["aabb"] if acc["found"] else AABB()


static func _collect_bounds(node: Node, xform: Transform3D, acc: Dictionary) -> void:
	if node is VisualInstance3D:
		var box: AABB = xform * (node as VisualInstance3D).get_aabb()
		if acc["found"]:
			acc["aabb"] = (acc["aabb"] as AABB).merge(box)
		else:
			acc["aabb"] = box
			acc["found"] = true

	for child in node.get_children():
		var next := xform
		if child is Node3D:
			next = xform * (child as Node3D).transform
		_collect_bounds(child, next, acc)
