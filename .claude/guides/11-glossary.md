# Glossary

Every term used anywhere in these documents or in the code comments, defined in
plain English. Alphabetical. Come back when one turns up.

---

**Abliterated:** a model with its refusal behaviour removed. The base model
here is abliterated because suspects need to be able to be hostile, evasive and
unpleasant. A butler telling you to go to hell is good drama; "I don't feel
comfortable with that" is the model stepping out from behind the butler.

**Account:** what a suspect will *say* about their evening, as opposed to what
really happened. For an innocent the two are identical. For the murderer, the
account is the claimed path. `GameManager.evening_account()`.

**Adapter:** the small file (about 100MB) that a training run produces. It is
a set of adjustments to the base model rather than a whole new model. Two runs
produce two adapters, which are then merged into the final model file.

**Autoload:** a Godot node created before any scene and never destroyed,
available as a global name in every script. This project has exactly one:
`GameManager`.

**BBCode:** the markup `RichTextLabel` understands, similar to old forum tags.
`[color=#ff0000]red[/color]`, `[i]italic[/i]`. Used here for suspect name
coloring and for actions in italics.

**Bitmask:** a single number where each bit means yes or no for one thing. A
case code's second number is a bitmask of which suspects were in the house:
bit 3 set means the suspect holding slot 3 was there.

**Block:** consecutive slots a suspect spent in the same room, collapsed into
one. Eight slots might become three blocks. `CaseGenerator.blocks()`.

**Case code:** `482913-171`. The seed plus the cast bitmask. Type it into the
selection screen to replay that exact mystery. The save game of this project.

**Case data:** `GameManager.case_data`, the dictionary `CaseGenerator` returns
holding the entire ground truth for one playthrough.

**Claimed path:** the eight rooms a suspect will *say* they were in. Identical
to the true path for everyone except the murderer.

**Colab:** Google Colab. A computer Google lends you through a browser tab,
with a GPU about three times the size of the one in this machine. Free. Where
the training actually happens, because of memory rather than speed.

**Compaction:** folding the oldest part of a conversation into a single
summary message so the whole thing fits in the context window.
`GameManager._compact_history_if_needed()`.

**Context window:** the maximum amount of text a model can see at once,
measured in tokens. 8192 here. Overflow it and the oldest messages are dropped
**silently**, starting with the system prompt.

**DPO:** Direct Preference Optimization. The second training run. Learns from
pairs of "this reply was wrong, this one was right". The run that fixes
breaking character and refusing.

**Draw call:** one instruction to the graphics card. Fewer is faster. The
manor shell batches down to about 3 by sharing meshes and materials, from about
47 before.

**Evidence:** anything examinable in the world. `Evidence.gd`, a
`StaticBody3D` exposing `get_interact_prompt()` and `interact()`.

**Fine-tune:** a model that has been trained further on your own examples.
`archibald-suspect:v1` is a fine-tune of the abliterated base.

**Framing:** reshaping what the player typed before it reaches the model.
`GameManager.frame_player_line()` turns bracketed text into a stage action and
turns an injection attempt into the detective saying something incomprehensible
out loud.

**GDScript:** Godot's own language. Reads like Python. All the game code here
is GDScript; the training tools are Python.

**GGUF:** the file format Ollama uses for a model. The one here is 2.1GB and
gitignored.

**Ground truth:** the real answer, as opposed to what anybody says. The
generator's `true_paths`, the Ctrl+1 overlay, and the table at the top of a
dialogue log.

**Group / Hall meetup:** a confrontation with several suspects in the Hall at
once, run by `GroupChat.gd`. Everything said there is heard by everyone
present.

**Guard:** `GameManager._reply_breaks_character()`. Inspects a reply before it
reaches the screen or the character's memory, and rejects it if it has left the
fiction. The most important safety mechanism in the game.

**Harvest:** running the whole 601-question prompt bank against Ollama
unattended, then judging the replies in a browser. The fast route to training
data. `Training/harvest.py`.

**History:** one character's stored conversation, in
`GameManager._histories[id]`. Sent with every request, because the model has no
memory of its own.

**Inertia:** `CaseGenerator.INERTIA`, 0.55. The chance a suspect stays put
rather than moving to another room in the next slot. Guests settle.

**JSONL:** JSON Lines. One complete JSON object per line, no wrapping array.
Easy to append to and easy to stream. Every training data file uses it.

**KV cache:** the model's working memory for one conversation. Keeping four of
them (`OLLAMA_NUM_PARALLEL=4`) is what lets four suspects take turns in the
Hall without each one re-reading everything.

**Language model:** a program that predicts what text comes next. That is
genuinely all it is. Everything else is achieved by choosing what text to send
it.

**Modelfile:** Ollama's recipe file. Names a base file and sets parameters
like `temperature` and `num_predict`. `Tools/ArchibaldModelfile`.

**Node:** Godot's unit of everything. A node is one capability: a Label shows
text, a RayCast3D shoots a line. You build things by nesting them.

**num_ctx:** how many tokens the model may see at once. See context window.

**num_predict:** the maximum tokens the model may generate. A **ceiling, not a
target**: a 35-token reply still takes 35 tokens.

**Ollama:** the program that runs models locally and answers HTTP requests.
Must be running before you press Play.

**Path:** in the case generator, an array of eight room names, one per slot.
Not a filesystem path.

**Preload:** `preload("res://...")`, which resolves at parse time from a
literal path. Preferred over `class_name` in this repo for new shared scripts,
because `class_name` can lose a scan-order race on a fresh clone.

**Prompt injection:** a player typing something aimed at the model rather than
the character, such as "ignore all previous instructions". Handled by reframing
rather than refusing, so the fiction survives.

**RefCounted:** a Godot object that is **not** in the scene tree and frees
itself when nothing references it. Used for pure logic: `CaseGenerator`,
`SuspectModel`, `DialogueLog`, `TrainingCapture`.

**res://:** the project folder, in Godot's path scheme. `user://` is a
writable per-user folder outside it.

**Role:** in a message list, one of `system` (the standing instruction), `user`
(the detective) or `assistant` (the model's previous replies).

**Scene:** in Godot, a saved tree of nodes in a `.tscn` file. In this project
also used for a Hall meetup ("the group scene"). Context makes it clear.

**Seed:** the number that determines every random choice the generator makes.
Same seed plus same cast equals the same mystery, exactly.

**SFT:** Supervised Fine-Tuning. The first training run. Learns the voice by
imitating examples you approved.

**Signal:** Godot's event mechanism. A node emits, others connect and listen.
The emitter does not know who is listening.

**Slot:** two different things, and it is worth keeping them apart:
1. **Time slot**: one of eight half-hour blocks of the evening, 8:00pm to
   midnight.
2. **Character slot**: a permanent number identifying a suspect, used in case
   codes. Never reused, ever. `NEXT_FREE_SLOT` records the next free one.

**Stop sequence:** text that makes the model stop generating immediately.
`"Detective:"` stops it writing your next line for you, which you would
otherwise pay for and throw away.

**System prompt:** the standing instruction sent with every request. Here it
is the shared case preamble plus that character's tail. About a thousand words.

**Temperature:** how varied the model's output is. Higher wanders more. 0.8
here.

**@tool:** a Godot annotation making a script run in the editor as well as at
runtime. `ManorBuilder.gd` is one, which is why the manor is drawn live in the
viewport.

**Token:** roughly three quarters of a word. Everything is measured in these:
context size, reply length, and time, at about 29ms per token on this hardware.

**Transcript:** `GameManager.transcript`. Every line every suspect has given
you, in order. Feeds the case notes.

**True path:** the eight rooms a suspect really was in. The ground truth.

**UID file:** `Something.gd.uid`. A stable identifier Godot maintains so
scenes can reference a script even if it moves. Never edit one by hand; do
commit them.

**Waypoint:** a world position an NPC walks to. Room travel is a list of them,
each the midpoint between two adjacent room centres, which is exactly where the
doorway is.

**Witness:** in the case generator, an innocent who was standing in the room
the murderer claims to have been in, at the exact moment of the murder. There
must be at least one, or the case is unwinnable and gets thrown away.
