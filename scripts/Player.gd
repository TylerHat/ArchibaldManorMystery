extends CharacterBody3D
# First-person detective controller: WASD movement, mouse look, and a
# center-screen raycast used to interact with suspects and the front door
# (via the E key or a left click, matching a normal FPS interact scheme).

const SPEED := 4.5
const JUMP_VELOCITY := 4.5
const MOUSE_SENSITIVITY := 0.0025
const GRAVITY := 9.8

@onready var camera: Camera3D = $Camera3D
@onready var ray: RayCast3D = $Camera3D/InteractRay

var mouse_captured := true
var current_target = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and mouse_captured:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		camera.rotate_x(-event.relative.y * MOUSE_SENSITIVITY)
		camera.rotation.x = clamp(camera.rotation.x, deg_to_rad(-80), deg_to_rad(80))

	var wants_interact := event.is_action_pressed("interact")
	var left_click := false
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		left_click = true
	if (wants_interact or left_click) and mouse_captured:
		_try_interact()


func _physics_process(delta: float) -> void:
	if not mouse_captured:
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= GRAVITY * delta
		move_and_slide()
		return

	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	else:
		velocity.y = 0.0
		if Input.is_action_just_pressed("jump"):
			velocity.y = JUMP_VELOCITY

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction.length() > 0.01:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0.0, SPEED)
		velocity.z = move_toward(velocity.z, 0.0, SPEED)

	move_and_slide()
	_update_interact_prompt()


func _update_interact_prompt() -> void:
	var main = get_tree().get_first_node_in_group("main_controller")
	if not main:
		return
	if ray.is_colliding():
		var col = ray.get_collider()
		if col and col.has_method("get_interact_prompt"):
			current_target = col
			main.show_prompt(col.get_interact_prompt())
			return
	current_target = null
	main.hide_prompt()


func _try_interact() -> void:
	if current_target and current_target.has_method("interact"):
		current_target.interact()


func set_mouse_captured(captured: bool) -> void:
	mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE
	if not captured:
		current_target = null
		var main = get_tree().get_first_node_in_group("main_controller")
		if main:
			main.hide_prompt()
