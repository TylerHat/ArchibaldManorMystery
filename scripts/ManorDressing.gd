extends Node
# Dresses the finished manor with background furniture.
#
# Everything is data: Models/Furniture/furniture.json lists, per room, which
# model goes where in room-local coordinates. Adding a chair means adding four
# numbers to that file, not touching this script.
#
# Called from Main._build_world() once the rooms exist. Returns the Node3D
# holding everything so a restart can free the lot in one call, the same
# contract CrimeScene.build() uses.
#
# Placement rules the layout data already respects, recorded here because they
# are invisible from the JSON alone:
#   - Suspects wander within NPCCharacter's margin of a room's centre, so every
#     solid piece sits in the band near the walls where nobody walks.
#   - The middle of every wall is a doorway; nothing solid straddles one.
#   - CrimeScene puts the body at centre +(3.9, -3.9) and the weapon gap at
#     (-4.1, -4.1) of whichever room the generator picked, so both of those
#     corners are kept clear in EVERY room - any of them can be the scene.

const SuspectModel = preload("res://Scripts/SuspectModel.gd")

const LAYOUT_PATH := "res://Models/Furniture/furniture.json"
const MODEL_DIR := "res://Models/Furniture"

## Main.WALL_H is 3.0; hang ceiling fittings just under it.
const CEILING_Y := 2.55

## Tried in order, so a model exported out of Blender as .glb drops in beside
## the .blend files without anything here changing.
const MODEL_EXTENSIONS := ["blend", "glb", "gltf", "fbx"]


## Builds every piece listed in furniture.json. Never throws on bad data: a
## missing model or an unknown room name warns and is skipped, so a typo costs
## one chair rather than the whole manor.
static func build(main: Node3D, parent: Node3D) -> Node3D:
	var root := Node3D.new()
	root.name = "Furniture"
	parent.add_child(root)

	var layout := _load_layout()
	if layout.is_empty():
		return root

	var default_scale := float(layout.get("scale", 1.0))
	var rooms: Dictionary = layout.get("rooms", {})
	var placed := 0
	var skipped := 0

	for room_name in rooms:
		if not main.room_centers.has(room_name):
			push_warning("ManorDressing: no room called '%s' in the manor." % room_name)
			continue
		var centre: Vector3 = main.room_centers[room_name]
		for entry in rooms[room_name]:
			if _place(root, centre, entry, default_scale):
				placed += 1
			else:
				skipped += 1

	if skipped > 0:
		print("[Furniture] placed %d pieces, skipped %d (see warnings)" % [placed, skipped])
	else:
		print("[Furniture] placed %d pieces across %d rooms" % [placed, rooms.size()])
	return root


# ------------------------------------------------------------------ pieces --

static func _place(root: Node3D, centre: Vector3, entry: Dictionary, default_scale: float) -> bool:
	var model_name := String(entry.get("model", ""))
	var scene := _load_model(model_name)
	if scene == null:
		return false

	var inst := scene.instantiate()
	if not (inst is Node3D):
		inst.free()
		push_warning("ManorDressing: '%s' is not a 3D scene." % model_name)
		return false
	var model := inst as Node3D
	model.name = model_name

	model.scale = Vector3.ONE * float(entry.get("scale", default_scale))
	model.rotation_degrees = Vector3(0.0, float(entry.get("rot", 0.0)), 0.0)

	# Where the piece actually sits once scaled and turned. Everything below is
	# derived from this rather than from the raw model, so a rotated bookcase
	# still lands flat on the floor with a collision box that matches it.
	var box: AABB = model.transform * SuspectModel.model_bounds(model)

	var pos := Vector3(centre.x + float(entry.get("x", 0.0)), 0.0,
			centre.z + float(entry.get("z", 0.0)))
	if String(entry.get("mount", "floor")) == "ceiling":
		# Hang it from the ceiling by its top rather than standing it up.
		pos.y = CEILING_Y - (box.position.y + box.size.y)
	else:
		# "y" is where the BOTTOM of the piece goes: 0 for anything on the
		# floor, table height for a plate, sill height for a window.
		pos.y = float(entry.get("y", 0.0)) - box.position.y

	if bool(entry.get("solid", true)):
		# The collider is a plain box around the model rather than its real
		# geometry: furniture only ever needs to stop someone walking through
		# it, and a convex hull per chair leg would cost far more than that is
		# worth. Parenting the model at the origin of the body keeps `box`
		# valid as the shape's local placement.
		var body := StaticBody3D.new()
		body.name = model_name
		body.position = pos
		root.add_child(body)
		body.add_child(model)
		model.position = Vector3.ZERO

		var coll := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = box.size
		coll.shape = shape
		coll.position = box.position + box.size * 0.5
		body.add_child(coll)
	else:
		root.add_child(model)
		model.position = pos

	return true


# ----------------------------------------------------------------- loading --

static func _load_layout() -> Dictionary:
	if not FileAccess.file_exists(LAYOUT_PATH):
		push_warning("ManorDressing: %s is missing - the manor stays empty." % LAYOUT_PATH)
		return {}
	var text := FileAccess.get_file_as_string(LAYOUT_PATH)
	var parsed = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_warning("ManorDressing: %s is not valid JSON." % LAYOUT_PATH)
		return {}
	return parsed


static func _load_model(model_name: String) -> PackedScene:
	if model_name == "":
		return null
	for ext in MODEL_EXTENSIONS:
		var path := "%s/%s.%s" % [MODEL_DIR, model_name, ext]
		if ResourceLoader.exists(path):
			var res := load(path)
			if res is PackedScene:
				return res as PackedScene
	push_warning("ManorDressing: no model file for '%s' in %s." % [model_name, MODEL_DIR])
	return null
