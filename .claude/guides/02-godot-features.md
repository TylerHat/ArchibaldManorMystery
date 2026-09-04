# Godot features, explained from zero

Every Godot concept this project uses, in the order you will meet it, with a
real example from this codebase for each one. If you have never opened Godot,
read this straight through. If you have, skim the headings and stop where
something looks unfamiliar.

---

## 1. The four ideas that make up Godot

### 1.1 A node is one thing that does one job

Godot has no "GameObject with components". Instead there are hundreds of node
types, each of which *is* a capability. A `Label` shows text. A `Camera3D` is a
viewpoint. A `RayCast3D` shoots an invisible line and reports what it hits. A
`Timer` counts down.

You build things by nesting nodes. Our player is:

```
Player            (CharacterBody3D)  moves and collides
└─ Camera3D                          what you see through
   └─ InteractRay  (RayCast3D)       points at whatever is in front of you
```

Nothing here is a component attached to an entity. The camera *is* a node, and
it is a child of the body, so it moves with it automatically.

### 1.2 A scene is a saved tree of nodes

A `.tscn` file is a text file describing a tree of nodes. You can open one in a
text editor and read it. `Scenes/Main.tscn` is only a few lines, because this
project builds nearly everything in code instead.

Any scene can be instanced inside another, which is how most Godot games are
built. This one barely uses that, on purpose.

### 1.3 A script attaches to a node and extends it

```gdscript
extends CharacterBody3D
```

That first line of `Player.gd` means: this script *is* a `CharacterBody3D`, and
adds to it. Inside, `self` is the node. You can call any method the base type
has, plus your own.

GDScript is Godot's own language. It reads like Python, with static typing
available and optional. If you know Python you can read it immediately.

### 1.4 The engine calls you, not the other way around

You do not write a main loop. You write specially named methods and Godot calls
them:

| Method | When Godot calls it |
|---|---|
| `_ready()` | once, when the node enters the tree and all its children are ready |
| `_process(delta)` | every rendered frame; `delta` is seconds since the last one |
| `_physics_process(delta)` | at a fixed rate, 60 times a second; use for movement |
| `_unhandled_input(event)` | on input nothing else consumed first |

`Main._process()` in this project does exactly one thing: hide furniture in
rooms you cannot see. `NPCCharacter._physics_process()` does all suspect
movement. Movement goes in the physics callback because the physics engine runs
at a fixed rate and frame rate varies.

---

## 2. Autoloads (this project's most important concept)

An **autoload** is a node Godot creates before any scene loads and never
destroys. It becomes a global name available in every script.

In `project.godot`:

```ini
[autoload]
GameManager="*res://Scripts/GameManager.gd"
```

The `*` means "make it a Node", so it can receive `_ready()`, hold children and
emit signals.

From that point on, in *any* script, with no import:

```gdscript
if GameManager.murderer_id == character_id:
    ...
```

This is why the codebase has no service locator and no dependency injection.
There is one global, everybody knows its name, and it holds everything that has
to outlive a scene.

**Consequence to remember:** an autoload's `_ready()` runs *before* the main
scene's. `GameManager` therefore cannot assume `Main` exists. It never looks
for it; `Main` finds `GameManager`, not the other way round.

---

## 3. Signals

A signal is an event a node emits that others can subscribe to. It is the
observer pattern with language support.

Declaring one:

```gdscript
signal ollama_response(character_id, text)
```

Emitting it:

```gdscript
ollama_response.emit(id, text)
```

Subscribing:

```gdscript
GameManager.ollama_response.connect(_on_ollama_response)
```

The point is that the emitter does not know or care who is listening.
`GameManager` finishes an AI request, emits, and is done. `Main` happens to be
listening and updates a `RichTextLabel`. Swap the UI out entirely and
`GameManager` does not change by one character. That is why the dialogue system
can be exercised by the headless test scenes.

---

## 4. Groups

A group is a string tag on a node, and the tree can be searched by it.

```gdscript
add_to_group("main_controller")            # in Main._ready()

var main = get_tree().get_first_node_in_group("main_controller")
```

This project uses exactly one group, `main_controller`. It is how a door
spawned at runtime opens a UI panel without anybody having wired a reference to
it. `Door.gd` is thirteen lines and that is the whole trick.

---

## 5. Resource paths, `res://` and `user://`

Godot addresses files by URL-ish prefixes, never by operating-system path.

| Prefix | Means |
|---|---|
| `res://` | the project folder. Read-only in an exported game. |
| `user://` | a per-user writable folder outside the project. |

```gdscript
const SuspectModel = preload("res://Scripts/SuspectModel.gd")
```

`DialogueLog.gd` shows the pattern for writing: try `res://DialogueLogs` first
so the file lands next to the project where it is easy to find, and fall back to
`user://DialogueLogs` when that is not writable, which is the case in an
exported build.

**This is the reason moving a script file is not free.** Every `preload`, every
`.tscn` reference and the autoload line in `project.godot` name scripts by
`res://` path. Move one outside the Godot editor and those references break.
Moving files *inside* the editor makes Godot rewrite them for you.

---

## 6. `preload` vs `load` vs `class_name`

Three ways to reach another script, and this project has a strong opinion about
which to use.

```gdscript
const SuspectModel = preload("res://Scripts/SuspectModel.gd")
```

`preload` resolves at parse time from a literal path. It cannot fail at
runtime and it cannot race.

```gdscript
class_name CaseGenerator
```

`class_name` registers a global identifier so any script can just say
`CaseGenerator.generate(...)`. Convenient, but Godot registers global classes
during a filesystem scan that can run *after* it parses the scripts using them.
On a fresh clone, or the first launch after adding the file, you get:

```
Identifier "SuspectModel" not declared in the current scope
```

Which is why `SuspectModel.gd` deliberately has **no** `class_name` and the
comment at the top of it says so. `CaseGenerator` and `ManorBuilder` do have
one, and both are older and stable. **New shared scripts in this repo should be
reached by `preload`.**

---

## 7. `.uid` files and `.import` files

Two kinds of sidecar file you will see everywhere and should not hand-edit.

**`Scripts/Main.gd.uid`** holds a stable identifier for that script so scenes
can reference it even if it moves. Godot generates and maintains these. They
belong in git. Never edit one.

**`Models/Furniture/Chair_1.blend.import`** records how Godot converted that
Blender file: scale, materials, whether to make collision shapes. Godot writes
it on import. The converted result goes into `.godot/`, which is cache and is
gitignored, so the `.import` file is what makes the conversion reproducible on
another machine. It belongs in git too.

---

## 8. `@tool` scripts

Normally a script only runs when you press Play. `@tool` on the first line
makes it run *in the editor as well*.

`ManorBuilder.gd` is a `@tool`. That is why the mansion is drawn live in the
editor viewport while you edit the `FLOORS` spec, instead of being invisible
until you hit Play.

The cost: a `@tool` script's bugs can affect the editor itself, including
crashing it or writing bad data into your scene. Read
[`../reference/manor-builder.md`](../reference/manor-builder.md) before you
touch it.

Related, `@export` puts a variable in the editor's Inspector panel:

```gdscript
@export var build_ceilings: bool = false
@export var rebuild_now: bool = false:
    set(value): rebuild()
```

The second one is a checkbox that runs code when ticked, which is how you press
"rebuild" from the Inspector.

---

## 9. The node types this project actually uses

| Type | Where | What it gives you |
|---|---|---|
| `Node` | `GameManager`, `GroupChat`, `CrimeScene` | no position, no drawing, pure logic in the tree |
| `Node3D` | `Main`, `ManorBuilder` | a position and rotation in 3D |
| `CharacterBody3D` | `Player`, `NPCCharacter` | a body you move yourself, with collision. `move_and_slide()` does the work |
| `StaticBody3D` | walls, `Door`, `Evidence` | a body that never moves but is solid and can be hit by a ray |
| `RayCast3D` | `Player`'s interact ray | reports the first thing along a line |
| `Camera3D` | inside `Player` | the viewpoint |
| `MeshInstance3D` | every box in the manor | draws a mesh |
| `CanvasLayer` | `Main.ui_layer` | 2D drawn on top of the 3D, unaffected by the camera |
| `Panel`, `Label`, `Button`, `RichTextLabel`, `TextEdit`, `CheckBox` | all UI | standard controls |
| `HTTPRequest` | inside `GameManager` | one asynchronous HTTP call at a time |
| `Timer` | map refresh | fires a signal on an interval |
| `Area3D` | room volumes from `ManorBuilder` | detects overlap without blocking movement |
| `AnimationPlayer` | inside imported suspect models | plays the model's idle and walk clips |
| `RefCounted` | `CaseGenerator`, `SuspectModel`, `DialogueLog`, `TrainingCapture` | **not** in the scene tree; a plain object that frees itself. Use this for pure logic |

That last row matters. `CaseGenerator extends RefCounted` and has no scene tree
access at all, which is precisely what lets `CaseGeneratorTest` generate a
thousand cases in a loop without building a single mansion.

---

## 10. `RichTextLabel` and BBCode

Ordinary `Label` shows plain text. `RichTextLabel` with `bbcode_enabled = true`
understands a markup similar to old forum tags:

```
[color=#e0b0ff]Victoria[/color] said she was in the [i]Library[/i]
```

This project uses it for two effects:

- **Name coloring.** Every suspect's name is painted to match their body color
  in the mansion, everywhere it appears, so you can track who is being
  discussed. `Main._colorize_names()` does it with per-character compiled
  regular expressions.
- **Actions in italics.** Anything you type in round brackets is treated as a
  physical action rather than speech, and rendered in italics so it reads
  differently. `Main._italicize_actions()`.

---

## 11. The InputMap, and why it is built in code here

Godot normally stores key bindings in Project Settings. This project registers
them in `GameManager._setup_input_map()` instead:

```gdscript
_add_key_action("move_forward", KEY_W)
_add_key_action("interact", KEY_E)
_add_key_action("toggle_notes", KEY_TAB)
```

Two reasons. First, the bindings are then visible in the same file as the code
that reads them. Second, and more useful, the debug keys are registered inside
`if DEBUG_KEYS:`, so when that constant is `false` the actions **do not exist at
all**. There is no hidden cheat to find in a shipped build, because there is no
binding.

That does create one trap, handled in `Main._unhandled_input()`:
`is_action_pressed("toggle_debug")` ignores modifiers by default, so a plain
`1` would fire the Ctrl+1 action. The calls pass `exact_match = true` to
prevent it, and short-circuit on `GameManager.DEBUG_KEYS` first, because asking
about an action that does not exist raises an error.

---

## 12. Building UI in code

Most Godot projects lay out UI in the editor. This one writes it:

```gdscript
var panel := Panel.new()
panel.set_anchors_preset(Control.PRESET_CENTER)
panel.custom_minimum_size = Vector2(900, 600)
ui_layer.add_child(panel)
```

`Main` has a `_build_*_panel()` function per panel and there are eight of them.
It is more code than dragging boxes around, and it is deliberate: the entire
game reviews as a text diff, and a UI change shows up in a pull request as
readable lines rather than as a re-serialized scene file that nobody can read.

If you are adding a panel, copy the shape of the nearest existing
`_build_*_panel()` function rather than inventing a new one. See
[`09-ui-and-case-notes.md`](09-ui-and-case-notes.md).

---

## 13. Godot gotchas that have already bitten this project

**Constant containers are read-only.** In Godot 4.4+, a `const` array or
dictionary cannot be modified, even a copy you took by assignment.
`CaseGenerator.generate()` calls `.duplicate(true)` on a weapon before handing
it out for exactly this reason.

**`await` yields the whole function.** Anything after an `await` runs later, by
which time the node may have been freed. This is why closing a dialogue panel
mid-request has to be handled explicitly rather than assumed impossible.

**Freeing a node is deferred.** `queue_free()` marks a node for deletion at the
end of the frame; it is not gone yet. Use `is_instance_valid(node)` before
touching anything you might have freed.

**Signals connected to a freed object error.** Disconnect, or use
`CONNECT_ONE_SHOT`, when the listener may not outlive the emitter.

**Physics and rendering run at different rates.** Move things in
`_physics_process()`. Read positions for display in `_process()`.

---

## 14. Where to look things up

- Godot's own docs: <https://docs.godotengine.org>. Pick the 4.x version in
  the sidebar, the 3.x API is quite different.
- GDScript basics: search the docs for "GDScript reference".
- In the editor, hold **Ctrl** and click any built-in type name in a script to
  jump straight to its documentation.
