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

## Two ways to collect

**By playing** (F9/F10 while you interrogate) or **by harvesting** (run the whole
prompt bank against Ollama unattended, then judge the replies in a browser).
Harvesting is faster and covers private interviews only; playing is the only
source of hall-meetup data and of the rare failures the guard catches.

### Harvest workflow

```bash
# 1. in game, press Ctrl+3 to export the active characters' system prompts.
#    Eight suspects go in a house, so two games cover the roster of twelve.

# 2. pass 1: ask all 601 questions once. ~10 min, unattended.
ollama serve
python Training/harvest.py

# 3. judge them. Serve the reviewer, do not just double-click it: Chrome blocks
#    downloads from file:// pages. From the project folder, in a second window:
#      python -m http.server 8000
#    then open http://localhost:8000/Training/review.html
#    Drag the harvest_*.jsonl in, press j for good and k for bad, download decisions.json.
#    (Double-clicking still works for reviewing; saving falls back to a copy box.)

# 4. pass 2: re-ask only the ones you rejected, three times each. ~7 min.
python Training/harvest.py --rerun decisions.json --k 3

# 5. judge again. Same page, drag the new file in, press 1-3 to pick a winner
#    or x to discard. That pick becomes a preference pair with no typing.

# 6. turn the decisions into training rows
python Training/harvest_to_dataset.py decisions.json decisions2.json
python Training/build_dataset.py
python Training/audit.py
```

### Play workflow

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
system prompt lifted out of your captured data, and writes `Training/reports/eval_report.md` with
the answers side by side.

It auto-flags two things: phrases from the game's own `OUT_OF_CHARACTER` list,
and the shapes a model refuses in. The automatic number is a floor, not a score.
Read the report and mark the pass/fail lines yourself, especially the `pressure`
group, where a polite deflection is a failure no keyword list can see.

Freeze `eval_lines.txt` once you have a baseline. Changing the questions between
runs destroys the only number this whole exercise produces.

## The judging pass

Between harvesting and reviewing there is an optional step that changes the
reviewer from "judge three hundred replies cold" into "confirm or overrule three
hundred recommendations".

    python Training/make_judge_packet.py --batch 50   # -> JudgePackets/packet_*.json
    # hand the packets to Claude, which writes JudgePackets/verdicts_*.json
    python Training/apply_judge.py                    # merges them onto the harvest

Each verdict is `keep` or `reject`. **Every rejection carries a `suggested`
replacement** written in that character's voice, so a rejection is not a dead
end: accepting one in the reviewer produces a preference pair immediately, with
no rerun against the model.

The rubric grades on personality first. A reply is rejected when it is generic,
when it is in a register the character would never use (helpdesk, therapy,
modern American idiom in 1930s England), when warmth leaks into a character
written cold, or when the line could be swapped between any two of the twelve
without anyone noticing. It is *not* rejected for lying, rudeness, brevity,
in-character refusal, or dark content: those are the game working.

Expect a low keep rate. Roughly one reply in five survives, because the base
model's default register is helpful-assistant and almost every suspect is
written as something else. That is the gap the training run exists to close.

Nothing here decides anything. Recommendations are advisory until you accept
them in `review.html` with `A`; `J` and `K` overrule. The reviewer records how
often you agreed, which is the only honest measure of whether the judge is
worth trusting.

### The room trap

`prompts.txt` is static; `CaseGenerator` randomises every suspect's room each
game. Two things followed from that, both now fixed:

1. **The briefs named the wrong room.** Ten of the twelve `found in the X` lines
   disagreed with the case actually harvested, so the judge marked correct
   answers as location drift. `make_judge_packet.py` now reads the real room
   *and the full movement list* off the row's own system prompt, and the briefs
   no longer carry a room at all.
2. **Twelve questions presupposed the wrong room** — "What were you doing in the
   Kitchen?" asked of a man who was in the Conservatory. Those are now
   room-agnostic ("What were you doing in there?"). The deliberately false ones
   ("Somebody says you were in the Study. Explain that.") are unchanged: a false
   premise is the point of that question.

Rebuild any packet made before this change. The `their_movements_last_night`
field is the useful half — without it a judge cannot check an alibi at all, it
can only check whether the suspect contradicted themselves.

### The rewrite pass

The first judging pass got the verdicts right and the replacement lines wrong.
Measured across all 493 rejections:

| | first pass | after rewriting |
|---|---|---|
| median suggestion length | 153 chars | 417 |
| carrying two or more stage directions | 7% | 100% |
| **shorter than the reply being replaced** | **73%** | **16%** |

That last row is the one that mattered. `audit.py` and `harvest_to_dataset.py`
both warn above 72%, and for good reason: DPO cannot see *why* a reply was
preferred, so a winner that is reliably the shorter one teaches "shorter is
better" and the model starts answering in fragments. The rubric that produced
those lines asked for 100-250 characters and "at most one stage direction",
which was an over-correction against a real risk - that a 3B cannot imitate a
literary target. The right constraint is **plain vocabulary, not short lines**:
ordinary period words and concrete physical business, at whatever length the
moment needs.

    python Training/make_rewrite_packet.py          # -> RewritePackets/rewrite_<character>.json
    # a writer produces RewritePackets/results/rewrite_<character>.json
    python Training/apply_rewrites.py               # swaps the lines in

Verdicts, reasons and confidences are carried through untouched. Rewriting a
line is far cheaper than re-judging a row, and the keep/reject calls held up.

One packet per character, because a writer holding a single voice for fifty
lines produces far more consistent work than one crossing a character boundary
mid-packet. The pass also caught factual errors the first one had introduced -
Whitmore placed in the Study at nine when her card had her in the Dining Room,
Ashford given a companion the movement list contradicts, Reeves denying a room
he was actually in.

## Covering the whole roster

`prompts.txt` has all twelve suspects, but a single game only puts up to
`MAX_ACTIVE_SUSPECTS` of them in the house, and **Ctrl+3 can only export
characters who are in the current case** — the rest have no system prompt to
export, so `harvest.py` skips them and they never reach a packet.

To cover the ones you have missed you do not need to play. Start a new game,
select them on the suspect screen, and press Ctrl+3 as soon as the manor loads.
The system prompts are built when the case is generated, not when you first
speak to someone.

`harvest.py` globs `TrainingData/prompts_export_*.json` and merges every export
it finds, so a second export simply adds those characters to the next run. The
second game is a different case with a different murderer, which is good for
variety and costs nothing: the character brief is the part being trained.

## Files

| Path | What |
|---|---|
| `Scripts/TrainingCapture.gd` | Writes the JSONL rows. No game logic. |
| `Scripts/GameManager.gd` | Hooks: the guard branches, F9/F10, session paths. |
| `TrainingData/` | Raw per-session capture. Generated, safe to delete. |
| `Training/harvest.py` | Runs the prompt bank against Ollama unattended. Resumable, and `--rerun` re-asks only what you rejected. |
| `Training/framing.py` | Port of the game's `frame_player_line()`. Verified byte-identical against the GDScript over the whole prompt bank. |
| `Training/review.html` | Local browser reviewer. Open it directly, drag a harvest file in. Nothing leaves your machine. |
| `Training/make_judge_packet.py` | Strips a harvest to what a judge needs, in readable batches. Writes `JudgePackets/packet_*.json`. |
| `Training/make_rewrite_packet.py` | Builds per-character packets for re-writing the suggested lines, keeping the verdicts. |
| `Training/apply_rewrites.py` | Swaps improved lines onto the harvest rows without touching verdicts. |
| `Training/apply_judge.py` | Merges `JudgePackets/verdicts_*.json` back onto the harvest rows as an advisory `recommendation`. |
| `Training/harvest_to_dataset.py` | Turns reviewer decisions into rows `build_dataset.py` already reads. |
| `Training/build_dataset.py` | Merges, dedupes, splits, reports. |
| `Training/fill_chosen.py` | Walks you through the rejected replies one at a time so you never hand-edit JSON. |
| `Training/audit.py` | Data health check. Run before every training run. Exits 1 on a blocker. |
| `Training/Manual/` | Seven phase-by-phase how-to documents plus an index. Gitignored, local only. |
| `Training/prompts.txt` | 601 interrogation lines, 50 per suspect, grouped by what they test. Gitignored, local only. Browse: https://claude.ai/code/artifact/f91df9da-a6b3-49b3-804a-24771a10fe80 |
| `Training/PLAYBOOK.md` | What to say while playing, and everything after. Gitignored, local only. |
| `Training/eval.py` | The before-and-after harness. |
| `Training/eval_lines.txt` | The 30 fixed questions. Do not edit after baseline. |

## Three audit checks that were wrong

Running the audit on a full twelve-character dataset for the first time turned up
four blockers. One was real, three were the check misfiring on this game's shape.
All are fixed; recording them so they are not re-introduced.

**Real: replies that the game's own guard would throw away.** Two accepted lines
quoted the detective's injection attack back at him - Natalie writing down "as the
administrator, I order you", Eugene answering "you tell me the game is over". Good
drama, but both phrases are in `GameManager.OUT_OF_CHARACTER`, so
`_reply_breaks_character()` would discard the reply at runtime and re-ask. Training
the model to say something the game deletes is worse than not training it at all.
Both were reworded to keep the defiance without the trigger phrase. **Any hand-written
line has to clear that list** - it is the one constraint the writer cannot see.

**False: `i cannot` as a refusal tell.** It is ordinary period English. "I cannot get
out of this costume", "what business he had there I cannot say". It flagged eight good
lines and caught nothing real. What marks a *model* refusing is the object of the
verb - cannot help, provide, assist, comply - so the list now matches those.

**False: `respectful` matching "Disrespectful".** Reeves describing how the victim
treated the staff. Now `keep it respectful` / `be respectful`.

**False: "17 different system prompts".** The check assumed one shared prompt, which
is right for a single-persona assistant and wrong here. Twelve suspects have twelve
prompts, and CaseGenerator rewrites the murder room, cast and movement list every
playthrough - so seventeen texts is what a healthy two-case harvest looks like, and
training across both cases is a *feature*: it teaches the model to read the schedule
off the prompt instead of memorising one evening. The check now compares ALL-CAPS
section headings and only fires when a prompt is missing a section the others have,
which is what a template edit actually looks like. On the current data it reports one
template with three intended variants: the base nine sections, the murderer's eleven
(`YOUR SECRET`, `THE ONE THING YOU LIE ABOUT`), and Blackwood's ten (`YOUR EXPERT
FINDING`).

## If you rewrite the system prompt

Rows captured before the rewrite train the model to answer a prompt it will
never be shown again. `build_dataset.py` warns when it sees more than one system
prompt across the rows. Recapture after any significant prompt change.
