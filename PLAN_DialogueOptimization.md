# Dialogue memory & performance review

How each character stores memory today, what actually breaks first when you
push past two attendees, and eight recommendations ranked by measured impact.

Everything in the "measured" sections comes from your own machine —
`%LOCALAPPDATA%\Ollama\server.log` and `server-3.log` — not from estimates.

---

## 1. What your machine actually is

| | |
|---|---|
| GPU | **NVIDIA GeForce RTX 4050 Laptop**, 6.0 GiB total, **5.0 GiB available** |
| Compute capability | 8.9 (Ada) |
| CPU | Intel i7-13620H |
| System RAM | 15.7 GiB total, 4.5 GiB free at probe time |
| Model | `huihui_ai/llama3.2-abliterate:3b`, **29/29 layers offloaded to GPU** |

The model is fully on the GPU. That's the good news — nothing here is a
"buy a better card" problem.

### Ollama config — every relevant knob is at its default

```
OLLAMA_NUM_PARALLEL      : 1        <-- this is the problem
OLLAMA_FLASH_ATTENTION   : false
OLLAMA_KV_CACHE_TYPE     : (empty = f16)
OLLAMA_KEEP_ALIVE        : 5m0s
```

And from the runner: `n_slots = 1`, `n_ctx_slot = 8192`, `n_keep = 4`.

---

## 2. Measured throughput

From 39 completed requests across two sessions:

| Phase | Rate | Notes |
|---|---|---|
| Generation (`eval`) | **34.3 tok/s** (29 ms/token) | Rock steady, 28–30 ms across every single request |
| Prefill (`prompt eval`) | **~1,150 tok/s** (0.87 ms/token) | 1,020–1,300 range |
| Prompt-cache restore | **~380 ms avg**, up to 660 ms | Charged per character switch |
| Cold model load | **60 s** | One-time, or after KEEP_ALIVE expires |

KV cache cost, straight from your log
(`prompt 00000209306AC680: 2313 tokens ... 253.012 MiB`):

> **112 KiB per token** at f16. 8192 tokens = **896 MiB** per slot.

That number matters for recommendation R1, so it's worth having exactly.

---

## 3. The diagnosis: what breaks first

You asked me to work this out rather than assume. It is **not** coherence
drift, and it is **not** context eviction. Those are real risks (see R4) but
neither is what you hit first.

**It's prefill thrash caused by `OLLAMA_NUM_PARALLEL=1`.**

There is exactly one KV slot. Every request that isn't from the same character
as the previous request has to re-process most of its history from scratch.

Your log shows the two regimes cleanly.

**Private interview** — consecutive turns, same character, cache holds:

```
prompt eval time =   94.33 ms /  49 tokens
prompt eval time =   98.77 ms /  53 tokens
prompt eval time =   57.15 ms /  14 tokens
prompt eval time =   77.13 ms /  61 tokens
```

Only the new question is processed. Prefill is ~90 ms. A turn is ~2.5 s, and
~95% of that is generation — which is the floor, and fine.

**Hall meetup** — alternating between two characters, cache misses every time:

```
prompt eval time = 1744.06 ms / 2246 tokens
prompt eval time =  843.30 ms /  989 tokens
prompt eval time =  826.76 ms /  922 tokens
prompt eval time =  844.66 ms /  982 tokens
prompt eval time =  809.41 ms /  826 tokens
prompt eval time =  886.52 ms / 1015 tokens
prompt eval time =  841.17 ms /  932 tokens
prompt eval time =  883.76 ms /  995 tokens
prompt eval time =  844.12 ms /  901 tokens
prompt eval time = 1029.32 ms / 1129 tokens
prompt eval time =  789.27 ms /  868 tokens
prompt eval time =  987.89 ms / 1287 tokens
```

Twelve consecutive misses — six rounds of a two-hander. And the scheduler
tells you why, in as many words:

```
slot get_availabl: checking sim = 0.683 (1985/2907) > 0.100
slot get_availabl: selected slot by LCP similarity, f_sim_best = 0.683
slot operator(): new prompt, n_ctx_slot = 8192, task.n_tokens = 2907
slot operator(): cached n_tokens = 1985, memory_seq_rm [1985, end)
```

Longest-common-prefix similarity against the resident slot is **0.68** when
switching characters, versus **0.95–0.99** within a private interview. 922 of
2,907 tokens get reprocessed, and you pay another ~380 ms for the prompt-cache
swap on top.

### Why similarity is only 0.68 and not ~0.99

Because `_build_system_prompt()` opens with the character's name:

```gdscript
text += "You are role-playing as %s in an interactive murder-mystery game..." % c["name"]
```

The prompts diverge at roughly **token 6**. Everything after it — the case, the
closed door, where you are now, what you know and don't know, physical actions,
all of it identical text for all eight suspects — is re-tokenized and
re-processed on every switch anyway. The 0.68 you're getting is Ollama's
disk-backed prompt cache partially rescuing you, not prefix sharing working.

### Scaling to 3–4 attendees

Two things grow at once, which is why it gets bad faster than it looks.

1. **Requests per line: linear in N.** Each detective line costs one sequential
   Ollama request per un-muted attendee.
2. **History per character: also grows with N.** Every line said gets written
   into every *other* attendee's `_histories` via `note_to_character()`. Per
   round, per character, that's a framed block of roughly
   `40 + (N-1)x50 + 35` tokens. Storage across the game is **O(N²) per round**.

Projected, using your measured constants:

| Attendees | History @ round 5 | Prefill/turn | Turns/line | **Wall time per line typed** |
|---|---|---|---|---|
| 2 (today) | ~2,700 tok | ~850 ms | 2 | **~4.2 s** |
| 3 | ~2,900 tok | ~1,000 ms | 3 | **~7.2 s** |
| 4 | ~3,200 tok | ~1,120 ms | 4 | **~10.1 s** |
| 4 @ round 10 | ~4,650 tok | ~1,600 ms | 4 | **~12.4 s** |

Ten to twelve seconds of dead air per line, with `"stream": false` so nothing
appears on screen until the whole round finishes. That's the wall, and it's the
reason `MAX_HALL_ATTENDEES := 2` feels right at the moment.

The good news: nearly all of that is recoverable, because it's overhead rather
than work. Generation at 34 tok/s x ~35 tokens is ~1 s per reply, and that is
the only part you genuinely have to pay.

---

## 4. How memory is stored today

For completeness, since this is what the recommendations act on.

```
GameManager._histories : Dictionary   character_id -> Array[{role, content}]
```

- Seeded once in `start_new_game()` with a single system message
  (~1,400 tokens for an innocent; ~1,900 for the murderer; +~250 for Blackwood).
- `ask_character()` appends `{user, question}`, and the reply appends
  `{assistant, answer}`.
- `note_to_character()` appends heard group lines **permanently**.
- `GroupChat._prime_attendees()` appends a group-scene briefing **every time a
  meetup opens**; `_note_scene_ended()` appends a closer **every time one ends**.
- **Nothing is ever removed.** The array is cleared only on `start_new_game()`.

Ephemeral, correctly not stored: `GroupChat._build_turn_prompt()` (~700 tokens)
is appended to a *duplicate* of the history in `ask_group_member()`. That was a
good call and the reasoning in the comment is right.

Two structural consequences:

- **Repeat meetups accumulate cruft.** Three meetups with the same person leaves
  three priming blocks and three scene-enders permanently in their history,
  none of which they need after the fact.
- **No budget, no eviction policy.** When a history plus its turn prompt exceeds
  8192, Ollama truncates — and the runner reports `n_keep = 4`, so only four
  tokens are pinned. The system prompt is not protected. The schedule block that
  the comment at line 645 correctly identifies as the thing that must never be
  crowded out is at the *end* of the system prompt, which means it goes
  early. Silently.

---

## 5. Recommendations

Ranked by measured impact per unit of effort.

---

### R1. Give each character its own KV slot — `OLLAMA_NUM_PARALLEL=4`
**Effort: none (environment). Impact: very high.**

This is the single biggest win available and requires no code at all.

```
OLLAMA_FLASH_ATTENTION = 1
OLLAMA_KV_CACHE_TYPE   = q8_0
OLLAMA_NUM_PARALLEL    = 4
```

With four slots, the scheduler's LCP matcher parks each attendee on their own
slot and keeps it there across the meetup. Similarity goes from 0.68 to ~0.99,
prefill per turn drops from ~850–1,120 ms to **~50 ms**, and the ~380 ms
prompt-cache swap disappears because there's nothing to swap.

Critically, the cost also stops growing with conversation length — a slot that
holds a character's history doesn't care how long it is.

**The VRAM math, which is why the other two variables are not optional:**

| Config | KV/token | 4 slots x 8192 | + model (~2.0 GB) + compute | Fits in 5.0 GiB? |
|---|---|---|---|---|
| f16 (today's default) | 112 KiB | 3.58 GiB | ~5.98 GiB | **No** — would spill to CPU |
| q8_0 | 56 KiB | 1.79 GiB | ~4.19 GiB | **Yes** |
| q8_0, `num_ctx` 6144 | 56 KiB | 1.34 GiB | ~3.74 GiB | Yes, comfortably |

`KV_CACHE_TYPE=q8_0` requires flash attention, which is why all three go
together. q8_0 is a very mild quantization — on a 3B roleplay workload it is not
something you'll notice, and it's a far better trade than spilling layers to CPU.

**Verify it took effect** by grepping the log for `n_ctx_slot` and `n_slots`
after the first request. If `n_slots` isn't 4, or `n_ctx_slot` came out as
2048 (8192÷4) rather than 8192, Ollama divided rather than multiplied the
context — in that case set `num_ctx` to 8192 explicitly and re-check, or drop
to `NUM_PARALLEL=3`.

Also set `OLLAMA_KEEP_ALIVE=-1` (or pass `"keep_alive": "30m"` in the request
body — see R5). Right now it's 5 minutes: a player who reads their case notes
for six minutes pays the **60-second cold reload** your log recorded.

---

### R2. Make the system prompt prefix byte-identical across all eight suspects
**Effort: low (~30 lines of reordering). Impact: high. Stacks with R1.**

Even with R1 in place, this matters — for the *first* turn each character takes,
for private interviews across eight suspects with only four slots, and as
insurance if the slot count is ever wrong.

Today `_build_system_prompt()` diverges at token 6. Restructure so the generic
material comes first, verbatim identical for everyone:

```
SHARED PREFIX (identical for all 8, ~800 tokens):
  You are role-playing a character in an interactive murder-mystery game
  called Archibald Manor.  [<-- no name]
  ...all the length/format rules...
  THE CASE:            (murder_room is the same for everyone)
  THE CLOSED DOOR:     (already generic)
  WHERE YOU ARE NOW:   (already generic)
  EVERYONE IN THE HOUSE:  <-- list ALL suspects including self, uniformly
  WHAT YOU KNOW AND DO NOT KNOW:  (already generic)
  PHYSICAL ACTIONS:    (already generic)

PER-CHARACTER TAIL:
  YOU ARE: <name>, <job>, <personality>, <flavor>, currently in <room>
  [murderer block | innocent block]
  [expert block]
  YOUR OWN MOVEMENTS LAST NIGHT: <schedule>
```

The only real change is the cast list. It's currently built as `"- You."` plus
the others, which makes it unique per character. List everyone by name uniformly
and let the `YOU ARE:` block downstream establish which one they are — a 3B
model handles that fine, and the anti-invention guarantee (the list is complete,
nobody else exists) is unaffected.

Payoff: ~800 shared tokens no longer reprocessed on a cold switch, about **700 ms**.

This does **not** fight your recency design. The schedule block stays last,
where the comment at line 645 correctly wants it. You're only moving
character-specific material *later*, which is the same direction that comment
argues for.

---

### R3. Stop broadcasting group lines into every attendee's permanent history
**Effort: medium. Impact: high — this is the one that actually unlocks 4+.**

This is the O(N²) fix and the most important *architectural* change.

Today every line said in the Hall is written permanently into all N-1 other
attendees' `_histories` as a framed narration block. With 4 attendees, one round
of conversation deposits roughly 600 tokens of duplicated text across the game's
memory; with 8 it's ~2,800. Every one of those characters then carries it for
the rest of the game, in the middle of their history where it can never be
trimmed without invalidating the cache.

`GroupChat` already keeps the canonical record — `scene_log`. Use it:

1. **During the scene**, render each attendee's view of `scene_log` *ephemerally*
   and append it to the duplicated history in `ask_group_member()`, right where
   `_build_turn_prompt()` already goes. Nothing persistent is written.
2. **At scene end**, write **one** condensed digest into each attendee's real
   history: who was there, what they themselves said, and the one or two claims
   made about them. Your `_condense()` already does the clipping.

Three things get better at once:

- Persistent history per character goes from O(N x rounds) to O(1) per meetup.
- The ephemeral block sits at the *tail*, so under R1 the cached prefix (system
  prompt + private interview) stays valid and only the new tail is prefilled —
  a few hundred tokens instead of a few thousand.
- The priming block and scene-ender stop accumulating across repeat meetups.

The rendered scene view can also be smarter than the current framing: one block
with a speaker-labelled transcript reads more clearly to a small model than N
separate `[THE HALL - ...]` headers, and it lets you drop older rounds of a long
scene without touching anyone's stored memory.

Keep the `_flush_heard()` framing discipline when you rewrite it — the
"THE DETECTIVE (the person questioning you)" / "another guest — NOT the
detective" tagging is doing real work and the comment explaining why is correct.

---

### R4. Give histories an explicit token budget and compaction step
**Effort: low–medium. Impact: medium now, high for long sessions.**

`_histories[id]` is unbounded and `n_keep = 4` means Ollama's truncation will
eat your system prompt — including the schedule block every alibi answer is read
from. You will not get an error; answers will just quietly start being invented
again, which is precisely the failure the whole CaseGenerator exists to prevent.

Take control of it in GDScript:

```gdscript
const HISTORY_TOKEN_BUDGET := 4500   # leaves room for turn prompt + generation
const HISTORY_KEEP_RECENT   := 8     # exchanges kept verbatim

# chars / 3.6 is a decent English estimate and costs nothing
func _approx_tokens(history: Array) -> int
func _compact_history(id: String) -> void
```

When over budget, fold everything older than the last 8 exchanges into a single
message:

```
[EARLIER IN THIS INVESTIGATION - what you have already told the detective:]
- <condensed answer>
- <condensed answer>
```

Two implementation notes that matter:

- **Compact in big steps, rarely.** Any rewrite of the history prefix
  invalidates the KV slot and forces a full reprocess. Halving the history once
  every ~15 exchanges costs one expensive turn; trimming one message per turn
  costs *every* turn. Do the former.
- Compaction must never touch the system message. Keep index 0 pinned.

You already have `private_recap()` and `_condense()` — this is the same
machinery promoted from a prompt-time hint to a real memory policy.

---

### R5. Three one-line changes worth taking immediately
**Effort: trivial. Impact: medium.**

**a) `keep_alive` per request.** Add to every body dict in `GameManager`:

```gdscript
"keep_alive": "30m",
```

Removes the 60-second cold-reload cliff without touching the environment.

**b) `MAX_RESPONSE_TOKENS := 300` is far too generous.** Observed replies run
13–154 tokens; the prompt asks for 1–3 sentences. At 29 ms/token a runaway
300-token reply is **8.8 seconds**. Drop it to ~140. `GROUP_MAX_TOKENS := 90`
could go to 70 — observed group replies averaged ~35.

**c) Add stop sequences.** Nothing currently stops the model writing a second
speaker's line and then being trimmed after you've already paid for it:

```gdscript
"options": {..., "stop": ["\n\n", "Detective:", "\nDetective"]},
```

Cheapest latency you will ever recover — you stop paying 29 ms/token for text
you were going to discard.

---

### R6. Stream the response
**Effort: medium. Impact: none on throughput, large on perceived latency.**

`"stream": false` means nothing renders until the entire reply is complete.
Generation is 34 tok/s, so a 35-token reply is 1 s of silence and a 90-token one
is 2.6 s — per attendee, sequentially.

With streaming, text appears roughly at reading speed and a four-person round
*feels* like a conversation instead of a load screen. Total wall time is
unchanged, but perceived latency is what actually caps how many people you can
put in a room before it stops being fun.

Godot's `HTTPRequest` doesn't stream. You'd move to `HTTPClient` with `poll()`
driven from `_process()`, reading Ollama's NDJSON one line per token. It's the
largest single piece of work on this list, and it's the one a player would
notice most.

Worth pairing with the existing "<name> is thinking..." signal: with streaming
you can switch that to the name appearing immediately and the line filling in.

---

### R7. Parallelise the first reaction round
**Effort: medium. Impact: high at 3–4 attendees. Requires R1.**

`GameManager` funnels everything through a single `HTTPRequest` and a `_busy`
flag, so all N turns are strictly sequential. With `NUM_PARALLEL=4` the GPU can
genuinely serve four at once, and you're leaving that on the table.

The catch is that sequencing is *deliberate* — each attendee hears the previous
one, which is what makes "one accuses, one defends, you referee" work.

A hybrid keeps the drama and most of the speedup:

- **Round 1 — parallel.** Everyone reacts to the detective's line simultaneously,
  none of them hearing each other. Fire N requests across N `HTTPRequest` nodes.
  Wall time becomes `max` rather than `sum`. Reveal the replies in rotation order
  so it still reads as a room.
- **Round 2 — sequential, and only for who needs it.** Anyone whose line
  contradicts another's gets a follow-up turn that *has* heard the rest.

This also fits the fiction better than it sounds: people in a room genuinely do
react at once, and the interesting exchange is the second beat.

If you'd rather not restructure the turn engine, a smaller version of the same
idea: keep turns sequential but **speculatively prefill** the next speaker's
prompt while the current one generates. Under R1 they're on different slots, so
it's free parallelism with no design change at all.

---

### R8. Consider the model's KV geometry, not just its size
**Effort: low to test. Impact: medium.**

You said model changes are on the table. The relevant axis here isn't parameter
count — it's KV heads, because that's what sets your per-token cache cost and
therefore how many slots fit in 6 GB.

| Model | KV heads | Layers | KV/token (f16) | 4 slots x 8192 |
|---|---|---|---|---|
| Llama 3.2 3B (yours) | 8 | 28 | **112 KiB** | 3.58 GiB |
| Qwen 2.5 3B | 2 | 36 | **~36 KiB** | 1.15 GiB |

Qwen 2.5 3B has roughly **one third** the KV footprint. Four slots would fit at
full f16 with room to spare, or you could run six to eight slots — one per
suspect — and never take a cold switch again.

Caveats worth weighing before you move:

- You're on an **abliterated** build, presumably so suspects don't refuse to
  role-play a murderer or break character on interrogation pressure. That's a
  real constraint and I wouldn't trade it away blind — check whether a
  comparable uncensored Qwen build exists before committing.
- Instruction-following on your very structured prompts (the `##TIMELINE##`
  markers, the pipe format, "never recite the whole list unprompted") is the
  thing that would actually need re-testing. Your `CaseGeneratorTest.tscn`
  validates the generator, not the model — this would need play-testing.

Treat this as an experiment to run *after* R1–R3, not instead of them. R1 already
gets you to four slots on the model you have.

---

## 6. Housekeeping found along the way

**Something is spawning a second Ollama server in a retry loop.** `server.log`
contains **7,899** instances of:

```
Error: listen tcp 127.0.0.1:11434: bind: Only one usage of each socket address...
```

Most likely the Ollama desktop app and a manual `ollama serve` both running, or
a stale service. It's burning CPU and making the log much harder to read. Worth
tracking down before you start measuring changes, since it adds noise to
exactly the numbers you'll be watching.

**Case-notes summaries evict the resident character's cache.** `request_summary()`
sends a completely different prompt shape (its own system message + a flat
transcript), so opening the Tab panel mid-meetup blows whatever slot was warm,
and `SUMMARY_MAX_TOKENS := 340` at 29 ms/token can block the shared queue for up
to **10 seconds**. Under R1 you could reserve one slot for summaries; you could
also drop summary generation to a smaller model entirely, since it's an
extraction task and doesn't need the abliterated build.

Its system prompt has the same LCP problem as R2, incidentally — the suspect's
name lands in the second sentence. Moving the name after the format
specification would let all eight summary requests share a prefix.

---

## 7. Suggested order, with expected numbers

Projected wall time per detective line, **4 attendees, round 5**:

| After | Prefill/turn | Gen/turn | Per line (4 turns) | vs. today |
|---|---|---|---|---|
| Today | ~1,120 ms | ~1,020 ms | **~10.1 s** | — |
| + R1 (env only) | ~50 ms | ~1,020 ms | **~4.3 s** | 2.3x |
| + R5 (stop seqs, shorter cap) | ~50 ms | ~750 ms | **~3.2 s** | 3.2x |
| + R2, R3 (prefix + ephemeral scene) | ~40 ms | ~750 ms | **~3.1 s**, and flat as the scene runs long | 3.3x |
| + R7 (parallel first round) | — | — | **~1.2 s** for the reaction round | ~8x |
| + R6 (streaming) | — | — | first words in <400 ms | perceptual |

**Do them in this order:**

1. **R1 + R5** — an afternoon, no architecture risk, gets you from 10 s to ~3 s.
   Re-measure from `server.log` before doing anything else; the numbers will
   tell you whether the rest is even needed.
2. **R2** — cheap, self-contained, makes everything downstream cheaper.
3. **R3** — the real unlock for 4 attendees, and it removes the accumulating
   cruft from repeat meetups regardless of performance.
4. **R4** — do this before you ship longer sessions. Silent truncation of the
   schedule block is a *correctness* bug, not a performance one, and it will
   look like the model hallucinating.
5. **R6 / R7 / R8** — only if you still want more after the above.

Raising `MAX_HALL_ATTENDEES` from 2 to 4 is safe after step 3.

---

## 8. Things I deliberately did not recommend

- **Reducing `OLLAMA_NUM_CTX` from 8192.** Tempting for VRAM, but your histories
  legitimately reach ~2,900 tokens in a two-person meetup and would exceed 4096
  with four. Fix the growth (R3) and the eviction policy (R4) rather than the
  ceiling. 6144 becomes reasonable *after* R3 and R4 land.
- **Trimming the system prompt.** It's ~1,400 tokens and reads as though every
  paragraph was added to fix something specific — the comments confirm that. It
  is also the part that caches best. Under R1 it costs ~50 ms to reuse. Leave it
  alone; the tokens are not where your time is going.
- **Summarising histories with the model itself.** A second model call to
  compress memory costs more than the memory saves at this scale. `_condense()`
  is string manipulation and it's free.
- **Lowering `temperature`.** 0.8 private / 0.6 group is a good split and the
  reasoning in the comment is sound. Temperature doesn't affect speed.

---

*Reviewed: `GameManager.gd` (1,262 lines), `GroupChat.gd` (739), `NPCCharacter.gd`
(267), `Main.gd` (constants), plus `server.log` / `server-3.log` — 39 completed
requests across two play sessions.*
