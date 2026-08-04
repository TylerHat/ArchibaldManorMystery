extends CharacterBody3D
# Attached to each suspect's body in the mansion. Idly wanders within
# whichever room it currently belongs to, and walks a doorway-by-doorway
# path to a new room when Main.command_npc_move() calls begin_travel() (in
# response to a "go to <room>" line typed into the dialogue box). Simple
# separation steering keeps multiple NPCs sharing a room from wandering
# into each other; the CharacterBody3D collision shape is the hard backstop.

const SPEED := 2.2
const ARRIVE_DIST := 0.35
const WANDER_MARGIN := 2.0 # stay this far inside the room's outer walls
const ROOM_HALF := 6.0 # half of Main.CELL - keep in sync if CELL ever changes
const WANDER_WAIT_MIN := 1.0
const WANDER_WAIT_MAX := 3.5
const SEPARATION_RADIUS := 1.3
const SEPARATION_STRENGTH := 2.0
const GRAVITY := 9.8

var character_id: String = ""

## Which room this NPC currently belongs to for wandering/avoidance purposes.
## Set to the destination room as soon as begin_travel() is called (not just
## on arrival), so a second move command issued mid-walk, and other NPCs'
## avoidance checks, treat it as already heading there.
var current_room: String = ""

## "wander" (default) or "moving" (walking a path set by begin_travel()).
var state: String = "wander"

var _path: Array = [] # remaining Vector3 waypoints while state == "moving"
var _wander_target: Vector3 = Vector3.ZERO
var _has_wander_target: bool = false
var _wander_wait: float = 0.0
var _main = null


func _ready() -> void:
	add_to_group("npc_characters")
	_main = get_tree().get_first_node_in_group("main_controller")
	_wander_wait = randf_range(0.0, WANDER_WAIT_MAX)


func get_interact_prompt() -> String:
	var c := GameManager.get_character(character_id)
	if c.is_empty():
		return "Talk"
	return "Talk to " + String(c["name"])


func interact() -> void:
	var main = get_tree().get_first_node_in_group("main_controller")
	if main:
		main.open_dialogue(character_id)


## Called by Main to send this NPC walking to a new room. `waypoints` is an
## ordered list of world-space points (doorway crossings, then that room's
## center, repeated per room passed through) ending inside `dest_room`; once
## the last waypoint is reached this NPC drops back into "wander" state
## using `dest_room` as its new home.
func begin_travel(waypoints: Array, dest_room: String) -> void:
	_path = waypoints.duplicate()
	current_room = dest_room
	state = "moving"
	_has_wander_target = false


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	var desired := Vector3.ZERO
	if state == "moving":
		desired = _movement_step()
	else:
		desired = _wander_step(delta)

	desired += _separation_force()

	if desired.length() > 0.05:
		var dir := desired.normalized()
		velocity.x = dir.x * SPEED
		velocity.z = dir.z * SPEED
		var look_pos := global_position + Vector3(dir.x, 0, dir.z)
		look_at(look_pos, Vector3.UP)
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)

	move_and_slide()


## Steers toward the next waypoint on _path, popping waypoints as they're
## reached. Falls back to "wander" once the path is exhausted.
func _movement_step() -> Vector3:
	if _path.is_empty():
		state = "wander"
		return Vector3.ZERO

	var flat_here := Vector3(global_position.x, 0, global_position.z)
	var target: Vector3 = _path[0]
	var flat_target := Vector3(target.x, 0, target.z)

	if flat_here.distance_to(flat_target) <= ARRIVE_DIST:
		_path.pop_front()
		if _path.is_empty():
			state = "wander"
			return Vector3.ZERO
		target = _path[0]
		flat_target = Vector3(target.x, 0, target.z)

	return flat_target - flat_here


## Picks a random point inside the current room, walks there, waits a bit,
## then repeats - the idle "wondering around" behavior.
func _wander_step(delta: float) -> Vector3:
	if not _has_wander_target:
		_wander_wait -= delta
		if _wander_wait > 0.0:
			return Vector3.ZERO
		_pick_wander_target()

	var flat_here := Vector3(global_position.x, 0, global_position.z)
	var flat_target := Vector3(_wander_target.x, 0, _wander_target.z)

	if flat_here.distance_to(flat_target) <= ARRIVE_DIST:
		_has_wander_target = false
		_wander_wait = randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
		return Vector3.ZERO

	return flat_target - flat_here


func _room_center() -> Vector3:
	if _main and _main.room_centers.has(current_room):
		return _main.room_centers[current_room]
	return global_position


## Tries a few random spots inside the room and keeps the first one that
## isn't already claimed by another NPC currently wandering the same room,
## so two characters don't pick targets on top of each other. Gives up and
## uses the last candidate anyway after a few tries rather than stalling.
func _pick_wander_target() -> void:
	var center := _room_center()
	var half := ROOM_HALF - WANDER_MARGIN
	var candidate := center

	for _attempt in range(6):
		candidate = Vector3(
			center.x + randf_range(-half, half),
			0,
			center.z + randf_range(-half, half)
		)
		if _far_enough_from_others(candidate):
			break

	_wander_target = candidate
	_has_wander_target = true


func _far_enough_from_others(candidate: Vector3) -> bool:
	for node in get_tree().get_nodes_in_group("npc_characters"):
		if node == self or node.current_room != current_room:
			continue
		var flat_other := Vector3(node.global_position.x, 0, node.global_position.z)
		if flat_other.distance_to(candidate) < SEPARATION_RADIUS:
			return false
	return true


## Steering force pushing this NPC away from any other NPC in the same room
## that's gotten too close, so two wandering characters don't walk on top of
## each other even if their chosen targets happen to cross paths.
func _separation_force() -> Vector3:
	var push := Vector3.ZERO
	for node in get_tree().get_nodes_in_group("npc_characters"):
		if node == self or node.current_room != current_room:
			continue
		var offset: Vector3 = global_position - node.global_position
		offset.y = 0.0
		var dist := offset.length()
		if dist > 0.001 and dist < SEPARATION_RADIUS:
			push += offset.normalized() * (SEPARATION_RADIUS - dist) * SEPARATION_STRENGTH
	return push
