# Start here

You have just been handed Archibald Manor. This document gets it running, tells
you in one page what it actually is, and then points you at the right guide for
whatever you have been asked to do.

Budget about twenty minutes for the setup and another twenty for the first
playthrough. Do play it once before you change anything. Almost every design
decision in the code makes sense only after you have stood in a room and asked
a suspect where they were at half past ten.

---

## 1. What this project is, in one page

It is a **3D first-person murder mystery** built in **Godot 4.7**. You are a
detective. Lord Reginald Archibald has been killed in his own manor and one of
the guests did it. You walk around a nine-room mansion, question people, catch
somebody in a lie, and accuse them at the front door.

Three things make it unusual, and all three are why the codebase looks the way
it does.

**The suspects are a language model.** Every answer a suspect gives is
generated at runtime by a small AI model running on your own machine through a
program called Ollama. Nothing is scripted. There is no dialogue tree anywhere
in this repo. When you type "where were you at eleven", the game builds a block
of instructions describing who that character is, sends it plus your question
to the model, and prints whatever comes back. See
[`05-the-dialogue-system.md`](05-the-dialogue-system.md).

**The murder is generated, not authored.** Every launch, a piece of pure logic
called `CaseGenerator` invents the whole evening: who died where, with what,
at what time, and exactly which room each of the eight guests was standing in
for each of eight half-hour slots. It then *proves* the result is solvable
before handing it to the game. If it cannot prove it, it throws the case away
and rolls again. See [`06-the-case-generator.md`](06-the-case-generator.md).

**Almost nothing is built in the Godot editor.** The mansion, every UI panel,
every suspect and the entire crime scene are created in code when the game
starts. `Scenes/Main.tscn` is nearly empty. This is deliberate: the whole game
is readable as text files in a diff. See
[`01-architecture.md`](01-architecture.md).

The interesting consequence of the first two together: because the game holds
the real timeline, and every innocent recites theirs honestly, a contradiction
between two suspects *means something*. Before the generator existed, everyone
was improvising and two conflicting stories told you nothing at all.

---

## 2. Getting it running

### 2.1 Install Godot

Download **Godot 4.7**, the standard build, from <https://godotengine.org>. It
is a single executable, there is no installer and nothing is written to your
system. Put it wherever you keep tools.

You want the plain version, not the ".NET" / C# one. This project is pure
GDScript.

### 2.2 Install Ollama and pull a model

Ollama is the program that runs the AI model locally on your machine. Get it
from <https://ollama.com> and install it.

Then, in a terminal:

```bash
ollama pull llama3.2:3b
```

That downloads about 2GB. This is the *stock* model, and it is enough to see
the game work. The version the project actually ships against is a fine-tune
called `archibald-suspect:v1` that only exists on machines that built it, which
is covered in [`08-ai-training-and-tuning.md`](08-ai-training-and-tuning.md).

If you only have the stock model, open `Scripts/GameManager.gd`, find
`OLLAMA_MODEL` near the top, and point it at `llama3.2:3b`. The line directly
above it is the abliterated base and is commented out ready to swap in.

**Ollama must be running before you press Play.** Either launch the Ollama app,
or run `ollama serve` in a terminal and leave it open. The game talks to it at
`http://127.0.0.1:11434/api/chat`. If it cannot reach it, the dialogue box says
so in plain words rather than failing silently.

On Windows, if Ollama is misbehaving (restart loops, everything suddenly slow),
right-click `Tools/Fix_Ollama.ps1` and choose **Run with PowerShell**. Not as
administrator; running it elevated is what caused the original problem.

### 2.3 Open the project

Launch Godot, click **Import**, and select `project.godot` in this folder.

The first import takes a minute or two. Godot is scanning every `.blend` file
in `Models/` and converting it into something it can render. That produces the
`.godot/` folder, which is a cache and is gitignored. Deleting it is always
safe; Godot rebuilds it.

**Blender must be installed for the `.blend` files to import.** Godot shells
out to it. If you do not have Blender, the models silently fail to import and
every suspect falls back to being a colored capsule, which is a perfectly
playable state, just an uglier one.

### 2.4 Press Play

**F5** runs the game. You should get, in order:

1. A **suspect-selection screen**. Eight of the twelve suspects are already
   ticked at random. Press **Start**.
2. The mansion, built in front of you, and a first-person view.

Walk with **WASD**, look with the mouse, and press **E** on a suspect to talk
to them. Press **Ctrl+1** at any time for a debug overlay that tells you who
the murderer is and prints the entire true timeline, which is how you check the
game against itself.

The full key list is in
[`03-running-and-debugging.md`](03-running-and-debugging.md).

### 2.5 If nothing happens when you press Play

Check the **Output** panel at the bottom of the Godot editor. The game prints a
great deal on startup, including the murderer, the case code, and any error.
Nearly every first-run problem is one of three things: Ollama is not running,
Godot is not 4.7, or Blender is missing so the models did not import.

---

## 3. The five-minute tour of the folders

```
ArchibaldManorMystery/
├─ project.godot        Godot's project file. Autoloads, window size, main scene.
├─ README.md            Player-facing description of the game.
├─ TODO.md              Live list of design ideas, rules and features only.
│
├─ Scripts/             ALL the game code. 17 GDScript files. Start with Main.gd.
├─ Scenes/              Four .tscn files, three of which are test harnesses.
├─ Models/              3D assets: Furniture/, Suspects/<id>/, Victim/.
├─ Objects/  Sprites/   Empty, reserved.
│
├─ CLAUDE.md            Entry point. The rules an assistant must follow here.
├─ .claude/             Every document about the project. You are here.
├─ Tools/               Helper scripts that are not part of the game.
├─ Training/            The AI fine-tuning pipeline. Python, not GDScript.
│
├─ TrainingData/        Generated. Captured play data.
├─ DialogueLogs/        Generated. Markdown transcripts of play sessions.
├─ JudgePackets/        Generated. Batches of replies awaiting judgement.
├─ RewritePackets/      Generated. Character-rewrite work packets.
└─ _to_delete/          Scratch drawer. Safe to empty, nothing reads it.
```

Everything from `TrainingData/` down is gitignored. So is `Training/Manual/`,
`Training/PLAYBOOK.md` and `Tools/ArchibaldModelfile*`, because the character
briefings in them give away the whole roster's secrets and the model file is
2.1GB.

---

## 4. Which guide to read next

Find the job closest to yours.

**Before any of these, read [`../../CLAUDE.md`](../../CLAUDE.md) and
[`../rules/00-documentation-is-part-of-every-change.md`](../rules/00-documentation-is-part-of-every-change.md).**
The rule in this repository is that documentation is part of every change, and
the second document carries the map of which documents your change will affect.

| You have been asked to... | Read, in this order |
|---|---|
| Understand the whole thing | [`01`](01-architecture.md), then [`02`](02-godot-features.md), then [`05`](05-the-dialogue-system.md) |
| Add or edit a suspect | [`07`](07-adding-a-character.md), then [`05`](05-the-dialogue-system.md) |
| Change how suspects talk | [`05`](05-the-dialogue-system.md), then [`08`](08-ai-training-and-tuning.md) |
| Make the model better | [`08`](08-ai-training-and-tuning.md), then `Training/PLAYBOOK.md` |
| Change the mystery rules | [`06`](06-the-case-generator.md), then [`../plans/procedural-cases.md`](../plans/procedural-cases.md) |
| Change rooms, walls or furniture | [`04`](04-the-manor-and-world.md), then [`../reference/manor-builder.md`](../reference/manor-builder.md) |
| Change a menu or panel | [`09`](09-ui-and-case-notes.md) |
| Fix a bug | [`03`](03-running-and-debugging.md), then whichever area above |
| Learn Godot itself | [`02`](02-godot-features.md) |

And before you open a pull request, read
[`../rules/02-project-invariants.md`](../rules/02-project-invariants.md). It is
short and it lists the handful of things in this codebase that fail *silently*
when broken, which is the only category of bug here that is genuinely expensive.

Then run:

```bash
python Tools/check_docs.py
```

It must print `ALL CHECKS PASSED`. That is how this repo keeps its
documentation honest.

---

## 5. Three things that will confuse you on day one

**The `Scripts` folder is `scripts` in git.** Git recorded the folder in
lowercase early on, and Windows does not care about case, so `git status` will
show you `scripts/GameManager.gd` while your editor shows `Scripts/`. They are
the same file. Do not "fix" it with a rename; on a case-insensitive filesystem
that produces a mess. Just read past it.

**Some documents are deliberately not on GitHub.** `Training/Manual/`,
`Training/PLAYBOOK.md` and everything under `TrainingData/` are gitignored on
purpose, not by accident. If a guide references a document you do not have, ask
whoever handed you the repo to send it directly.

**One document is marked SUPERSEDED and means it.**
`.claude/reference/build-gui-geometry-superseded.md` walks you through placing
37 walls by hand in the editor. Do not do it. `Scripts/ManorBuilder.gd`
generates exactly the same geometry from a spec. The file is kept only for its
wall-size tables.
