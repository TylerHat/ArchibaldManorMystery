# Running and debugging

Every key, every test scene, every log, and what to do when something is wrong.
Keep this one open on a second screen while you work.

---

## 1. Running the game

**F5** in the Godot editor runs the main scene, `Scenes/Main.tscn`.
**F6** runs whichever scene is currently open in the editor, which is how you
run the test harnesses.

Before you press either, **Ollama must be running**. Launch the Ollama app or
run `ollama serve` and leave the terminal open. Without it the world still
builds, you can still walk around, but every suspect answers with a clear error
message instead of a line of dialogue.

Keep the Godot **Output** panel visible. On startup the game prints the case
code, the murderer, the weapon and, if training capture is on, two file paths
and a running count. That console is half your debugging.

---

## 2. Every key

### Playing

| Key | Does |
|---|---|
| **W A S D** | walk |
| **Space** | jump |
| **Mouse** | look |
| **E** or **left click** | interact with whatever the crosshair is on |
| **Tab** | open / close case notes |
| **M** | open / close the manor map |
| **Esc** | release the mouse, or close whichever panel is open |

`Esc` closes panels in a fixed priority order: dialogue, group, accusation,
examine, map, notes. Tab and M refuse to open while any other panel is up.

### Typing at a suspect

These are not keys, they are things you type into the dialogue box, and they
are handled **locally by regular expressions**. They cost no AI thinking time
and the suspect does not answer them in character.

| You type | Effect |
|---|---|
| `go to the library` / `wait in the study` | that suspect walks there through the doorways |
| `(slides the photograph across)` | round brackets mean a physical action, not speech. Rendered in italics, and reacted to as a real event |
| `Marcus, be quiet` | in a Hall meetup: drops him from the rotation. He still hears everything |
| `Marcus, go ahead` | restores him and gives him the floor now |
| `Everyone be quiet except Marcus` | silences the room but one |
| `Everyone may speak` | clears the mute list |
| `Marcus, leave` | sends him back to his own room |

A line containing a question mark is always treated as a question, so
"Marcus, why were you so quiet last night?" asks him rather than silencing him.

### Developer keys

All of these live behind `GameManager.DEBUG_KEYS`. Set that constant to `false`
and the actions are never registered, so the keys do nothing at all. There is
no hidden binding left in a shipped build.

| Key | Does |
|---|---|
| **Ctrl+1** | Toggle the truth overlay: murderer, weapon and its home room, the lie being told, who can disprove it, and every suspect's real movements slot by slot |
| **Ctrl+2** | Toggle group prompt dump. The next line spoken in a Hall meetup prints its entire message payload to the console, with each message's distance from the generation point |
| **Ctrl+3** | Export the active characters' system prompts to a JSON file, for the training harvest |
| **F9** | Keep the reply currently on screen as a good example. Writes to the SFT file |
| **F10** | Reject it. Writes to the DPO file with an empty `chosen` for you to fill in later |

**Ctrl+1 is the single most useful thing in this list.** Almost every check you
will ever run is "does what the game just said match what Ctrl+1 says". If a
suspect gives an alibi that contradicts the overlay, that is a real bug. If two
suspects contradict each other and the overlay says one of them is the
murderer, the game is working.

---

## 3. The test scenes

Three scenes in `Scenes/` are not part of the game. Open one and press **F6**.
They print to the Output panel and none of them build a mansion.

### `CaseGeneratorTest.tscn`

The important one. Builds **1,000 complete cases** and asserts every design
rule on each of them, then prints distribution statistics and dumps three full
sample cases including the schedule text each suspect would be given.

Expect `1000/1000 valid`. It also checks:

- every character's `slot` number is unique
- a 200-case encode and decode round trip of case codes
- that a code referencing a retired slot is actually rejected

**Run this after any change to `CaseGenerator.gd`, to `CHARACTERS`, or to
anything touching case codes.** It takes seconds and it is the only thing
standing between you and a silently unsolvable mystery.

### `GuardTest.tscn`

Regression tests for the reply guard, the code that inspects a suspect's answer
before it reaches the screen. Run it after touching `_reply_breaks_character()`
or any of its keyword lists.

The guard's failure modes are asymmetric. A guard that is too loose lets a
suspect announce the murderer and end the game wrongly. A guard that is too
tight rejects good drama, retries constantly and makes everything slow. The
tests cover both directions.

### `DialogueOptTest.tscn`

23 checks covering the dialogue memory and performance work: history
compaction, the token budget, the recap, scene rendering for group turns. Run
it after touching history handling in `GameManager` or `GroupChat`.

---

## 3b. The documentation checker

Not a Godot scene, but it belongs in the same habit:

```bash
python Tools/check_docs.py
```

Runs in under a second with no dependencies. It fails if a document links to a
file that does not exist, if a document fell out of the index, if a `res://`
path no longer resolves, if a script is missing from the architecture guide, or
if a constant's value quoted in a document no longer matches the source.

Run it whenever you move a file, rename a folder or change a documented
constant. The rule it enforces is
[`../rules/00-documentation-is-part-of-every-change.md`](../rules/00-documentation-is-part-of-every-change.md).

---

## 4. Reading the logs

### The dialogue log

On the selection screen, tick the **dialogue log** checkbox before you start.
Every line every suspect says is then written to a markdown file in
`DialogueLogs/`.

The file is worth understanding because it is designed to be read weeks later
with the game closed:

- the **case code** at the top, so you can replay the exact mystery
- the **ground truth table**: every suspect's real movements slot by slot
- each suspect's **actual briefing** in their section header
- the **full timeline** at the end, in the order things happened

That third point is the one that makes it useful. A reply can only be judged a
hallucination against what that character was actually told. "Marcus threatened
me" is a bug if the two never shared a scene, and perfectly good play if they
did. Without the briefing in the file you cannot tell the difference.

The file is rewritten in full on every new line, not appended to, so it is
always complete even if the game is closed mid-session.

### The training capture

The same checkbox turns on training capture. It writes
`TrainingData/sft_*.jsonl` and `TrainingData/dpo_*.jsonl` alongside the log.
See [`08-ai-training-and-tuning.md`](08-ai-training-and-tuning.md).

### Ollama's own log

On Windows: `%LOCALAPPDATA%\Ollama\server.log`. This is where you find out
whether the model reloaded (which costs about 60 seconds on the hardware this
was tuned for), what context size it actually chose, and how many slots it has.

---

## 5. When something is wrong

### Every suspect answers with an error

Ollama is not running, or the model named in `GameManager.OLLAMA_MODEL` is not
installed. Check with:

```bash
ollama list
```

If `archibald-suspect:v1` is not there, either build it (see guide 08) or point
`OLLAMA_MODEL` at a stock model you do have.

On Windows, if Ollama is in a restart loop, run `Tools/Fix_Ollama.ps1` with
PowerShell, **not** as administrator.

### Everything is suddenly very slow

Usually the model got evicted from VRAM and is being reloaded on every
question. `OLLAMA_KEEP_ALIVE` is set to `30m` and sent with every request
precisely to prevent this, so if it is happening, check the Ollama server log
for reload lines and check `n_slots` reads 4.

A Hall meetup is *legitimately* slower than a private interview: it costs one
sequential request per attendee for every line you say. Two attendees means
double. That is why the Hall holds only two and a third refuses in character.

### A suspect has forgotten something

Press **Ctrl+2** and say another line in the meetup. The console prints the
whole payload that was sent. That tells you immediately which of the two
problems you have:

- the information is **missing from the payload**, which is a bug in prompt
  construction
- the information is **present but far from the generation point**, which is a
  prompting problem and needs the ordering changed, not the data

### A suspect invented a room, a person or an event

Check the dialogue log's ground truth table first. If the claim contradicts
their own briefing, that is a model failure worth capturing with **F10** for the
training set. If the claim is consistent with what they were told, the game is
working and your expectation was wrong.

Note that suspects **lie**. Exactly one person in the house is lying, about
exactly one half-hour block. Do not report a lie as a bug, and do not press F10
on one, or you will train the lying out of a murder mystery.

### The mansion looks wrong, or you can see through corners

That is geometry. Read the `WALL_SPAN` comment at the top of `Main.gd`, which
documents the corner-gap bug and its fix, then
[`04-the-manor-and-world.md`](04-the-manor-and-world.md).

### Godot says an identifier is not declared, on a fresh clone

Almost certainly the `class_name` scan-order race described in
[`02-godot-features.md`](02-godot-features.md) section 6. Reopen the project.
If you added a new shared script with a `class_name`, switch it to `preload`.

### Suspects are all colored capsules

Blender is not installed, so Godot could not import the `.blend` files. Install
Blender and reimport, or carry on: capsules are a fully supported fallback and
the game plays identically.

---

## 6. Reproducing a specific bug

Use the case code. Every game prints one at startup, shows it in the Ctrl+1
overlay, prints it at the top of the dialogue log, and displays it on the
selection screen after the game ends.

Paste it into the **Case code** box on the selection screen and you get that
exact mystery back: same murderer, same schedules, same weapon, same dropped
item. It also re-ticks the suspect boxes for you, because the code carries the
cast as well as the seed.

That last part is not cosmetic. The generator draws every decision from one
random number generator, so the same seed with a different cast produces a
completely different mystery. A seed alone would look reproducible and quietly
not be.

**So: a bug report for this project should always include the case code.**
