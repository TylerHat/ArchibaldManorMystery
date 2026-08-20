class_name SuspectModels
extends RefCounted

# Turns a downloaded character model into a suspect body, or falls back to the
# old coloured capsule when there is no model for that character yet.
#
# THE ONLY THING YOU NORMALLY HAVE TO DO
#   Drop a .glb file into res://Models/Suspects/ named after the character id.
#   That is it. No code change. The ids are:
#
#     blackwood   sterling   ashford   carter
#     whitmore    reeves     cross_natalie   cross_eugene
#     moreau      varga      pike      thorne
#
#   So res://Models/Suspects/varga.glb becomes Count Lucian Varga's body the
#   next time you press Play. Characters with no file keep their capsule, so
#   you can add models one at a time and the game never breaks.
#
# WHAT IT FIXES FOR YOU AUTOMATICALLY
#   - Scale. Models arrive at wildly different sizes. Every model is measured
#     and rescaled to TARGET_HEIGHT, so a 0.02-unit Blender export and a
#     180-unit FBX conversion both end up the same height as the player.
#   - Origin. Plenty of models are centred on the hips rather than the feet,
#     which leaves them sunk into or floating above the floor. The model is
#     shifted so the bottom of its bounding box sits exactly on the ground.
#   - Animation names. Mixamo calls its animation "mixamo.com", Quaternius
#     calls it "CharacterArmature|Idle", someone else calls it "idle_01". The
#     matcher below looks for keywords instead of exact names, so all three
#     just work.
#
# WHAT YOU MIGHT HAVE TO SET BY HAND
#   Facing. If a suspect moonwalks (slides backwards while facing you), add a
#   yaw entry for them in OVERRIDES below. See CHARACTER_MODELS.md.


## Every suspect is rescaled to this height in metres. Matches the player
## capsule, so eye lines work and the name Label3D sits correctly overhead.
const TARGET_HEIGHT := 1.8

## Where to look for model files, and which extensions to try in order.
const MODEL_DIR := "res://Models/Suspects/"
const EXTENSIONS := [".glb", ".gltf", ".tscn", ".fbx"]

## Godot's look_at() points a node's -Z axis at its target, while most exported
## characters face +Z. 180 corrects that and is right for Mixamo, Quaternius and
## Kenney. Only override it per character if one of them comes out backwards.
const DEFAULT_YAW := 180.0

## Per-character tweaks. You should not need any of these to begin with. Add an
## entry only when a specific model misbehaves.
##
##   yaw          degrees to spin the model on the spot. Try 180 or -90 or 90.
##   scale        multiplier applied AFTER the auto height fit. 1.1 makes a
##                character a bit taller than everyone else, which is a
##                perfectly good way to make Varga loom.
##   y_offset     nudge up or down in metres, if the auto floor fit is off.
##   file         use a different filename instead of "<id>.glb".
##   idle / walk  exact animation names, if the keyword matcher picks wrong.
const OVERRIDES := {
	# "varga": {"scale": 1.08},
	# "pike":  {"yaw": 0.0},
}

## Keywords the animation matcher looks for, in priority order. First hit wins.
##
## Deliberately no "tpose" or "rest" here. Those names almost always belong to a
## bind pose rather than an idle animation, and a model with no animation
## playing already stands in its bind pose, so matching them gains nothing and
## risks beating a real idle clip that sorts later.
const IDLE_WORDS := ["idle", "stand", "breath", "wait"]
const WALK_WORDS := ["walk", "jog", "run", "move", "locomotion"]


# --------------------------------------------------------------- public --

## Builds the visual body for one suspect and parents it to `npc`.
## Returns the holder Node3D, or null if the capsule fallback was used.
## `fallback_color` is that character's colour from Main.NPC_COLORS.
static func build_visual(npc: Node3D, character_id: String, fallback_color: Color) -> Node3D:
	var cfg: Dictionary = OVERRIDES.get(character_id, {})
	var packed := _find_model(character_id, cfg)

	if packed == null:
		_build_capsule(npc, fallback_color)
		return null

	var holder := Node3D.new()
	holder.name = "ModelRoot"
	npc.add_child(holder)

	var model := packed.instantiate()
	holder.add_child(model)

	if model is Node3D:
		_fit(model, cfg)

	holder.rotation_degrees.y = float(cfg.get("yaw", DEFAULT_YAW))
	holder.position.y = float(cfg.get("y_offset", 0.0))
	return holder


## Finds the AnimationPlayer inside a spawned model, or null. NPCCharacter uses
## this to drive idle and walk.
static func find_animation_player(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	if root is AnimationPlayer:
		return root
	for child in root.get_children():
		var found := find_animation_player(child)
		if found:
			return found
	return null


## Picks the animation whose name best matches a set of keywords.
##
## This is the piece that makes models from different sites interchangeable.
## Exact names are hopeless across sources: Mixamo exports a single clip called
## "mixamo.com", Blender exports "Armature|ActionName", Quaternius exports
## "CharacterArmature|Walk". Matching on a substring handles all of them, and
## when a model has exactly one animation that one is used regardless, which is
## the correct answer for a Mixamo download.
static func pick_animation(player: AnimationPlayer, keywords: Array, explicit: String = "") -> String:
	if player == null:
		return ""
	var names := player.get_animation_list()
	if names.is_empty():
		return ""

	if explicit != "" and player.has_animation(explicit):
		return explicit

	for word in keywords:
		for n in names:
			var tail := String(n).get_slice("|", String(n).get_slice_count("|") - 1)
			if tail.to_lower().contains(String(word)):
				return n

	# A single-clip model (every Mixamo download) means there is nothing to
	# choose between, so use it rather than standing frozen.
	if names.size() == 1:
		return names[0]
	return ""


# -------------------------------------------------------------- internal --

static func _find_model(character_id: String, cfg: Dictionary) -> PackedScene:
	var names := []
	if cfg.has("file"):
		names.append(String(cfg["file"]))
	else:
		for ext in EXTENSIONS:
			names.append(character_id + ext)

	for n in names:
		var path: String = n if n.begins_with("res://") else MODEL_DIR + n
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is PackedScene:
				return res
			push_warning("SuspectModels: %s exists but is not a scene. glTF and FBX files import as scenes; if this is a raw mesh, wrap it in one." % path)
	return null


## Measures the model, scales it to TARGET_HEIGHT, and drops it so its feet
## rest on y = 0.
static func _fit(model: Node3D, cfg: Dictionary) -> void:
	var box := _visual_bounds(model, Transform3D.IDENTITY)
	if box.size.y <= 0.0001:
		# No meshes found, or a zero-height model. Leave it alone rather than
		# dividing by ~zero and flinging it into orbit.
		push_warning("SuspectModels: could not measure '%s', skipping auto-fit." % model.name)
		return

	var factor := TARGET_HEIGHT / box.size.y
	factor *= float(cfg.get("scale", 1.0))
	model.scale = Vector3.ONE * factor
	# After scaling, put the bottom of the bounding box on the floor and centre
	# the model horizontally on its own footprint, which fixes both hip-centred
	# origins and models authored off to one side.
	model.position = Vector3(
		-box.position.x * factor - box.size.x * factor / 2.0,
		-box.position.y * factor,
		-box.position.z * factor - box.size.z * factor / 2.0
	)


## Union of every mesh's bounding box in the subtree, in the subtree root's
## own space. Walks manually rather than using get_aabb() on the root, because
## the root of an imported glTF scene is usually a plain Node3D with no bounds
## of its own.
static func _visual_bounds(node: Node, xform: Transform3D) -> AABB:
	var out := AABB()
	var started := false

	if node is VisualInstance3D:
		var vi := node as VisualInstance3D
		var local := vi.get_aabb()
		if local.size.length_squared() > 0.0:
			out = xform * local
			started = true

	for child in node.get_children():
		var child_xform := xform
		if child is Node3D:
			child_xform = xform * (child as Node3D).transform
		var sub := _visual_bounds(child, child_xform)
		if sub.size.length_squared() > 0.0:
			out = out.merge(sub) if started else sub
			started = true

	return out


## The original coloured capsule, used for any character without a model file.
static func _build_capsule(npc: Node3D, color: Color) -> void:
	var mesh := MeshInstance3D.new()
	mesh.name = "CapsuleBody"
	var cap := CapsuleMesh.new()
	cap.height = TARGET_HEIGHT
	cap.radius = 0.4
	mesh.mesh = cap
	mesh.position.y = TARGET_HEIGHT / 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	npc.add_child(mesh)
