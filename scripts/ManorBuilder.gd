@tool
class_name ManorBuilder
extends Node3D

# Generates the whole manor shell (floors, walls, doorway gaps, ceilings,
# stairs, room volumes) from the FLOORS spec below.
#
# Why this exists: Main.gd used to build the mansion procedurally at runtime,
# which was correct but invisible until you pressed Play. The alternative on
# the table was hand-placing 37 walls in the editor, which is the same geometry
# typed in by hand and impossible to re-layout. This is the third option: the
# spec stays the single source of truth, and because the script is @tool the
# result is drawn live in the editor viewport while you work.
#
# WHAT THIS OWNS ...... floors, walls, doorway gaps, ceilings, stairs,
#                       per-room Area3D volumes, room labels, collision.
# WHAT IT NEVER TOUCHES  everything under the "Decor" child. Put furniture,
#                       props, trim and set dressing there. Rebuilding the
#                       shell will not disturb any of it.
#
# ---------------------------------------------------------------------------
# QUICK START
#   1. Open Scenes/Main.tscn.
#   2. Add a Node3D child of the root, rename it to "Manor".
#   3. Attach this script to it.
#   4. In the Inspector, tick "Rebuild Now". The manor appears in the viewport.
#   5. Delete the four hand-placed Kitchen_* walls under the old Rooms node.
#
# See MANOR_BUILDER.md for the Main.gd integration patch.
# ---------------------------------------------------------------------------


# ------------------------------------------------------------------- spec --
# Dimensions. These are the same values Main.gd uses today, so the generated
# manor is geometrically identical to the one the old code produced.

const CELL := 12.0      # inside width of one room
const PITCH := 13.0     # centre-to-centre distance between rooms
const WALL_H := 3.0     # wall height
const WALL_T := 0.4     # wall thickness
const DOOR_W := 3.0     # width of the gap left for a doorway
const FLOOR_T := 0.2    # floor slab thickness
# Vertical distance between floor levels. 3.2 is not arbitrary: Main.gd roofs
# every ground-floor room with a 0.2-thick ceiling slab occupying y 3.0 to 3.2,
# and an upper room at level 1 puts its floor slab at center.y - FLOOR_T/2,
# occupying exactly the same band. So the upper floor IS the ceiling of the
# rooms beneath it - one slab, no gap between the top of the ground-floor walls
# and the floor above, and no pair of coplanar slabs to z-fight. Main skips its
# own ceiling for any room that has an upper room over it.
#
# Raising this back to 4.0 reopens a 0.8 band above the ground-floor walls that
# you can see straight over into the next room.
const STOREY := 3.2     # vertical distance between floor levels

# How far a wall runs along its own axis.
#
# This is the fix for the corner gaps. The original code built walls CELL long
# (12) while spacing rooms PITCH apart (13), so every wall stopped 1.0 short of
# the next one and left a hole exactly where the corner should be. 16 of them
# on the ground floor. Measured by flood fill, the widest clear route from
# outside into a room was 0.76m against a 0.80m player capsule: visible, not
# quite passable. On the plus-shaped upstairs the same defect measured 1.08m,
# which IS passable.
#
# Walls now span exactly PITCH and sit on the room boundary, so a wall butts
# its neighbour end to end with no gap and no overlap.
#
# NOT PITCH + WALL_T. Overlapping walls by their own thickness also seals the
# corners, and it is what this file did for one revision, but it puts two
# same-facing coplanar quads in the same place at every junction. That is
# textbook z-fighting: the depth test picks a winner per pixel, the winner
# flips as the camera moves, and you see the triangulation of the quads
# crawling across the wall. It measured 96 m2 of fighting surface. Butting is
# safe; overlapping is not. Faces that merely touch back to back are fine,
# because backface culling only ever draws one of them.
const WALL_SPAN := PITCH

# An empty string means "no room in this cell". Void cells are how you get a
# footprint that is not a full rectangle: an upper floor smaller than the
# ground floor, an L-shaped wing, a courtyard. A room next to a void cell
# builds a solid exterior wall on that side instead of a doorway, which falls
# out of the neighbour test automatically.
const FLOORS := [
	{
		"id": "ground",
		"level": 0,
		"enabled": true,
		# Indexed but not built. Main.gd still owns the ground floor; this entry
		# exists so room_centers knows where the Hall is, which is what the stair
		# flight measures its rise from. Flip to true only if Main ever stops
		# building the mansion itself.
		"emit": false,
		"grid": [
			["Kitchen", "Ballroom", "Conservatory"],
			["Lounge", "Dining Room", "Study"],
			["Billiard Room", "Hall", "Library"],
		],
	},
	{
		# LIVE. Built at runtime by Main._build_upper_floor(), which instantiates
		# this script with build_ground_plane off. These room names are deliberately
		# kept OUT of Main.GRID, Main.grid_pos, Main.room_centers and
		# CaseGenerator.GRID: the case generator is a closed system over its own
		# private grid, so a room it has never heard of cannot end up in a schedule,
		# an alibi, a witness list or the murder room. That is what keeps every
		# suspect downstairs without a single change to the generator.
		"id": "upper",
		"level": 1,
		"enabled": true,
		"emit": true,
		"grid": [
			["", "Master Bedroom", ""],
			["Nursery", "Landing", "Guest Room"],
			["", "Stair Hall", ""],
		],
	},
]

# Vertical connections between levels.
#   from / to  room names on adjacent levels
#   side       which wall of the lower room the flight climbs TOWARD, so the
#              top step arrives there and the bottom step is at the far end
#   length     how far into the room the flight reaches. Leave it short of CELL
#              or the bottom step lands flush against the opposite wall, which
#              in the Hall's case is the front door.
#   offset     sideways shift across the room, perpendicular to the climb.
#   extend_to_wall
#              whether the stairwell opening is stretched out to the wall the
#              flight arrives at. Only wanted when the top step really does
#              reach that wall; otherwise it opens a slot between the top step
#              and the wall instead of leaving continuous floor there.
#
# WHY THIS FLIGHT IS WHERE IT IS. Every wall of the Hall has a 3m doorway in the
# middle of it, and the middle of the room is spoken for three times over: it is
# where the first suspect in a room spawns, where every NPC's travel path
# terminates, and where the player spawns. The clear ground is the corners.
#
# So: hard against the west wall (inner face x = -6.3 now that Main's walls sit
# on the room boundary too), north of the Billiard Room doorway (which spans
# z 11.5 to 14.5), climbing north. The flight occupies x -6.3..-4.1, z 7.0..10.8.
# Nearest approach to the Hall centre is 4.6m, well outside the 3.4m disc the
# meetup ring and the wander box need, and 0.7m clear of the doorway. You come up
# in the north-west corner of the Stair Hall and step off the top tread eastward
# onto the landing floor, which is at exactly the same height.
const STAIRS := [
	{
		"from": "Hall", "to": "Stair Hall", "side": "north",
		"steps": 15, "width": 2.2, "length": 3.8, "offset": -5.2,
		"extend_to_wall": false,
	},
]

const ROOM_COLORS := {
	"Kitchen": Color(0.85, 0.8, 0.6),
	"Ballroom": Color(0.75, 0.65, 0.85),
	"Conservatory": Color(0.65, 0.85, 0.7),
	"Lounge": Color(0.8, 0.6, 0.55),
	"Study": Color(0.6, 0.55, 0.75),
	"Dining Room": Color(0.85, 0.7, 0.5),
	"Billiard Room": Color(0.4, 0.5, 0.45),
	"Library": Color(0.55, 0.45, 0.35),
	"Hall": Color(0.75, 0.72, 0.65),
	"Master Bedroom": Color(0.7, 0.6, 0.7),
	"Nursery": Color(0.9, 0.85, 0.7),
	"Guest Room": Color(0.65, 0.7, 0.8),
	"Landing": Color(0.78, 0.75, 0.68),
	"Stair Hall": Color(0.72, 0.7, 0.66),
}
const DEFAULT_ROOM_COLOR := Color(0.8, 0.75, 0.65)
const WALL_COLOR := Color(0.92, 0.9, 0.85)
const GROUND_COLOR := Color(0.1, 0.1, 0.12)
const DOOR_COLOR := Color(0.36, 0.2, 0.1)

# The one room whose exterior wall gets a front door instead of a solid slab.
const FRONT_DOOR_ROOM := "Hall"
const FRONT_DOOR_SIDE := "south"


# ---------------------------------------------------------------- inspector --

@export_group("Build")

## Tick to regenerate. Untargets itself immediately, so it acts as a button.
@export var rebuild_now: bool = false:
	set(value):
		rebuild_now = false
		if value:
			rebuild()

## OFF (default): the shell is drawn in the viewport but is NOT written into
## Main.tscn, so the scene file stays tiny and the spec above is the only
## source of truth. Turn ON when you want the individual wall nodes to appear
## in the Scene dock so you can select and tweak them; they then get saved
## into the .tscn and a later rebuild will overwrite your tweaks.
@export var save_to_scene: bool = false

## ON (default): all boxes of a kind collapse into one MultiMeshInstance3D.
## Takes the manor from ~47 draw calls to 3. Turn OFF to get individually
## selectable StaticBody3D nodes for debugging; positions are identical either
## way, so you can flip back and forth freely.
@export var batch_meshes: bool = true

@export_group("Content")
@export var build_ceilings: bool = false
@export var build_room_labels: bool = true
@export var build_room_volumes: bool = true
@export var build_ground_plane: bool = true

@export_group("Materials")
## Leave empty to get flat colours matching the current look. Assign your own
## StandardMaterial3D here once you have textures. One material shared by every
## wall in the manor is what makes the batching work, so keep it to one.
@export var wall_material: StandardMaterial3D
@export var floor_material: StandardMaterial3D
@export var ceiling_material: StandardMaterial3D

@export_group("Geometry tweaks")
## Merges colinear coplanar wall segments into single boxes before emitting
## them. Leave ON. It is what keeps the wall surface free of z-fighting, and it
## drops the ground floor from 37 boxes to 20 as a side effect. Turn OFF only to
## see the individual per-room segments the layout pass produced.
@export var merge_wall_runs: bool = true

@export_group("Physics")
## Room volumes go on their own layer so they never collide with the player or
## suspects. Change only if layer 3 is already in use.
@export_flags_3d_physics var room_volume_layer: int = 4


# ------------------------------------------------------------------ state --

var room_centers: Dictionary = {}   # room name -> Vector3 centre (y = floor level)
var grid_pos: Dictionary = {}       # room name -> Vector2i(row, col)
var room_level: Dictionary = {}     # room name -> int floor level
var front_door_node: StaticBody3D = null

var _shell: Node3D
var _decor: Node3D
var _collision_body: StaticBody3D
var _shape_cache: Dictionary = {}   # "x,y,z" -> BoxShape3D, shared between identical boxes
var _pending: Dictionary = {}       # bucket name -> Array of {size, pos, color}
var _unit_box: BoxMesh
var _stair_steps: Array = []        # precomputed step boxes
var _stair_ramps: Array = []        # one convex wedge per flight, collision only
var _openings: Dictionary = {}      # room name -> Rect2 hole in that room's floor slab (world XZ)
var _opening_arrival: Dictionary = {}  # room name -> which side the flight climbs toward


func _ready() -> void:
	# At runtime the shell is never saved into the scene, so build it on load.
	# In the editor, build once so opening Main.tscn shows the manor without
	# needing to press anything.
	if not Engine.is_editor_hint() or _shell == null:
		rebuild()


# ------------------------------------------------------------------ public --

## Wipes and regenerates the entire shell. Safe to call as often as you like.
## Never touches the Decor subtree.
func rebuild() -> void:
	_reset()
	_index_rooms()
	# Stairs are computed before any floor slab is emitted, because a flight
	# arriving from below needs a hole cut in the slab above it.
	_compute_stairs()
	_emit_ground()
	_emit_rooms()
	_emit_stair_steps()
	_emit_stair_ramps()
	_emit_railings()
	_flush()
	_finalise_owners()


## Room name -> {center, grid, level}. This is what Main.gd should read
## instead of building the mansion itself.
func get_room_data() -> Dictionary:
	var out := {}
	for rname in room_centers.keys():
		out[rname] = {
			"center": room_centers[rname],
			"grid": grid_pos[rname],
			"level": room_level[rname],
		}
	return out


## All room names on a given floor level, in reading order.
func rooms_on_level(level: int) -> Array:
	var out := []
	for rname in room_level.keys():
		if room_level[rname] == level:
			out.append(rname)
	out.sort()
	return out


## True when two rooms share a wall with a doorway in it (same level, adjacent
## cells) or are joined by a flight of stairs. Phase 2 pathing should use this
## rather than assuming a 2D grid.
func rooms_connected(a: String, b: String) -> bool:
	if not grid_pos.has(a) or not grid_pos.has(b):
		return false
	if room_level[a] == room_level[b]:
		var d: Vector2i = grid_pos[a] - grid_pos[b]
		return abs(d.x) + abs(d.y) == 1
	for s in STAIRS:
		if (s["from"] == a and s["to"] == b) or (s["from"] == b and s["to"] == a):
			return true
	return false


# ------------------------------------------------------------------ layout --

func _level_y(level: int) -> float:
	return float(level) * STOREY


func _room_center(level: int, row: int, col: int) -> Vector3:
	return Vector3((col - 1) * PITCH, _level_y(level), (row - 1) * PITCH)


func _enabled_floors() -> Array:
	var out := []
	for f in FLOORS:
		if f.get("enabled", true):
			out.append(f)
	return out


## Floors whose geometry this script actually builds. A floor can be enabled
## (so it is indexed, and stairs can measure against it) without being emitted,
## which is how the upper floor is built alongside a ground floor that Main.gd
## still owns.
func _emitted_floors() -> Array:
	var out := []
	for f in _enabled_floors():
		if f.get("emit", true):
			out.append(f)
	return out


func _floor_for_level(level: int) -> Dictionary:
	for f in _enabled_floors():
		if f["level"] == level:
			return f
	return {}


## The room name at a cell, or "" for a void cell or out of bounds.
func _room_at_cell(level: int, row: int, col: int) -> String:
	var f := _floor_for_level(level)
	if f.is_empty():
		return ""
	var grid: Array = f["grid"]
	if row < 0 or row >= grid.size():
		return ""
	var line: Array = grid[row]
	if col < 0 or col >= line.size():
		return ""
	return line[col]


const _DIR_OFFSET := {
	"north": Vector2i(-1, 0),
	"south": Vector2i(1, 0),
	"west": Vector2i(0, -1),
	"east": Vector2i(0, 1),
}


## True when a real room sits on the far side of this wall, i.e. the wall gets
## a doorway gap instead of being solid. Void cells count as "no neighbour",
## which is what gives irregular footprints correct exterior walls for free.
func _has_neighbour(level: int, row: int, col: int, dir: String) -> bool:
	var d: Vector2i = _DIR_OFFSET[dir]
	return _room_at_cell(level, row + d.x, col + d.y) != ""


func _index_rooms() -> void:
	room_centers.clear()
	grid_pos.clear()
	room_level.clear()
	for f in _enabled_floors():
		var level: int = f["level"]
		var grid: Array = f["grid"]
		for row in range(grid.size()):
			for col in range(grid[row].size()):
				var rname: String = grid[row][col]
				if rname == "":
					continue
				if room_centers.has(rname):
					push_warning("ManorBuilder: duplicate room name '%s'. Room names must be unique across all floors, because Main.gd keys everything by name." % rname)
					continue
				room_centers[rname] = _room_center(level, row, col)
				grid_pos[rname] = Vector2i(row, col)
				room_level[rname] = level


# ---------------------------------------------------------------- emission --
# Nothing is instantiated during the walk. Boxes are collected into buckets
# and flushed at the end, so batching is a property of the flush rather than
# something the layout code has to know about.

func _box(bucket: String, size: Vector3, pos: Vector3, color: Color, box_name: String = "") -> void:
	if not _pending.has(bucket):
		_pending[bucket] = []
	_pending[bucket].append({
		"size": size,
		"pos": pos,
		"color": color,
		"name": box_name,
	})


func _emit_ground() -> void:
	if not build_ground_plane:
		return
	# Safety net beneath everything, sized to cover the widest floor plus slack.
	_box("ground", Vector3(60, 0.2, 60), Vector3(0, -0.6, 0), GROUND_COLOR, "Ground")


func _emit_rooms() -> void:
	for f in _emitted_floors():
		var level: int = f["level"]
		var grid: Array = f["grid"]
		for row in range(grid.size()):
			for col in range(grid[row].size()):
				var rname: String = grid[row][col]
				if rname == "":
					continue
				_emit_room(rname, level, row, col)


func _emit_room(rname: String, level: int, row: int, col: int) -> void:
	var center := _room_center(level, row, col)
	var color: Color = ROOM_COLORS.get(rname, DEFAULT_ROOM_COLOR)

	# Floor slabs are sized to PITCH rather than CELL so neighbouring slabs butt
	# up exactly, leaving no missing strip under the doorway gaps. A slab with
	# a flight of stairs arriving under it gets a stairwell opening cut in it.
	_emit_floor_slab(rname, center, center.y - FLOOR_T / 2.0, color, "_Floor")

	if build_ceilings:
		_box("ceiling", Vector3(PITCH, FLOOR_T, PITCH),
			Vector3(center.x, center.y + WALL_H + FLOOR_T / 2.0, center.z),
			Color(0.88, 0.86, 0.82), rname + "_Ceiling")

	# Each shared boundary is built exactly once, by whichever room owns it.
	# South and east are always owned by this room. North and west are only
	# built when there is no neighbour there, because otherwise the neighbour's
	# south/east pass already covered that same boundary. Building both sides
	# produces two offset slabs with a player-trapping sliver between them.
	_emit_wall(rname, level, row, col, "south")
	_emit_wall(rname, level, row, col, "east")
	if not _has_neighbour(level, row, col, "north"):
		_emit_wall(rname, level, row, col, "north")
	if not _has_neighbour(level, row, col, "west"):
		_emit_wall(rname, level, row, col, "west")

	if build_room_labels:
		_emit_label(rname, center)
	if build_room_volumes:
		_emit_volume(rname, center, level)


func _emit_wall(rname: String, level: int, row: int, col: int, dir: String) -> void:
	var has_n := _has_neighbour(level, row, col, dir)
	# Every wall, interior and exterior alike, sits on the room boundary at
	# PITCH/2 rather than at CELL/2. Three things depend on this. Wall planes
	# then line up exactly with floor slab edges, so a WALL_SPAN-long wall butts
	# its neighbour with neither gap nor overlap. Rooms come out symmetric
	# instead of 0.5 short on their south and east sides. And the doorway
	# waypoint get_room_travel_waypoints() computes, the midpoint between two
	# room centres, lands exactly in the door opening rather than 0.5 past it.
	var reach := PITCH / 2.0

	var center := _room_center(level, row, col)
	var base_y := center.y + WALL_H / 2.0
	# Each half of a doorway wall runs from the door opening out to the far end
	# of the wall's span, so the two segments plus the DOOR_W gap between them
	# add up to WALL_SPAN and the doorway stays centred on the room.
	var seg := (WALL_SPAN - DOOR_W) / 2.0
	var off := DOOR_W / 2.0 + seg / 2.0

	var is_front_door := (rname == FRONT_DOOR_ROOM and dir == FRONT_DOOR_SIDE and not has_n)

	if dir == "north" or dir == "south":
		var z: float = center.z + (-reach if dir == "north" else reach)
		if has_n or is_front_door:
			_box("wall", Vector3(seg, WALL_H, WALL_T),
				Vector3(center.x - off, base_y, z), WALL_COLOR, rname + "_" + dir + "_a")
			_box("wall", Vector3(seg, WALL_H, WALL_T),
				Vector3(center.x + off, base_y, z), WALL_COLOR, rname + "_" + dir + "_b")
			if is_front_door:
				_emit_front_door(Vector3(center.x, center.y, z))
		else:
			_box("wall", Vector3(WALL_SPAN, WALL_H, WALL_T),
				Vector3(center.x, base_y, z), WALL_COLOR, rname + "_" + dir)
	else:
		var x: float = center.x + (-reach if dir == "west" else reach)
		if has_n:
			_box("wall", Vector3(WALL_T, WALL_H, seg),
				Vector3(x, base_y, center.z - off), WALL_COLOR, rname + "_" + dir + "_a")
			_box("wall", Vector3(WALL_T, WALL_H, seg),
				Vector3(x, base_y, center.z + off), WALL_COLOR, rname + "_" + dir + "_b")
		else:
			_box("wall", Vector3(WALL_T, WALL_H, WALL_SPAN),
				Vector3(x, base_y, center.z), WALL_COLOR, rname + "_" + dir)


## Clearance a walking player needs between their feet and the underside of the
## slab above. Any stretch of flight with less than this sits under the stairwell
## opening instead. The collision capsule is 1.8 tall, so this is that plus a
## comfortable margin - at 2.6 the whole of a normal flight opens up and there is
## never anything over your head on the way up.
##
## Raise it to open more of the flight, lower it to leave more ceiling in place.
const STAIR_HEADROOM := 2.6


## Builds the step boxes and works out where the floor above has to be cut.
##
## Convention: the flight CLIMBS TOWARD `side`. The bottom step sits at the
## opposite end of the lower room and the top step arrives at the `side` wall,
## so with side = "north" you walk north and up. Flip the side to reverse it.
func _compute_stairs() -> void:
	_stair_steps.clear()
	_stair_ramps.clear()
	_openings.clear()
	_opening_arrival.clear()

	for s in STAIRS:
		var from_name: String = s["from"]
		var to_name: String = s["to"]
		if not room_centers.has(from_name) or not room_centers.has(to_name):
			continue  # the upper floor is disabled, nothing to connect to

		var base: Vector3 = room_centers[from_name]
		var top_y: float = room_centers[to_name].y
		var steps: int = s.get("steps", 14)
		var width: float = s.get("width", 3.0)
		var side: String = s.get("side", "north")
		var total_rise := top_y - base.y
		if total_rise <= 0.0:
			push_warning("ManorBuilder: stair '%s' -> '%s' does not go up. Check the level values." % [from_name, to_name])
			continue

		var length: float = minf(s.get("length", CELL), CELL)
		var rise := total_rise / float(steps)
		var run := length / float(steps)
		var dir_sign := -1.0 if side in ["north", "west"] else 1.0
		var horizontal := side in ["north", "south"]
		# Sideways across the room, perpendicular to the climb: X for a flight that
		# runs north-south, Z for one that runs east-west.
		var lateral: float = s.get("offset", 0.0)

		# Footprint of the steps that pass under the slab above, in world XZ.
		var hole_min := Vector2(INF, INF)
		var hole_max := Vector2(-INF, -INF)

		for i in range(steps):
			var h := rise * float(i + 1)
			# i = 0 is the bottom step. The run is anchored so the LAST step
			# finishes flush against the `side` wall, and the flight extends
			# back into the room by `length`.
			var along := dir_sign * (CELL / 2.0 - length + run * (float(i) + 0.5))
			var pos: Vector3
			var size: Vector3
			if horizontal:
				pos = Vector3(base.x + lateral, base.y + h / 2.0, base.z + along)
				size = Vector3(width, h, run)
			else:
				pos = Vector3(base.x + along, base.y + h / 2.0, base.z + lateral)
				size = Vector3(run, h, width)

			_stair_steps.append({
				"size": size,
				"pos": pos,
				"name": "%s_to_%s_step_%02d" % [from_name, to_name, i],
			})

			# Does a person walking over this step have room to stand? The original
			# test measured the tread's own top against top_y, and was wrong twice
			# over in the same direction - together the two errors cost 0.4m and put
			# the slab through your head about a third of the way up.
			#
			# 1. The ceiling is the slab's UNDERSIDE, at top_y - FLOOR_T, not the
			#    walking surface at top_y.
			# 2. You do not walk on the treads, you walk on the ramp, which sits one
			#    rise above the tread at the back of each step. The highest your feet
			#    get anywhere over step i is therefore the height of step i+1.
			if base.y + rise * float(i + 2) + STAIR_HEADROOM > top_y - FLOOR_T:
				hole_min.x = min(hole_min.x, pos.x - size.x / 2.0)
				hole_min.y = min(hole_min.y, pos.z - size.z / 2.0)
				hole_max.x = max(hole_max.x, pos.x + size.x / 2.0)
				hole_max.y = max(hole_max.y, pos.z + size.z / 2.0)

		# A capsule does not climb stairs on its own. Godot's CharacterBody3D has no
		# step-up, this project never set floor_max_angle, and a 0.4 radius meeting
		# a 0.21 riser contacts it where the surface normal points slightly DOWN -
		# so move_and_slide pushes you back off the tread instead of over it, and
		# the only way up is to jump every step.
		#
		# The fix is a collision-only wedge whose sloped face passes exactly through
		# every step nose: the treads stay visible, the player walks up a plain
		# incline. Its slope is total_rise / length, which for any sane flight is
		# well under the 45 degrees Godot treats as walkable floor.
		#
		# The toe is carried one run PAST the bottom step so the ramp meets the floor
		# at y = 0 rather than starting with a 0.21 lip of its own.
		var a_toe := dir_sign * (CELL / 2.0 - length - run)
		var a_top := dir_sign * (CELL / 2.0 - run)
		var hw := width / 2.0
		var y_lo := base.y
		var y_hi := base.y + total_rise
		var pts := PackedVector3Array()
		if horizontal:
			var rx := base.x + lateral
			pts.append(Vector3(rx - hw, y_lo, base.z + a_toe))
			pts.append(Vector3(rx + hw, y_lo, base.z + a_toe))
			pts.append(Vector3(rx - hw, y_lo, base.z + a_top))
			pts.append(Vector3(rx + hw, y_lo, base.z + a_top))
			pts.append(Vector3(rx - hw, y_hi, base.z + a_top))
			pts.append(Vector3(rx + hw, y_hi, base.z + a_top))
		else:
			var rz := base.z + lateral
			pts.append(Vector3(base.x + a_toe, y_lo, rz - hw))
			pts.append(Vector3(base.x + a_toe, y_lo, rz + hw))
			pts.append(Vector3(base.x + a_top, y_lo, rz - hw))
			pts.append(Vector3(base.x + a_top, y_lo, rz + hw))
			pts.append(Vector3(base.x + a_top, y_hi, rz - hw))
			pts.append(Vector3(base.x + a_top, y_hi, rz + hw))
		_stair_ramps.append({
			"points": pts,
			"name": "%s_to_%s_ramp" % [from_name, to_name],
			"degrees": rad_to_deg(atan2(total_rise, length)),
		})

		if hole_min.x < INF:
			# Extend the opening out to the wall the flight arrives at, so the
			# top step emerges level with the upper floor rather than under a
			# lip of slab. Only correct when the flight genuinely reaches that
			# wall - see extend_to_wall in the STAIRS notes.
			if bool(s.get("extend_to_wall", true)):
				if horizontal:
					if dir_sign < 0.0:
						hole_min.y = min(hole_min.y, base.z - PITCH / 2.0)
					else:
						hole_max.y = max(hole_max.y, base.z + PITCH / 2.0)
				else:
					if dir_sign < 0.0:
						hole_min.x = min(hole_min.x, base.x - PITCH / 2.0)
					else:
						hole_max.x = max(hole_max.x, base.x + PITCH / 2.0)
			_openings[to_name] = Rect2(hole_min, hole_max - hole_min)
			_opening_arrival[to_name] = side


func _emit_stair_steps() -> void:
	for st in _stair_steps:
		_box("stairs", st["size"], st["pos"], Color(0.5, 0.4, 0.3), st["name"])


## Invisible walking surface over each flight. Collision only - it is added
## straight to the shared body rather than going through a render bucket, since
## there is deliberately nothing to draw.
func _emit_stair_ramps() -> void:
	for r in _stair_ramps:
		var shape := ConvexPolygonShape3D.new()
		shape.points = r["points"]
		var coll := CollisionShape3D.new()
		coll.name = String(r["name"])
		coll.shape = shape
		_collision_body.add_child(coll)
		if float(r["degrees"]) > 44.0:
			push_warning("ManorBuilder: '%s' rises at %.1f degrees, past the angle Godot walks up. Add steps or lengthen the flight." % [r["name"], r["degrees"]])


## Height and thickness of the parapet round a stairwell opening.
const RAIL_H := 1.0
const RAIL_T := 0.12
const RAIL_COLOR := Color(0.42, 0.33, 0.24)

## How much of the SIDE railings to leave out where the flight meets the landing.
##
## Leaving the arrival end open is not enough on its own. The flight climbs to
## the wall, so the floor straight ahead of the top tread is only the strip
## between that wall and the opening - here 0.30m, against a 0.80m player. The
## way off the stairs is sideways onto the landing, and a parapet running the
## full length of the well seals exactly that, leaving jumping as the only exit.
##
## So the two rails that run ALONGSIDE the flight stop short of the arrival end.
## 1.1 clears the 0.80 capsule comfortably. It is the gap a real staircase has
## between its newel post and the wall.
const RAIL_LANDING_GAP := 1.1


## Walls the height of a handrail around every open edge of a stairwell, except
## the edge the flight climbs toward - that one is the way in. Without this the
## landing is a hole in the floor with nothing between you and it, and the
## suspects downstairs cannot even be blamed, because an NPC steers only in XZ
## and will happily be pushed over an unguarded edge.
func _emit_railings() -> void:
	for rname in _openings.keys():
		if not room_centers.has(rname):
			continue
		var hole: Rect2 = _openings[rname]
		var centre: Vector3 = room_centers[rname]
		var arrival := String(_opening_arrival.get(rname, ""))
		var mid_y := centre.y + RAIL_H / 2.0
		var half := PITCH / 2.0

		var x0 := hole.position.x
		var x1 := hole.position.x + hole.size.x
		var z0 := hole.position.y
		var z1 := hole.position.y + hole.size.y

		# The rails that run alongside the flight stop short at the arrival end, so
		# there is a doorway-sized gap to step through onto the landing. Only the
		# axis the flight runs along is shortened; the rail across the far end of the
		# well is the one you never walk through, and it stays full length.
		var gx0 := x0
		var gx1 := x1
		var gz0 := z0
		var gz1 := z1
		match arrival:
			"north": gz0 = minf(z0 + RAIL_LANDING_GAP, z1)
			"south": gz1 = maxf(z1 - RAIL_LANDING_GAP, z0)
			"west":  gx0 = minf(x0 + RAIL_LANDING_GAP, x1)
			"east":  gx1 = maxf(x1 - RAIL_LANDING_GAP, x0)

		# An edge the room's own wall already backs needs no rail - the wall is the
		# rail - and the edge the stairs arrive at has to stay open or you cannot
		# get off them. The margin is WALL_T rather than a hair, so an opening that
		# runs right up to a wall's inner face does not get a parapet buried in it.
		var edge := half - WALL_T - 0.01
		var span_x := (gx1 - gx0) + RAIL_T * 2.0
		var span_z := gz1 - gz0
		if arrival != "north" and z0 > centre.z - edge and span_x > RAIL_T:
			_box("rail", Vector3(span_x, RAIL_H, RAIL_T),
				Vector3((gx0 + gx1) / 2.0, mid_y, z0), RAIL_COLOR, rname + "_rail_n")
		if arrival != "south" and z1 < centre.z + edge and span_x > RAIL_T:
			_box("rail", Vector3(span_x, RAIL_H, RAIL_T),
				Vector3((gx0 + gx1) / 2.0, mid_y, z1), RAIL_COLOR, rname + "_rail_s")
		if arrival != "west" and x0 > centre.x - edge and span_z > RAIL_T:
			_box("rail", Vector3(RAIL_T, RAIL_H, span_z),
				Vector3(x0, mid_y, (gz0 + gz1) / 2.0), RAIL_COLOR, rname + "_rail_w")
		if arrival != "east" and x1 < centre.x + edge and span_z > RAIL_T:
			_box("rail", Vector3(RAIL_T, RAIL_H, span_z),
				Vector3(x1, mid_y, (gz0 + gz1) / 2.0), RAIL_COLOR, rname + "_rail_e")


## A floor slab with a rectangular bite taken out of it, emitted as up to four
## boxes around the hole. Falls back to a single slab when there is no opening.
func _emit_floor_slab(rname: String, center: Vector3, y: float, color: Color, suffix: String) -> void:
	var half := PITCH / 2.0
	var x0 := center.x - half
	var x1 := center.x + half
	var z0 := center.z - half
	var z1 := center.z + half

	if not _openings.has(rname):
		_box("floor", Vector3(PITCH, FLOOR_T, PITCH), Vector3(center.x, y, center.z), color, rname + suffix)
		return

	var hole: Rect2 = _openings[rname]
	var hx0 := clampf(hole.position.x, x0, x1)
	var hx1 := clampf(hole.position.x + hole.size.x, x0, x1)
	var hz0 := clampf(hole.position.y, z0, z1)
	var hz1 := clampf(hole.position.y + hole.size.y, z0, z1)

	# Two full-width strips beyond the hole, then two shorter strips beside it.
	_strip(rname + suffix + "_n", x0, x1, z0, hz0, y, color)
	_strip(rname + suffix + "_s", x0, x1, hz1, z1, y, color)
	_strip(rname + suffix + "_w", x0, hx0, hz0, hz1, y, color)
	_strip(rname + suffix + "_e", hx1, x1, hz0, hz1, y, color)


func _strip(box_name: String, x0: float, x1: float, z0: float, z1: float, y: float, color: Color) -> void:
	var w := x1 - x0
	var d := z1 - z0
	if w <= 0.001 or d <= 0.001:
		return
	_box("floor", Vector3(w, FLOOR_T, d), Vector3((x0 + x1) / 2.0, y, (z0 + z1) / 2.0), color, box_name)


func _emit_front_door(pos: Vector3) -> void:
	# The door is a real node rather than a batched box: Door.gd hangs off it,
	# and the interact ray needs something to hit.
	var door := StaticBody3D.new()
	door.name = "FrontDoor"
	var script_res := load("res://Scripts/Door.gd")
	if script_res:
		door.set_script(script_res)
	_shell.add_child(door)
	door.position = pos

	var size := Vector3(DOOR_W - 0.6, WALL_H - 0.3, 0.2)

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position.y = size.y / 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = DOOR_COLOR
	mesh.material_override = mat
	door.add_child(mesh)

	var coll := CollisionShape3D.new()
	coll.shape = _shape_for(size)
	coll.position.y = size.y / 2.0
	door.add_child(coll)

	front_door_node = door


func _emit_label(rname: String, center: Vector3) -> void:
	var label := Label3D.new()
	label.name = rname + "_Label"
	label.text = rname
	label.font_size = 56
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	var holder := _bucket_node("Labels")
	holder.add_child(label)
	label.position = Vector3(center.x, center.y + 3.4, center.z)


## An Area3D per room, tagged with its name. This is what makes "which room is
## X standing in" a lookup instead of a nearest-centre guess, and it is the
## piece that makes multi-floor work at all: two rooms can share an XZ position
## as long as they are at different heights.
func _emit_volume(rname: String, center: Vector3, level: int) -> void:
	var area := Area3D.new()
	area.name = rname
	area.monitorable = false
	area.collision_layer = room_volume_layer
	area.collision_mask = 0
	area.set_meta("room_name", rname)
	area.set_meta("room_level", level)
	area.add_to_group("room_volume")

	var coll := CollisionShape3D.new()
	# The clear interior of a room, wall faces included, is PITCH minus one
	# wall thickness now that walls sit on the boundary.
	coll.shape = _shape_for(Vector3(PITCH - WALL_T, WALL_H, PITCH - WALL_T))
	area.add_child(coll)

	var holder := _bucket_node("Rooms")
	holder.add_child(area)
	area.position = Vector3(center.x, center.y + WALL_H / 2.0, center.z)


# ------------------------------------------------------------------ flush --

## Collapses colinear coplanar wall segments into single boxes.
##
## This is the anti-z-fighting pass, and it matters more than it looks. The
## layout walk emits walls per room, so a long run like the whole north face of
## the manor arrives as three separate boxes that meet end to end. Meeting is
## fine on its own, but any overlap at all puts two same-facing quads on the
## same plane, and rounding alone can produce that. Merging removes the question
## entirely: one run, one box, no internal seams to fight over.
##
## It is also free geometry savings. The ground floor goes from 37 wall boxes
## to 20, the plus-shaped upper floor from 20 to 12.
func _merge_wall_runs() -> void:
	var items: Array = _pending.get("wall", [])
	if items.is_empty():
		return

	# Group by the plane a wall lies in: its thin axis, that axis's coordinate,
	# plus height and vertical position so floors never merge into each other.
	var groups := {}
	for it in items:
		var size: Vector3 = it["size"]
		var pos: Vector3 = it["pos"]
		var thin_x: bool = size.x < size.z
		var plane: float = pos.x if thin_x else pos.z
		var key := "%s|%.4f|%.4f|%.4f" % ["x" if thin_x else "z", plane, pos.y, size.y]
		if not groups.has(key):
			groups[key] = {"thin_x": thin_x, "plane": plane, "y": pos.y, "h": size.y, "spans": []}
		var run_pos: float = pos.z if thin_x else pos.x
		var run_len: float = size.z if thin_x else size.x
		groups[key]["spans"].append(Vector2(run_pos - run_len / 2.0, run_pos + run_len / 2.0))

	var out := []
	for key in groups:
		var g: Dictionary = groups[key]
		var spans: Array = g["spans"]
		spans.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)

		var merged := []
		for s in spans:
			# Touching counts as joined. The epsilon absorbs float drift so two
			# walls that should meet exactly are never left a hair apart.
			if not merged.is_empty() and s.x <= merged[-1].y + 0.0001:
				merged[-1].y = maxf(merged[-1].y, s.y)
			else:
				merged.append(s)

		for i in range(merged.size()):
			var m: Vector2 = merged[i]
			var length: float = m.y - m.x
			var mid: float = (m.x + m.y) / 2.0
			var size: Vector3
			var pos: Vector3
			if g["thin_x"]:
				size = Vector3(WALL_T, g["h"], length)
				pos = Vector3(g["plane"], g["y"], mid)
			else:
				size = Vector3(length, g["h"], WALL_T)
				pos = Vector3(mid, g["y"], g["plane"])
			out.append({
				"size": size,
				"pos": pos,
				"color": WALL_COLOR,
				"name": "Wall_%s%.1f_L%.1f_%d" % ["x" if g["thin_x"] else "z", g["plane"], g["y"], i],
			})

	_pending["wall"] = out


func _flush() -> void:
	if merge_wall_runs:
		_merge_wall_runs()
	_flush_bucket("Walls", "wall", _material_for("wall"))
	_flush_bucket("Floors", "floor", _material_for("floor"))
	_flush_bucket("Ceilings", "ceiling", _material_for("ceiling"))
	_flush_bucket("Stairs", "stairs", _material_for("wall"))
	_flush_bucket("Railings", "rail", _material_for("wall"))
	_flush_bucket("Ground", "ground", _material_for("floor"))


func _flush_bucket(node_name: String, bucket: String, mat: StandardMaterial3D) -> void:
	var items: Array = _pending.get(bucket, [])
	if items.is_empty():
		return

	if batch_meshes:
		_flush_batched(node_name, items, mat)
	else:
		_flush_individual(node_name, items, mat)

	# Collision is always separate from rendering. One StaticBody3D holding
	# every shape costs far less than one body per wall, and BoxShape3D
	# resources are shared between identically sized boxes.
	for it in items:
		var coll := CollisionShape3D.new()
		coll.name = str(it["name"]) + "_col"
		coll.shape = _shape_for(it["size"])
		_collision_body.add_child(coll)
		coll.position = it["pos"]


func _flush_batched(node_name: String, items: Array, mat: StandardMaterial3D) -> void:
	var mm := MultiMesh.new()
	# Order matters: format flags must be set before instance_count, or Godot
	# allocates the buffer without room for the per-instance colours.
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = _unit_mesh()
	mm.instance_count = items.size()

	for i in range(items.size()):
		var it: Dictionary = items[i]
		var basis := Basis.IDENTITY.scaled(it["size"])
		mm.set_instance_transform(i, Transform3D(basis, it["pos"]))
		mm.set_instance_color(i, it["color"])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	_shell.add_child(mmi)


func _flush_individual(node_name: String, items: Array, mat: StandardMaterial3D) -> void:
	var holder := Node3D.new()
	holder.name = node_name
	_shell.add_child(holder)

	for it in items:
		var mi := MeshInstance3D.new()
		mi.name = str(it["name"])
		var box := BoxMesh.new()
		box.size = it["size"]
		mi.mesh = box
		# A per-instance material here is the reason the old code could not
		# batch: 47 identical cream boxes meant 47 distinct materials. Unbatched
		# mode is for inspection only, so the cost is acceptable.
		var m := mat.duplicate()
		m.albedo_color = it["color"]
		mi.material_override = m
		holder.add_child(mi)
		mi.position = it["pos"]


func _unit_mesh() -> BoxMesh:
	if _unit_box == null:
		_unit_box = BoxMesh.new()
		_unit_box.size = Vector3.ONE
	return _unit_box


func _material_for(kind: String) -> StandardMaterial3D:
	var assigned: StandardMaterial3D = null
	match kind:
		"wall":
			assigned = wall_material
		"floor":
			assigned = floor_material
		"ceiling":
			assigned = ceiling_material
	if assigned:
		var m: StandardMaterial3D = assigned.duplicate()
		m.vertex_color_use_as_albedo = true
		return m
	var mat := StandardMaterial3D.new()
	# Per-instance colours arrive as vertex colours from the MultiMesh, so this
	# one shared material paints every room its own shade without splitting
	# the batch.
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color.WHITE
	return mat


func _shape_for(size: Vector3) -> BoxShape3D:
	var key := "%.4f,%.4f,%.4f" % [size.x, size.y, size.z]
	if not _shape_cache.has(key):
		var s := BoxShape3D.new()
		s.size = size
		_shape_cache[key] = s
	return _shape_cache[key]


# ------------------------------------------------------------- scene plumbing --

func _reset() -> void:
	_pending.clear()
	_shape_cache.clear()
	front_door_node = null

	# Decor is created once and never cleared. Everything the player hand-places
	# lives here and survives every rebuild.
	_decor = get_node_or_null("Decor")
	if _decor == null:
		_decor = Node3D.new()
		_decor.name = "Decor"
		add_child(_decor)
		if Engine.is_editor_hint():
			var root := get_tree().edited_scene_root if get_tree() else null
			if root:
				_decor.owner = root

	var old := get_node_or_null("Shell")
	if old:
		remove_child(old)
		old.queue_free()

	_shell = Node3D.new()
	_shell.name = "Shell"
	add_child(_shell)

	_collision_body = StaticBody3D.new()
	_collision_body.name = "Collision"
	_shell.add_child(_collision_body)


func _bucket_node(node_name: String) -> Node3D:
	var existing := _shell.get_node_or_null(node_name)
	if existing:
		return existing
	var n := Node3D.new()
	n.name = node_name
	_shell.add_child(n)
	return n


## A node is only written into Main.tscn if it has an owner. Leaving the shell
## unowned means the manor renders in the editor viewport but the scene file
## stays a handful of lines, with this script's spec as the only source of
## truth. Turning on save_to_scene claims ownership so the nodes become real,
## selectable and editable, at the cost of a large .tscn that a rebuild will
## overwrite.
func _finalise_owners() -> void:
	if not save_to_scene or not Engine.is_editor_hint():
		return
	var tree := get_tree()
	if tree == null:
		return
	var root := tree.edited_scene_root
	if root == null:
		return
	_claim(_shell, root)


func _claim(n: Node, root: Node) -> void:
	n.owner = root
	for c in n.get_children():
		_claim(c, root)
