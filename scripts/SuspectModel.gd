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

## Config keys starting with this recolor the material of the same name, e.g.
## `color_skin="#e8c19a"` retints every surface whose material is called Skin.
## Material names differ between models in the pack - Casual* use Shirt/Pants,
## Suit* use Black/Details, the Wizard uses Clothes/Gold - so this matches on
## whatever the model actually has rather than a fixed set of slots.
const COLOR_PREFIX := "color_"

## Material names repainted in the suspect's own notepad colour, so the person
## standing in the room is the same colour as their name in the case notes.
## Listed per suspect in suspect_models.cfg rather than hardcoded, because which
## material is "the outfit" differs by model: the Casual bodies wear a Shirt,
## the Suits wear Black with Details for trim, the Doctor wears Main and the
## Wizard wears Clothes. Comma-separated, e.g. tint_main="shirt, vest".
##
## An explicit color_<material> line always wins over a derived tint, so any one
## suspect can still be dressed entirely by hand.
const TINT_MAIN_KEY := "tint_main"
const TINT_ACCENT_KEY := "tint_accent"


# suspect_models.cfg was re-read from disk once per suspect and again for the
# victim - thirteen parses of the same small file inside a single spawn. Read it
# once and hand the same object out. reset_config_cache() is called at the start
# of every game so editing the file and hitting Play Again still picks it up,
# which is the workflow the file's own header promises.
static var _cfg_cache: ConfigFile = null
static var _cfg_cache_ok := false
static var _cfg_cache_valid := false


## Drops the cached suspect_models.cfg so the next spawn re-reads it. Called
## from Main._start_game().
static func reset_config_cache() -> void:
	_cfg_cache = null
	_cfg_cache_ok = false
	_cfg_cache_valid = false


## The parsed config, and whether it loaded at all. Every caller shares one
## instance; nothing here ever writes to it.
static func _config() -> Array:
	if not _cfg_cache_valid:
		_cfg_cache_valid = true
		_cfg_cache = ConfigFile.new()
		_cfg_cache_ok = _cfg_cache.load(CONFIG_PATH) == OK
	return [_cfg_cache, _cfg_cache_ok]

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
	return find_model_in_dir("%s/%s" % [SUSPECTS_DIR, character_id])


## The same lookup against any folder, so things that are not on the suspect
## roster - Lord Reginald's body in CrimeScene.gd - can use the same
## drop-a-file-in convention without having to pretend to be a suspect.
static func find_model_in_dir(dir_path: String) -> String:
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
	return build_from_dir("%s/%s" % [SUSPECTS_DIR, character_id], character_id, fallback_color)


## Builds from an explicit folder, reading tuning and color from `section` of
## suspect_models.cfg. build_visual() is this with both the folder and the
## config section derived from a character id.
static func build_from_dir(dir_path: String, section: String, fallback_color: Color) -> Node3D:
	var path := find_model_in_dir(dir_path)
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
			% [path, section]
		)
		return _build_capsule(fallback_color)

	model.name = "Model"
	var loaded := _config()
	var cfg: ConfigFile = loaded[0]
	var has_cfg: bool = loaded[1]
	_apply_tuning(model, cfg, has_cfg, section)
	_apply_recolor(model, cfg, has_cfg, section, fallback_color)
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
static func _apply_tuning(
	model: Node3D, cfg: ConfigFile, has_cfg: bool, character_id: String
) -> void:
	var auto_fit := bool(_cfg_value(cfg, has_cfg, character_id, "auto_fit_height", true))
	var scale_mult := float(_cfg_value(cfg, has_cfg, character_id, "scale", 1.0))
	var x_offset := float(_cfg_value(cfg, has_cfg, character_id, "x_offset", 0.0))
	var y_offset := float(_cfg_value(cfg, has_cfg, character_id, "y_offset", 0.0))
	var z_offset := float(_cfg_value(cfg, has_cfg, character_id, "z_offset", 0.0))
	# rot_x and rot_z exist for one reason: laying a standing model on its
	# back. Suspects only ever need rot_y.
	var rot_x := float(_cfg_value(cfg, has_cfg, character_id, "rot_x", 0.0))
	var rot_y := float(_cfg_value(cfg, has_cfg, character_id, "rot_y", 0.0))
	var rot_z := float(_cfg_value(cfg, has_cfg, character_id, "rot_z", 0.0))
	var center_xz := bool(_cfg_value(cfg, has_cfg, character_id, "center_xz", false))

	# Measured BEFORE any rotation, deliberately: a body tipped onto its back is
	# still a 1.8m man, and fitting his rotated height to 1.8 would inflate him
	# into a giant lying on the carpet.
	var bounds := _model_bounds(model)
	var final_scale := scale_mult
	if auto_fit and bounds.size.y > 0.001:
		# Whatever units the artist worked in, end up 1.8m tall so the model
		# matches its own collision capsule and the doorways.
		final_scale = (BODY_HEIGHT / bounds.size.y) * scale_mult

	model.scale = Vector3.ONE * final_scale
	model.rotation_degrees = Vector3(rot_x, rot_y, rot_z)
	model.position = Vector3.ZERO

	# Where the model actually lands once scaled and rotated. Placing from this
	# rather than from the raw bounds is what lets a model rotated about its feet
	# still come to rest on the floor instead of half inside it.
	var placed := model.transform * bounds

	var pos := Vector3(x_offset, y_offset, z_offset)
	if auto_fit:
		# Lowest point on the floor: a model whose origin sits at the hips - or one
		# rotated until its origin is level with its shoulder - still rests on the
		# ground rather than sinking or hovering.
		pos.y -= placed.position.y
	if center_xz:
		# Rotating about the feet leaves a lying figure sprawled off to one side of
		# its own origin. Only wanted when dropping a model onto an existing marker,
		# like the victim onto the body's collision box, so it stays opt-in and
		# every standing suspect is untouched.
		pos.x -= placed.position.x + placed.size.x * 0.5
		pos.z -= placed.position.z + placed.size.z * 0.5
	model.position = pos


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


## Public view of the bounds helper, for callers that need to size a collision
## box or stand something on a surface. ManorDressing does both.
static func model_bounds(model: Node3D) -> AABB:
	return _model_bounds(model)


## Union of every mesh bounding box in the model, in the model root's own
## space. Used to work out how big the thing actually is.
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


# ----------------------------------------------------------------- recolor --
# Every character in the pack ships with its Skin material set to #1f1f1f, so
# heads and hands render as black silhouettes. Rather than editing twelve .blend
# files, surfaces are retinted here at spawn from suspect_models.cfg.

## Applies every `color_<material>` key for this suspect, [default] first so a
## per-suspect section overrides it. Does nothing when the config names no
## colors, which keeps the model exactly as the artist authored it.
static func _apply_recolor(
	model: Node3D, cfg: ConfigFile, has_cfg: bool, character_id: String, ui_color: Color
) -> void:
	if not has_cfg:
		return

	var wanted := {}

	# Derived tints go in first so an explicit color_<material> line below can
	# still override them. ui_color is the suspect's NPC_COLORS entry - the same
	# colour their name is printed in throughout the notepad and the map - which
	# is what ties the two together: change the palette in Main.gd and the cast
	# redresses itself.
	for mat_name in _cfg_names(cfg, has_cfg, character_id, TINT_MAIN_KEY):
		wanted[mat_name] = _garment_color(ui_color)
	for mat_name in _cfg_names(cfg, has_cfg, character_id, TINT_ACCENT_KEY):
		wanted[mat_name] = _accent_color(ui_color)

	for section in ["default", character_id]:
		if not cfg.has_section(section):
			continue
		for key in cfg.get_section_keys(section):
			if key.begins_with(COLOR_PREFIX):
				wanted[key.substr(COLOR_PREFIX.length()).to_lower()] = cfg.get_value(section, key)

	if not wanted.is_empty():
		_recolor_node(model, wanted)


## Retints matching surfaces via set_surface_override_material() on a DUPLICATE
## of the material. Editing the imported material in place would write through
## to the shared resource and repaint every other suspect using the same .blend.
static func _recolor_node(node: Node, wanted: Dictionary) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var current := mi.get_active_material(i)
				if current == null:
					continue
				var key := current.resource_name.to_lower()
				if not wanted.has(key):
					continue
				var dup := current.duplicate() as BaseMaterial3D
				if dup == null:
					continue # a ShaderMaterial has no albedo_color to set
				dup.albedo_color = _parse_color(wanted[key], dup.albedo_color)
				mi.set_surface_override_material(i, dup)

	for child in node.get_children():
		_recolor_node(child, wanted)


## Reads a comma-separated material list out of the config ("shirt, details"),
## trimmed and lowercased to match how _recolor_node() keys materials. Empty
## when the key is absent, which is what leaves the victim - who has no notepad
## colour of his own - exactly as the artist authored him.
static func _cfg_names(
	cfg: ConfigFile, has_cfg: bool, character_id: String, key: String
) -> Array:
	var out := []
	for part in String(_cfg_value(cfg, has_cfg, character_id, key, "")).split(",", false):
		var mat_name := String(part).strip_edges().to_lower()
		if mat_name != "":
			out.append(mat_name)
	return out


## The notepad palette is picked for maximum separation against a dark UI, which
## makes several of those colours read as hi-vis once they are worn. Pulling
## saturation and brightness back into fabric range keeps each suspect
## recognisably their own colour without dressing the cast in safety vests.
static func _garment_color(ui: Color) -> Color:
	return Color.from_hsv(ui.h, minf(ui.s, 0.62), clampf(ui.v * 0.78, 0.18, 0.72))


## Trim, a tie, a hat band. A small surface can carry the colour at full
## strength, and that is what makes the match to the notepad readable across a
## room rather than only from arm's length.
static func _accent_color(ui: Color) -> Color:
	return Color.from_hsv(ui.h, minf(ui.s * 1.15, 0.88), clampf(ui.v * 1.05, 0.35, 0.95))


## Accepts either an HTML string ("#e8c19a") or a Color written straight into
## the config. Anything unparseable warns and keeps the model's own color, so
## one typo tints nothing rather than turning a suspect invisible.
static func _parse_color(value: Variant, fallback: Color) -> Color:
	if value is Color:
		return value
	if value is String:
		var text := (value as String).strip_edges()
		if Color.html_is_valid(text):
			return Color.html(text)
		push_warning("SuspectModel: '%s' is not a valid color - expected \"#rrggbb\"." % text)
	return fallback
