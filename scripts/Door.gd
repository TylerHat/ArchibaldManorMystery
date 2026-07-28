extends StaticBody3D
# The front door of Archibald Manor. Interacting with it opens the final
# accusation panel - this is the only way to win the game.


func get_interact_prompt() -> String:
	return "Open the front door and name the murderer"


func interact() -> void:
	var main = get_tree().get_first_node_in_group("main_controller")
	if main:
		main.open_accusation()
