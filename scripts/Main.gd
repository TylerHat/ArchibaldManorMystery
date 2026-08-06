extends Node3D
# Builds the entire mansion, the player, all 8 suspects, and all UI purely in
# code (no hand-authored sub-scenes), so the whole game lives in a handful of
# readable script files. Also acts as the central "controller" that NPCs and
# the front door call into (via the "main_controller" group) to open dialogue
# / accusation panels.

const CELL := 12.0
const PITCH := 13.0
const WALL_H := 3.0
const WALL_T := 0.4
const DOOR_W := 3.0

# The Hall doubles as the meetup room: suspects ordered there gather for a
# group confrontation. Capped because every attendee costs one sequential
# Ollama call per line the detective says, and because a confrontation with
# more than four voices stops being readable.
const MEETUP_ROOM := "Hall"
const MAX_HALL_ATTENDEES := 4

# 3x3 layout. Hall (front door + player spawn) sits at the front-center so
# the front door can face the exterior.
const GRID := [
	["Kitchen", "Ballroom", "Conservatory"],
	["Lounge", "Study", "Dining Room"],
	["Billiard Room", "Hall", "Library"],
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
}
const WALL_COLOR := Color(0.92, 0.9, 0.85)

# These double as both the suspect's 3D capsule color AND their name color
# in the Case Notes UI, so every entry needs to stay legible as text on a
# dark panel background - avoid very dark/near-black shades here.
const NPC_COLORS := {
	"blackwood": Color(0.2, 0.5, 0.8),
	"sterling": Color(0.8, 0.2, 0.2),
	"ashford": Color(0.7, 0.2, 0.6),
	"carter": Color(0.6, 0.6, 0.65),
	"whitmore": Color(0.9, 0.7, 0.2),
	"reeves": Color(0.4, 0.6, 0.3),
	"cross_natalie": Color(0.8, 0.4, 0.1),
	"cross_eugene": Color(0.6, 0.5, 0.4),
}

var rooms_node: Node3D
var room_centers: Dictionary = {}
var grid_pos: Dictionary = {} # room name -> Vector2i(row, col), for pathing between rooms
var player: CharacterBody3D
var front_door_node = null

var npc_nodes: Dictionary = {} # character_id -> spawned NPCCharacter node

# Movement commands typed straight into the dialogue box, e.g. "go to the
# library" or "wait in the study" - detected with plain regex (no extra
# Ollama round-trip) rather than sent through GameManager as a question.
var room_name_lookup: Dictionary = {} # lowercase room name -> canonical room name
var move_command_regex: RegEx = null
var wait_command_regex: RegEx = null

# Floor-control orders typed into the Hall meetup box - "Marcus, be quiet",
# "everyone except Eleanor stay quiet", "Tom, you can go". Detected locally
# the same way movement commands are, so an order to the room never costs an
# Ollama round-trip and never gets answered in character.
var group_silence_regex: RegEx = null
var group_speak_regex: RegEx = null
var group_leave_regex: RegEx = null
var group_everyone_regex: RegEx = null
var group_except_regex: RegEx = null

var ui_layer: CanvasLayer
var crosshair: ColorRect
var prompt_label: Label

var dialogue_panel: Panel
var dialogue_name_label: Label
var dialogue_log: RichTextLabel
var dialogue_input: LineEdit
var dialogue_ask_button: Button
var dialogue_status_label: Label
var current_dialogue_character: String = ""

# Hall meetup panel - the group confrontation. The turn logic itself lives in
# GameManager.group_chat (Scripts/GroupChat.gd); everything here is UI.
var group_panel: Panel
var group_roster: HBoxContainer
var group_log: RichTextLabel
var group_input: LineEdit
var group_say_button: Button
var group_status_label: Label
var group_frozen_ids: Array = [] # attendees currently held still by the open scene

var accusation_panel: Panel
var accusation_suspect_buttons: Dictionary = {} # character_id -> Button
var accusation_selected_id: String = ""
var accusation_accuse_button: Button
var accusation_result_label: Label

var notes_panel: Panel
var notes_log: RichTextLabel
var notes_tab_buttons: Dictionary = {} # character_id -> Button
var notes_flag_dots: Dictionary = {} # character_id -> ColorRect (shown when Slipups has real content)
var notes_selected_char: String = ""
var _pending_summaries: Dictionary = {} # character_id -> true while a summary request is in flight

var win_panel: Panel
var win_label: Label

var debug_label: Label

var name_regexes: Dictionary = {} # character_id -> compiled RegEx matching that suspect's name variants

var selection_layer: CanvasLayer
var selection_checkboxes: Dictionary = {} # character_id -> CheckBox
var selection_count_label: Label
var selection_start_button: Button


func _ready() -> void:
	add_to_group("main_controller")
	GameManager.ollama_response.connect(_on_ollama_response)
	GameManager.ollama_error.connect(_on_ollama_error)
	GameManager.summary_ready.connect(_on_summary_ready)
	GameManager.summary_error.connect(_on_summary_error)

	GameManager.group_chat.line_added.connect(_on_group_line_added)
	GameManager.group_chat.turn_started.connect(_on_group_turn_started)
	GameManager.group_chat.state_changed.connect(_on_group_state_changed)
	GameManager.group_chat.round_failed.connect(_on_group_round_failed)
	GameManager.group_chat.roster_changed.connect(_on_group_roster_changed)
	GameManager.group_chat.quorum_lost.connect(_on_group_quorum_lost)

	_build_room_name_lookup()
	_build_move_command_regexes()
	_build_group_command_regexes()

	# The mouse may still be captured (MOUSE_MODE_CAPTURED) from a previous
	# game if this is a "Play Again" scene reload - make sure it's free so
	# the player can click checkboxes on the selection screen below.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_selection_screen()


## Builds the whole game (mansion, suspects, player, UI) once the player has
## picked which suspects are in tonight - called from _on_start_pressed().
func _start_game(selected_ids: Array) -> void:
	GameManager.start_new_game(selected_ids)
	_build_name_regexes()
	_build_world()
	_build_mansion()
	_spawn_npcs()
	_spawn_player()
	_build_ui()


# --------------------------------------------------------- selection screen --
# A pre-game screen letting the player choose 2-8 of the 8 suspects, either by
# checking them individually or via a "Random N" quick-select row. The mansion
# itself is always the same fixed 3x3 grid of 9 rooms; suspects who aren't
# chosen simply don't get spawned into their room.

func _build_selection_screen() -> void:
	selection_layer = CanvasLayer.new()
	add_child(selection_layer)

	var bg := ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	selection_layer.add_child(bg)

	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	var panel_size := Vector2(640, 640)
	panel.size = panel_size
	panel.position = -panel_size / 2.0
	selection_layer.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 20
	vbox.offset_top = 20
	vbox.offset_right = -20
	vbox.offset_bottom = -20
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var title := Label.new()
	title.text = "Archibald Manor: A Clue Mystery"
	title.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Choose which suspects are in the manor tonight (2 to %d)." % GameManager.CHARACTERS.size()
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(subtitle)

	var quick_label := Label.new()
	quick_label.text = "Quick pick (random):"
	quick_label.add_theme_font_size_override("font_size", 14)
	quick_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	vbox.add_child(quick_label)

	var quick_row := HBoxContainer.new()
	quick_row.add_theme_constant_override("separation", 6)
	vbox.add_child(quick_row)
	for n in range(2, GameManager.CHARACTERS.size() + 1):
		var qbtn := Button.new()
		qbtn.text = str(n)
		qbtn.custom_minimum_size = Vector2(38, 34)
		qbtn.pressed.connect(_random_select.bind(n))
		quick_row.add_child(qbtn)

	var list_label := Label.new()
	list_label.text = "Or pick specific suspects:"
	list_label.add_theme_font_size_override("font_size", 14)
	list_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	vbox.add_child(list_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 260)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list_vbox := VBoxContainer.new()
	list_vbox.add_theme_constant_override("separation", 4)
	list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_vbox)

	selection_checkboxes.clear()
	for c in GameManager.CHARACTERS:
		var id: String = c["id"]
		var cb := CheckBox.new()
		cb.text = "%s - %s" % [String(c["name"]), String(c["job"])]
		cb.button_pressed = true
		cb.add_theme_color_override("font_color", NPC_COLORS.get(id, Color.WHITE))
		cb.add_theme_color_override("font_hover_color", NPC_COLORS.get(id, Color.WHITE))
		cb.toggled.connect(func(_pressed): _update_selection_count())
		list_vbox.add_child(cb)
		selection_checkboxes[id] = cb

	selection_count_label = Label.new()
	vbox.add_child(selection_count_label)

	var button_row := HBoxContainer.new()
	button_row.add_theme_constant_override("separation", 10)
	vbox.add_child(button_row)

	var all_btn := Button.new()
	all_btn.text = "Select All"
	all_btn.pressed.connect(func(): _set_all_checkboxes(true))
	button_row.add_child(all_btn)

	var none_btn := Button.new()
	none_btn.text = "Clear"
	none_btn.pressed.connect(func(): _set_all_checkboxes(false))
	button_row.add_child(none_btn)

	selection_start_button = Button.new()
	selection_start_button.text = "Start Game"
	selection_start_button.pressed.connect(_on_start_pressed)
	button_row.add_child(selection_start_button)

	_update_selection_count()


func _random_select(n: int) -> void:
	var ids := []
	for c in GameManager.CHARACTERS:
		ids.append(c["id"])
	ids.shuffle()
	var chosen := {}
	for i in range(min(n, ids.size())):
		chosen[ids[i]] = true
	for id in selection_checkboxes.keys():
		selection_checkboxes[id].set_pressed_no_signal(chosen.has(id))
	_update_selection_count()


func _set_all_checkboxes(pressed: bool) -> void:
	for id in selection_checkboxes.keys():
		selection_checkboxes[id].set_pressed_no_signal(pressed)
	_update_selection_count()


func _update_selection_count() -> void:
	var count := 0
	for id in selection_checkboxes.keys():
		if selection_checkboxes[id].button_pressed:
			count += 1
	var max_count: int = GameManager.CHARACTERS.size()
	selection_count_label.text = "%d selected" % count
	if count < 2 or count > max_count:
		selection_count_label.add_theme_color_override("font_color", Color(1, 0.45, 0.45))
		selection_start_button.disabled = true
	else:
		selection_count_label.add_theme_color_override("font_color", Color(0.55, 1, 0.55))
		selection_start_button.disabled = false


func _on_start_pressed() -> void:
	var selected_ids := []
	for c in GameManager.CHARACTERS: # keep CHARACTERS' stable order regardless of click order
		var id: String = c["id"]
		if selection_checkboxes[id].button_pressed:
			selected_ids.append(id)
	if selected_ids.size() < 2:
		return

	selection_layer.queue_free()
	selection_layer = null
	_start_game(selected_ids)


func _unhandled_input(event: InputEvent) -> void:
	if selection_layer != null:
		return # still on the pre-game suspect-selection screen; nothing to handle yet
	if event.is_action_pressed("ui_cancel"):
		if dialogue_panel and dialogue_panel.visible:
			close_dialogue()
			get_viewport().set_input_as_handled()
		elif group_panel and group_panel.visible:
			close_group_dialogue()
			get_viewport().set_input_as_handled()
		elif accusation_panel and accusation_panel.visible:
			close_accusation()
			get_viewport().set_input_as_handled()
		elif notes_panel and notes_panel.visible:
			toggle_notes()
			get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_notes"):
		if not (dialogue_panel.visible or group_panel.visible or accusation_panel.visible):
			toggle_notes()
	elif event.is_action_pressed("toggle_debug"):
		toggle_debug()
	elif event.is_action_pressed("toggle_prompt_dump"):
		GameManager.debug_dump_group = not GameManager.debug_dump_group
		print("[DEBUG] Group prompt dump %s - the next line spoken in a hall meetup will print its full payload." % ("ON" if GameManager.debug_dump_group else "OFF"))


# ---------------------------------------------------------------- geometry --

func add_solid_box(parent: Node3D, box_name: String, size: Vector3, pos: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = box_name
	parent.add_child(body)
	body.position = pos

	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_instance.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_instance.material_override = mat
	body.add_child(mesh_instance)

	var coll := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	coll.shape = shape
	body.add_child(coll)

	return body


func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.05, 0.08)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.53, 0.58)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 1.1
	light.shadow_enabled = true
	add_child(light)

	rooms_node = Node3D.new()
	rooms_node.name = "Rooms"
	add_child(rooms_node)

	# A large safety-net ground plane beneath everything.
	add_solid_box(rooms_node, "Ground", Vector3(60, 0.2, 60), Vector3(0, -0.6, 0), Color(0.1, 0.1, 0.12))


func _room_center(row: int, col: int) -> Vector3:
	return Vector3((col - 1) * PITCH, 0, (row - 1) * PITCH)


func _has_neighbor(row: int, col: int, dir: String) -> bool:
	match dir:
		"north":
			return row - 1 >= 0
		"south":
			return row + 1 <= 2
		"west":
			return col - 1 >= 0
		_:
			return col + 1 <= 2


func _build_mansion() -> void:
	for row in range(GRID.size()):
		for col in range(GRID[row].size()):
			var rname: String = GRID[row][col]
			var center := _room_center(row, col)
			room_centers[rname] = center
			grid_pos[rname] = Vector2i(row, col)
			_build_room(rname, center, row, col)


func _build_room(rname: String, center: Vector3, row: int, col: int) -> void:
	var color: Color = ROOM_COLORS.get(rname, Color(0.8, 0.75, 0.65))
	# Floor tiles are sized to PITCH (room spacing), not CELL (room interior
	# width), so neighboring floors butt up exactly against each other with
	# no strip of missing floor under the doorway gaps in the walls.
	add_solid_box(rooms_node, rname + "_Floor", Vector3(PITCH, 0.2, PITCH), Vector3(center.x, -0.1, center.z), color)

	# Each shared boundary between two rooms must only be built ONCE, by
	# whichever room "owns" it - otherwise two offset wall segments end up
	# facing each other with a sliver of a gap between them that's narrower
	# than the player and easy to get wedged in. South and east walls are
	# always built by this room (covering both interior boundaries and the
	# south/east edges of the mansion). North and west walls are only built
	# here when there's no neighbor on that side (i.e. they're the outer
	# edge of the mansion) - otherwise the neighboring room's south/east
	# call already covers that same boundary.
	_build_wall_side(rname, center, row, col, "south")
	_build_wall_side(rname, center, row, col, "east")
	if not _has_neighbor(row, col, "north"):
		_build_wall_side(rname, center, row, col, "north")
	if not _has_neighbor(row, col, "west"):
		_build_wall_side(rname, center, row, col, "west")

	var label := Label3D.new()
	label.text = rname
	label.position = Vector3(center.x, 3.4, center.z)
	label.font_size = 56
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	rooms_node.add_child(label)


func _build_wall_side(rname: String, center: Vector3, row: int, col: int, dir: String) -> void:
	var half := CELL / 2.0
	if dir == "north" or dir == "south":
		var has_n := _has_neighbor(row, col, dir)
		var z: float = center.z + (-half if dir == "north" else half)
		var is_front_door := rname == "Hall" and dir == "south" and not has_n
		if has_n or is_front_door:
			var seg := (CELL - DOOR_W) / 2.0
			var off := DOOR_W / 2.0 + seg / 2.0
			add_solid_box(rooms_node, rname + "_" + dir + "_a", Vector3(seg, WALL_H, WALL_T), Vector3(center.x - off, WALL_H / 2.0, z), WALL_COLOR)
			add_solid_box(rooms_node, rname + "_" + dir + "_b", Vector3(seg, WALL_H, WALL_T), Vector3(center.x + off, WALL_H / 2.0, z), WALL_COLOR)
			if is_front_door:
				_build_front_door(Vector3(center.x, 0, z))
		else:
			add_solid_box(rooms_node, rname + "_" + dir, Vector3(CELL, WALL_H, WALL_T), Vector3(center.x, WALL_H / 2.0, z), WALL_COLOR)
	else:
		var has_n2 := _has_neighbor(row, col, dir)
		var x: float = center.x + (-half if dir == "west" else half)
		if has_n2:
			var seg2 := (CELL - DOOR_W) / 2.0
			var off2 := DOOR_W / 2.0 + seg2 / 2.0
			add_solid_box(rooms_node, rname + "_" + dir + "_a", Vector3(WALL_T, WALL_H, seg2), Vector3(x, WALL_H / 2.0, center.z - off2), WALL_COLOR)
			add_solid_box(rooms_node, rname + "_" + dir + "_b", Vector3(WALL_T, WALL_H, seg2), Vector3(x, WALL_H / 2.0, center.z + off2), WALL_COLOR)
		else:
			add_solid_box(rooms_node, rname + "_" + dir, Vector3(WALL_T, WALL_H, CELL), Vector3(x, WALL_H / 2.0, center.z), WALL_COLOR)


func _build_front_door(pos: Vector3) -> void:
	var door := StaticBody3D.new()
	door.name = "FrontDoor"
	door.set_script(load("res://Scripts/Door.gd"))
	rooms_node.add_child(door)
	door.position = pos

	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(DOOR_W - 0.6, WALL_H - 0.3, 0.2)
	mesh.mesh = box
	mesh.position.y = box.size.y / 2.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.36, 0.2, 0.1)
	mesh.material_override = mat
	door.add_child(mesh)

	var coll := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box.size
	coll.shape = shape
	coll.position.y = mesh.position.y
	door.add_child(coll)

	front_door_node = door


# -------------------------------------------------------------- characters --

func _spawn_npcs() -> void:
	npc_nodes.clear()
	for c in GameManager.active_characters():
		var center: Vector3 = room_centers.get(c["room"], Vector3.ZERO)
		var npc := CharacterBody3D.new()
		npc.name = "NPC_" + c["id"]
		npc.set_script(load("res://Scripts/NPCCharacter.gd"))
		rooms_node.add_child(npc)
		npc.character_id = c["id"]
		npc.current_room = c["room"]
		npc.position = Vector3(center.x + randf_range(-2.5, 2.5), 0, center.z + randf_range(-2.5, 2.5))
		npc_nodes[c["id"]] = npc

		var mesh := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.height = 1.8
		cap.radius = 0.4
		mesh.mesh = cap
		mesh.position.y = 0.9
		var mat := StandardMaterial3D.new()
		mat.albedo_color = NPC_COLORS.get(c["id"], Color.WHITE)
		mesh.material_override = mat
		npc.add_child(mesh)

		var coll := CollisionShape3D.new()
		var cshape := CapsuleShape3D.new()
		cshape.height = 1.8
		cshape.radius = 0.4
		coll.shape = cshape
		coll.position.y = 0.9
		npc.add_child(coll)

		var label := Label3D.new()
		label.text = c["name"]
		label.position.y = 2.15
		label.font_size = 36
		label.outline_size = 10
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		npc.add_child(label)


# ------------------------------------------------------- room navigation --
# NPCs wander freely within whichever room they currently belong to, but a
# "go to <room>" command typed in the dialogue box needs an actual path
# through the mansion's doorways since the 9 rooms are only connected to
# their orthogonal neighbors in the 3x3 GRID. get_room_travel_waypoints()
# does a short BFS over that grid and turns the room-name path into a list
# of world-space points (each doorway crossing, then the room's center)
# that NPCCharacter.begin_travel() walks through in order.

func _build_room_name_lookup() -> void:
	room_name_lookup.clear()
	for row in GRID:
		for rname in row:
			room_name_lookup[String(rname).to_lower()] = rname


## Builds the two regexes used to detect a movement instruction typed into
## the dialogue box: "go/move/walk/head ... to ... <room>" and
## "wait/stay ... in ... <room>". Reuses _sorted_escaped() (already used for
## suspect-name coloring) so room names are escaped and tried longest-first.
func _build_move_command_regexes() -> void:
	var room_names := []
	for row in GRID:
		for rname in row:
			room_names.append(rname)
	var escaped := _sorted_escaped(room_names)
	var alt := "|".join(escaped)

	move_command_regex = RegEx.new()
	move_command_regex.compile("(?i)\\b(?:go|move|walk|head)\\b[^\\n]{0,20}?\\bto\\b[^\\n]{0,12}?\\b(" + alt + ")\\b")

	wait_command_regex = RegEx.new()
	wait_command_regex.compile("(?i)\\b(?:wait|stay)\\b[^\\n]{0,15}?\\bin\\b[^\\n]{0,12}?\\b(" + alt + ")\\b")


## Returns the canonical room name if `text` reads as a movement instruction,
## or "" if it doesn't (including anything with a "?" in it, which is treated
## as a real question - "Did you go to the kitchen?" should still be asked to
## the character rather than acted on).
func _parse_move_command(text: String) -> String:
	if text.find("?") != -1:
		return ""
	if move_command_regex == null or wait_command_regex == null:
		return ""
	var m := move_command_regex.search(text)
	if m == null:
		m = wait_command_regex.search(text)
	if m == null:
		return ""
	return String(room_name_lookup.get(m.get_string(1).to_lower(), ""))


## Builds the five regexes behind the Hall meetup's floor-control orders. Kept
## as separate intent patterns (silence / speak / leave / everyone / except)
## rather than one big pattern per command, so the parser can combine them -
## "everyone be quiet except Marcus" is the everyone pattern plus the silence
## pattern plus the except pattern, with no dedicated rule of its own.
func _build_group_command_regexes() -> void:
	group_silence_regex = RegEx.new()
	group_silence_regex.compile("(?i)\\b(?:be\\s+quiet|keep\\s+quiet|stay\\s+quiet|quiet\\s+down|say\\s+nothing|don't\\s+speak|do\\s+not\\s+speak|don't\\s+say|stop\\s+talking|hold\\s+your\\s+tongue|shut\\s+up|silence|silent)\\b")

	group_speak_regex = RegEx.new()
	group_speak_regex.compile("(?i)\\b(?:may\\s+speak|can\\s+speak|speak\\s+up|speak\\s+now|speak\\s+freely|go\\s+ahead|your\\s+turn|you\\s+may\\s+answer|answer\\s+me|say\\s+something|talk\\s+again|speak)\\b")

	# "Leave" also covers being sent home, since dismissal already walks a
	# suspect back to their own starting room - "go back to your room" and
	# "leave" want the same thing to happen.
	group_leave_regex = RegEx.new()
	group_leave_regex.compile("(?i)\\b(?:leave|get\\s+out|step\\s+out|you\\s+can\\s+go|you\\s+may\\s+go|you're\\s+dismissed|dismissed|clear\\s+off|wait\\s+outside|go\\s+home|(?:go\\s+|head\\s+)?back\\s+to\\s+(?:your|their|his|her)\\s+(?:own\\s+)?rooms?|return\\s+to\\s+(?:your|their|his|her)\\s+(?:own\\s+)?rooms?)\\b")

	group_everyone_regex = RegEx.new()
	group_everyone_regex.compile("(?i)\\b(?:everyone|everybody|all\\s+of\\s+you|the\\s+room|nobody|no\\s+one)\\b")

	group_except_regex = RegEx.new()
	group_except_regex.compile("(?i)\\b(?:except|apart\\s+from|other\\s+than|but)\\b\\s+(.+)$")


## Classifies a line typed into the meetup box. Returns {"kind": ..., "id": ...}
## where kind is one of:
##   "none"               ordinary line to the room - everyone un-muted answers
##   "address"            aimed at one named suspect - only they answer
##   "mute" / "unmute"    floor control for one suspect
##   "silence_all"        shut the whole room up
##   "silence_all_except" shut everyone up but one
##   "unmute_all"         let the room speak again
##   "dismiss"            send a suspect out of the Hall
func _parse_group_command(text: String) -> Dictionary:
	var none := {"kind": "none", "id": ""}
	if group_silence_regex == null:
		return none

	# A question is never an order, matching how _parse_move_command treats
	# "Did you go to the kitchen?" as something to ask rather than something to
	# do. Without this, "Marcus, why were you so quiet last night?" silences him
	# instead of asking him. Note this only suppresses ORDERS - a question
	# beginning with a name is still routed to that suspect below, since
	# "Marcus, where were you?" is the single most common thing you'll type.
	var is_order := text.find("?") == -1

	# Room-wide orders are checked first: "everyone be quiet except Marcus"
	# also starts with no suspect's name, so it would otherwise fall through to
	# the name-prefix branch and be treated as an ordinary question.
	if is_order and group_everyone_regex.search(text) != null:
		# Silence is tested before speech because the silence phrasings contain
		# the word "speak" ("don't speak", "do not speak") and would otherwise
		# be read as permission to talk.
		if group_silence_regex.search(text) != null:
			var ex := group_except_regex.search(text)
			if ex != null:
				var ex_id := _find_attendee_in(ex.get_string(1))
				if ex_id != "":
					return {"kind": "silence_all_except", "id": ex_id}
			return {"kind": "silence_all", "id": ""}
		# "Everyone, back to your rooms" - the one order you always need at the
		# end of a confrontation, and the only way to clear the Hall in one go.
		if group_leave_regex.search(text) != null:
			return {"kind": "dismiss_all", "id": ""}
		if group_speak_regex.search(text) != null:
			return {"kind": "unmute_all", "id": ""}

	# Everything else must be addressed to someone by name, at the START of the
	# line. "Marcus, where were you?" is aimed at Marcus; "Where were you,
	# Marcus?" is a question to the room that happens to mention him. Requiring
	# the leading position keeps that distinction predictable instead of having
	# any stray mention hijack the round.
	var lead := _leading_attendee(text)
	var id := String(lead["id"])
	if id == "":
		# No name at the front, but if the line mentions exactly one person in
		# the room it's still aimed at them - "what about you, Tom?" obviously
		# wants Tom, not a full round of everyone. Requiring the name to lead
		# was too strict and made ordinary phrasing silently address the room.
		# Two or more names stays room-wide, since "Marcus, is Tom lying?"
		# genuinely is ambiguous about who should answer.
		var named := _attendees_named_in(text)
		if named.size() == 1:
			return {"kind": "address", "id": String(named[0])}
		return none

	if is_order:
		var rest := text.substr(int(lead["end"])).strip_edges().lstrip(",:;-. \t")
		if group_leave_regex.search(rest) != null:
			return {"kind": "dismiss", "id": id}
		# "Marcus, go to the library" - the same movement command that works in
		# a private conversation, which previously did nothing in here and got
		# answered in character instead.
		var room := _parse_move_command(rest)
		if room != "" and room != MEETUP_ROOM:
			return {"kind": "move", "id": id, "room": room}
		if group_silence_regex.search(rest) != null:
			return {"kind": "mute", "id": id}
		if group_speak_regex.search(rest) != null:
			return {"kind": "unmute", "id": id}
	return {"kind": "address", "id": id}


## Every attendee mentioned anywhere in `text`, in seating order. Used to work
## out whether a line singles someone out.
func _attendees_named_in(text: String) -> Array:
	var out := []
	for id in GameManager.group_chat.attendees:
		if not name_regexes.has(id):
			continue
		if name_regexes[id].search(text) != null:
			out.append(id)
	return out


## The attendee whose name appears earliest in `text`, or "" if none do.
func _find_attendee_in(text: String) -> String:
	var best := ""
	var best_pos := -1
	for id in GameManager.group_chat.attendees:
		if not name_regexes.has(id):
			continue
		var m: RegExMatch = name_regexes[id].search(text)
		if m == null:
			continue
		if best_pos == -1 or m.get_start() < best_pos:
			best_pos = m.get_start()
			best = id
	return best


## The attendee named at the very start of `text`, as {"id", "end"} where end
## is the character offset just past their name. Longest match wins, so
## "Marcus Sterling, ..." consumes the surname too instead of leaving it in
## the remainder and confusing the intent match.
func _leading_attendee(text: String) -> Dictionary:
	var best_id := ""
	var best_end := 0
	for id in GameManager.group_chat.attendees:
		if not name_regexes.has(id):
			continue
		var m: RegExMatch = name_regexes[id].search(text)
		if m == null or m.get_start() != 0:
			continue
		if m.get_end() > best_end:
			best_end = m.get_end()
			best_id = id
	return {"id": best_id, "end": best_end}


## Shortest path (in room names, excluding `from_room`) between two rooms
## over the 3x3 GRID, treating every orthogonally adjacent pair of rooms as
## connected (every internal wall in the mansion has a doorway gap - see
## _build_wall_side). Returns [] if there's no path or from == to.
func _room_bfs_path(from_room: String, to_room: String) -> Array:
	if from_room == to_room:
		return []
	if not grid_pos.has(from_room) or not grid_pos.has(to_room):
		return []
	var start: Vector2i = grid_pos[from_room]
	var goal: Vector2i = grid_pos[to_room]

	var visited := {start: true}
	var prev := {}
	var queue := [start]
	var found := start == goal

	while not queue.is_empty() and not found:
		var cur: Vector2i = queue.pop_front()
		for d in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var nxt: Vector2i = cur + d
			if nxt.x < 0 or nxt.x >= GRID.size() or nxt.y < 0 or nxt.y >= GRID[0].size():
				continue
			if visited.has(nxt):
				continue
			visited[nxt] = true
			prev[nxt] = cur
			if nxt == goal:
				found = true
				break
			queue.append(nxt)

	if not found:
		return []

	var name_by_pos := {}
	for rname in grid_pos.keys():
		name_by_pos[grid_pos[rname]] = rname

	var rev_path := [goal]
	var cur2: Vector2i = goal
	while cur2 != start:
		cur2 = prev[cur2]
		rev_path.append(cur2)
	rev_path.reverse()

	var out := []
	for i in range(1, rev_path.size()):
		out.append(name_by_pos[rev_path[i]])
	return out


## Turns a room-name path into world-space waypoints: the doorway crossing
## (midpoint between the two room centers - always lines up with the
## doorway gap since it's centered on that shared wall) followed by the
## room's own center, for every room passed through on the way to `to_room`.
func get_room_travel_waypoints(from_room: String, to_room: String) -> Array:
	var path := _room_bfs_path(from_room, to_room)
	if path.is_empty():
		return []
	var waypoints := []
	var prev_center: Vector3 = room_centers.get(from_room, Vector3.ZERO)
	for rname in path:
		var center: Vector3 = room_centers[rname]
		var doorway := (prev_center + center) / 2.0
		doorway.y = 0.0
		waypoints.append(doorway)
		waypoints.append(center)
		prev_center = center
	return waypoints


# ------------------------------------------------------------- hall meetup --
# Suspects are gathered for a group confrontation one at a time, by telling
# each of them "go to the hall" during a normal one-on-one conversation.
# MAX_HALL_ATTENDEES caps how many will agree to crowd in there.

## How many suspects currently count against the Hall's capacity. Deliberately
## counts NPCs still walking there as well as those already standing in it -
## begin_travel() sets current_room to the destination immediately, so an NPC
## sent to the Hall occupies a slot from the moment they're ordered. Without
## this you could order six suspects to the Hall in a row (each one passing the
## capacity check while the previous ones are still in the corridors) and end
## up with all six arriving.
func hall_occupancy() -> int:
	var count := 0
	for id in npc_nodes.keys():
		var npc = npc_nodes[id]
		if is_instance_valid(npc) and npc.current_room == MEETUP_ROOM:
			count += 1
	return count


## The suspects actually standing in the Hall right now - arrived, not still
## en route. This is the guest list for a group confrontation, so it excludes
## anyone still walking (state == "moving"); hall_occupancy() is the one that
## counts those. Returned in stable CHARACTERS order rather than spawn or
## arrival order, matching active_characters().
func hall_attendees() -> Array:
	var out := []
	for c in GameManager.active_characters():
		var id: String = c["id"]
		if not npc_nodes.has(id):
			continue
		var npc = npc_nodes[id]
		if is_instance_valid(npc) and npc.current_room == MEETUP_ROOM and npc.state != "moving":
			out.append(id)
	return out


## Which room a world-space point sits in, by nearest room center. The 3x3
## grid is evenly spaced and every room is the same size, so nearest-center is
## exactly equivalent to a cell lookup here, without duplicating the PITCH/CELL
## arithmetic that _build_mansion() already owns.
func _room_at(pos: Vector3) -> String:
	var best := ""
	var best_d := INF
	for rname in room_centers.keys():
		var c: Vector3 = room_centers[rname]
		var d := Vector2(pos.x - c.x, pos.z - c.z).length_squared()
		if d < best_d:
			best_d = d
			best = rname
	return best


## True when the interact key should open a group confrontation rather than a
## private interview: the detective is standing in the Hall and at least two
## suspects have actually arrived there. This is the "I must be there to engage
## the conversation" rule - a meetup cannot be opened, and therefore cannot
## produce a single line of dialogue, from anywhere else in the mansion.
func can_open_group_scene() -> bool:
	if not is_instance_valid(player):
		return false
	if _room_at(player.global_position) != MEETUP_ROOM:
		return false
	return hall_attendees().size() >= 2


## Sends an NPC walking toward `room_name`. Returns a status string Main uses
## to write a short acknowledgement into the dialogue log: "moving",
## "already_there", "already_heading", "hall_full" (the meetup room has hit
## MAX_HALL_ATTENDEES), or "invalid" (unknown character/room).
func command_npc_move(character_id: String, room_name: String) -> String:
	if not npc_nodes.has(character_id) or not room_centers.has(room_name):
		return "invalid"
	var npc = npc_nodes[character_id]
	if npc.current_room == room_name:
		return "already_heading" if npc.state == "moving" else "already_there"
	# Checked after the already-there cases above, so an NPC who is themselves
	# in the Hall is never blocked by their own occupancy slot.
	if room_name == MEETUP_ROOM and hall_occupancy() >= MAX_HALL_ATTENDEES:
		return "hall_full"
	var waypoints := get_room_travel_waypoints(npc.current_room, room_name)
	if waypoints.is_empty():
		return "invalid"
	npc.begin_travel(waypoints, room_name)
	return "moving"


## Handles a movement instruction typed into the dialogue box instead of
## sending it to GameManager/Ollama - logs the player's line plus a short
## acknowledgement, and actually moves the NPC in the 3D world.
func _handle_move_command(character_id: String, room_name: String, original_text: String) -> void:
	var c := GameManager.get_character(character_id)
	var short := String(c.get("short", "They"))
	var status := command_npc_move(character_id, room_name)
	var ack := ""
	match status:
		"moving":
			ack = "%s heads off toward the %s." % [short, room_name]
		"already_there":
			ack = "%s is already in the %s." % [short, room_name]
		"already_heading":
			ack = "%s is already on the way to the %s." % [short, room_name]
		"hall_full":
			ack = "%s glances toward the hall. \"There's a crowd in there already - I'll wait my turn.\"" % short
		_:
			ack = "%s doesn't seem able to get there." % short
	dialogue_log.append_text("[b]You:[/b] %s\n" % _colorize_names(original_text))
	dialogue_log.append_text("[i]%s[/i]\n\n" % ack)


func _spawn_player() -> void:
	# Build the whole node hierarchy (collision shape, camera, interact ray)
	# BEFORE the player enters the scene tree. Player.gd resolves $Camera3D
	# and $Camera3D/InteractRay via @onready as soon as it enters the tree,
	# so those children must already exist by the time add_child(player)
	# below runs - otherwise they resolve to null.
	player = CharacterBody3D.new()
	player.name = "Player"
	player.set_script(load("res://Scripts/Player.gd"))

	var hall_center: Vector3 = room_centers.get("Hall", Vector3.ZERO)
	player.position = Vector3(hall_center.x, 0.05, hall_center.z - 2.0)

	var coll := CollisionShape3D.new()
	var cshape := CapsuleShape3D.new()
	cshape.height = 1.8
	cshape.radius = 0.4
	coll.shape = cshape
	coll.position.y = 0.9
	player.add_child(coll)

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position.y = 1.6
	cam.current = true
	player.add_child(cam)

	var ray := RayCast3D.new()
	ray.name = "InteractRay"
	ray.target_position = Vector3(0, 0, -3.5)
	ray.enabled = true
	cam.add_child(ray)

	add_child(player)


# --------------------------------------------------------------------- UI --

func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)

	crosshair = ColorRect.new()
	crosshair.color = Color(1, 1, 1, 0.85)
	crosshair.size = Vector2(4, 4)
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.position = Vector2(-2, -2)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(crosshair)

	prompt_label = Label.new()
	prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt_label.position = Vector2(-220, -80)
	prompt_label.size = Vector2(440, 30)
	prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt_label.add_theme_color_override("font_color", Color(1, 1, 1))
	prompt_label.add_theme_font_size_override("font_size", 20)
	prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt_label.visible = false
	ui_layer.add_child(prompt_label)

	var help := Label.new()
	help.text = "WASD move | Space jump | Mouse look | Click or E to interact | Tab case notes | F1 debug | F2 prompt dump | Esc release mouse"
	help.set_anchors_preset(Control.PRESET_TOP_LEFT)
	help.position = Vector2(16, 16)
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(help)

	debug_label = Label.new()
	debug_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	debug_label.position = Vector2(-360, 16)
	debug_label.size = Vector2(344, 80)
	debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	debug_label.add_theme_font_size_override("font_size", 14)
	debug_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debug_label.visible = false
	_refresh_debug_label()
	ui_layer.add_child(debug_label)

	_build_dialogue_panel()
	_build_group_panel()
	_build_accusation_panel()
	_build_notes_panel()
	_build_win_panel()


func _build_dialogue_panel() -> void:
	dialogue_panel = Panel.new()
	dialogue_panel.set_anchors_preset(Control.PRESET_CENTER)
	dialogue_panel.size = Vector2(560, 420)
	dialogue_panel.position = Vector2(-280, -210)
	dialogue_panel.visible = false
	ui_layer.add_child(dialogue_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 16
	vbox.offset_right = -16
	vbox.offset_bottom = -16
	vbox.add_theme_constant_override("separation", 8)
	dialogue_panel.add_child(vbox)

	dialogue_name_label = Label.new()
	dialogue_name_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(dialogue_name_label)

	dialogue_log = RichTextLabel.new()
	dialogue_log.custom_minimum_size = Vector2(0, 260)
	dialogue_log.bbcode_enabled = true
	dialogue_log.scroll_following = true
	vbox.add_child(dialogue_log)

	dialogue_status_label = Label.new()
	dialogue_status_label.text = ""
	dialogue_status_label.add_theme_color_override("font_color", Color(1, 0.8, 0.3))
	vbox.add_child(dialogue_status_label)

	var hbox := HBoxContainer.new()
	vbox.add_child(hbox)

	dialogue_input = LineEdit.new()
	dialogue_input.placeholder_text = "Type your question..."
	dialogue_input.custom_minimum_size = Vector2(420, 0)
	dialogue_input.text_submitted.connect(func(_t): _send_question())
	hbox.add_child(dialogue_input)

	dialogue_ask_button = Button.new()
	dialogue_ask_button.text = "Ask"
	dialogue_ask_button.pressed.connect(_send_question)
	hbox.add_child(dialogue_ask_button)

	var close_btn := Button.new()
	close_btn.text = "Close (Esc)"
	close_btn.pressed.connect(close_dialogue)
	vbox.add_child(close_btn)


## The Hall meetup panel. Deliberately wider than the one-on-one panel: group
## lines are short but there are several per round, and each is prefixed with
## a speaker name, so the log needs the extra room to stay readable.
func _build_group_panel() -> void:
	group_panel = Panel.new()
	group_panel.set_anchors_preset(Control.PRESET_CENTER)
	group_panel.size = Vector2(720, 480)
	group_panel.position = Vector2(-360, -240)
	group_panel.visible = false
	ui_layer.add_child(group_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 16
	vbox.offset_right = -16
	vbox.offset_bottom = -16
	vbox.add_theme_constant_override("separation", 8)
	group_panel.add_child(vbox)

	var title := Label.new()
	title.text = "The Hall"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	# One name chip per attendee, in that suspect's own body color, so the log
	# below reads against a visible cast list.
	group_roster = HBoxContainer.new()
	group_roster.add_theme_constant_override("separation", 14)
	vbox.add_child(group_roster)

	group_log = RichTextLabel.new()
	group_log.custom_minimum_size = Vector2(0, 290)
	group_log.bbcode_enabled = true
	group_log.scroll_following = true
	vbox.add_child(group_log)

	group_status_label = Label.new()
	group_status_label.text = ""
	group_status_label.add_theme_color_override("font_color", Color(1, 0.8, 0.3))
	vbox.add_child(group_status_label)

	var hbox := HBoxContainer.new()
	vbox.add_child(hbox)

	group_input = LineEdit.new()
	group_input.placeholder_text = "Say something to the room..."
	group_input.custom_minimum_size = Vector2(580, 0)
	group_input.text_submitted.connect(func(_t): _send_group_line())
	hbox.add_child(group_input)

	group_say_button = Button.new()
	group_say_button.text = "Say"
	group_say_button.pressed.connect(_send_group_line)
	hbox.add_child(group_say_button)

	var group_close_btn := Button.new()
	group_close_btn.text = "Leave the room (Esc)"
	group_close_btn.pressed.connect(close_group_dialogue)
	vbox.add_child(group_close_btn)


func _build_accusation_panel() -> void:
	accusation_panel = Panel.new()
	accusation_panel.set_anchors_preset(Control.PRESET_CENTER)
	accusation_panel.size = Vector2(480, 480)
	accusation_panel.position = Vector2(-240, -240)
	accusation_panel.visible = false
	ui_layer.add_child(accusation_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 16
	vbox.offset_right = -16
	vbox.offset_bottom = -16
	vbox.add_theme_constant_override("separation", 10)
	accusation_panel.add_child(vbox)

	var title := Label.new()
	title.text = "Who is the murderer?"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Select a suspect below and make your final accusation."
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(subtitle)

	# One button per suspect actually in this game (matches the Case Notes
	# tabs), colored to match their body color in the mansion. Clicking one
	# selects it (highlighted, like the notes tabs) rather than typing a name.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 240)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var list_vbox := VBoxContainer.new()
	list_vbox.add_theme_constant_override("separation", 4)
	list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list_vbox)

	accusation_suspect_buttons.clear()
	for c in GameManager.active_characters():
		var id: String = c["id"]
		var color: Color = NPC_COLORS.get(id, Color.WHITE)
		var btn := Button.new()
		btn.text = String(c["name"])
		btn.custom_minimum_size = Vector2(0, 36)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 16)
		btn.add_theme_color_override("font_color", color)
		btn.add_theme_color_override("font_hover_color", color)
		btn.add_theme_color_override("font_pressed_color", color)
		btn.pressed.connect(_select_accusation_suspect.bind(id))
		list_vbox.add_child(btn)
		accusation_suspect_buttons[id] = btn

	var hbox := HBoxContainer.new()
	vbox.add_child(hbox)

	accusation_accuse_button = Button.new()
	accusation_accuse_button.text = "Accuse"
	accusation_accuse_button.disabled = true
	accusation_accuse_button.pressed.connect(_submit_accusation)
	hbox.add_child(accusation_accuse_button)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel (Esc)"
	cancel_btn.pressed.connect(close_accusation)
	hbox.add_child(cancel_btn)

	accusation_result_label = Label.new()
	accusation_result_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
	accusation_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(accusation_result_label)


## Highlights the clicked suspect button (matching the Case Notes tab style)
## and enables the Accuse button once something is selected.
func _select_accusation_suspect(id: String) -> void:
	accusation_selected_id = id
	accusation_accuse_button.disabled = false
	for bid in accusation_suspect_buttons.keys():
		var btn: Button = accusation_suspect_buttons[bid]
		if bid == id:
			btn.add_theme_stylebox_override("normal", _selected_tab_stylebox())
			btn.add_theme_stylebox_override("hover", _selected_tab_stylebox())
		else:
			btn.remove_theme_stylebox_override("normal")
			btn.remove_theme_stylebox_override("hover")


func _build_notes_panel() -> void:
	notes_panel = Panel.new()
	notes_panel.set_anchors_preset(Control.PRESET_CENTER)

	# Twice the original size (760x520 -> 1520x1040), but clamped so it can
	# never overflow off-screen on a smaller monitor/window.
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var max_size: Vector2 = vp_size - Vector2(40, 40)
	var panel_size := Vector2(min(1520.0, max_size.x), min(1040.0, max_size.y))
	notes_panel.size = panel_size
	notes_panel.position = -panel_size / 2.0
	notes_panel.visible = false
	ui_layer.add_child(notes_panel)

	var outer_vbox := VBoxContainer.new()
	outer_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	outer_vbox.offset_left = 16
	outer_vbox.offset_top = 16
	outer_vbox.offset_right = -16
	outer_vbox.offset_bottom = -16
	outer_vbox.add_theme_constant_override("separation", 10)
	notes_panel.add_child(outer_vbox)

	var title := Label.new()
	title.text = "Case Notes"
	title.add_theme_font_size_override("font_size", 24)
	outer_vbox.add_child(title)

	var hbox := HBoxContainer.new()
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 14)
	outer_vbox.add_child(hbox)

	# Left column: one tab per suspect, colored to match their body color in
	# the mansion, dimmed if you haven't talked to them yet, with a small
	# red dot if their Slipups section has real content worth checking.
	var tabs_vbox := VBoxContainer.new()
	tabs_vbox.custom_minimum_size = Vector2(190, 0)
	tabs_vbox.add_theme_constant_override("separation", 6)
	hbox.add_child(tabs_vbox)

	notes_tab_buttons.clear()
	notes_flag_dots.clear()
	for c in GameManager.active_characters():
		var id: String = c["id"]
		var color: Color = NPC_COLORS.get(id, Color.WHITE)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		tabs_vbox.add_child(row)

		var btn := Button.new()
		btn.text = String(c["short"])
		btn.custom_minimum_size = Vector2(160, 36)
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 16)
		btn.add_theme_color_override("font_color", color)
		btn.add_theme_color_override("font_hover_color", color)
		btn.add_theme_color_override("font_pressed_color", color)
		btn.pressed.connect(func(): _select_notes_character(id))
		row.add_child(btn)

		var dot := ColorRect.new()
		dot.color = Color(1, 0.25, 0.25)
		dot.custom_minimum_size = Vector2(10, 10)
		dot.size = Vector2(10, 10)
		dot.visible = false
		row.add_child(dot)

		notes_tab_buttons[id] = btn
		notes_flag_dots[id] = dot

	# Right pane: the selected suspect's Timeline / Motive / Slipups.
	notes_log = RichTextLabel.new()
	notes_log.bbcode_enabled = true
	notes_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notes_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	notes_log.add_theme_font_size_override("normal_font_size", 18)
	hbox.add_child(notes_log)

	var close_btn := Button.new()
	close_btn.text = "Close (Tab)"
	close_btn.pressed.connect(toggle_notes)
	outer_vbox.add_child(close_btn)


func _build_win_panel() -> void:
	win_panel = Panel.new()
	win_panel.set_anchors_preset(Control.PRESET_CENTER)
	win_panel.size = Vector2(480, 240)
	win_panel.position = Vector2(-240, -120)
	win_panel.visible = false
	ui_layer.add_child(win_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_top = 16
	vbox.offset_right = -16
	vbox.offset_bottom = -16
	win_panel.add_child(vbox)

	win_label = Label.new()
	win_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	win_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(win_label)

	var restart_btn := Button.new()
	restart_btn.text = "Play Again (new random murderer)"
	restart_btn.pressed.connect(func(): get_tree().reload_current_scene())
	vbox.add_child(restart_btn)


# --------------------------------------------------------- name coloring --
# Wherever conversation or notes text mentions a suspect by name, that name
# gets colored to match their body color in the mansion (e.g. if Victoria
# mentions Marcus, "Marcus" shows up in his red). The murder victim, Lord
# Reginald Archibald, isn't a suspect (he has no body/color in the mansion),
# so his name gets bold+underlined instead.

# Common titles/honorifics the model might place directly in front of a
# name ("Lady Victoria", "Mr. Sterling", "Dr. Blackwood", ...). Included as
# an OPTIONAL prefix on every pattern so the whole phrase gets styled
# together instead of just the bare name.
const HONORIFIC_GROUP := "(?:Lord|Lady|Mr|Mrs|Ms|Miss|Dr|Sir)\\.?\\s+"

var victim_regex: RegEx = null


## All the distinct ways this suspect might reasonably be referred to:
## surname, formal first name, nickname/short name, and "first + surname" /
## "nickname + surname" combos. Using an explicit first_name field (rather
## than trying to parse it out of the display name) is what makes sure a
## formal first name like "Samuel" is caught even though his short name is
## the nickname "Sam".
func _name_variants(c: Dictionary) -> Array:
	var full := String(c["name"]).replace('"', "")
	while full.find("  ") != -1: # collapse double spaces left by removing a quoted nickname
		full = full.replace("  ", " ")
	var parts := full.split(" ")
	var surname := String(parts[parts.size() - 1]) if parts.size() > 0 else ""
	var first_name := String(c.get("first_name", c["short"]))
	var short := String(c["short"])

	var candidates := [full, first_name, short, surname]
	if surname != "":
		candidates.append("%s %s" % [first_name, surname])
		candidates.append("%s %s" % [short, surname])

	var seen := {}
	var out := []
	for cand in candidates:
		var key := String(cand).strip_edges()
		if key == "":
			continue
		var lk := key.to_lower()
		if seen.has(lk):
			continue
		seen[lk] = true
		out.append(key)
	return out


func _regex_escape(s: String) -> String:
	var special := ["\\", ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|"]
	var out := s
	for ch in special:
		out = out.replace(ch, "\\" + ch)
	return out


func _sorted_escaped(variants: Array) -> PackedStringArray:
	var sorted_variants := variants.duplicate()
	# Longest first, so e.g. "Marcus Sterling" is preferred over lone
	# "Marcus" when both could match at the same position.
	sorted_variants.sort_custom(func(a, b): return String(a).length() > String(b).length())
	var escaped := PackedStringArray()
	for v in sorted_variants:
		escaped.append(_regex_escape(String(v)))
	return escaped


## Builds one compiled regex per suspect matching all of their unambiguous
## name variants (full name, first name, nickname, surname, combos). A
## variant shared by more than one suspect (e.g. "Cross" belongs to both
## Natalie and Eugene) is dropped for everyone rather than guessing the
## wrong color.
func _build_name_regexes() -> void:
	var variant_owner: Dictionary = {} # lowercase variant -> character_id, or "AMBIGUOUS"
	var variants_by_char: Dictionary = {} # character_id -> Array[String]

	for c in GameManager.active_characters():
		var id: String = c["id"]
		var variants: Array = _name_variants(c)
		variants_by_char[id] = variants
		for v in variants:
			var key: String = v.to_lower()
			if variant_owner.has(key) and variant_owner[key] != id:
				variant_owner[key] = "AMBIGUOUS"
			elif not variant_owner.has(key):
				variant_owner[key] = id

	name_regexes.clear()
	for c in GameManager.active_characters():
		var id: String = c["id"]
		var valid_variants: Array = []
		for v in variants_by_char[id]:
			if variant_owner.get(String(v).to_lower(), "") == id:
				valid_variants.append(v)
		if valid_variants.is_empty():
			continue

		var escaped := _sorted_escaped(valid_variants)
		var pattern := "(?i)\\b(?:" + HONORIFIC_GROUP + ")?(?:" + "|".join(escaped) + ")\\b"

		var re := RegEx.new()
		if re.compile(pattern) == OK:
			name_regexes[id] = re

	_build_victim_regex()


## The victim isn't a suspect, but comes up constantly in questions/answers.
## Matches "Lord Reginald Archibald" and shorter forms of it.
func _build_victim_regex() -> void:
	var raw := String(GameManager.VICTIM_NAME) # "Lord Reginald Archibald"
	var parts := raw.split(" ")
	var candidates := [raw]
	if parts.size() >= 3:
		candidates.append("%s %s" % [parts[1], parts[2]]) # "Reginald Archibald"
		candidates.append("%s %s" % [parts[0], parts[2]]) # "Lord Archibald"
		candidates.append(String(parts[1])) # "Reginald"
		candidates.append(String(parts[2])) # "Archibald"
	elif parts.size() > 0:
		candidates.append(String(parts[parts.size() - 1]))

	var seen := {}
	var unique_candidates := []
	for cand in candidates:
		var lk := String(cand).to_lower()
		if seen.has(lk):
			continue
		seen[lk] = true
		unique_candidates.append(String(cand))

	var escaped := _sorted_escaped(unique_candidates)
	var pattern := "(?i)\\b(?:" + HONORIFIC_GROUP + ")?(?:" + "|".join(escaped) + ")\\b"

	victim_regex = RegEx.new()
	if victim_regex.compile(pattern) != OK:
		victim_regex = null


## Wraps every mention of the victim in bold+underline, and every mention of
## a known suspect's name in `text` with a [color=#hex] tag matching that
## suspect's body color.
func _colorize_names(text: String) -> String:
	var result := text
	if victim_regex != null:
		result = victim_regex.sub(result, "[b][u]$0[/u][/b]", true)
	for id in name_regexes.keys():
		var re: RegEx = name_regexes[id]
		var color: Color = NPC_COLORS.get(id, Color.WHITE)
		result = re.sub(result, "[color=#%s]$0[/color]" % color.to_html(false), true)
	return result


# ----------------------------------------------------------- UI behaviour --

func show_prompt(text: String) -> void:
	prompt_label.text = text
	prompt_label.visible = true


func hide_prompt() -> void:
	prompt_label.visible = false


func open_dialogue(character_id: String) -> void:
	if win_panel.visible:
		return
	# Taking one suspect aside ends the confrontation - the others go back to
	# wandering rather than standing frozen in the hall unattended.
	if group_panel != null and group_panel.visible:
		close_group_dialogue()
	# If some other suspect was somehow still held, release them first.
	_set_npc_talking(current_dialogue_character, false)
	current_dialogue_character = character_id
	# Freeze this NPC in place (facing the player) for the conversation.
	_set_npc_talking(character_id, true)
	var c := GameManager.get_character(character_id)
	dialogue_name_label.text = String(c.get("name", ""))
	dialogue_name_label.add_theme_color_override("font_color", NPC_COLORS.get(character_id, Color.WHITE))
	dialogue_log.clear()
	for entry in GameManager.transcript:
		if entry["character_id"] == character_id:
			_append_transcript_entry(entry)
	dialogue_status_label.text = ""
	dialogue_input.editable = true
	dialogue_ask_button.disabled = false
	dialogue_panel.visible = true
	player.set_mouse_captured(false)
	dialogue_input.grab_focus()


func close_dialogue() -> void:
	dialogue_panel.visible = false
	# Let the suspect get back to wandering / finish any walk they were on.
	_set_npc_talking(current_dialogue_character, false)
	current_dialogue_character = ""
	player.set_mouse_captured(true)


## Holds an NPC still while the player is talking to them, or releases them.
## Safe to call with an empty/unknown id.
func _set_npc_talking(character_id: String, talking: bool) -> void:
	if character_id == "" or not npc_nodes.has(character_id):
		return
	var npc = npc_nodes[character_id]
	if not is_instance_valid(npc):
		return
	if talking and is_instance_valid(player):
		npc.set_talking(true, player.global_position)
	else:
		npc.set_talking(talking)


# ---------------------------------------------------------- hall meetup UI --

## Opens a group confrontation with everyone standing in the Hall. Falls back
## to a normal one-on-one if there's only one suspect in there.
func open_group_dialogue() -> void:
	if win_panel.visible:
		return
	var ids := hall_attendees()
	if ids.size() < 2:
		if ids.size() == 1:
			open_dialogue(String(ids[0]))
		return

	close_dialogue()
	_set_group_frozen(ids, true)

	group_log.clear()
	group_status_label.text = ""
	group_input.editable = true
	group_say_button.disabled = false
	group_panel.visible = true
	player.set_mouse_captured(false)
	group_input.grab_focus()

	# Started before the roster is drawn so the guest list and mute state the
	# buttons read from are the session's, not the previous scene's leftovers.
	GameManager.group_chat.start(ids)
	_rebuild_group_roster(ids)


func close_group_dialogue() -> void:
	GameManager.group_chat.stop()
	group_panel.visible = false
	_set_group_frozen(group_frozen_ids, false)
	if is_instance_valid(player):
		player.set_mouse_captured(true)


## Holds every attendee still (facing the detective) for the duration of the
## scene, or releases them. Tracks who was frozen so the release can't miss
## someone who has since left the Hall.
func _set_group_frozen(ids: Array, frozen: bool) -> void:
	if frozen:
		group_frozen_ids = ids.duplicate()
	for id in ids:
		if not npc_nodes.has(id):
			continue
		var npc = npc_nodes[id]
		if not is_instance_valid(npc):
			continue
		if frozen and is_instance_valid(player):
			npc.set_group_scene(true, player.global_position)
		else:
			npc.set_group_scene(false)
	if not frozen:
		group_frozen_ids.clear()


## One chip per attendee: their name in their own body color, plus a button
## that silences or restores them. The button and the typed order ("Marcus, be
## quiet") call exactly the same engine method, so the two can never disagree.
func _rebuild_group_roster(ids: Array) -> void:
	for child in group_roster.get_children():
		group_roster.remove_child(child)
		child.queue_free()

	var gc = GameManager.group_chat
	for id in ids:
		var c := GameManager.get_character(id)
		var silent: bool = gc.is_muted(id)

		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)
		group_roster.add_child(col)

		var chip := Label.new()
		chip.text = String(c.get("short", ""))
		chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		chip.add_theme_font_size_override("font_size", 16)
		var name_col: Color = NPC_COLORS.get(id, Color.WHITE)
		if silent:
			name_col = name_col.darkened(0.45)
		chip.add_theme_color_override("font_color", name_col)
		col.add_child(chip)

		var btn := Button.new()
		btn.text = "Let speak" if silent else "Silence"
		btn.custom_minimum_size = Vector2(104, 0)
		btn.add_theme_font_size_override("font_size", 12)
		btn.pressed.connect(_toggle_attendee_muted.bind(id))
		col.add_child(btn)

		# Take one suspect aside. Without this the Hall is a trap: pressing E on
		# anyone standing in it always opens the group panel, so once two
		# suspects are gathered there's otherwise no route to a private
		# conversation with either of them.
		var alone_btn := Button.new()
		alone_btn.text = "Speak alone"
		alone_btn.custom_minimum_size = Vector2(104, 0)
		alone_btn.add_theme_font_size_override("font_size", 12)
		alone_btn.pressed.connect(open_dialogue.bind(id))
		col.add_child(alone_btn)

		var send_btn := Button.new()
		send_btn.text = "Send home"
		send_btn.custom_minimum_size = Vector2(104, 0)
		send_btn.add_theme_font_size_override("font_size", 12)
		send_btn.pressed.connect(_dismiss_attendee.bind(id))
		col.add_child(send_btn)


## Roster button handler. Un-silencing from the button only clears the mute -
## it doesn't hand them the floor, because unlike typing "Marcus, go ahead"
## there's no accompanying line from the detective for them to answer.
func _toggle_attendee_muted(id: String) -> void:
	var gc = GameManager.group_chat
	gc.set_muted(id, not gc.is_muted(id))


func _on_group_roster_changed() -> void:
	if group_panel == null or not group_panel.visible:
		return
	_rebuild_group_roster(GameManager.group_chat.attendees)


## Everyone left the hall, or all but one did. With nobody left there's nothing
## to talk to, so the panel closes. With one left the panel keeps working -
## it's just a private conversation held in a wider window now, and closing it
## out from under a half-finished exchange would be more disruptive than
## leaving it open.
func _on_group_quorum_lost(remaining: int) -> void:
	if group_panel == null or not group_panel.visible:
		return
	if remaining <= 0:
		close_group_dialogue()


## Releases a suspect from the confrontation's freeze and walks them to
## `room_name` - or to their own starting room if none is given.
func _walk_attendee_out(id: String, room_name: String = "") -> void:
	group_frozen_ids.erase(id)
	if npc_nodes.has(id) and is_instance_valid(npc_nodes[id]):
		npc_nodes[id].set_group_scene(false)
	var dest := room_name
	if dest == "":
		dest = String(GameManager.get_character(id).get("room", ""))
	if dest != "" and dest != MEETUP_ROOM:
		command_npc_move(id, dest)


## Sends one suspect back to their own room and drops them from the scene.
func _dismiss_attendee(id: String) -> void:
	if not GameManager.group_chat.dismiss(id):
		return
	_walk_attendee_out(id)


## Drops one suspect from the scene and sends them to a room you named.
func _move_attendee_out(id: String, room_name: String) -> void:
	if not GameManager.group_chat.dismiss(id):
		return
	_walk_attendee_out(id, room_name)


## Clears the whole Hall. Without this the only way out was dismissing each
## suspect by name, and any you forgot stayed in the Hall occupying the
## 4-person cap with no way to reach them one-on-one.
func _dismiss_all_attendees() -> void:
	for id in GameManager.group_chat.dismiss_all():
		_walk_attendee_out(String(id))


func _send_group_line() -> void:
	if group_panel == null or not group_panel.visible:
		return
	var text := group_input.text.strip_edges()
	if text == "":
		return
	var gc = GameManager.group_chat
	# Orders and questions alike are refused mid-round; the input box is
	# already disabled then, but Enter can still fire through it.
	if gc.state != "awaiting_player":
		return
	group_input.text = ""

	var cmd := _parse_group_command(text)
	var kind := String(cmd["kind"])
	var id := String(cmd["id"])

	match kind:
		"silence_all":
			gc.log_player_command(text)
			gc.silence_all()
		"silence_all_except":
			gc.log_player_command(text)
			gc.silence_all(id)
		"unmute_all":
			gc.log_player_command(text)
			gc.allow_all()
		"mute":
			gc.log_player_command(text)
			gc.set_muted(id, true)
		"dismiss":
			gc.log_player_command(text)
			_dismiss_attendee(id)
		"dismiss_all":
			gc.log_player_command(text)
			_dismiss_all_attendees()
		"move":
			gc.log_player_command(text)
			_move_attendee_out(id, String(cmd.get("room", "")))
		"unmute":
			# Restoring someone by name also gives them the floor - "Marcus, go
			# ahead" plainly expects Marcus to say something, not just to
			# rejoin the rotation for next time. Announce is suppressed since
			# his answer follows immediately.
			gc.set_muted(id, false, false)
			gc.submit_player_line(text, id)
		"address":
			gc.submit_player_line(text, id)
		_:
			gc.submit_player_line(text)


## The four handlers below all null-check group_panel because GroupChat lives on
## the GameManager autoload and outlives the scene: a "Play Again" reload
## reconnects these signals in _ready(), well before _build_ui() has created the
## panel, and start_new_game() can emit state_changed in that window.
func _on_group_line_added(entry: Dictionary) -> void:
	if group_panel == null or not group_panel.visible:
		return
	var speaker_id := String(entry["speaker_id"])
	var text := _colorize_names(String(entry["text"]))
	var kind := String(entry["kind"])
	if kind == "stage":
		group_log.append_text("[i]%s[/i]\n\n" % text)
	elif kind == "command":
		# An order to the room, not a line of dialogue - dimmed so it reads as
		# something you did rather than something you said.
		group_log.append_text("[b]You:[/b] [i][color=#9aa0a6]%s[/color][/i]\n" % text)
	elif speaker_id == "":
		group_log.append_text("[b]You:[/b] %s\n\n" % text)
	else:
		var c := GameManager.get_character(speaker_id)
		var col: Color = NPC_COLORS.get(speaker_id, Color(1, 0.82, 0.5))
		group_log.append_text("[b][color=#%s]%s:[/color][/b] %s\n\n" % [col.to_html(false), String(c.get("short", "")), text])


func _on_group_turn_started(character_id: String) -> void:
	if group_panel == null or not group_panel.visible:
		return
	var c := GameManager.get_character(character_id)
	group_status_label.text = "%s is thinking..." % String(c.get("short", ""))


## The engine only accepts a new line while it's "awaiting_player", so the
## input box mirrors that exactly - no way to queue a second question on top of
## a round that's still resolving.
func _on_group_state_changed(new_state: String) -> void:
	if group_panel == null or not group_panel.visible:
		return
	var ready_for_input := new_state == "awaiting_player"
	group_input.editable = ready_for_input
	group_say_button.disabled = not ready_for_input
	if ready_for_input:
		group_status_label.text = ""
		group_input.grab_focus()


func _on_group_round_failed(message: String) -> void:
	if group_panel == null or not group_panel.visible:
		return
	group_status_label.text = "Error: " + message


## Writes one recorded exchange into the open one-on-one log. Lines this
## suspect gave during a Hall meetup are replayed here too - it's one
## continuous record for them - but marked, since the question above them was
## put to the whole room rather than to them privately.
func _append_transcript_entry(entry: Dictionary) -> void:
	var c := GameManager.get_character(entry["character_id"])
	var speaker_color: Color = NPC_COLORS.get(entry["character_id"], Color(1, 0.82, 0.5))
	if String(entry.get("scene", "")) == "group":
		dialogue_log.append_text("[i][color=#9aa0a6]in the hall[/color][/i]\n")
	var question := String(entry["question"])
	if question != "":
		dialogue_log.append_text("[b]You:[/b] %s\n" % _colorize_names(question))
	dialogue_log.append_text("[b][color=#%s]%s:[/color][/b] %s\n\n" % [speaker_color.to_html(false), String(c.get("short", "")), _colorize_names(String(entry["answer"]))])


func _send_question() -> void:
	var q := dialogue_input.text.strip_edges()
	if q == "" or current_dialogue_character == "":
		return
	dialogue_input.text = ""

	# "Go to the library" / "wait in the study" etc. are handled locally as
	# stage directions rather than sent to Ollama as an in-character question.
	var move_room := _parse_move_command(q)
	if move_room != "":
		_handle_move_command(current_dialogue_character, move_room, q)
		return

	dialogue_input.editable = false
	dialogue_ask_button.disabled = true
	var c := GameManager.get_character(current_dialogue_character)
	dialogue_status_label.text = "%s is thinking..." % String(c.get("short", ""))
	GameManager.ask_character(current_dialogue_character, q)


func _on_ollama_response(character_id: String, _text: String) -> void:
	if character_id == current_dialogue_character:
		dialogue_status_label.text = ""
		var last: Dictionary = GameManager.transcript[GameManager.transcript.size() - 1]
		_append_transcript_entry(last)
		dialogue_input.editable = true
		dialogue_ask_button.disabled = false
		dialogue_input.grab_focus()
	# Dialogue can't actually be open at the same time as the Notes panel
	# (opening Notes releases the mouse, which disables interaction), but
	# keep this in sync just in case that ever changes.
	if notes_panel.visible and notes_selected_char == character_id:
		_render_notes_content(character_id)


func _on_ollama_error(character_id: String, message: String) -> void:
	if character_id == current_dialogue_character:
		dialogue_status_label.text = "Error: " + message
		dialogue_input.editable = true
		dialogue_ask_button.disabled = false


func open_accusation() -> void:
	close_dialogue()
	# The front door can't be reached with the meetup panel open (the mouse is
	# released, which disables interaction), but leaving a live confrontation
	# running behind the accusation screen would strand frozen suspects if that
	# ever changes.
	if group_panel != null and group_panel.visible:
		close_group_dialogue()
	accusation_result_label.text = ""
	accusation_selected_id = ""
	accusation_accuse_button.disabled = true
	for bid in accusation_suspect_buttons.keys():
		var btn: Button = accusation_suspect_buttons[bid]
		btn.remove_theme_stylebox_override("normal")
		btn.remove_theme_stylebox_override("hover")
	accusation_panel.visible = true
	player.set_mouse_captured(false)


func close_accusation() -> void:
	accusation_panel.visible = false
	player.set_mouse_captured(true)


func _submit_accusation() -> void:
	if accusation_selected_id == "":
		return
	if GameManager.check_accusation(accusation_selected_id):
		accusation_panel.visible = false
		var c := GameManager.get_character(GameManager.murderer_id)
		win_label.text = "Case closed! %s was the murderer.\n\nMotive: %s" % [String(c.get("name", "")), String(c.get("flavor", ""))]
		win_panel.visible = true
		player.set_mouse_captured(false)
	else:
		var c := GameManager.get_character(accusation_selected_id)
		accusation_result_label.text = "%s isn't who the evidence points to. Keep investigating..." % String(c.get("short", "That suspect"))


func toggle_notes() -> void:
	if win_panel.visible:
		return
	notes_panel.visible = not notes_panel.visible
	if notes_panel.visible:
		# Default to whichever suspect was showing last time, unless you
		# haven't talked to them (or anyone) - then pick the first suspect
		# with any conversation.
		if notes_selected_char == "" or not GameManager.has_notes(notes_selected_char):
			notes_selected_char = _first_interviewed_character()
		_select_notes_character(notes_selected_char)
		player.set_mouse_captured(false)
	elif not dialogue_panel.visible and not accusation_panel.visible:
		player.set_mouse_captured(true)


func _first_interviewed_character() -> String:
	for c in GameManager.active_characters():
		if GameManager.has_notes(c["id"]):
			return c["id"]
	return ""


## Switches the right-hand pane to a suspect, kicking off a summary request
## for them (lazily, per-tab, rather than for everyone at once) if their
## conversation has grown since their last summary and one isn't already in
## flight.
func _select_notes_character(id: String) -> void:
	notes_selected_char = id
	_update_notes_tab_styles()
	if id != "" and not _pending_summaries.has(id) and GameManager.needs_summary_refresh(id):
		_pending_summaries[id] = true
		GameManager.request_summary(id)
	_render_notes_content(id)


## Refreshes every tab's three indicators: a highlighted background if it's
## the currently selected suspect, dimming if you haven't talked to them
## yet, and a red dot if their Slipups section has real content. Tab text
## color itself always stays that suspect's body color and is never
## overridden, so it stays consistent whether selected or not.
func _update_notes_tab_styles() -> void:
	for id in notes_tab_buttons.keys():
		var btn: Button = notes_tab_buttons[id]
		var talked: bool = GameManager.has_notes(id)
		btn.modulate = Color(1, 1, 1, 1.0) if talked else Color(1, 1, 1, 0.4)

		if id == notes_selected_char:
			btn.add_theme_stylebox_override("normal", _selected_tab_stylebox())
			btn.add_theme_stylebox_override("hover", _selected_tab_stylebox())
		else:
			btn.remove_theme_stylebox_override("normal")
			btn.remove_theme_stylebox_override("hover")

		var dot: ColorRect = notes_flag_dots.get(id)
		if dot:
			dot.visible = _has_slipup_flag(id)


func _selected_tab_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.16)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 6
	return sb


## True if a suspect's Slipups section has real, non-empty content - as
## opposed to being blank or the model's "nothing notable" placeholder.
func _has_slipup_flag(id: String) -> bool:
	var summary: Dictionary = GameManager.get_summary(id)
	if summary.is_empty():
		return false
	var s: String = String(summary.get("slipups", "")).strip_edges().to_lower()
	if s == "":
		return false
	var negative_markers := ["nothing notable", "nothing relevant", "nothing suspicious", "no slip", "n/a", "none yet", "none noted"]
	for m in negative_markers:
		if s.find(m) != -1:
			return false
	return true


func _on_summary_ready(character_id: String, _text: String) -> void:
	_pending_summaries.erase(character_id)
	if not notes_panel.visible:
		return
	_update_notes_tab_styles() # refreshes that suspect's slipup flag dot
	if notes_selected_char == character_id:
		_render_notes_content(character_id)


func _on_summary_error(character_id: String, _message: String) -> void:
	_pending_summaries.erase(character_id)
	if not notes_panel.visible:
		return
	_update_notes_tab_styles()
	if notes_selected_char == character_id:
		_render_notes_content(character_id)


## Renders the right-hand pane for one suspect: their Timeline / Motive /
## Slipups / Contradictions sections, a "Summarizing..." placeholder while one's
## in flight, or a raw transcript fallback if no summary is available (nothing
## asked yet, or the last summarization attempt failed).
func _render_notes_content(id: String) -> void:
	notes_log.clear()
	if id == "":
		notes_log.append_text("Talk to a suspect, then check back here.")
		return

	var c := GameManager.get_character(id)
	var name_color: Color = NPC_COLORS.get(id, Color.WHITE)
	notes_log.append_text("[b][color=#%s]%s[/color][/b] [color=#999999](%s)[/color]\n\n" % [name_color.to_html(false), String(c.get("name", "")), String(c.get("job", ""))])

	# Sources, not just their own answers: a suspect who stood silently through
	# a Hall confrontation still has notes worth reading.
	var entries: Array = GameManager.summary_sources(id)
	if entries.is_empty():
		notes_log.append_text("You haven't asked %s anything yet." % String(c.get("short", "them")))
		return

	if _pending_summaries.has(id):
		notes_log.append_text("[i]Summarizing...[/i]")
		return

	var summary: Dictionary = GameManager.get_summary(id)
	if summary.is_empty():
		# No structured summary available - fall back to the raw record.
		for e in entries:
			var answer := _colorize_names(String(e["answer"]))
			if String(e["character_id"]) != id:
				var other := GameManager.get_character(String(e["character_id"]))
				notes_log.append_text("[i]In the hall, %s said:[/i] %s\n\n" % [String(other.get("short", "someone")), answer])
			elif String(e.get("scene", "")) == "group":
				notes_log.append_text("[i]In the hall[/i]\nQ: %s\nA: %s\n\n" % [_colorize_names(String(e["question"])), answer])
			else:
				notes_log.append_text("Q: %s\nA: %s\n\n" % [_colorize_names(String(e["question"])), answer])
		return

	notes_log.append_text("[b][color=#8fd3ff]TIMELINE[/color][/b]\n%s\n\n" % _colorize_names(_section_or_placeholder(summary.get("timeline", ""))))
	notes_log.append_text("[b][color=#ffb37a]POTENTIAL REASON TO KILL[/color][/b]\n%s\n\n" % _colorize_names(_section_or_placeholder(summary.get("motive", ""))))
	notes_log.append_text("[b][color=#ff8f8f]SLIPUPS[/color][/b]\n%s\n\n" % _colorize_names(_section_or_placeholder(summary.get("slipups", ""))))
	notes_log.append_text("[b][color=#ffd166]CONTRADICTIONS[/color][/b]\n%s\n\n" % _colorize_names(_section_or_placeholder(summary.get("contradictions", ""))))


func _section_or_placeholder(text: String) -> String:
	var t := String(text).strip_edges()
	if t == "":
		return "Nothing notable yet."
	return t


# --------------------------------------------------------------- debug UI --
# A dev/testing aid so you don't have to interrogate all 8 suspects just to
# confirm the murderer logic is working. This is meant for testing only -
# remove the F1 binding (in GameManager._setup_input_map) before sharing
# builds with anyone you actually want to keep guessing.

func toggle_debug() -> void:
	debug_label.visible = not debug_label.visible
	if debug_label.visible:
		_refresh_debug_label()


func _refresh_debug_label() -> void:
	var c := GameManager.get_character(GameManager.murderer_id)
	debug_label.text = "[DEBUG] Murderer: %s\nWeapon: %s\nTime: %s" % [String(c.get("name", "?")), GameManager.murder_weapon, GameManager.murder_time]
