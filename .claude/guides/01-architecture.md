# Architecture

How the whole game fits together, from the moment you press Play to the moment
a suspect answers a question. Written to be read top to bottom once, then
skimmed back to whenever you need to find where something lives.

---

## 1. The one-sentence version

`GameManager` is a permanent singleton that owns the case and every
conversation with the AI model; `Main` is a giant builder that constructs the
mansion and every UI panel in code and acts as the switchboard everything else
calls into; `CaseGenerator` is a pure function that invents the mystery before
either of them starts.

---

## 2. The picture

```
                        ┌──────────────────────────────────────────┐
                        │  Ollama  (separate program on your PC)   │
                        │  http://127.0.0.1:11434/api/chat         │
                        └───────────────▲──────────────────────────┘
                                        │  one HTTP request at a time
                        ┌───────────────┴──────────────────────────┐
                        │  GameManager  (autoload singleton)       │
                        │                                          │
   CaseGenerator ──────►│  · the case (who/where/when/with what)   │
   (pure logic,         │  · every character's conversation memory │
    no scene tree)      │  · builds the system prompt per suspect  │
                        │  · the reply guard                       │
                        │  · the request queue (this is the spine) │
                        │  · case-notes summaries                  │
                        │      └── GroupChat (child node)          │
                        └───────────────▲──────────────────────────┘
                                        │  signals up, function calls down
                        ┌───────────────┴──────────────────────────┐
                        │  Main  (Node3D, the scene root)          │
                        │                                          │
                        │  builds ──► the mansion (ManorBuilder)   │
                        │             the furniture (ManorDressing)│
                        │             the crime scene (CrimeScene) │
                        │             the suspects (NPCCharacter)  │
                        │             the player (Player)          │
                        │             every UI panel, in code      │
                        └──────────────────────────────────────────┘
```

Two rules explain most of the structure:

1. **Everything that talks to Ollama goes through `GameManager`'s single
   request queue.** Private interviews, Hall meetups and case-notes summaries
   all sit in the same line. They can never collide, because there is only ever
   one HTTP request in flight.
2. **`Main` builds; `GameManager` remembers.** If it is on screen, `Main` made
   it. If it will still be true after you close a panel, `GameManager` holds
   it.

---

## 3. What happens when you press Play

In order, and worth reading once because a surprising number of bugs are
ordering bugs.

1. **Godot loads `project.godot`.** It sees `GameManager="*res://Scripts/GameManager.gd"`
   under `[autoload]`, so `GameManager` is created first, before any scene
   exists, and stays alive for the whole run.
2. **`GameManager._ready()`** checks that every character's `slot` number is
   unique (see [invariants](../rules/02-project-invariants.md)), registers the
   keyboard actions in code rather than in Project Settings, creates the single
   `HTTPRequest` node, and creates `GroupChat` as a child of itself.
3. **`Scenes/Main.tscn` loads** and `Main._ready()` runs. It does *not* build
   the mansion yet. It builds the **suspect-selection screen** and waits.
4. **You tick suspects and press Start.** `Main._on_start_pressed()` collects
   the ticked ids and calls `Main._start_game(ids)`.
5. **`GameManager.start_new_game(ids)`** runs. This is the real beginning:
   - clears every character's history, summaries, evidence and transcript
   - creates a `RandomNumberGenerator`, seeded from the case code you typed or
     from a fresh random number
   - calls `CaseGenerator.generate(active_ids, rng)`, which returns the whole
     mystery as one dictionary, or `{}` on failure
   - stores it in `GameManager.case_data` and sets `murderer_id`,
     `murder_room`, `murder_weapon`, `murder_time` from it
   - if generation failed, falls back to a fixed hand-written scenario so the
     game still runs
6. **`Main._build_world()`** builds, in this order: the mansion shell, the
   furniture, the crime scene, the player, the suspects, then all the UI
   panels. Order matters because each stage reads room positions computed by
   the one before it.
7. You are standing in the Hall and the game is live.

---

## 4. The files, in the order you should meet them

All under `Scripts/`. Line counts are a rough sense of weight, not a target.

### The two big ones

**`GameManager.gd`** (~2,500 lines) is the autoload singleton. Everything that
must survive a panel closing lives here.

Its responsibilities, in the order they appear in the file:

- **The roster.** `CHARACTERS` is a constant array of twelve dictionaries, one
  per suspect: `id`, `slot`, `name`, `short`, `first_name`, `job`,
  `personality`, `flavor`, `room`. This is the single source of truth for who
  exists. See [`07-adding-a-character.md`](07-adding-a-character.md).
- **The tuning constants.** `OLLAMA_MODEL`, `MAX_RESPONSE_TOKENS`,
  `OLLAMA_NUM_CTX`, `HISTORY_TOKEN_BUDGET` and friends. Every one of them
  carries a comment explaining what was measured to arrive at the number. Read
  those comments before changing any of them.
- **Case state.** `case_data`, `murderer_id`, `case_seed`, `evidence_found`,
  `transcript`, `active_character_ids`.
- **Prompt construction.** `_shared_case_preamble()` builds the block that is
  byte-identical for every suspect; `_build_character_tail()` builds the part
  that is only theirs; `_build_system_prompt()` glues them together.
- **The reply guard.** `_reply_breaks_character()` and its keyword lists. It
  inspects a reply *before* it reaches the screen or the character's memory.
- **The request queue.** `_enqueue()`, `_process_queue()`,
  `_on_request_completed()`. One `HTTPRequest`, one queue, three kinds of
  work.
- **Case notes.** `request_summary()` and the parser that splits the model's
  answer into Timeline / Motive / Slipups / Contradictions.
- **Case codes.** `case_code()` and `parse_case_code()`.

**`Main.gd`** (~3,400 lines) is the scene root and the switchboard.

It is in the `main_controller` group, which is how anything else in the world
finds it without holding a reference: `get_tree().get_first_node_in_group("main_controller")`.

Its responsibilities:

- Builds the selection screen, the mansion, the player, the suspects.
- Builds every UI panel from scratch in code: dialogue, group, accusation,
  notes, map, examine, win, debug overlay.
- Owns the room grid at runtime (`room_centers`, `grid_pos`) and the
  breadth-first pathfinding between rooms that NPCs walk.
- Parses everything you type that is *not* a question: "go to the library",
  "Marcus, be quiet", "everyone may speak". These are matched with compiled
  regular expressions locally, so they cost no AI thinking time at all.
- Colors every suspect's name wherever it appears, so you can tell at a glance
  who is being talked about.

### The supporting cast

| File | Lines | What it does |
|---|---|---|
| `CaseGenerator.gd` | 785 | Generates and validates the mystery. Pure logic, no scene tree, no Ollama. Fully testable. |
| `GroupChat.gd` | 875 | Turn engine for Hall meetups. Lives as a child of `GameManager`. Owns no UI. |
| `ManorBuilder.gd` | 1,103 | `@tool` script that generates the manor shell from a spec, live in the editor. |
| `SuspectModel.gd` | 437 | Builds the visible body for a suspect: a 3D model if one exists in their folder, otherwise a colored capsule. |
| `CaseGeneratorTest.gd` | 453 | Generates 1,000 cases and asserts every rule. Run it after touching the generator. |
| `NPCCharacter.gd` | 340 | One suspect's physical body. Wanders a room, walks doorway to doorway when told to move. |
| `ManorDressing.gd` | 315 | Places furniture from `Models/Furniture/furniture.json`. |
| `DialogueLog.gd` | 263 | Writes the markdown play transcript, ground truth included. |
| `GuardTest.gd` | 260 | Regression tests for the reply guard. |
| `CrimeScene.gd` | 205 | Builds the body, weapon, traces and dropped item for the generated case. |
| `DialogueOptTest.gd` | 165 | 23 regression checks for the dialogue memory work. |
| `TrainingCapture.gd` | 105 | Writes captured play into fine-tuning data files. |
| `Player.gd` | 92 | First-person controller and the centre-screen interact ray. |
| `Evidence.gd` | 31 | One examinable object. |
| `Door.gd` | 13 | The front door. Opens the accusation panel. That is all it does. |

---

## 5. How the pieces talk to each other

There are exactly four mechanisms, and knowing them means you can trace any
behaviour in the game.

### 5.1 The autoload singleton

`GameManager` is registered in `project.godot` as an autoload. That means the
identifier `GameManager` is globally available in every script with no import,
no reference passing and no setup. `GameManager.murderer_id` works anywhere.

This is why the game has no dependency-injection anything: there is one global,
it is obvious, and every other script reaches it by name.

### 5.2 Signals, going up

Godot's signals are the observer pattern with syntax. `GameManager` declares
six:

```gdscript
signal ollama_response(character_id, text)
signal ollama_error(character_id, message)
signal summary_ready(character_id, text)
signal summary_error(character_id, message)
signal group_response(character_id, text, token)
signal group_error(character_id, message, token)
```

`Main` connects to them in `_ready()` and updates the screen when they fire.
This is the *only* way a reply reaches the UI. `GameManager` never touches a
Label. That separation is what makes it possible to run the dialogue system
headless in the test scenes.

Note the `token` on the group signals. A Hall meetup can have a reply arrive
after the scene has closed or after the turn moved on. The token identifies
which round the reply belongs to, so a stale one is recognised and dropped
rather than spoken by somebody who has already left the room.

### 5.3 Groups, going down

`Main` puts itself in the `main_controller` group. Anything in the world that
needs to open a panel does this:

```gdscript
var main = get_tree().get_first_node_in_group("main_controller")
if main:
    main.open_accusation()
```

`Door.gd` in its entirety is that pattern. So is `Evidence.gd` and
`NPCCharacter.interact()`. It means a spawned object needs no wiring at all.

### 5.4 Duck-typed interaction

`Player.gd` fires a `RayCast3D` out of the camera. Whatever it hits, it asks:

```gdscript
if target.has_method("get_interact_prompt"):
    # show the prompt
if target.has_method("interact"):
    # E or left click calls it
```

That is the whole interaction contract. Two methods. `Door`, `Evidence` and
`NPCCharacter` each implement them and share nothing else. Adding a new
interactable object means writing those two methods and nothing more: no
registration, no interface, no change to `Player.gd`.

---

## 6. The request queue, in detail

This is the spine of the game and the thing most worth understanding.

Godot's `HTTPRequest` node can only have one request in flight. The game has
three kinds of work that all want to talk to Ollama:

- a private interview question
- one attendee's turn in a Hall meetup
- a case-notes summary

If any two overlapped, one would fail. So `GameManager` puts a queue in front
of the single `HTTPRequest`:

```
ask_character()      ┐
ask_group_member()   ├──► _enqueue(item) ──► _request_queue [] ──► _process_queue()
request_summary()    ┘                                                   │
                                                                         ▼
                                                            one HTTPRequest node
                                                                         │
                                                          _on_request_completed()
                                                                         │
                              ┌──────────────────────────────────────────┤
                              ▼                                          ▼
                    reply guard rejects it                    reply is accepted
                              │                                          │
                    retry once, or use a                      append to history,
                    written fallback line                     emit the signal
```

Consequences worth knowing:

- A summary requested while you are mid-conversation simply waits its turn. It
  does not fail, it is just late.
- A Hall meetup with two attendees costs **two sequential requests per line you
  say**, which is why `GROUP_MAX_TOKENS` (130) is capped harder than
  `MAX_RESPONSE_TOKENS` (200). Latency there is multiplied by the number of
  people in the room.
- Nothing is ever enqueued in a Hall meetup except from
  `GroupChat.submit_player_line()`. Suspects can stand in the Hall forever and
  not one token is generated until you speak.

---

## 7. Where the state lives

| State | Lives in | Survives |
|---|---|---|
| Who exists at all | `GameManager.CHARACTERS` (a constant) | forever |
| Who is in the house this game | `GameManager.active_character_ids` | one game |
| The whole mystery | `GameManager.case_data` | one game |
| A suspect's conversation memory | `GameManager._histories[id]` | one game |
| Everything said, for the notes | `GameManager.transcript` | one game |
| Things you have examined | `GameManager.evidence_found` | one game |
| Case-notes summaries | `GameManager._summaries` | one game, regenerated lazily |
| Who is standing where, physically | the `NPCCharacter` nodes themselves | until the scene is freed |
| Room positions, panels, colors | `Main` | until the scene is freed |

Nothing is saved to disk between runs except the optional dialogue log and the
training capture files. There is no save game, by design: the case code is the
save game. Type `482913-171` into the selection screen and you get that exact
mystery back, same murderer, same schedules, same weapon, same dropped item.

---

## 8. What to read next

- The Godot concepts used above, explained from zero:
  [`02-godot-features.md`](02-godot-features.md)
- How a question becomes an answer:
  [`05-the-dialogue-system.md`](05-the-dialogue-system.md)
- How the mystery is invented:
  [`06-the-case-generator.md`](06-the-case-generator.md)
