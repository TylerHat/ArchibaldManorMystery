# Training data capture

Turns play sessions into a fine-tuning set for a model that stays in character
and does not refuse the player. Full write-up, including the Colab side:
https://claude.ai/code/artifact/cb83292a-cd1f-47c6-9445-210ab6b33a81

**New to this? Start with `Training/Manual/INDEX.md`.** Seven step-by-step
documents, one per phase, written for someone who has never trained a model.
Overview: https://claude.ai/code/artifact/4fb303e9-3066-4626-a09e-22066214e2bf

What to say while playing, how to judge replies, and the deep dive on what comes
after: `Training/PLAYBOOK.md`, or
https://claude.ai/code/artifact/499dcfe8-f9fa-4df8-9355-c9cff1509b64

## The short version

Capture rides along with the dialogue log. Tick the log box on the selection
screen and the game starts writing `TrainingData/sft_*.jsonl` and
`TrainingData/dpo_*.jsonl` alongside the usual markdown log.

While playing:

| Key | Does |
|---|---|
| **F9** | Keeps the reply on screen as a good example. |
| **F10** | Rejects it. Lands in the dpo file with an empty `chosen` for you to fill in. |

Nothing is kept automatically just for passing the guard. A fine-tune trained on
every reply that happened to squeak through learns the mediocre ones as hard as
the good ones, and the symptom (every suspect converging on one flat voice) only
shows up after an hour of training.

## The part that costs nothing

`_reply_breaks_character()` already catches replies that leave the fiction,
throws them away and re-asks. That discarded reply and its clean replacement are
a preference pair, so they get written out with no keypress at all. Roughly half
the pairs in a session arrive this way, and they are the best rows in the file:
the rejected half is a failure the model really produced.

Two cases do need you:

- A guard catch in a **hall meetup**. There is no retry there (a second round
  trip per attendee would be felt), so it lands with an empty `chosen`.
- Anything you press **F10** on. The guard is a keyword list, so it is blind to
  a refusal, a moralising aside, or a suspect who has quietly started talking
  like a chatbot without ever saying "as an AI". Those are the ones worth a key.

## Workflow

```bash
# 1. play with the log box ticked, 3 to 5 hours across a few sessions

# 2. see what you have
python Training/build_dataset.py

# 3. write the better reply for each flagged failure, one at a time
python Training/fill_chosen.py

# 4. re-run until dpo_needs_chosen.jsonl is empty
python Training/build_dataset.py

# 5. check it is worth training on BEFORE you spend GPU time
python Training/audit.py

# 6. train on sft.jsonl then dpo.jsonl (see the write-up)

# 7. measure, every single time
ollama serve
python Training/eval.py --models huihui_ai/llama3.2-abliterate:3b archibald-suspect:v1
```

Targets before a first run: **300+** rows in `sft.jsonl`, **120+** pairs in
`dpo.jsonl`.

## eval.py

Asks all 30 questions in `eval_lines.txt` of every model named, using the real
system prompt lifted out of your captured data, and writes `eval_report.md` with
the answers side by side.

It auto-flags two things: phrases from the game's own `OUT_OF_CHARACTER` list,
and the shapes a model refuses in. The automatic number is a floor, not a score.
Read the report and mark the pass/fail lines yourself, especially the `pressure`
group, where a polite deflection is a failure no keyword list can see.

Freeze `eval_lines.txt` once you have a baseline. Changing the questions between
runs destroys the only number this whole exercise produces.

## Files

| Path | What |
|---|---|
| `Scripts/TrainingCapture.gd` | Writes the JSONL rows. No game logic. |
| `Scripts/GameManager.gd` | Hooks: the guard branches, F9/F10, session paths. |
| `TrainingData/` | Raw per-session capture. Generated, safe to delete. |
| `Training/build_dataset.py` | Merges, dedupes, splits, reports. |
| `Training/fill_chosen.py` | Walks you through the rejected replies one at a time so you never hand-edit JSON. |
| `Training/audit.py` | Data health check. Run before every training run. Exits 1 on a blocker. |
| `Training/Manual/` | Seven phase-by-phase how-to documents plus an index. Gitignored, local only. |
| `Training/PLAYBOOK.md` | What to say while playing, and everything after. Gitignored, local only. |
| `Training/eval.py` | The before-and-after harness. |
| `Training/eval_lines.txt` | The 30 fixed questions. Do not edit after baseline. |

## If you rewrite the system prompt

Rows captured before the rewrite train the model to answer a prompt it will
never be shown again. `build_dataset.py` warns when it sees more than one system
prompt across the rows. Recapture after any significant prompt change.
