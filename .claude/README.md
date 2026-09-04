# The `.claude` folder

Everything written *about* this project lives here. Code lives in `Scripts/`,
scenes in `Scenes/`, art in `Models/`. Nothing in this folder is loaded by the
game, so you can move, rename or rewrite anything here without touching a
single line of what runs.

**This file is the index.** The rule in
[`../CLAUDE.md`](../CLAUDE.md) is that it gets read at the start of every
session and before any change, so that whoever is working knows which documents
their change is about to make wrong.

> **Documentation is part of every change.** A change is not finished until the
> documentation is correct, in the same commit. The rule, and the map of which
> documents cover which code, is
> [`rules/00-documentation-is-part-of-every-change.md`](rules/00-documentation-is-part-of-every-change.md).
> Verify with `python Tools/check_docs.py`.

## Who this is for

Someone who has just been handed the repo. It assumes you can program, and
assumes nothing else. You do not need to have used Godot, you do not need to
know what a language model is, and you do not need to have played the game.

## Where to start

Read [`../CLAUDE.md`](../CLAUDE.md) first, then
[`guides/00-start-here.md`](guides/00-start-here.md). The second gets the game
running on your machine in about twenty minutes and then tells you which of the
other guides to read for the job you have been given.

## What is in here

### `guides/`, how the thing works

| Doc | What it covers |
|---|---|
| [`00-start-here.md`](guides/00-start-here.md) | Setup, first run, and a reading order per task |
| [`01-architecture.md`](guides/01-architecture.md) | The whole system in one picture, then file by file |
| [`02-godot-features.md`](guides/02-godot-features.md) | Every Godot concept this project uses, explained from zero |
| [`03-running-and-debugging.md`](guides/03-running-and-debugging.md) | Keys, test scenes, logs, and what to do when it breaks |
| [`04-the-manor-and-world.md`](guides/04-the-manor-and-world.md) | The 3x3 grid, walls, furniture, the crime scene, NPC movement |
| [`05-the-dialogue-system.md`](guides/05-the-dialogue-system.md) | Prompts, memory, the reply guard, the request queue, Hall meetups |
| [`06-the-case-generator.md`](guides/06-the-case-generator.md) | How a solvable murder is generated and validated every launch |
| [`07-adding-a-character.md`](guides/07-adding-a-character.md) | Adding a 13th suspect, start to finish, without breaking case codes |
| [`08-ai-training-and-tuning.md`](guides/08-ai-training-and-tuning.md) | Ollama, the fine-tune, collecting data, training, measuring |
| [`09-ui-and-case-notes.md`](guides/09-ui-and-case-notes.md) | Every panel, and why the UI is built in code rather than the editor |
| [`10-data-and-file-formats.md`](guides/10-data-and-file-formats.md) | Every file format the project reads or writes, field by field |
| [`11-glossary.md`](guides/11-glossary.md) | Plain-English definitions for every term used anywhere above |

### `rules/`, how to work on it

| Doc | What it covers |
|---|---|
| [`00-documentation-is-part-of-every-change.md`](rules/00-documentation-is-part-of-every-change.md) | **The top rule.** Documentation must always be correct, with the code-to-doc map |
| [`01-gdscript-style.md`](rules/01-gdscript-style.md) | How code in this repo is written and commented |
| [`02-project-invariants.md`](rules/02-project-invariants.md) | The nine things that must never break, and what happens if they do |
| [`03-git-workflow.md`](rules/03-git-workflow.md) | Branch, commit, PR, and the two Windows traps in this repo |
| [`04-documentation.md`](rules/04-documentation.md) | Where a new document goes and what it has to contain |
| [`05-ai-assistant-rules.md`](rules/05-ai-assistant-rules.md) | Ground rules when Claude or another assistant edits this repo |

### `reference/`, deep dives on one subsystem

| Doc | Status |
|---|---|
| [`manor-builder.md`](reference/manor-builder.md) | Current. Setup and spec format for the `@tool` manor generator |
| [`build-gui-geometry-superseded.md`](reference/build-gui-geometry-superseded.md) | Superseded. Kept for the wall-size tables only |

### `plans/`, design documents written before the work

| Doc | Status |
|---|---|
| [`procedural-cases.md`](plans/procedural-cases.md) | Phases 1 to 5, all shipped. Still the spec for how cases work |
| [`dialogue-optimization-technical.md`](plans/dialogue-optimization-technical.md) | Measured latency review, all eight recommendations applied |
| [`dialogue-optimization-plain-english.md`](plans/dialogue-optimization-plain-english.md) | The same findings with every term explained |
| [`dialogue-optimization-changes.md`](plans/dialogue-optimization-changes.md) | What was actually changed, and how it was verified |

### `testing/`, manual test scripts

| Doc | What it covers |
|---|---|
| [`phases-2-3-test-script.md`](testing/phases-2-3-test-script.md) | Hand-run checklist for the schedule and crime-scene work |

## Where everything moved

If you have an older clone, a bookmark or a search result pointing at one of
these, this is where it went.

| Was | Is now |
|---|---|
| `MANOR_BUILDER.md` | `.claude/reference/manor-builder.md` |
| `BUILD_GUI_Geometry.md` | `.claude/reference/build-gui-geometry-superseded.md` |
| `PLAN_ProceduralCases.md` | `.claude/plans/procedural-cases.md` |
| `PLAN_DialogueOptimization.md` | `.claude/plans/dialogue-optimization-technical.md` |
| `PLAN_DialogueOptimization_PlainEnglish.md` | `.claude/plans/dialogue-optimization-plain-english.md` |
| `CHANGES_DialogueOptimization.md` | `.claude/plans/dialogue-optimization-changes.md` |
| `TESTING_Phase2_3.md` | `.claude/testing/phases-2-3-test-script.md` |
| `GitCommands.md` | `.claude/rules/03-git-workflow.md` |
| `Fix_Ollama.ps1` | `Tools/Fix_Ollama.ps1` |
| `ArchibaldModelfile`, `ArchibaldModelfile_v11` | `Tools/` |
| `eval_report.md`, `probe_A.md`, `probe_B.md`, `probe_c.md` | `Training/reports/` |

`README.md` and `TODO.md` stayed at the root on purpose: the first is what
GitHub shows a visitor, and the second is the live idea list you want to trip
over rather than go looking for. `CLAUDE.md` joined them as the entry point an
assistant reads automatically.

The folder was called `Claude/` when these documents were first written and is
now `.claude/`. Every reference was updated with the rename, which is exactly
the kind of breakage `python Tools/check_docs.py` exists to catch.

`sft.jsonl`, `dpo.jsonl` and `dpo_needs_chosen.jsonl` also stayed at the root.
They are outputs of `Training/build_dataset.py` and the Colab notebook picks
them up by that exact name, so moving them would mean rewriting the training
manual and the notebook for no gain. They are gitignored.
