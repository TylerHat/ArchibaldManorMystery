# AI training and tuning

The model that plays the suspects, how it was made, and how to make it better.
Written for someone who has never trained a model and does not intend to learn
the maths.

This guide is the **overview**. The step-by-step manual is
`Training/Manual/`, seven documents, one per phase. That folder is gitignored
and local-only, so if you do not have it, ask.

---

## 1. What is actually running

Three separate things, and keeping them apart prevents most of the confusion.

| Thing | What it is |
|---|---|
| **Ollama** | A program on your machine that runs AI models and answers HTTP requests. The game talks to it at `http://127.0.0.1:11434/api/chat` |
| **The base model** | `huihui_ai/llama3.2-abliterate:3b`. A general 3-billion-parameter model. Downloaded, not made here |
| **The tuned model** | `archibald-suspect:v1`. The base model plus training on replies captured from real play. Built locally, 2.1GB, not distributed in this repo |

`GameManager.OLLAMA_MODEL` names which one the game uses. To run against the
stock model instead, change it back; the line above it is commented out and
ready.

**"Abliterated"** means the refusal behaviour has been removed from the base
model. That matters here for one reason: suspects in a murder mystery need to
be able to say hostile, evasive and unpleasant things. A butler telling you to
go to hell is good drama. "I don't feel comfortable with that" is the model
stepping out from behind the butler, and it ruins the scene.

---

## 2. Why train at all

Right now, every time a suspect speaks, the game hands the model about a
thousand words of instructions explaining who they are and how to behave. The
model reads all of it, then answers. It works, but the instructions are fresh
every single time, which means they can be argued with, ignored, or squeezed
out of memory by a long conversation.

**Training moves that behaviour out of the instructions and into the model
itself.**

The comparison that holds: right now you are handing an actor the script two
seconds before every take, forever. Training is the month of rehearsal. You
still hand them the scene, because the murderer changes every playthrough, but
you stop re-explaining what acting is.

You do it by showing the model a few hundred examples of your suspects
answering well, and a couple of hundred pairs of "this answer was wrong, this
one was right". That is the whole idea. Everything below is plumbing.

---

## 3. The two file shapes

Everything in the pipeline produces one of these two.

**`sft.jsonl`, imitation.** One line per example, each a full conversation
ending in a reply you approved. "Answer like this."

```json
{"messages": [{"role":"system","content":"You are Dr Evelyn..."},
              {"role":"user","content":"Where were you at ten?"},
              {"role":"assistant","content":"The Library. Alone."}],
 "character_id": "blackwood", "scene": "private"}
```

**`dpo.jsonl`, preference.** One line per pair: the same prompt, one bad reply
and one good one. "Prefer this over that."

```json
{"messages": [...same shape, without the final assistant turn...],
 "chosen":   "The Library. Alone.",
 "rejected": "As an AI language model, I cannot speculate about...",
 "character_id": "blackwood", "scene": "private"}
```

SFT teaches the voice. DPO teaches what to do instead of breaking character or
refusing. DPO is the run that fixes the two things you actually care about.

---

## 4. Where the data comes from

### The free source: the reply guard

`_reply_breaks_character()` already catches a reply that has left the fiction,
throws it away and re-asks. **That discarded reply and its clean replacement
are exactly a preference pair**: same prompt, one wrong answer, one right one.
They get written out with no keypress at all.

Roughly half the pairs in a session arrive this way, and they are the best rows
in the file, because the rejected half is a failure the model really produced
rather than one somebody sat down and imagined.

Two cases still need you: a guard catch in a Hall meetup (there is no retry
there, because a second round trip per attendee would be felt), and anything
you press F10 on.

### F9 and F10 while playing

Tick the **dialogue log** box on the selection screen. That one checkbox turns
on capture too. Look for `[Training] capture ON` and two file paths in the
console.

| Key | Means | Lands in |
|---|---|---|
| **F9** | Good reply, keep as an example to imitate | `TrainingData/sft_*.jsonl` |
| **F10** | Wrong reply, keep as something to train away from | `TrainingData/dpo_*.jsonl` |

Both label the reply currently on screen, most recent only. A second press does
nothing, on purpose.

**Nothing is kept automatically just for passing the guard.** A fine-tune
trained on every reply that happened to squeak through learns the mediocre ones
as hard as the good ones, and the symptom, every suspect converging on one flat
voice, only shows up after an hour of training.

### Harvesting, the fast route

Rather than playing for five hours, run the whole prompt bank against Ollama
unattended and judge the replies in a browser.

```bash
# 1. In game, Ctrl+3 exports the active characters' system prompts.
#    Eight suspects go in a house, so two games cover a roster of twelve.

# 2. Pass 1: ask all 601 questions once. About 10 minutes, unattended.
ollama serve
python Training/harvest.py

# 3. Judge them. SERVE the reviewer, do not double-click it: Chrome blocks
#    downloads from file:// pages. From the project folder, second terminal:
python -m http.server 8000
#    then open http://localhost:8000/Training/review.html
#    Drag the harvest_*.jsonl in. j = good, k = bad. Download decisions.json.

# 4. Pass 2: re-ask only the ones you rejected, three times each. ~7 minutes.
python Training/harvest.py --rerun decisions.json --k 3

# 5. Judge again. Press 1-3 to pick a winner, x to discard. That pick becomes
#    a preference pair with no typing.

# 6. Turn decisions into training rows.
python Training/harvest_to_dataset.py decisions.json decisions2.json
python Training/build_dataset.py
python Training/audit.py
```

Harvesting covers private interviews only. Playing is the only source of
Hall-meetup data and of the rare failures the guard catches. Do both.

**Rotate the cast.** Eight of twelve go in the house. Always take the same
eight and four characters end up with no data and inherit whichever voice
dominates the set.

---

## 5. Judging replies, which is the part that matters

Everything downstream of this is mechanical. This is where the exercise
succeeds or fails.

### The F9 bar

Not "was that acceptable". **Would I be happy if the finished game handed a
stranger this exact reply?** Three things must be true:

- **Only this suspect could have said it.** If you could swap in any of the
  other eleven and not notice, it is generic, and generic replies are how
  twelve characters collapse into one voice.
- **One to three sentences.** Long replies teach that long is correct, and at
  29ms a token you pay for that forever.
- **Nothing they could not know.** No invented rooms, no facts from another
  suspect's private interview, no murder details they were never briefed on.

Calibration: pressing F9 on nearly everything means the bar is too low. Four
times in an hour means it is too high. **About one in three is right.**

### The F10 bar

The guard already catches the keyword failures and pairs them automatically. Do
not spend keypresses there. F10 is for what a keyword list cannot see:

- a refusal that came from the model rather than the character
- moralising, or a disclaimer nobody asked for
- modern voice: therapy-speak, corporate politeness, "I hear you"
- a knowledge leak: a private conversation they were not in
- structural junk: repeating the question, narrating your actions, prose
  narration instead of speech, prefixing their own name
- rambling past three or four sentences

About one in eight earns it.

### Do NOT press F10 for these

The most expensive mistake available to you, because these look like failures.

- **A suspect refusing, in character.** A butler telling you to go to hell is
  good drama. Only the model stepping out from behind the butler is a failure.
- **A suspect lying.** Suspects lie. That is the game. Flag lies as failures
  and you will train the lying out of your murder mystery.
- **A hostile, rude or cold answer.** Blackwood is written cold. Thorne is
  written blunt. That is the character.
- **A short answer.** Short is what you want.

---

## 6. Cleaning up

```bash
python Training/build_dataset.py   # merge every session file into sft/dpo/needs_chosen
python Training/fill_chosen.py     # write the better reply for each flagged failure
python Training/build_dataset.py   # re-run until dpo_needs_chosen.jsonl is empty
python Training/audit.py           # health check, BEFORE you spend GPU time
```

`build_dataset.py` reads every `TrainingData/sft_*.jsonl` and `dpo_*.jsonl` and
writes three files to the project root:

| File | Contains |
|---|---|
| `sft.jsonl` | imitation examples, ready to train on |
| `dpo.jsonl` | preference pairs, ready to train on |
| `dpo_needs_chosen.jsonl` | rejected replies still missing a better answer |

**Targets before a first run: 300+ rows in `sft.jsonl`, 120+ pairs in
`dpo.jsonl`.**

Run `audit.py` before every training run. It catches the mistakes you cannot
see by reading the file, and GPU time is the expensive part.

---

## 7. Training

The actual training does **not** happen on your machine, and the reason is
memory rather than speed. The card here has about 5GB usable and is already
holding the model and four conversation caches while the game runs. Google
Colab hands you 16GB free, and skips the part that genuinely eats a weekend:
installing CUDA and its dependencies on Windows.

Three places are involved:

| Place | Role |
|---|---|
| Your machine | the game, Ollama, the Python scripts, the final model |
| Google Colab | the borrowed GPU that does the training |
| Google Drive | the doorway between the two |

The notebook is `Training/Manual/Archibald_Training_Runbook.ipynb`, with a
written version alongside it at `COLAB_RUNBOOK.md`. You change about six
numbers and press play.

Two runs, in order: **SFT first** to learn the voice, **DPO second** to learn
what to do instead of breaking character. The output of each is an "adapter", a
small file of adjustments, about 100MB.

Then you squash the result into one file, bring it home, and register it with
Ollama using a Modelfile:

```
FROM <path to>\Training\Modelfile\Llama-3.2-3B-Instruct-abliterated.Q4_K_M.gguf

PARAMETER temperature 0.8
PARAMETER num_ctx 8192
PARAMETER num_predict 200
PARAMETER repeat_penalty 1.15
PARAMETER stop "Detective:"
PARAMETER stop "DETECTIVE:"
```

```bash
ollama create archibald-suspect:v1 -f Tools\ArchibaldModelfile
```

`Tools/ArchibaldModelfile` and `Tools/ArchibaldModelfile_v11` are the two
recipes used so far. The difference between them is instructive: v11 raised
`num_predict` from 140 to 200 and added `repeat_penalty 1.15`.

---

## 8. Measuring, every single time

```bash
ollama serve
python Training/eval.py --models huihui_ai/llama3.2-abliterate:3b archibald-suspect:v1
```

Asks all 30 questions in `Training/eval_lines.txt` of every model named, using
the real system prompt lifted out of your captured data, and writes
`Training/reports/eval_report.md` with the answers side by side.

It auto-flags two things: phrases from the game's own `OUT_OF_CHARACTER` list,
and the shapes a model refuses in.

**The automatic number is a floor, not a score.** Read the report and mark the
pass and fail lines yourself, especially the `pressure` ones. A suspect who
quietly stopped being a suspect passes every automatic check.

`Training/probe_c.py` does the same for injection-resistance probes, writing to
`Training/reports/probe_c.md`.

Keep the reports. `Training/reports/probe_A.md` and `probe_B.md` are earlier
runs, kept for comparison.

---

## 9. Tuning without retraining

Retraining costs hours. Several problems have a cheaper fix. Try these first.

### In the Modelfile, then `ollama create` again

| Parameter | Effect |
|---|---|
| `temperature` | higher is more varied and more likely to wander. 0.8 currently |
| `repeat_penalty` | discourages repetition. 1.15 fixed a model that looped |
| `num_predict` | ceiling on reply length. A ceiling, not a target |
| `stop` | cut generation the moment the model starts writing the detective's line |

### In `GameManager.gd`

Every constant carries a comment recording what was measured to arrive at it.
Read it before changing the number. The full table is in
[`05-the-dialogue-system.md`](05-the-dialogue-system.md) section 9. In short:

- `MAX_RESPONSE_TOKENS` (200) and `GROUP_MAX_TOKENS` (130) are latency budgets
- `OLLAMA_KEEP_ALIVE` ("30m") stops a 60-second reload
- `OLLAMA_NUM_CTX` (8192) must be explicit, and see the compaction section
- `STOP_SEQUENCES` are free money

### In the prompts

`_shared_case_preamble()` and `_build_character_tail()`. Cheapest of all to
try, and often the right answer, but remember section 6 of guide 05: a 3B model
cannot select a row, reformat a time and stay in voice all at once. If you find
yourself asking it to do three things, do one of them in GDScript instead.

---

## 10. Where everything lives

```
Training/
├─ README.md                     the short version of this guide
├─ PLAYBOOK.md                   what to say while playing, and the judging bars
├─ Manual/                       seven step-by-step phase documents  [gitignored]
│  ├─ INDEX.md                   start here
│  ├─ 00-OVERVIEW.md
│  ├─ 01-collect.md   01b-harvest.md
│  ├─ 02-clean.md     03-colab.md
│  ├─ 04-train-sft.md 05-train-dpo.md
│  ├─ 06-install.md   07-measure.md
│  ├─ COLAB_RUNBOOK.md
│  └─ Archibald_Training_Runbook.ipynb
├─ Modelfile/                    the 2.1GB .gguf lives here  [gitignored]
├─ reports/                      eval and probe output  [gitignored]
│
├─ harvest.py                    ask the prompt bank unattended
├─ harvest_to_dataset.py         judged harvest -> training rows
├─ build_dataset.py              merge sessions -> sft.jsonl / dpo.jsonl
├─ fill_chosen.py                write better replies for flagged failures
├─ audit.py                      health check before training
├─ eval.py                       30 questions, side by side
├─ probe_c.py                    injection-resistance probes
├─ check_dialogue_log.py         static analysis of a play log
├─ apply_judge.py                apply judged verdict packets
├─ apply_rewrites.py             apply character rewrite packets
├─ make_judge_packet.py          build a batch for judging
├─ make_rewrite_packet.py        build a batch for rewriting
├─ framing.py                    shared prompt framing helpers
├─ review.html                   the browser reviewer, SERVE it
├─ eval_lines.txt                the 30 eval questions
└─ prompts.txt                   the 601-question harvest bank  [gitignored]

Tools/
├─ Fix_Ollama.ps1                Windows Ollama repair
├─ ArchibaldModelfile            v1 recipe  [gitignored]
└─ ArchibaldModelfile_v11        v11 recipe  [gitignored]
```

Much of this is gitignored on purpose, not by accident: the harvests are
hundreds of megabytes, the character briefs give away every suspect's secret,
and the play logs print the murderer at the top.
