# Why your Hall meetups are slow — the plain English version

Same findings as the technical report, but every term explained as it comes up.

---

## The one-sentence version

Your AI model has to **re-read a suspect's entire conversation from the
beginning every time you switch to a different suspect** — and a Hall meetup is
nothing but switching between suspects. That re-reading is where almost all your
waiting time goes, and it's fixable mostly by changing a setting.

---

## First, five words you need

I'll use these constantly, so here's what they actually mean.

### Token
A chunk of text, roughly ¾ of a word. "Archibald Manor" is about 4 tokens.
A typical suspect's reply is ~35 tokens. Your system prompt (all those
instructions about the case, the closed door, their schedule) is about 1,400
tokens — roughly 1,000 words.

Everything the AI does is measured in tokens, because that's the unit of work.

### The two things the model does, and only one of them is unavoidable

When you ask a suspect a question, the model does **two separate jobs**:

**Job 1 — Reading (the technical name is "prefill" or "prompt eval").**
Before it can say anything, it reads the entire conversation so far: the system
prompt, every previous question, every previous answer. On your machine this
goes at about **1,150 tokens per second**.

**Job 2 — Writing (the technical name is "generation" or "eval").**
It produces the reply, one token at a time. On your machine this goes at about
**34 tokens per second** — roughly 33× slower than reading, because writing each
token requires a full pass through the model.

So: a 35-token reply takes about **1 second to write**. That's your floor. You
can't beat it without a smaller/faster model, and 1 second is fine.

The problem is Job 1. Reading 2,900 tokens takes ~2.5 seconds. And there's a
trick that's *supposed* to make you not have to do it.

### The KV cache — "the model's bookmark"
After the model reads a conversation, it keeps its working notes in GPU memory.
The technical name is the **KV cache**. Think of it as a bookmark plus
everything the model figured out while reading up to that point.

If you ask the *same* suspect a follow-up question, the model doesn't re-read
anything. It finds its bookmark, reads only your new question (~15 tokens,
about 15 milliseconds), and starts writing. This is why one-on-one interviews
feel fine.

### A "slot" — how many bookmarks it can hold at once
Here's the catch, and it's the whole problem:

> **Your Ollama is configured to hold exactly ONE bookmark at a time.**

The setting is called `OLLAMA_NUM_PARALLEL`, and yours is set to `1` — the
default. One slot means one bookmark.

Each suspect is a completely separate conversation with its own history. So when
you're in the Hall talking to Marcus and Victoria:

- Ask the room something → **Marcus's turn.** Model loads Marcus's bookmark,
  reads his new material, replies.
- Now → **Victoria's turn.** But the one slot is holding *Marcus's* bookmark.
  So it throws Marcus's away, and reads Victoria's entire conversation from
  the top.
- Now → **Marcus again.** Throws away Victoria's, re-reads Marcus's from the top.

Every single turn is a from-scratch re-read. It's like having one desk and one
open book: every time you switch books you lose your page.

### Context window
The maximum amount of conversation the model can hold at once — yours is set to
8,192 tokens. When a conversation exceeds it, the **oldest** material gets
silently deleted. More on why that's dangerous in Fix #4.

---

## Your computer (measured, not guessed)

I read your actual Ollama logs at `%LOCALAPPDATA%\Ollama\server.log`.

| | |
|---|---|
| Graphics card | NVIDIA RTX 4050 Laptop, **6 GB** video memory (~5 GB usable) |
| Processor | Intel i7-13620H |
| Model | `llama3.2-abliterate:3b` — **fully loaded onto the GPU** ✓ |
| Reading speed | ~1,150 tokens/sec |
| Writing speed | ~34 tokens/sec |

**Your hardware is not the problem.** The model is entirely on the graphics card,
which is exactly where you want it. This is a configuration and code problem,
not a "buy a better laptop" problem.

---

## The evidence, in your own logs

Ollama writes down how long each job took. Here's a one-on-one interview —
consecutive questions to the same suspect:

```
prompt eval time =   94.33 ms /  49 tokens     <-- reading
prompt eval time =   98.77 ms /  53 tokens
prompt eval time =   57.15 ms /  14 tokens
prompt eval time =   77.13 ms /  61 tokens
```

**Reading only 14–61 tokens.** The bookmark worked. It only had to read your new
question. Reading takes about a tenth of a second and the whole turn is ~2.5
seconds, nearly all of it writing the reply. That's healthy.

Now here's a Hall meetup with two suspects:

```
prompt eval time = 1744.06 ms / 2246 tokens    <-- reading
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

**Reading 826–2,246 tokens, twelve times in a row.** That's six rounds of
back-and-forth, and the bookmark failed every single time. Each of those is
roughly a second of pure waste — the model re-reading things it already read
thirty seconds ago.

Ollama even explains itself. This line appears before each miss:

```
selected slot by LCP similarity, f_sim_best = 0.683
cached n_tokens = 1985, memory_seq_rm [1985, end)
```

Translated: *"The bookmark I'm holding matches this new conversation for only
68% of its length. I can reuse the first 1,985 tokens, then I have to re-read
the remaining 922 from scratch."*

In one-on-one mode, that same number is 0.95–0.99 — near-perfect reuse.

### Why is it 68% and not 99%?

Because of a single line in `GameManager.gd`:

```gdscript
text += "You are role-playing as %s in an interactive murder-mystery game..." % c["name"]
```

The suspect's **name is the sixth word of the prompt.** The model compares
conversations from the very first word and stops at the first difference. So
Marcus's prompt and Victoria's prompt stop matching almost immediately — even
though the next ~800 tokens after that (the case, the closed door, where you are
now, the rules about not inventing people) are **word-for-word identical for all
eight suspects.**

The 68% you're getting comes from a slower backup cache that lives outside the
GPU, which is also why you're paying an extra ~380 ms per turn to shuffle it
around.

---

## Why 4 suspects is much worse than 2× as bad

Two separate things grow when you add people to the room.

**1. More turns per line you type.** Obvious one. Say something to a room of 4,
and that's 4 sequential AI requests instead of 2.

**2. Every suspect's conversation gets longer, faster.** This one is sneaky.

Right now, when Marcus says something in the Hall, your code writes it into
Victoria's private memory *and* Eleanor's *and* Eugene's (via
`note_to_character()`). So with 4 people in a room, every single line spoken
gets stored **3 times over**, permanently, in three different conversations.

Which means each suspect's conversation grows ~3× faster than in a two-hander,
and each conversation is what has to be re-read every turn. The costs multiply
rather than add.

Here's where it lands, using your measured speeds:

| People in the Hall | Conversation length by round 5 | **Wait per line you type** |
|---|---|---|
| 2 (today) | ~2,700 tokens | **~4.2 seconds** |
| 3 | ~2,900 tokens | **~7.2 seconds** |
| 4 | ~3,200 tokens | **~10.1 seconds** |
| 4, by round 10 | ~4,650 tokens | **~12.4 seconds** |

And because you have `"stream": false`, **nothing appears on screen** until the
entire round is finished. Ten seconds of a frozen text box.

That's why `MAX_HALL_ATTENDEES := 2` feels right today. It isn't a design
instinct — it's the ceiling your configuration imposed.

---

## How your game stores memory right now

Plain description of what's actually happening in the code:

Each suspect has a list of messages — `_histories["marcus"]`, and so on. It
starts with one big instruction message (the system prompt: who they are, the
case, their schedule, whether they're the murderer). Then every question you ask
and every answer they give gets appended to the end of the list.

Things get added to that list from four places:

1. You ask them something privately → question + answer appended.
2. Somebody speaks in a Hall meetup → appended to **everyone else's** list too.
3. A meetup opens → a "you're in a group scene now" briefing appended.
4. A meetup ends → a "the meeting is over, you're alone with the detective"
   note appended.

**Nothing is ever removed.** The list only resets when you start a new game.

So if you run three meetups with the same suspect, they're permanently carrying
three copies of the "you're in a group scene" briefing and three copies of the
"meeting's over" note, forever, in the middle of their memory.

One thing your code already gets right, worth saying: the turn instruction in
`GroupChat._build_turn_prompt()` is sent to the model but deliberately **not
saved**. That was the correct call, and the comment explaining why is spot on.

---

## The fixes

Eight of them, easiest and highest-payoff first.

---

### Fix #1 — Give the model more bookmarks
**Effort: none. Just settings. Biggest single win.**

Set three environment variables:

```
OLLAMA_NUM_PARALLEL    = 4
OLLAMA_FLASH_ATTENTION = 1
OLLAMA_KV_CACHE_TYPE   = q8_0
```

**What the first one does:** 4 bookmarks instead of 1. Now each of your four
suspects keeps their own place, and nobody has to re-read anything. Reading time
per turn drops from **~1,000 ms to ~50 ms**, and — this is the important part —
**it stops growing as the conversation gets longer.** A bookmark doesn't care
how long the book is.

**Why the other two aren't optional:** bookmarks live in graphics memory, and
you only have ~5 GB. From your own logs, each bookmark costs **112 KB per token**
of conversation, so a full 8,192-token bookmark is **896 MB**.

| Setup | 4 bookmarks | Plus the model (~2 GB) | Fits in 5 GB? |
|---|---|---|---|
| As-is | 3.58 GB | ~5.98 GB | **No** — would spill onto the CPU and get *much* slower |
| With `q8_0` | 1.79 GB | ~4.19 GB | **Yes** |

`KV_CACHE_TYPE=q8_0` stores the bookmarks in a more compact form — roughly half
the size, with a quality difference you won't notice on a 3B roleplay model.
It requires flash attention to be turned on, which is why all three go together.
(Flash attention is just a more efficient way of doing the same math. It's on by
default in most setups; yours is off.)

**Also worth setting:** `OLLAMA_KEEP_ALIVE = -1`. Right now it's 5 minutes,
meaning if a player reads their case notes for six minutes, Ollama unloads the
model — and your log shows reloading it takes **60 seconds**. That's a brutal
worst case for a player who just wanted to check their notes.

**How to check it worked:** after your first question, search `server.log` for
`n_slots`. It should say 4. If `n_ctx_slot` comes out as 2048 instead of 8192,
Ollama divided your context instead of multiplying it — drop to
`NUM_PARALLEL=3` and re-check.

---

### Fix #2 — Move the suspect's name out of the first sentence
**Effort: about 30 lines of rearranging. Works together with Fix #1.**

Remember: the model compares conversations from word one and stops at the first
difference. Your suspect's name is word six.

Rearrange `_build_system_prompt()` so all the identical stuff comes first:

```
IDENTICAL FOR ALL 8 SUSPECTS (~800 tokens):
  "You are role-playing a character in a murder-mystery game called
   Archibald Manor..."          <-- no name here
  ...all the "keep it short, 1-3 sentences" rules...
  THE CASE                       (already identical)
  THE CLOSED DOOR                (already identical)
  WHERE YOU ARE NOW              (already identical)
  EVERYONE IN THE HOUSE          <-- needs one change, see below
  WHAT YOU KNOW AND DON'T KNOW   (already identical)
  PHYSICAL ACTIONS               (already identical)

THEN THE PERSONAL STUFF:
  YOU ARE: Marcus Sterling, investment banker, charismatic...
  [murderer secret, or "you are innocent"]
  [Dr Blackwood's expert finding]
  YOUR MOVEMENTS LAST NIGHT: <their schedule>
```

Almost all of it is already generic — you just have to move the name. The one
real edit is the cast list, which currently reads `"- You."` followed by the
others, making it unique per suspect. List all eight by name instead, identically
for everyone, and let the `YOU ARE:` section below establish which one they are.
A 3B model handles that fine, and your "this list is complete, nobody else
exists" guarantee is unaffected.

**Payoff:** ~800 tokens of shared text no longer re-read on a cold switch, about
**700 ms**.

**This doesn't fight your existing design.** Your comment at line 645 says the
schedule block goes last because small models weight the end of the prompt most
heavily. That's correct, and it stays last. You're only pushing character-specific
material *later*, which is the same direction that comment already argues for.

---

### Fix #3 — Stop copying every Hall line into everyone's permanent memory
**Effort: medium. This is the one that actually makes 4 people practical.**

Right now, one line spoken in a room of 4 gets written permanently into 3 other
suspects' memories. Round after round, that's a lot of duplicated text sitting in
the *middle* of each conversation, where you can't remove it later without
throwing away the bookmark.

**The good news:** `GroupChat` already keeps one clean copy of everything — it's
called `scene_log`. Use that instead.

**During the meetup:** build each suspect's view of the scene fresh each turn and
attach it to the *end* of what gets sent — the same place `_build_turn_prompt()`
already goes. Send it, don't save it.

**When the meetup ends:** save **one** short summary into each suspect's real
memory. Who was there, what they themselves said, and the one or two accusations
made against them. Your existing `_condense()` function already does the
shortening.

Three things improve at once:

- Each suspect's stored memory stops growing with the size of the room.
- Because the fresh part goes at the **end**, the bookmark for everything before
  it stays valid. The model re-reads a few hundred tokens instead of a few
  thousand.
- The "you're in a group scene" and "the meeting is over" notes stop piling up
  across repeat meetups.

When you rewrite this, keep the careful labelling you already have — the
"THE DETECTIVE (the person questioning you)" and "another guest — NOT the
detective" tags are doing real work, and the comment explaining why they exist
is right.

**After this fix, raising `MAX_HALL_ATTENDEES` from 2 to 4 is safe.**

---

### Fix #4 — Decide yourself what gets forgotten
**Effort: low-medium. This one is a correctness bug, not a speed bug.**

Conversations can't exceed 8,192 tokens. When they do, Ollama deletes the oldest
material to make room.

The oldest material is **your system prompt.** Including the schedule block —
the thing every alibi answer is read from, the whole reason `CaseGenerator`
exists.

Ollama's log confirms it's not protected: `n_keep = 4`. Only four tokens are
pinned. Everything else is fair game.

You will get **no error**. Suspects will just quietly start making up where they
were again, and it'll look like the model hallucinating rather than what it is.

So manage it yourself in GDScript:

```gdscript
const HISTORY_TOKEN_BUDGET := 4500   # room left over for the turn prompt + reply
const HISTORY_KEEP_RECENT  := 8      # keep the last 8 exchanges word-for-word
```

When a conversation goes over budget, squash everything older than the last 8
exchanges into one message:

```
[EARLIER IN THIS INVESTIGATION - what you have already told the detective:]
- I was in the Library from nine until ten, on my own.
- I last saw Lord Archibald at dinner.
```

(To estimate tokens without any extra work: characters ÷ 3.6 is close enough
for English.)

**Two things to get right:**

- **Squash rarely, in big chunks.** Any edit to the earlier part of a
  conversation invalidates the bookmark and forces a full re-read. Halving the
  history once every ~15 exchanges costs you one slow turn. Trimming one message
  every turn costs you a slow turn *every time*.
- **Never touch message #0**, the system prompt. Pin it.

You've already got the pieces — `private_recap()` and `_condense()` do this
kind of shortening. This is promoting them from a prompt hint to a real memory
policy.

---

### Fix #5 — Three one-line changes, worth doing today
**Effort: trivial.**

**(a) Stop the model unloading.** Add to each request in `GameManager.gd`:

```gdscript
"keep_alive": "30m",
```

Same effect as the environment variable in Fix #1, but from inside your code.
Kills the 60-second reload.

**(b) `MAX_RESPONSE_TOKENS := 300` is far too generous.** Your replies actually
run 13–154 tokens, and your prompt asks for 1–3 sentences. But at 29 ms per
token, if the model *does* ramble to 300, that's **8.8 seconds**. Set it to 140.
(`GROUP_MAX_TOKENS := 90` could go to 70 — group replies averaged ~35.)

**(c) Add stop words.** Right now nothing stops the model from writing a second
character's line and then having it thrown away — you paid 29 ms per token for
text you discard:

```gdscript
"options": {..., "stop": ["\n\n", "Detective:", "\nDetective"]},
```

This is the cheapest time you'll ever recover.

---

### Fix #6 — Show the words as they're typed
**Effort: medium-high. Doesn't make it faster — makes it *feel* enormously faster.**

`"stream": false` means the model finishes the whole reply before you see any of
it. At 34 tokens/sec, a 35-token reply is a full second of blank screen, and a
90-token one is 2.6 seconds — per suspect, one after another.

Ollama can send words as it produces them. Then text appears at roughly reading
speed and a four-person round feels like a conversation instead of a loading bar.

The work: Godot's `HTTPRequest` can't do this. You'd switch to `HTTPClient` and
`poll()` from `_process()`, reading Ollama's output one line at a time. It's the
biggest job on this list — and the one a player would notice most.

Pairs nicely with your existing "<name> is thinking..." message: with streaming
you can show the name straight away and let their line fill in underneath.

---

### Fix #7 — Let people react at the same time
**Effort: medium. Needs Fix #1 first.**

Your code sends one request at a time, through a single `HTTPRequest` with a
`_busy` flag. Once you have 4 bookmarks, your graphics card can genuinely handle
4 requests at once — you're leaving that on the table.

The complication is that the one-at-a-time order is **deliberate**: each suspect
hears the previous one, which is what makes "one accuses, one defends, you
referee" work.

A middle path keeps the drama and most of the speed:

- **First round, all at once.** Everyone reacts to *you*, not to each other.
  Fire all 4 requests simultaneously. Total wait becomes the *slowest* one,
  not the *sum* — roughly 1.2 seconds instead of 4.3. Reveal them in rotation
  order so it still reads like a room.
- **Second round, one at a time, only for whoever needs it.** Anyone whose line
  contradicts someone else's gets a follow-up turn that *has* heard the others.

This arguably fits the fiction better anyway — real people in a room do react at
once, and the interesting exchange is the comeback.

**Smaller version if you'd rather not restructure the turn engine:** keep turns
sequential, but start *reading* the next speaker's conversation while the
current one is still writing. With Fix #1 they're on separate bookmarks, so it's
free speed with no design change at all.

---

### Fix #8 — A different model might hold more bookmarks
**Effort: low to test, but test it last.**

You said a model change is on the table. The thing that matters here isn't size —
it's how much bookmark space each model needs per token.

| Model | Bookmark cost per token | 4 bookmarks × 8,192 tokens |
|---|---|---|
| Llama 3.2 3B (yours) | 112 KB | 3.58 GB |
| Qwen 2.5 3B | ~36 KB | 1.15 GB |

Qwen 2.5 3B needs about **a third** the space, because of how its internals are
arranged. You could run 4 bookmarks without any compression at all — or run
**eight**, one per suspect, and never take a cold switch for the rest of the game.

**Two reasons to be careful:**

- You're using an *abliterated* build, presumably so suspects don't refuse to
  play a murderer or break character under pressure. That's a real constraint —
  check whether an equivalent uncensored Qwen exists before switching.
- Your prompts are very structured (the `##TIMELINE##` markers, the pipe format,
  "never recite the whole list unprompted"). A different model would need
  play-testing on all of that. `CaseGeneratorTest.tscn` checks your *generator*,
  not the model.

**Do this after Fixes #1–#3, not instead of them.** Fix #1 already gets you four
bookmarks on the model you already have and already trust.

---

## Two other things I noticed

**Something keeps trying to start a second Ollama server.** Your log contains
**7,899** copies of:

```
Error: listen tcp 127.0.0.1:11434: bind: Only one usage of each socket address...
```

That's almost certainly the Ollama desktop app *and* a manual `ollama serve`
both running, or a leftover Windows service. It's wasting CPU and burying the
useful lines in your log. Worth sorting out **before** you start measuring
changes, so your before-and-after numbers are clean.

**Opening your case notes throws away the bookmark.** `request_summary()` sends a
totally different kind of prompt, so it evicts whichever suspect was loaded. And
`SUMMARY_MAX_TOKENS := 340` at 29 ms/token can tie up the queue for **10
seconds**. With Fix #1 you could reserve one of the four bookmarks for summaries.
You could also run summaries on a smaller, ordinary model — summarizing is a
tidy-up job that doesn't need the abliterated build at all.

(It has the same name-too-early problem as Fix #2, incidentally — the suspect's
name is in the second sentence.)

---

## What order to do them in, and what you get

Wait per line typed, with **4 suspects in the Hall, round 5**:

| After doing... | Wait per line | Improvement |
|---|---|---|
| Nothing (today) | **~10.1 s** | — |
| Fix #1 (settings only) | **~4.3 s** | 2.3× faster |
| \+ Fix #5 (stop words, shorter cap) | **~3.2 s** | 3.2× faster |
| \+ Fixes #2 & #3 | **~3.1 s**, and it stops getting worse as the scene runs long | 3.3× faster |
| \+ Fix #7 (react simultaneously) | **~1.2 s** for the reaction round | ~8× faster |
| \+ Fix #6 (streaming) | first words on screen in under half a second | feels instant |

**Recommended order:**

1. **Fix #1 and Fix #5 first.** An afternoon's work, no risk of breaking
   anything, and it takes you from 10 seconds to about 3. **Then re-measure**
   from `server.log` — the numbers may well tell you the rest isn't needed.
2. **Fix #2.** Cheap, self-contained, makes everything after it cheaper.
3. **Fix #3.** The real unlock for 4 people — and it cleans up the accumulating
   junk from repeat meetups regardless of speed.
4. **Fix #4** before you ship longer sessions. This one is about *correctness*.
   Suspects silently forgetting their own schedule will look like the AI
   hallucinating, and you'll spend a long time chasing the wrong bug.
5. **Fixes #6, #7, #8** only if you still want more after all that.

---

## Things I deliberately did *not* suggest

- **Shrinking the context window from 8,192.** Tempting for graphics memory, but
  your conversations genuinely reach ~2,900 tokens with two people and would
  blow past 4,096 with four. Fix the *growth* (#3) and the *forgetting policy*
  (#4) instead of lowering the ceiling. 6,144 becomes reasonable once those land.
- **Cutting down the system prompt.** It's ~1,400 tokens and it reads like every
  paragraph was added to fix a specific problem — your comments confirm that.
  It's also the part that caches best. Once Fix #1 is in, reusing the whole thing
  costs ~50 ms. Leave it alone; that's not where your time is going.
- **Using the AI to summarize its own memory.** A second AI call to compress
  memory costs more than the memory it saves at this scale. `_condense()` is
  plain string manipulation and it's free.
- **Lowering the temperature setting.** Your 0.8 for private / 0.6 for group
  split is a good one and the reasoning in your comment is sound. Temperature
  doesn't affect speed at all.

---

*Based on reading `GameManager.gd`, `GroupChat.gd`, `NPCCharacter.gd`, and
`Main.gd`, plus 39 real requests recorded in your Ollama logs across two play
sessions.*
