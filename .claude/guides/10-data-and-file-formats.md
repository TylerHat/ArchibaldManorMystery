# Data and file formats

Every file this project reads or writes, field by field. Reach for this when
you need to hand-edit something or write a script against it.

---

## 1. Config the game reads

### `project.godot`

Godot's project file. Four things in it matter to you:

```ini
[application]
run/main_scene="res://Scenes/Main.tscn"
config/features=PackedStringArray("4.7", "Forward Plus")

[autoload]
GameManager="*res://Scripts/GameManager.gd"

[display]
window/size/viewport_width=1920
window/size/viewport_height=1080
window/size/mode=2                    ; maximized
window/stretch/mode="canvas_items"
```

The `*` in the autoload line means "make it a Node". The stretch settings are
why the 3D view and the UI fill any window size without black bars.

Key bindings are **not** in here. They are registered in code, in
`GameManager._setup_input_map()`, so that the debug actions can be omitted
entirely when `DEBUG_KEYS` is false.

### `Models/Furniture/furniture.json`

Read by `ManorDressing.gd`. Per room, which model goes where in room-local
coordinates.

```json
{
  "scale": 0.5,
  "rooms": {
    "Library": [
      {
        "model": "Shelf_Large",
        "x": -4.05,
        "z": 6.14,
        "rot": 180,
        "stretch": [1.92, 1.0, 1.0]
      }
    ]
  }
}
```

| Field | Means |
|---|---|
| `scale` (top level) | multiplier applied to every piece |
| `model` | a filename stem, no extension. Searched in `MODEL_DIRS` in order, first match wins |
| `x`, `z` | metres from the **room centre**, not world coordinates |
| `rot` | degrees around Y |
| `stretch` | optional per-axis scale, `[x, y, z]` |

`Extra/` is searched as well as `Furniture/`, so a second downloaded pack can
be dropped in whole without renaming anything.

**Three placement rules the existing data respects and you must too:**

- Suspects wander within `NPCCharacter.WANDER_MARGIN` (3.5m) of the room
  centre, and they have **no obstacle avoidance**. Keep solid pieces in the
  band near the walls.
- The middle of every wall is a doorway. Nothing solid straddles one.
- `CrimeScene` puts the body at centre + `(3.9, -3.9)` and the weapon gap at
  `(-4.1, -4.1)`. Keep those corners clear in **every** room, because any room
  can be the scene.

### `Models/Suspects/suspect_models.cfg`

Read by `SuspectModel.gd`. Standard INI. `[default]` applies to everyone; a
section named after a suspect id overrides it for that person. Changes take
effect on the next run, no reimport needed.

```ini
[default]
auto_fit_height=true
scale=1.0
y_offset=0.0
rot_y=180.0

[pike]
scale=1.05
color_shirt="#5f6b42"
tint_main="#402a1c"
```

| Key | Means |
|---|---|
| `auto_fit_height` | rescale to 1.8m so the model matches its collision capsule and fits the doorways. `false` if you sized it in Blender |
| `scale` | extra multiplier on top of that |
| `y_offset` | nudge up or down in metres, if feet float or sink |
| `rot_y` | spin in place, degrees. **180 is the default** because Godot treats -Z as forward and these models are authored facing +Z. Without it every suspect walks backwards |
| `color_<material>` | retint the material of that name. `color_shirt="#5f6b42"` repaints every surface whose material is called Shirt |
| `tint_main`, `tint_accent` | broad tints for models with generic material names |

**You can only recolor a material the model actually has.** The comments in the
file list each model's real material names, read out of the `.blend` files
rather than guessed. `color_shirt` on a model with no Shirt material does
nothing at all, silently. This is the single most common confusion with this
file.

### `Models/Suspects/<id>/_WHO.txt`

Plain text, read by nobody. It is a note to whoever is dropping a model in,
saying who lives in that folder and which file from the asset pack was
suggested.

---

## 2. In-memory shapes

### A character

`GameManager.CHARACTERS`, a constant array of twelve.

```gdscript
{
    "id": "blackwood",        # lowercase key, used everywhere
    "slot": 0,                # PERMANENT, never reused. Case codes depend on it
    "name": "Dr. Evelyn Blackwood",
    "short": "Evelyn",        # what others call her
    "first_name": "Evelyn",   # for accusation matching
    "job": "Forensic Pathologist",
    "personality": "Calm, analytical, observant, and emotionally reserved...",
    "flavor": "Has an unsettlingly detailed knowledge of how someone died.",
    "room": "Library",        # fallback only; the generator normally decides
}
```

### The case

`GameManager.case_data`, produced by `CaseGenerator.generate()`. Full shape in
[`06-the-case-generator.md`](06-the-case-generator.md) section 6. The two
fields you will reach for most:

- `true_paths[id]`, an array of 8 room names, what really happened
- `claimed_paths[id]`, identical except for the murderer's lie block

### A transcript entry

`GameManager.transcript`, in the order things happened.

```gdscript
{"character_id": "sterling", "question": "...", "answer": "..."}
```

Lines spoken during a Hall meetup add two more keys:

```gdscript
{"character_id": "sterling", "question": "...", "answer": "...",
 "scene": "group",              # said out loud in front of others
 "heard_by": ["reeves", "pike"]}
```

One-on-one entries simply omit both, so **anything reading this array can treat
a missing `scene` as a private interview.**

### An evidence entry

`GameManager.evidence_found`, deduplicated by `id`.

```gdscript
{"id": "body", "title": "the body", "text": "..."}
```

### A group scene line

`GroupChat.scene_log`.

```gdscript
{"speaker_id": "sterling", "text": "...", "kind": "say"}
```

`speaker_id` empty means the detective. `kind` is one of:

| kind | Means |
|---|---|
| `say` | a spoken line |
| `stage` | the engine's own italic narration |
| `command` | an order the detective typed |
| `action` | a physical thing the detective did, in round brackets |

### A case code

`"482913-171"`. Seed, then a bitmask of the cast over permanent slot numbers.
`GameManager.case_code()` builds it, `parse_case_code()` reads it and returns
`{"seed": int, "ids": Array}` or `{"error": String}`. A bare seed with no cast
is accepted, and keeps whatever suspects are ticked.

---

## 3. Files the game writes

### `DialogueLogs/dialogue_<timestamp>.md`

Written by `DialogueLog.gd` when the log checkbox is ticked. Markdown, and
**rewritten in full on every new line** rather than appended to, so the file on
disk is always complete even if the game is closed mid-session. The transcript
is small enough that the cost does not matter next to an Ollama round trip.

Contains, in order:

1. the case code
2. the ground truth table: every suspect's real movements slot by slot
3. a section per suspect, headed with **the exact briefing that suspect was
   given**
4. the full timeline of everything said, in order

Point 3 is what makes the file useful weeks later. A reply can only be judged a
hallucination against what that character was actually told. Point 4 is where
cross-character bleed shows up: a suspect referring to something only another
suspect was told, or answering a question never put to them.

### `TrainingData/sft_<timestamp>.jsonl`

One JSON object per line. Written by `TrainingCapture.gd`, **appended
immediately** rather than rebuilt, so a session that ends in a crash still
keeps every row it earned.

```json
{"messages": [{"role":"system","content":"..."},
              {"role":"user","content":"..."},
              {"role":"assistant","content":"..."}],
 "character_id": "blackwood", "scene": "private"}
```

### `TrainingData/dpo_<timestamp>.jsonl`

```json
{"messages": [...],
 "chosen": "the good reply, or \"\" if it still needs one",
 "rejected": "the bad reply",
 "reason": "why the guard caught it",
 "chosen_source": "guard-retry | manual",
 "source": "...",
 "character_id": "blackwood",
 "scene": "private",
 "group": "alibi",
 "case_code": "482913-171"}
```

An empty `chosen` means the row is waiting for you.
`Training/fill_chosen.py` walks them one at a time.

### `TrainingData/prompts_export_<code>.json`

Written by **Ctrl+3**. The active characters' full system prompts plus the
generation settings, so the harvest can ask questions with exactly the prompts
the game would have used.

```json
{"case_code": "222839-29376",
 "characters": {"pike": {...}, "thorne": {...}},
 "exported_at": "...",
 "model": "archibald-suspect:v1",
 "num_ctx": 8192, "max_response_tokens": 200, "stop": [...],
 "murderer_id": "...", "murder_room": "...", "murder_weapon": "...", "murder_time": "..."}
```

---

## 4. Files the training tools write

### `TrainingData/harvest_<timestamp>.jsonl`

Output of `harvest.py`. One row per question asked.

```json
{"id": "blackwood/alibi/0",
 "character_id": "blackwood", "character": "Evelyn",
 "case_code": "...", "group": "alibi",
 "question": "Where were you when the body was found?",
 "framed": "...the question after frame_player_line()...",
 "depth": 0,
 "messages": [...],
 "candidates": ["reply 1", "reply 2", "reply 3"],
 "model": "archibald-suspect:v1"}
```

`candidates` holds one reply on pass 1, and `--k` replies on a rerun.

The `id` format `<character>/<group>/<n>` is the join key across every file in
the pipeline. Do not change it casually.

### `decisions.json`

Downloaded from the browser reviewer (`Training/review.html`).

```json
{"source": "TrainingData/harvest_2026-08-29_104621.jsonl",
 "mode": "binary",
 "saved": "2026-08-29T18:03:13.235Z",
 "verdicts": {"blackwood/alibi/0": "rewrite", "blackwood/alibi/2": "good"},
 "picks": {},
 "rewrites": {},
 "judge": {}}
```

`verdicts` values are `good`, `bad` or `rewrite`. In pick mode (`--rerun`),
`picks` holds which candidate index won.

### `JudgePackets/packet_NNN.json`

A batch of replies sent out for judging, as a JSON array. Each entry carries
enough context to judge without the game open:

```json
{"id": "blackwood/alibi/0",
 "character": "Evelyn",
 "who": "Dr. Evelyn Blackwood, Forensic Pathologist, found in the Library",
 "trait_to_protect": "clinical detachment...",
 "what_failure_looks_like": "squeamishness, warmth, a disclaimer...",
 "their_secret": "...",
 "group": "alibi",
 "question": "...",
 "reply": "...",
 "auto_flags": [],
 "source_file": "..."}
```

`trait_to_protect` and `what_failure_looks_like` are the interesting fields.
They exist because judging a reply requires knowing what this specific
character was supposed to sound like, and a judge working from the reply alone
marks everything polite as good.

### `JudgePackets/verdicts_NNN.json`

The answers, as a JSON array.

```json
{"id": "blackwood/alibi/0",
 "verdict": "reject",
 "reason": "Generic alibi with none of her voice, and a lady guest cooking her own breakfast in a staffed manor is off for the period.",
 "suggested": "In the Lounge, with the papers. When the shouting started I went up...",
 "confidence": "high"}
```

Applied by `Training/apply_judge.py`.

### `RewritePackets/rewrite_<id>.json`

Same shape as a judge packet, batched per character, for rewriting a
character's replies wholesale rather than judging them one at a time. Results
land in `RewritePackets/results/` and are applied by
`Training/apply_rewrites.py`.

### Root-level `sft.jsonl`, `dpo.jsonl`, `dpo_needs_chosen.jsonl`

Output of `build_dataset.py`. The merged, ready-to-train files. They stay at
the project root because the Colab notebook and the whole training manual
reference them by that exact name.

### `Training/reports/`

`eval_report.md` from `eval.py`, `probe_c.md` from `probe_c.py`, plus
`probe_A.md` and `probe_B.md` kept from earlier runs for comparison.

---

## 5. What is in git and what is not

Everything in `.gitignore` is there deliberately. The reasons, in the file's own
words: the harvests and datasets are hundreds of megabytes, the character
briefs give away every suspect's secret, the play logs print the murderer at the
top, and the model file is 2.1GB.

| Ignored | Why |
|---|---|
| `.godot/`, `.import/` | Godot cache, rebuilt automatically |
| `TrainingData/`, `sft.jsonl`, `dpo.jsonl`, `dpo_needs_chosen.jsonl` | size |
| `DialogueLogs/`, `JudgePackets/`, `RewritePackets/` | spoilers and size |
| `Training/Manual/`, `Training/PLAYBOOK.md`, `Training/RUNS.md` | character briefs |
| `Training/prompts.txt`, `Training/_probe_*.txt` | prompt bank |
| `Training/Modelfile/`, `*.gguf`, `Tools/ArchibaldModelfile*` | 2.1GB, and machine-specific absolute paths |
| `Training/reports/` | regenerated output |
| `_to_delete/` | scratch drawer |

**`.gitattributes` matters more than it looks.** `* text=auto` makes git store
text as LF and convert on the way in, so a CRLF working tree on Windows stops
showing up as a whole-repo diff. Without it, 65 files and about 17,000 lines of
pure line-ending churn drowned out 9 files of real changes. Binary types
(`.blend`, `.png`, `.gguf`, fonts, audio) are marked `binary` so git never
touches them.
