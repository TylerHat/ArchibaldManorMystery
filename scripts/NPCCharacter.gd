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
const ROOM_HALF := 6.5 # half of Main.PITCH - walls now sit on the room boundary
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

## True while the player has this NPC's dialogue panel open. Movement is
## suspended entirely so a suspect doesn't wander off mid-interrogation; the
## underlying `state` and any remaining `_path` are left untouched so travel
## resumes exactly where it left off once the conversation ends.
var _is_talking: bool = false

## True while this NPC is an attendee of an open Hall meetup. Freezes movement
## the same way _is_talking does, so nobody wanders off mid-confrontation while
## the other three are answering.
var _in_group_scene: bool = false

# --- character model animation (see SuspectModels.gd, CHARACTER_MODELS.md) ---
# All null/empty for a suspect still using the fallback capsule, in which case
# every animation call below is a no-op and nothing else changes.
var _anim: AnimationPlayer = null
var _idle_anim: String = ""
var _walk_anim: String = ""
var _current_anim: String = ""

## Speed the walk cycle was authored for. The clip is time-scaled by the ratio
## of actual speed to this, which is what stops the feet skating.
const WALK_ANIM_REFERENCE_SPEED := 1.4
const MOVING_THRESHOLD := 0.2


func _ready() -> void:
	add_to_group("npc_characters")
	_main = get_tree().get_first_node_in_group("main_controller")
	_wander_wait = randf_range(0.0, WANDER_WAIT_MAX)


## Called by Main._spawn_npcs() right after SuspectModels.build_visual(), which
## is why this is not just done in _ready(): character_id and the model are both
## set after this node enters the tree.
func bind_model() -> void:
	_anim = SuspectModels.find_animation_player(get_node_or_null("ModelRoot"))
	if _anim == null:
		return

	var cfg: Dictionary = SuspectModels.OVERRIDES.get(character_id, {})
	_idle_anim = SuspectModels.pick_animation(_anim, SuspectModels.IDLE_WORDS, String(cfg.get("idle", "")))
	_walk_anim = SuspectModels.pick_animation(_anim, SuspectModels.WALK_WORDS, String(cfg.get("walk", "")))

	# Downloaded clips very often arrive set to play once and then freeze on the
	# last frame, which reads as the character dying mid-step. Force both to loop.
	for n in [_idle_anim, _walk_anim]:
		if n != "" and _anim.has_animation(n):
			_anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR

	if _idle_anim == "" and _walk_anim == "":
		push_warning("SuspectModels: '%s' has an AnimationPlayer but no clip matched idle or walk. Animations present: %s" % [character_id, ", ".join(_anim.get_animation_list())])

	_apply_animation(_idle_anim, 1.0)


## Swaps between idle and walk based on how fast the body is actually moving,
## so it stays correct whether the NPC is wandering, pathing between rooms, or
## frozen for a conversation.
func _update_animation() -> void:
	if _anim == null:
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed > MOVING_THRESHOLD and _walk_anim != "":
		_apply_animation(_walk_anim, maxf(0.35, speed / WALK_ANIM_REFERENCE_SPEED))
	else:
		_apply_animation(_idle_anim, 1.0)


func _apply_animation(anim_name: String, speed_scale: float) -> void:
	if anim_name == "":
		return
	_anim.speed_scale = speed_scale
	if anim_name != _current_anim:
		_current_anim = anim_name
		_anim.play(anim_name)


func get_interact_prompt() -> String:
	if _wants_group_scene():
		return "Address the room"
	var c := GameManager.get_character(character_id)
	if c.is_empty():
		return "Talk"
	return "Talk to " + String(c["name"])


func interact() -> void:
	var main = get_tree().get_first_node_in_group("main_controller")
	if main == null:
		return
	if _wants_group_scene():
		main.open_group_dialogue()
	else:
		main.open_dialogue(character_id)


## True when looking at this NPC should open a group confrontation instead of a
## private interview: this NPC is standing in the meetup room, and so are the
## detective and at least one other suspect.
func _wants_group_scene() -> bool:
	if _main == null or not _main.has_method("can_open_group_scene"):
		return false
	if current_room != _main.MEETUP_ROOM:
		return false
	return _main.can_open_group_scene()


## Freezes this NPC for the duration of a Hall meetup and turns them toward the
## detective. Separate from set_talking() so ending a group scene can't
## accidentally un-freeze someone who is also mid one-on-one.
func set_group_scene(in_scene: bool, face_position: Vector3 = Vector3.INF) -> void:
	_in_group_scene = in_scene
	if in_scene:
		velocity.x = 0.0
		velocity.z = 0.0
		_has_wander_target = false
		_wander_wait = randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
		if face_position != Vector3.INF:
			var to_player := face_position - global_position
			to_player.y = 0.0
			if to_player.length() > 0.05:
				look_at(global_position + to_player.normalized(), Vector3.UP)


## Called by Main when the player opens or closes this NPC's dialogue panel.
## While talking the NPC stands still (and turns to face the player, if one is
## given) rather than continuing to wander or walk its path.
func set_talking(talking: bool, face_position: Vector3 = Vector3.INF) -> void:
	_is_talking = talking
	if talking:
		velocity.x = 0.0
		velocity.z = 0.0
		# Drop any half-finished wander target so they pick a fresh spot when
		# the conversation ends instead of resuming a now-stale walk.
		if state == "wander":
			_has_wander_target = false
			_wander_wait = randf_range(WANDER_WAIT_MIN, WANDER_WAIT_MAX)
		if face_position != Vector3.INF:
			var to_player := face_position - global_position
			to_player.y = 0.0
			if to_player.length() > 0.05:
				look_at(global_position + to_player.normalized(), Vector3.UP)


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
	# A "go to the library" order given during a conversation should take
	# effect immediately, so an explicit travel command overrides both the
	# stand-still-while-talking hold and the group-scene hold.
	_is_talking = false
	_in_group_scene = false


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0

	# Frozen mid-conversation or standing in a group confrontation: hold
	# position (gravity still applies) and skip wandering, pathing, and
	# separation entirely.
	if _is_talking or _in_group_scene:
		velocity.x = 0.0
		velocity.z = 0.0
		move_and_slide()
		_update_animation()
		return

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
	_update_animation()


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
