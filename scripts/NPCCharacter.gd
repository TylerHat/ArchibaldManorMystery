extends StaticBody3D
# Attached to each suspect's placeholder body in the mansion. Just needs to
# know which character it represents; Main.gd owns the actual dialogue UI.

var character_id: String = ""


func get_interact_prompt() -> String:
	var c := GameManager.get_character(character_id)
	if c.is_empty():
		return "Talk"
	return "Talk to " + String(c["name"])


func interact() -> void:
	var main = get_tree().get_first_node_in_group("main_controller")
	if main:
		main.open_dialogue(character_id)
