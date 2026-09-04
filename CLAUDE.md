# CLAUDE.md

Entry point for Claude, and for any other assistant or contributor working in
this repository. Read this first, every session, before touching anything.

---

## THE RULE

**Documentation is part of every change. A change is not finished until the
documentation is correct.**

This is the highest-priority rule in the repository. It outranks finishing
quickly, it outranks a clean diff, and it applies to every change including
one-line ones.

Concretely, on **every** task in this repo:

1. **Before changing anything**, read [`.claude/README.md`](.claude/README.md).
   It is the index of every document in `.claude/`, and it tells you which ones
   cover the area you are about to touch. Then read those documents.
2. **While changing things**, keep a list of what you touched.
3. **Before declaring the work done**, update every document that your change
   made wrong, in the same commit as the change itself. The map of which
   documents cover which code is in
   [`.claude/rules/00-documentation-is-part-of-every-change.md`](.claude/rules/00-documentation-is-part-of-every-change.md).
4. **Verify it**, by running:

   ```bash
   python Tools/check_docs.py
   ```

   It must report `ALL CHECKS PASSED`. If it does not, the change is not
   finished.

If you find documentation that was already wrong before you arrived, fix it.
Do not leave a known error in place because you did not cause it.

If a change makes a document obsolete rather than merely inaccurate, supersede
it rather than deleting it. See
[`.claude/rules/04-documentation.md`](.claude/rules/04-documentation.md).

### Why this matters here more than usual

Almost nothing in this project fails loudly. A reused character slot silently
repoints every case code at the wrong cast. A context-window overflow silently
evicts the system prompt and suspects start improvising alibis again. A
loosened validation rule silently ships an unsolvable mystery.

The documentation in `.claude/` is where the reasoning behind those decisions
lives, and much of it exists nowhere else. When it goes stale, the next person
does not get a compile error. They get a plausible-looking change that breaks
something a week later. **The documents are load-bearing.**

---

## What this project is

A 3D first-person murder mystery in **Godot 4.7**. Suspects are played by a
local language model through Ollama, and every playthrough generates its own
murder with a provably solvable set of alibis.

If you have never worked on it, read
[`.claude/guides/00-start-here.md`](.claude/guides/00-start-here.md) before
anything else.

---

## The `.claude` folder

Everything written about the project. Full index with descriptions:
[`.claude/README.md`](.claude/README.md).

### `.claude/guides/`, how it works

| Doc | Covers |
|---|---|
| [`00-start-here.md`](.claude/guides/00-start-here.md) | Setup, first run, and a reading order per task |
| [`01-architecture.md`](.claude/guides/01-architecture.md) | The whole system, then file by file |
| [`02-godot-features.md`](.claude/guides/02-godot-features.md) | Every Godot concept used here, from zero |
| [`03-running-and-debugging.md`](.claude/guides/03-running-and-debugging.md) | Keys, test scenes, logs, what to do when it breaks |
| [`04-the-manor-and-world.md`](.claude/guides/04-the-manor-and-world.md) | Grid, walls, furniture, crime scene, NPC movement |
| [`05-the-dialogue-system.md`](.claude/guides/05-the-dialogue-system.md) | Prompts, memory, the reply guard, the queue, Hall meetups |
| [`06-the-case-generator.md`](.claude/guides/06-the-case-generator.md) | How a solvable murder is generated and validated |
| [`07-adding-a-character.md`](.claude/guides/07-adding-a-character.md) | Adding a suspect without breaking case codes |
| [`08-ai-training-and-tuning.md`](.claude/guides/08-ai-training-and-tuning.md) | Ollama, the fine-tune, collecting data, measuring |
| [`09-ui-and-case-notes.md`](.claude/guides/09-ui-and-case-notes.md) | Every panel, and why the UI is built in code |
| [`10-data-and-file-formats.md`](.claude/guides/10-data-and-file-formats.md) | Every file format read or written, field by field |
| [`11-glossary.md`](.claude/guides/11-glossary.md) | Plain-English definitions for every term used |

### `.claude/rules/`, how to work on it

| Doc | Covers |
|---|---|
| [`00-documentation-is-part-of-every-change.md`](.claude/rules/00-documentation-is-part-of-every-change.md) | **The rule above, in full, with the code-to-doc map** |
| [`01-gdscript-style.md`](.claude/rules/01-gdscript-style.md) | How code here is written and commented |
| [`02-project-invariants.md`](.claude/rules/02-project-invariants.md) | The nine things that must never break |
| [`03-git-workflow.md`](.claude/rules/03-git-workflow.md) | Branch, commit, PR, and two Windows traps |
| [`04-documentation.md`](.claude/rules/04-documentation.md) | Where a document goes and what it must contain |
| [`05-ai-assistant-rules.md`](.claude/rules/05-ai-assistant-rules.md) | Ground rules when an assistant edits this repo |

### `.claude/reference/`, `.claude/plans/`, `.claude/testing/`

Subsystem deep dives, design documents written before the work, and manual test
scripts. Listed in [`.claude/README.md`](.claude/README.md).

---

## Before you open a pull request

Open it against **`staging`**, not `main`. See
[`.claude/rules/03-git-workflow.md`](.claude/rules/03-git-workflow.md) for the
branch model.

- [ ] `python Tools/check_docs.py` reports `ALL CHECKS PASSED`
- [ ] Touched `CaseGenerator.gd`, `CHARACTERS` or case codes?
      Run `Scenes/CaseGeneratorTest.tscn` (F6), expect **1000/1000 valid**
- [ ] Touched the reply guard or its keyword lists?
      Run `Scenes/GuardTest.tscn` (F6)
- [ ] Touched history handling or group prompts?
      Run `Scenes/DialogueOptTest.tscn` (F6)
- [ ] Changed a tuned constant? The comment above it now says what was measured
      to justify the new value
- [ ] Every document your change made wrong is fixed, in this same commit

The full invariant list is in
[`.claude/rules/02-project-invariants.md`](.claude/rules/02-project-invariants.md).

---

## Quick facts

| | |
|---|---|
| Engine | Godot 4.7, plain build, not .NET |
| Language | GDScript for the game, Python for the training tools |
| Main scene | `Scenes/Main.tscn` |
| Autoload | `GameManager` = `res://Scripts/GameManager.gd` |
| Model | `archibald-suspect:v1` via Ollama at `127.0.0.1:11434` |
| Doc checker | `python Tools/check_docs.py` |
| Branches | Work goes to `staging`. `main` is the stable pre-AI-training line |

**Ollama must be running before you press Play.** On Windows, if it misbehaves,
run `Tools/Fix_Ollama.ps1` with PowerShell, not as administrator.

One thing that will confuse you: git recorded the code folder as `scripts/`
in lowercase while your editor shows `Scripts/`. They are the same file on
Windows. Do not try to fix it with a rename. See
[`.claude/rules/03-git-workflow.md`](.claude/rules/03-git-workflow.md).
