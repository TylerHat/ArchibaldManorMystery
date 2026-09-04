# Git workflow

The branch model, the commit and PR loop, and the two Windows-specific traps
that have already cost time here.

---

## 1. The branch model

There are two long-lived branches. **Work goes to `staging`, not to `main`.**

```
   AMM-00xx feature branches
              │  pull request
              ▼
          staging          integration. Everything lands here first.
              │  pull request, when a body of work is ready and tested
              ▼
           main            stable. The line you would show somebody.
```

| Branch | What it is |
|---|---|
| `main` | The stable line. Held at the pre-AI-training state: the AMM-0010 work plus the line-endings fix, the multiline dialogue input and the Play Again crash fix |
| `staging` | Integration. Carries the AI training and model-versioning work from AMM-0015 onward, which is still in development |
| `AMM-00xx-*` | One branch per piece of work, branched from `staging` |

The split exists because the fine-tuning pipeline, the captured datasets and
the model versioning are still moving. They are not ready to be the thing a
newcomer clones, but they do need somewhere to integrate. `staging` is that
place.

**So: branch from `staging`, and open your pull request into `staging`.** Only
a deliberate release moves `staging` into `main`.

---

## 2. The loop

### Create a branch

```bash
git checkout staging
git pull origin staging
git checkout -b AMM-0019-short-description
```

Branch names in this repo follow `AMM-<number>-<short-description>`, taken from
the existing history: `AMM-0017-reply-length-and-schedule-recall`,
`AMM-0016-guard-tell-tuning`. Keep it.

### Commit to it

```bash
git add .
git commit -m "Describe what you changed"
```

Repeat as you go. Small commits are easier to bisect when a case starts
generating wrongly.

### Push

```bash
git push -u origin AMM-0019-short-description
```

`-u` only on the first push of a branch. After that, `git push`.

Then open a pull request on GitHub from that branch **into `staging`**.

### After it merges

```bash
git checkout staging
git pull origin staging
git branch -d AMM-0019-short-description
git push origin --delete AMM-0019-short-description
```

### Releasing staging into main

Rare and deliberate. Open a pull request from `staging` into `main`, and treat
it as a release: run every test scene, run the doc checker, and play a full
game first. Nothing else should ever target `main`.

---

## 3. Before you push

**First, always:**

```bash
python Tools/check_docs.py
```

It must print `ALL CHECKS PASSED`. Documentation is part of every change; see
[`00-documentation-is-part-of-every-change.md`](00-documentation-is-part-of-every-change.md)
for the rule and for the map of which documents cover which code.

**Then** run whichever test scenes your change touches. They take seconds and
they cover the failures that do not crash.

| You changed | Run (F6 in Godot) |
|---|---|
| `CaseGenerator.gd`, `CHARACTERS`, case codes | `Scenes/CaseGeneratorTest.tscn`, expect **1000/1000 valid** |
| the reply guard or its keyword lists | `Scenes/GuardTest.tscn` |
| history handling, group prompts | `Scenes/DialogueOptTest.tscn` |
| anything in the dialogue path | play for ten minutes with the log on, and read the log |

The full list is at the bottom of
[`02-project-invariants.md`](02-project-invariants.md).

---

## 4. Commit messages

Say what changed and, when the reason is not obvious, why. The existing history
is plain and readable: `fixed false facts from the suspects`.

If your change was driven by something measured, put the number in the message
as well as the code comment. `raise MAX_RESPONSE_TOKENS to 200, 14% of
harvested replies were being cut mid-sentence` is worth ten times `tweak
constant`.

---

## 5. The two Windows traps

### Line endings

`.gitattributes` sets `* text=auto`, which makes git store text as LF and
convert on the way in and out. **This is load-bearing.** Without it, a CRLF
working tree on Windows showed up as a whole-repo diff: 65 files and about
17,000 lines of pure line-ending churn drowning out 9 files of real changes.

Do not remove it, and do not commit a file with a forced line ending unless it
is already marked `binary`.

Binary types (`.blend`, `.png`, `.jpg`, `.glb`, `.gltf`, `.ttf`, `.wav`,
`.ogg`, `.gguf`) are marked `binary` so git never touches them.

### `Scripts` versus `scripts`

Git recorded the code folder in lowercase early on, and Windows filesystems do
not distinguish case. So `git status` shows `scripts/GameManager.gd` while your
editor shows `Scripts/`. **They are the same file.**

Do not try to fix this with a rename on a case-insensitive filesystem. It
produces a much worse mess than the cosmetic inconsistency you started with.
Read past it.

Note that `res://` paths inside the code use `Scripts/`, and a few older
comments and the root `README.md` use `scripts/`. Godot does not care on
Windows. It would care on Linux, so if this ever needs to build there, that is
the moment to fix it properly with a two-step case-only rename.

---

## 6. What does not go in the repo

Everything in `.gitignore` is there deliberately, not by accident:

- **Size.** `TrainingData/`, `sft.jsonl`, `dpo.jsonl`, the 2.1GB `.gguf`.
- **Spoilers.** `DialogueLogs/` print the murderer at the top. The character
  briefs in `Training/Manual/` and `Training/PLAYBOOK.md` give away every
  suspect's secret.
- **Machine-specific.** `Tools/ArchibaldModelfile*` contains an absolute path
  to one person's drive.
- **Regenerated.** `.godot/`, `.import/`, `Training/reports/`.

Before adding a new generated artifact, add it to `.gitignore` in the same
commit.

`_to_delete/` is a scratch drawer for files that could not be deleted on a
OneDrive mount. It is gitignored, nothing reads it, and it is safe to empty
whenever you like.

---

## 7. Do not commit these by accident

- `.godot/`. If it appears in `git status`, your `.gitignore` is not being
  applied; check you are in the repo root.
- A dialogue log. It names the murderer in the first ten lines.
- `Tools/ArchibaldModelfile`, which has somebody's home directory in it.
- A `.blend` you exported at the wrong scale. Check it in the editor first;
  they are binary and bloat history permanently.
