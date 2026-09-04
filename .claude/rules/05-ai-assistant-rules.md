# Working with AI assistants on this repo

Ground rules for pointing Claude, or any other coding assistant, at this
project. Most of this repo was written with one, so these are lessons rather
than speculation.

---

## 1. Point it at the right documents first

An assistant with no context will produce plausible code that violates an
invariant, because the invariants are not inferable from the code alone.

Before asking for anything substantial, have it read:

1. [`../../CLAUDE.md`](../../CLAUDE.md), the repository entry point, always
2. [`00-documentation-is-part-of-every-change.md`](00-documentation-is-part-of-every-change.md), always
3. [`02-project-invariants.md`](02-project-invariants.md), always
4. the guide for the area being changed
5. the file itself, in full, not in fragments

The comments in `GameManager.gd` and `CaseGenerator.gd` carry most of the
reasoning in this project. An assistant that has read the file has the reasons;
one working from a summary does not.

---

## 2. Never let it change a tuned constant without the measurement

Every number in this codebase that was arrived at by experiment carries a
comment saying what was measured:

```gdscript
## Raised from 140 after measuring the tuned model: its replies run a median
## ~115 tokens and 14% of 601 harvested replies hit the old ceiling...
const MAX_RESPONSE_TOKENS := 200
```

An assistant will happily change 200 to 150 and delete the comment, because the
comment does not look like code. **When a tuned constant changes, the comment
changes with it, and the new comment says what was measured to justify the new
number.** If nothing was measured, the number should not change.

---

## 3. Make it update the documentation, and prove it

The rule is in
[`00-documentation-is-part-of-every-change.md`](00-documentation-is-part-of-every-change.md):
a change is not finished until the documentation is correct, in the same
commit.

An assistant will not do this by default. It will change the code, report
success, and leave eight documents describing the old behaviour. So:

- Ask for the list of documents it updated **and** the list it checked and
  found still correct. "Documentation updated" without a list is not a report.
- Have it run `python Tools/check_docs.py` and paste the output. It can run
  that; it cannot press F6 in Godot.
- If it says a document did not need changing, spot-check one.

---

## 4. Insist on the tests

The expensive failures here do not crash. Ask for the test run, do not assume
it happened.

- `CaseGenerator.gd`, `CHARACTERS` or case codes changed
  → `Scenes/CaseGeneratorTest.tscn`, expect `1000/1000 valid`
- the guard or its lists changed → `Scenes/GuardTest.tscn`
- history or group prompts changed → `Scenes/DialogueOptTest.tscn`

An assistant cannot press F6 in Godot. It can tell you which scene to run, and
it should.

---

## 5. Be specific about which layer the fix belongs in

The most common wrong answer on this project is putting the fix in the prompt
when it belongs in GDScript, or the other way round.

The worked example is schedule recall. Asking the model to select the right
row, reformat the time and stay in voice all at once scored 2 to 3 out of 10.
Doing the lookup in GDScript and handing over one resolved row scored 4.5 out
of 5.

**The rule: if a small model is being asked to do three things at once, do one
of them in code.** Say so explicitly when you ask.

---

## 6. Watch for these specific failure patterns

Things that have actually happened, or would clearly happen.

**Reusing a burned character slot.** The slot rules are unusual and an
assistant will not infer them. Say "take `NEXT_FREE_SLOT` and increment it"
every time.

**Adding upstairs rooms to `CaseGenerator.GRID`.** It looks like an oversight.
It is deliberate, and the reason is in
[`02-project-invariants.md`](02-project-invariants.md) section 6.

**Loosening the guard to fix a false positive.** The right fix is usually
narrowing a pattern, not removing it. A guard that is too tight is also a bug,
but the failure modes are asymmetric: too loose lets a suspect end the game
wrongly.

**Reaching `GameManager` from inside `CaseGenerator`.** It looks harmless and
it destroys the test scene.

**Removing a "redundant" duplicate.** `Main.GRID` and `CaseGenerator.GRID` are
duplicated on purpose. `NPCCharacter.ROOM_HALF` duplicates `Main.CELL / 2` on
purpose. Both carry comments saying so.

**Rewriting a comment into something shorter.** The long comments in this repo
are the documentation. Several of them cite a specific dialogue log and date.
That is evidence, not verbosity.

---

## 7. Files an assistant should not touch

- **`*.uid` files.** Godot generates and maintains them.
- **`*.import` files.** Same.
- **`.gitattributes`.** The `text=auto` line is load-bearing on Windows.
- **`Training/Manual/Archibald_Training_Runbook.ipynb`** by hand. It is JSON
  with escaped strings inside it, and a hand edit that looks right will often
  produce invalid JSON. Edit it with a script that reparses afterwards.
- **Anything in `_to_delete/`.** It is a scratch drawer. Nothing reads it.

---

## 8. What an assistant is genuinely good at here

Worth saying, because the list above is all cautions.

- **Reading a dialogue log and finding the bleed.** Cross-character leakage in
  a thirty-line log is exactly the kind of pattern that is tedious for a person
  and easy for a model.
- **Writing character personalities**, then having them judged against the bar
  in [`../guides/07-adding-a-character.md`](../guides/07-adding-a-character.md):
  could you swap this for any other character and not notice?
- **Judging harvested replies in bulk.** The judge packet format in
  `JudgePackets/` exists for exactly this, and carries `trait_to_protect` and
  `what_failure_looks_like` per character precisely so a judge working without
  the game open has enough to go on.
- **Building furniture layouts.** `furniture.json` is pure numbers against
  documented constraints.
- **Writing and updating these documents.**

---

## 9. If an assistant wrote it, say so

Commits made with an assistant in this project carry a `Co-Authored-By` trailer.
Keep doing that. It is useful later when working out why a change was made and
what context the author had.
