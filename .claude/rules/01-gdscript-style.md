# GDScript style

How code in this repo is written. Most of it is Godot's own convention; the
parts that are not are listed here because they are choices this project made
on purpose.

---

## 1. Naming

Godot's standard, no deviations.

| Thing | Style | Example |
|---|---|---|
| files | PascalCase | `GameManager.gd` |
| classes | PascalCase | `class_name CaseGenerator` |
| functions and variables | snake_case | `evening_account`, `murder_room` |
| private | leading underscore | `_build_character_tail()`, `_histories` |
| constants | SCREAMING_SNAKE | `MAX_ACTIVE_SUSPECTS` |
| signals | snake_case, past tense | `summary_ready`, `line_added` |
| character ids | lowercase, no spaces | `cross_natalie` |

The leading underscore is a convention, not enforcement. It means "nothing
outside this file should call me", and it is respected throughout.

---

## 2. Typing

Use static types where they cost nothing.

```gdscript
func room_for(id: String) -> String:
var mask := 0
var errs := []
```

`:=` infers the type and is preferred over a bare `var x = 0`.

**Where you cannot type it, do not fake it.** Dictionaries carrying mixed data
are typed `Dictionary` and documented in a comment, not wrapped in a class for
the sake of it. `case_data` is a plain dictionary with a documented shape and
that is deliberate: it crosses a boundary into Python-shaped data files, and a
class would have to be unpacked at every crossing.

Cast explicitly when reading out of one:

```gdscript
var slot := int(c["slot"])
var path: Array = case_data["true_paths"][id]
```

---

## 3. Comments: the one rule that actually matters here

**A comment on a tuned number says what was measured.**

This is the strongest convention in the codebase and it is worth more than
everything else on this page. Every constant that was arrived at by experiment
carries the experiment:

```gdscript
## Raised from 140 after measuring the tuned model: its replies run a median
## ~115 tokens and 14% of 601 harvested replies hit the old ceiling and were
## cut mid-sentence. Four of 32 lines in dialogue_20260901_182749.md end
## mid-clause for this reason. Costs ~1.7s on the longest replies.
const MAX_RESPONSE_TOKENS := 200
```

Without that, the next person sees an arbitrary number, changes it to a
different arbitrary number, and the measurement is lost forever.

The same applies to a design decision that looks wrong:

```gdscript
# The murder room is never the weapon's home room - that would make
# constraint 6 vacuous and throw away the best clue in the case.
```

**And to bugs that have already happened.** Several comments in this repo name
a specific dialogue log and a specific date. Keep doing that. "This broke once,
here is the evidence" is the most persuasive comment there is.

### Comment style

- `##` for documentation comments on a function, constant or exported variable.
  Godot shows these in the editor's autocomplete.
- `#` for ordinary comments.
- `# ---- section name --` to divide a long file into readable regions. Both
  `GameManager.gd` and `CaseGenerator.gd` use these; follow the existing shape.

### What not to comment

Do not restate the code. `# increment the counter` above `count += 1` is noise.
Comment the *why*, and especially the why-not.

---

## 4. File structure

Order within a file:

1. `@tool` / `class_name` / `extends`
2. a header comment saying what this file owns and, if it is not obvious, what
   it deliberately does **not** own
3. `preload` constants
4. tuning constants, grouped, each with its measurement comment
5. signals
6. exported variables
7. public variables
8. private variables
9. `_ready()` and other engine callbacks
10. public functions
11. private functions

The header comment is not optional. `ManorBuilder.gd` is the model:

```gdscript
# WHAT THIS OWNS ...... floors, walls, doorway gaps, ceilings, stairs,
#                       per-room Area3D volumes, room labels, collision.
# WHAT IT NEVER TOUCHES  everything under the "Decor" child.
```

---

## 5. Reaching other scripts

**Use `preload`, not `class_name`, for new shared scripts.**

```gdscript
const SuspectModel = preload("res://Scripts/SuspectModel.gd")
```

`class_name` works most of the time and then fails on a fresh clone with
`Identifier "X" not declared in the current scope`, because Godot registers
global classes during a filesystem scan that can run after it parses the
scripts using them. `preload` resolves at parse time from the path and cannot
lose that race.

`CaseGenerator` and `ManorBuilder` have a `class_name` because they are older
and stable. That is not a reason to add more.

---

## 6. Talking to other objects

Four mechanisms, and there should not be a fifth.

- **The autoload.** `GameManager.anything`, available everywhere with no setup.
- **Signals, upward.** `GameManager` emits, `Main` listens.
  `GameManager` must never touch a UI node.
- **Groups, downward.**
  `get_tree().get_first_node_in_group("main_controller")`.
- **Duck typing, for interaction.** Anything with `get_interact_prompt()` and
  `interact()` is interactable. `Player.gd` needs no change to support a new
  kind of object.

---

## 7. Failure

**Never leave the player with nothing.**

Every failure path in this codebase degrades to something readable:

- a rejected reply is retried once, then replaced with a written in-character
  fallback line
- a failed case-notes summary falls back to the raw questions and answers
- a suspect with no 3D model falls back to a colored capsule
- a failed case generation falls back to a fixed hand-written scenario
- `DialogueLog` falls back from `res://` to `user://` when the project folder
  is not writable

Use `push_error()` for a developer-facing problem, `print()` for information
the person playing in the editor wants. Never `assert()` on something a player
could cause.

---

## 8. Performance, where it has mattered

Three lessons already learned. Follow them rather than rediscovering them.

**Share meshes, materials and shapes.** `Main._shared_box_mesh()`,
`_shared_box_material()` and `_shared_box_shape()` exist because the manor
shell used to mint a fresh `BoxMesh`, `StandardMaterial3D` and `BoxShape3D` per
box. The material was the expensive part: forty identical cream wall segments
each carrying their own material means forty draw calls, because Godot can only
batch geometry that shares one.

**Do not recompute per frame what changes per room.** `Main._process()` only
recomputes furniture visibility when `_culled_for_room` changes.

**Cache what is identical across characters.** `_cached_preamble` exists so the
shared opening of every system prompt is byte-identical, which lets Ollama cache
processing it. Twelve slightly different openings would be dramatically more
expensive than twelve identical ones.

---

## 9. Godot version traps

- **`const` containers are read-only** in 4.4+. `.duplicate(true)` before
  handing one out.
- **`queue_free()` is deferred.** Check `is_instance_valid()` before touching
  anything you may have freed.
- **`await` yields the whole function.** The node may be gone by the time it
  resumes.
- **Move things in `_physics_process()`,** read positions for display in
  `_process()`.
