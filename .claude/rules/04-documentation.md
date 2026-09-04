# Documentation rules

Where a document goes, what it has to contain, and how to keep this folder from
turning back into a pile of files at the project root.

---

## 1. Where a new document goes

| It is... | It goes in |
|---|---|
| an explanation of how something works, for a newcomer | `.claude/guides/` |
| a convention or a decision that binds future work | `.claude/rules/` |
| a deep dive on one subsystem, for somebody already oriented | `.claude/reference/` |
| a design document written before the work | `.claude/plans/` |
| a manual test script | `.claude/testing/` |
| about the training pipeline specifically | `Training/` |
| the player-facing description of the game | root `README.md` |
| an idea not yet decided on | root `TODO.md` |

**Nothing new goes at the project root.** The root currently holds
`README.md`, `TODO.md`, `project.godot`, the dotfiles, and three generated
dataset files whose names the Colab notebook depends on. That is the whole
allowance.

---

## 2. Naming

- lowercase, hyphen separated: `the-case-generator.md`
- guides are numbered, because they have a reading order:
  `06-the-case-generator.md`
- rules are numbered for the same reason
- reference and plans are not numbered, because they are read on demand
- if a document is superseded, say so **in the filename**:
  `build-gui-geometry-superseded.md`, and put a banner at the top of the file
  as well

---

## 3. What every document needs

**A first paragraph that says who it is for and what it covers.** Not a
restatement of the title. A reader should be able to tell in one sentence
whether to keep reading.

**Links to the documents on either side of it.** Where to go before, where to
go after.

**Concrete examples from this codebase**, not invented ones. If you are
explaining the character dictionary, show Blackwood's actual entry.

**The reason, not only the rule.** Every worthwhile document in this folder
explains why something is the way it is. "The murder room is never the weapon's
home room" is a fact. "The murder room is never the weapon's home room, because
otherwise the empty-table clue in the weapon's home room is worthless" is
useful.

---

## 4. Superseding rather than deleting

When a document stops being true, do not delete it if somebody might still
follow a link to it. Rename it with a `-superseded` suffix, put a banner at the
top naming the replacement, and update
[`../README.md`](../README.md)'s table.

`build-gui-geometry-superseded.md` is the pattern. Its banner says, in effect:
do not follow Part 4 of this document, it hand-places 37 walls that
`ManorBuilder.gd` generates correctly; the file is kept for its wall-size
tables.

---

## 5. Keeping things in sync

Three pairs drift apart if you let them.

**Code comment and document.** When both describe the same thing, the code
comment is the authority and the document links to it. Do not copy a
measurement into a document; describe it and say which constant holds it.

**Root `README.md` and the guides.** Where they disagree, **the code wins**.
Fix both rather than picking one: the README is player-facing, and a player
reading a stale description of a mechanic has no way to know it is stale.
`python Tools/check_docs.py` catches the mechanical half of this.

**This folder's index and its contents.** If you add, move or supersede a
document, update the tables in [`../README.md`](../README.md) in the same
commit. That file is how anybody finds anything here.

---

## 6. Style

Written for someone who has never done this before. That is the standing brief
for everything in `guides/`, and it means:

- define a term the first time it appears, or link to
  [`../guides/11-glossary.md`](../guides/11-glossary.md)
- prefer a worked example over an abstract description
- say what happens when it goes wrong, not only when it goes right
- when a decision looks wrong, explain the alternative that was rejected and
  why

House style, matching the existing documents:

- no em dashes or en dashes as punctuation. Use a comma, or restructure the
  sentence. Hyphens in compound words are fine
- tables for anything with more than three parallel items
- code blocks for anything you would type
- headings numbered within a document, so sections can be cited
