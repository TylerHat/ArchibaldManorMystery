# Documentation is part of every change

**The highest-priority rule in this repository.** A change is not finished
until the documentation is correct.

It outranks finishing quickly and it outranks a clean diff. It applies to every
change, including one-line ones, and it applies whether the change was made by
a person or by an assistant.

---

## 1. The loop

Every task in this repo, without exception:

### Before you change anything

Read [`../README.md`](../README.md), the index of the `.claude` folder. It
lists every document and what each one covers. Then read the documents that
cover the area you are about to touch.

This is not a formality. Most of the reasoning in this project lives in these
documents and in the code comments, and nowhere else. A change made without
reading them is a change made without knowing why the current code is the way
it is.

### While you change things

Keep a list of what you touched. Files, constants, behaviours, file formats,
key bindings. You will need it in a moment.

### Before you say you are done

Walk your list against the map in section 3 and update every document your
change made wrong. **In the same commit as the change.** Not a follow-up
commit, not a to-do, not "I will do it after review".

A separate documentation commit is how documentation rots. The commit gets
deferred, then forgotten, and now the repo contains a document that confidently
describes something that is no longer true, which is worse than no document at
all.

### Then verify it

```bash
python Tools/check_docs.py
```

It must print `ALL CHECKS PASSED`. If it does not, you are not finished. The
checker is described in section 4.

---

## 2. Fix what was already wrong

If you find a document that was wrong before you arrived, fix it.

Do not leave a known error in place on the grounds that you did not cause it,
and do not open a ticket for it. The cost of correcting a stale sentence while
you are already reading the file is close to zero. The cost of the next person
believing it is not.

---

## 3. The map: which documents cover which code

Find every row that matches what you touched.

### Game code

| You changed | Update |
|---|---|
| `Scripts/GameManager.gd` roster (`CHARACTERS`, `NEXT_FREE_SLOT`) | [`../guides/07-adding-a-character.md`](../guides/07-adding-a-character.md), [`../guides/10-data-and-file-formats.md`](../guides/10-data-and-file-formats.md) §2, [`02-project-invariants.md`](02-project-invariants.md) §1 |
| `GameManager.gd` prompt building (`_shared_case_preamble`, `_build_character_tail`, `_schedule_recall`, `frame_player_line`) | [`../guides/05-the-dialogue-system.md`](../guides/05-the-dialogue-system.md) §3, §6 |
| `GameManager.gd` reply guard (`_reply_breaks_character` and its keyword lists) | [`../guides/05-the-dialogue-system.md`](../guides/05-the-dialogue-system.md) §5, [`02-project-invariants.md`](02-project-invariants.md) §4, [`../guides/07-adding-a-character.md`](../guides/07-adding-a-character.md) §6 |
| `GameManager.gd` request queue or history compaction | [`../guides/01-architecture.md`](../guides/01-architecture.md) §6, [`../guides/05-the-dialogue-system.md`](../guides/05-the-dialogue-system.md) §4, [`02-project-invariants.md`](02-project-invariants.md) §5 |
| `GameManager.gd` any tuned constant | [`../guides/05-the-dialogue-system.md`](../guides/05-the-dialogue-system.md) §9, and **the comment above the constant**, which must say what was measured |
| `GameManager.gd` case codes (`case_code`, `parse_case_code`) | [`../guides/06-the-case-generator.md`](../guides/06-the-case-generator.md) §10, [`../guides/03-running-and-debugging.md`](../guides/03-running-and-debugging.md) §6 |
| `Scripts/CaseGenerator.gd` anything | [`../guides/06-the-case-generator.md`](../guides/06-the-case-generator.md), [`../plans/procedural-cases.md`](../plans/procedural-cases.md), [`02-project-invariants.md`](02-project-invariants.md) §2, §3 |
| `Scripts/GroupChat.gd` | [`../guides/05-the-dialogue-system.md`](../guides/05-the-dialogue-system.md) §7, [`../guides/09-ui-and-case-notes.md`](../guides/09-ui-and-case-notes.md) §5 |
| `Scripts/Main.gd` world building, `GRID`, `CELL`, `PITCH`, `WALL_SPAN` | [`../guides/04-the-manor-and-world.md`](../guides/04-the-manor-and-world.md) §1, §2, [`02-project-invariants.md`](02-project-invariants.md) §6 |
| `Main.gd` any UI panel | [`../guides/09-ui-and-case-notes.md`](../guides/09-ui-and-case-notes.md) |
| `Main.gd` typed commands, move or group regexes | [`../guides/03-running-and-debugging.md`](../guides/03-running-and-debugging.md) §2 |
| `Main.NPC_COLORS` or `ROOM_COLORS` | [`../guides/04-the-manor-and-world.md`](../guides/04-the-manor-and-world.md) §4, [`../guides/07-adding-a-character.md`](../guides/07-adding-a-character.md) §3 |
| `Scripts/ManorBuilder.gd`, `FLOORS`, `STAIRS` | [`../reference/manor-builder.md`](../reference/manor-builder.md), [`../guides/04-the-manor-and-world.md`](../guides/04-the-manor-and-world.md) §3 |
| `Scripts/ManorDressing.gd` or `furniture.json` | [`../guides/04-the-manor-and-world.md`](../guides/04-the-manor-and-world.md) §3, [`../guides/10-data-and-file-formats.md`](../guides/10-data-and-file-formats.md) §1 |
| `Scripts/CrimeScene.gd` | [`../guides/04-the-manor-and-world.md`](../guides/04-the-manor-and-world.md) §3, [`../guides/06-the-case-generator.md`](../guides/06-the-case-generator.md) §4 |
| `Scripts/NPCCharacter.gd` | [`../guides/04-the-manor-and-world.md`](../guides/04-the-manor-and-world.md) §5 |
| `Scripts/SuspectModel.gd` or `suspect_models.cfg` | [`../guides/07-adding-a-character.md`](../guides/07-adding-a-character.md) §4, [`../guides/10-data-and-file-formats.md`](../guides/10-data-and-file-formats.md) §1 |
| `Scripts/Player.gd`, `Evidence.gd`, `Door.gd` | [`../guides/01-architecture.md`](../guides/01-architecture.md) §5.4, [`../guides/02-godot-features.md`](../guides/02-godot-features.md) §9 |
| `Scripts/DialogueLog.gd` or `TrainingCapture.gd` | [`../guides/10-data-and-file-formats.md`](../guides/10-data-and-file-formats.md) §3, [`../guides/08-ai-training-and-tuning.md`](../guides/08-ai-training-and-tuning.md) §4 |
| Any key binding in `_setup_input_map()` | [`../guides/03-running-and-debugging.md`](../guides/03-running-and-debugging.md) §2, root `README.md` Controls |
| Added or removed a script | [`../guides/01-architecture.md`](../guides/01-architecture.md) §4 file table |
| Added or removed a scene | [`../guides/03-running-and-debugging.md`](../guides/03-running-and-debugging.md) §3 |

### Everything else

| You changed | Update |
|---|---|
| Anything in `Training/*.py` | [`../guides/08-ai-training-and-tuning.md`](../guides/08-ai-training-and-tuning.md), `Training/README.md`, and the relevant `Training/Manual/` phase document |
| An output path or file format in a training tool | [`../guides/10-data-and-file-formats.md`](../guides/10-data-and-file-formats.md) §4 |
| `.gitignore` | [`../guides/10-data-and-file-formats.md`](../guides/10-data-and-file-formats.md) §5, [`03-git-workflow.md`](03-git-workflow.md) §5 |
| Anything in `Tools/` | `Tools/README.md` |
| Player-facing behaviour: controls, what a panel shows, how a mechanic works | root `README.md` **and** the relevant guide |
| Moved, renamed or added any document | [`../README.md`](../README.md) index tables, [`../../CLAUDE.md`](../../CLAUDE.md) index tables, and every document that links to it |
| Renamed or moved any folder | run `python Tools/check_docs.py` immediately; this is the change that breaks the most links at once |

### A term nobody has met before

If your change introduces a concept, add it to
[`../guides/11-glossary.md`](../guides/11-glossary.md). That file is what lets
every other document use a term without stopping to define it.

---

## 4. The checker

```bash
python Tools/check_docs.py
```

No dependencies, runs in under a second. It verifies six things:

| Check | Catches |
|---|---|
| **Links** | every relative markdown link in `CLAUDE.md`, `README.md`, `.claude/` and `Tools/` resolves to a file that exists |
| **Index completeness** | every file in `.claude/` is listed in `.claude/README.md`, and every file listed there exists |
| **Doc paths in code** | every `.claude/...` path mentioned in a `.gd` or `.py` comment exists |
| **Resource paths** | every `res://` path in code, scenes and `project.godot` exists |
| **Documented constants** | a constant's value quoted in a document still matches the value in the source file |
| **Script coverage** | every `Scripts/*.gd` is named in the architecture guide's file table |

The fifth is the one that catches drift nobody would otherwise notice. It is
driven by a table at the top of `check_docs.py` pairing a constant with the
documents that quote its value. **When you document a new constant's value, add
it to that table.** When you change a constant, the checker tells you which
documents to fix.

It is not a substitute for reading. It cannot tell whether a paragraph still
describes the behaviour correctly, only whether the links, paths, names and
numbers line up. Prose accuracy is on you.

---

## 5. What "correct" means

A document is correct when all six are true:

1. **Accurate.** Every claim matches the code today.
2. **Complete.** It covers what its title and first paragraph promise.
3. **Reachable.** It is linked from [`../README.md`](../README.md), and every
   link inside it resolves.
4. **Current.** No sentence describes behaviour that has been replaced.
5. **Honest about drift.** Where two documents disagree and you cannot fix
   both, the disagreement is called out explicitly rather than left for the
   reader to trip over.
6. **Explains why.** The reasoning is there, not only the rule. A fact without
   its reason gets "simplified" away by the next person.

---

## 6. When the change is too large to document immediately

It happens: a refactor lands over several days and half the guides are wrong in
the middle of it.

The rule does not become optional. It becomes explicit:

- Work on a branch, and do not merge to `main` until the documentation is
  correct on that branch.
- If something must land in an intermediate state, put a dated banner at the
  top of each affected document saying exactly what is now wrong and which
  branch will fix it.
- `main` never carries a document that is silently wrong. A loud, dated warning
  is acceptable for a few days. Silence is not.

---

## 7. For assistants specifically

More detail in [`05-ai-assistant-rules.md`](05-ai-assistant-rules.md). The
short version:

- Read [`../README.md`](../README.md) at the start of every session in this
  repo, and read the guides for the area before proposing a change.
- Never delete a comment that records a measurement. Never change a tuned
  number without a new measurement to justify it.
- State plainly which documents you updated, and which you checked and found
  still correct. "Documentation updated" without a list is not a report.
- You cannot press F6 in Godot. Say which test scene needs running.
- You **can** run `python Tools/check_docs.py`. Run it, and report the output.
