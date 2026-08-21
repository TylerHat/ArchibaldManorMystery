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
## Searched in order, first match wins. Extra/ is where a second pack lands, so
## a new download can be dropped in whole without renaming anything - the only
## consequence of a name clash is that the original pack keeps the name.
const MODEL_DIRS := [
	"res://Models/Furniture",
	"res://Models/Furniture/Extra",
]

## How far above a room's OWN floor a ceiling fitting hangs. Main.WALL_H is 3.0,
## so this leaves a chandelier just under the ceiling. Relative rather than
## absolute, so an upstairs room hangs its lights from its own ceiling rather
## than from the ground floor's.
const CEILING_DROP := 2.55

## Flat floor props (rugs) are modelled with their base at exactly y=0, which
## is also exactly where the floor's top surface sits - so the two planes
## z-fight and the rug flickers in and out as the camera moves. Lifting them a
## hair breaks the tie. Too small to see, far too big for depth precision to
## care about at these distances.
const FLOOR_DECAL_LIFT := 0.012

## Tried in order, so a model exported out of Blender as .glb drops in beside
## the .blend files without anything here changing.
const MODEL_EXTENSIONS := ["blend", "glb", "gltf", "fbx"]

## Longest edge below which a piece stops casting a shadow. A fork, a plate or a
## paperweight contributes nothing legible to the shadow map but still costs a
## full render of its geometry from the light's point of view, once per light
## that reaches it. Raise this to cut more; drop it to 0.0 to shadow everything.
const SHADOW_MIN_SIZE := 0.35


## Builds every piece listed in furniture.json. Never throws on bad data: a
## missing model or an unknown room name warns and is skipped, so a typo costs
## one chair rather than the whole manor.
## `centres` maps every room name in the building - both storeys - to its world
## centre, with y at that room's floor level. Passing it in rather than reading
## main.room_centers is what lets the upstairs be furnished at all: those rooms
## are deliberately kept out of room_centers so the case generator can never see
## them, but the furniture layout addresses them exactly like any other room.
static func build(main: Node3D, parent: Node3D, centres: Dictionary) -> Node3D:
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
		if not centres.has(room_name):
			push_warning("ManorDressing: no room called '%s' in the manor." % room_name)
			continue
		var centre: Vector3 = centres[room_name]

		# One node per room, named exactly as the room is. Main hides the ones the
		# player cannot currently see into, which is only possible if a room's
		# pieces - and its lamps - sit under a single switch. Hiding a node never
		# touches its CollisionShape3D children, so an unseen room is still solid
		# to walk into.
		var room_root := Node3D.new()
		room_root.name = String(room_name)
		root.add_child(room_root)

		for entry in rooms[room_name]:
			if _place(room_root, centre, entry, default_scale, _interior_half(main)):
				placed += 1
			else:
				skipped += 1

	if skipped > 0:
		print("[Furniture] placed %d pieces, skipped %d (see warnings)" % [placed, skipped])
	else:
		print("[Furniture] placed %d pieces across %d rooms" % [placed, rooms.size()])
	return root


# ------------------------------------------------------------------ pieces --

## Distance from a room's centre to the INNER face of its walls. Walls sit on
## the room boundary at WALL_SPAN/2 and are WALL_T thick, so the face a piece of
## furniture can actually touch is half a wall thickness inside that. Read off
## Main rather than duplicated, because getting it wrong is exactly how furniture
## ends up buried in a wall.
static func _interior_half(main: Node3D) -> float:
	return float(main.WALL_SPAN) / 2.0 - float(main.WALL_T) / 2.0


static func _place(root: Node3D, centre: Vector3, entry: Dictionary, default_scale: float,
		interior_half: float) -> bool:
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

	# "stretch" is a per-axis multiplier on top of "scale", in the model's OWN
	# space - so stretching x widens a bookcase along whatever wall it has been
	# turned to face, rather than along the world X axis. That is almost always
	# what you want, and it is why the stretch is applied before the rotation.
	var uniform := float(entry.get("scale", default_scale))

	# "fit_y": 0.65 means "stand this 0.65m tall", whatever units the artist
	# worked in. Height is the one dimension that is reliably known for a piece
	# of furniture, which makes it the right handle for a pack whose scene scale
	# you have not measured. Bounds are taken before any scaling, because
	# model_bounds() deliberately measures in the model's own space.
	var fit_y := float(entry.get("fit_y", 0.0))
	if fit_y > 0.0:
		var raw: AABB = SuspectModel.model_bounds(model)
		if raw.size.y > 0.0001:
			uniform = fit_y / raw.size.y
		else:
			push_warning("ManorDressing: '%s' is flat, so fit_y cannot size it." % model_name)

	var stretch = entry.get("stretch", null)
	if stretch is Array and (stretch as Array).size() == 3:
		model.scale = Vector3(uniform * float(stretch[0]),
				uniform * float(stretch[1]), uniform * float(stretch[2]))
	else:
		model.scale = Vector3.ONE * uniform
	model.rotation_degrees = Vector3(0.0, float(entry.get("rot", 0.0)), 0.0)

	# Where the piece actually sits once scaled and turned. Everything below is
	# derived from this rather than from the raw model, so a rotated bookcase
	# still lands flat on the floor with a collision box that matches it.
	var box: AABB = model.transform * SuspectModel.model_bounds(model)

	# Anything this small is not readable as a silhouette on the floor anyway.
	# Opt a specific piece back in with "shadow": true in furniture.json.
	if not bool(entry.get("shadow", false)):
		if maxf(box.size.x, maxf(box.size.y, box.size.z)) < SHADOW_MIN_SIZE:
			_disable_shadows(model)

	# Everything vertical is measured from the room's OWN floor, so the same
	# layout entry places a chair correctly whether the room is at ground level
	# or one storey up.
	var floor_y := centre.y
	var pos := Vector3(centre.x + float(entry.get("x", 0.0)), 0.0,
			centre.z + float(entry.get("z", 0.0)))

	# "anchor" opts a piece into placement by its MEASURED bounds instead of by
	# its origin, which is the same trick the y line below already uses. Without
	# it, x and z position the model's origin - and an artist can put that
	# anywhere. In the pack under Extra/, BookCaseLarge's origin sits 0.4 off its
	# own centre and CoffeeTable2's is a metre and a half outside the mesh
	# entirely, so origin placement buried one bookcase 1.28m inside a wall.
	#
	#   "anchor": "center"                x and z place the piece's own centre
	#   "anchor": "north"|"south"|"east"|"west"
	#                                     as above, and the named coordinate is
	#                                     overridden so the piece's back face
	#                                     lands exactly on that wall's inner face
	#
	# Deliberately opt-in. The ground-floor layout was hand-tuned against origin
	# placement and half its models have off-centre origins too, so switching it
	# wholesale would shove 145 pieces around.
	var anchor := String(entry.get("anchor", ""))
	if anchor != "":
		var want_x := centre.x + float(entry.get("x", 0.0))
		var want_z := centre.z + float(entry.get("z", 0.0))
		match anchor:
			"north":
				want_z = centre.z - interior_half + box.size.z * 0.5
			"south":
				want_z = centre.z + interior_half - box.size.z * 0.5
			"west":
				want_x = centre.x - interior_half + box.size.x * 0.5
			"east":
				want_x = centre.x + interior_half - box.size.x * 0.5
			"center":
				pass
			_:
				push_warning("ManorDressing: '%s' has anchor \"%s\", which is not a side." % [model_name, anchor])
		pos.x = want_x - (box.position.x + box.size.x * 0.5)
		pos.z = want_z - (box.position.z + box.size.z * 0.5)
	if String(entry.get("mount", "floor")) == "ceiling":
		# Hang it from the ceiling by its top rather than standing it up.
		pos.y = floor_y + CEILING_DROP - (box.position.y + box.size.y)
	else:
		# "y" is where the BOTTOM of the piece goes, above this room's floor: 0
		# for anything standing on it, table height for a plate, sill height for
		# a window.
		pos.y = floor_y + float(entry.get("y", 0.0)) - box.position.y
		if String(entry.get("mount", "floor")) == "floor" and box.size.y < 0.15:
			pos.y += FLOOR_DECAL_LIFT

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

	var light_cfg = entry.get("light", null)
	if light_cfg is Dictionary:
		_add_light(root, pos + box.position + box.size * 0.5, light_cfg)

	return true


## Turns off shadow casting for every mesh under a piece. Visibility and
## lighting are untouched - the piece still renders and is still lit, it just
## stops being drawn again into every shadow map that reaches it.
static func _disable_shadows(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_disable_shadows(child)


## A light fixture is only geometry - it emits nothing by itself. This hangs a
## real OmniLight3D in the middle of the shade, so the room is lit by the thing
## the player can see lighting it.
##
## Shadows are OFF by default, deliberately: the manor runs a dozen or so of
## these at once and shadow-casting omni lights are among the most expensive
## things in a Forward+ scene. Put "shadow": true on the one or two fixtures
## where it genuinely reads.
static func _add_light(root: Node3D, at: Vector3, cfg: Dictionary) -> void:
	var lamp := OmniLight3D.new()
	lamp.position = at - Vector3(0.0, float(cfg.get("drop", 0.1)), 0.0)
	lamp.omni_range = float(cfg.get("range", 8.0))
	lamp.light_energy = float(cfg.get("energy", 1.6))
	lamp.light_color = _colour(cfg.get("color", "#ffd9a8"))
	lamp.shadow_enabled = bool(cfg.get("shadow", false))
	# Falls off like a bulb instead of ending at a hard sphere edge.
	lamp.omni_attenuation = float(cfg.get("attenuation", 1.4))
	root.add_child(lamp)


static func _colour(value: Variant) -> Color:
	if value is Color:
		return value
	var text := String(value).strip_edges()
	return Color.html(text) if Color.html_is_valid(text) else Color(1.0, 0.85, 0.66)


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
	for dir_path in MODEL_DIRS:
		for ext in MODEL_EXTENSIONS:
			var path := "%s/%s.%s" % [dir_path, model_name, ext]
			if ResourceLoader.exists(path):
				var res := load(path)
				if res is PackedScene:
					return res as PackedScene
	push_warning("ManorDressing: no model file for '%s' in %s." % [model_name, ", ".join(PackedStringArray(MODEL_DIRS))])
	return null
