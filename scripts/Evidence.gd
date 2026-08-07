extends StaticBody3D
# One examinable thing at (or connected to) the crime scene - the body, the
# weapon, a trace mark, a dropped possession, the gap on a shelf where the
# weapon should be.
#
# Deliberately the same shape as Door.gd: a StaticBody3D exposing
# get_interact_prompt() and interact(). Player.gd's centre-screen raycast picks
# up anything with those two methods, so evidence needs no new input handling,
# no new prompt logic and no changes to the player at all.

## Short label shown in the examine panel's header and in the case notes.
var title: String = "Something"

## What the detective sees. Written by CrimeScene.gd from the generated case.
var examine_text: String = ""

## Stable id so re-examining the same object doesn't duplicate a note.
var evidence_id: String = ""

## Prompt shown when the player looks at it.
var prompt: String = "Examine"


func get_interact_prompt() -> String:
	return "%s the %s" % [prompt, title]


func interact() -> void:
	var main = get_tree().get_first_node_in_group("main_controller")
	if main:
		main.open_examine(self)
