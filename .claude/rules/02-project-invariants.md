# Project invariants

The things that must not break. Each one has already broken at least once, or
would fail in a way nobody would notice for weeks.

They share a property: **none of them crash.** A broken invariant here produces
a game that runs, looks right, and is quietly wrong. That is why they are
written down rather than left to judgement.

---

## 1. Character slot numbers are permanent and are never reused

`GameManager.CHARACTERS[n]["slot"]`.

Case codes encode the cast as a bitmask over slot numbers. If a slot is reused,
every case code ever generated that referenced it decodes to a different
person. The code still parses, still produces a plausible-looking house, and is
quietly the wrong mystery.

**Rules:**

- Take the number in `NEXT_FREE_SLOT`, then increment it.
- Retiring a character burns their slot **forever**. Leave a comment saying so.
- Never reduce `NEXT_FREE_SLOT`.
- Append to the end of `CHARACTERS`. Never insert in the middle.

**Enforced by:** `GameManager._ready()` asserts uniqueness at startup;
`CaseGeneratorTest.tscn` checks uniqueness, a 200-case round trip, and that a
retired slot is refused.

**Not enforced:** reuse of a burned slot. Nothing can detect that. This is on
you.

---

## 2. A generated case must be provably solvable

`CaseGenerator.validate()` returns a list of problems, and `generate()` throws
the candidate away if it is not empty.

The single most important line in it:

```gdscript
errs.append("NOBODY can contradict the murderer - case is unwinnable")
```

If you loosen validation, you can ship a mystery with no solution. Nobody finds
out until a player has spent an hour on it.

**Rules:**

- Every design rule goes in `validate()`, not in a comment and not in your head.
- Adding a constraint to `generate()` means adding the matching check to
  `validate()`.
- **Run `Scenes/CaseGeneratorTest.tscn` (F6) after every change to that file.**
  Expect `1000/1000 valid`.

---

## 3. Innocents never lie

`validate()` checks that every innocent's `claimed_path` equals their
`true_path`, and that exactly one person in the house is lying, about exactly
one block.

This is the pillar the whole game stands on. It is what makes a contradiction
between two suspects *mean* something. Before it, everyone improvised and two
conflicting stories told you nothing.

If you want more than one liar, that is a real design change with consequences
throughout `TODO.md`, not a tweak.

---

## 4. Nothing that has left the fiction ever enters a character's history

`GameManager._reply_breaks_character()` runs on every reply **before** it
reaches the screen or the history.

The reason is the cascade. A model's own previous replies are the strongest
steer in its context, so one out-of-character reply conditions every reply
after it. It has already happened once: a refusal written in a help-desk voice
went into the history, and two turns later that suspect announced a murderer
and declared the game over. She had invented it, and the player believed her.

**Rules:**

- Guard first, then history, then screen. Never reorder those.
- Rejected replies are retried once, then replaced with a written fallback.
  Never show the player nothing.
- Run `Scenes/GuardTest.tscn` after touching the guard or any of its lists.
- A guard that is too tight is also a bug. Rejecting honest answers cost eight
  of twenty-six exchanges in one log, and that failure is invisible: it reads
  as a bad model, not as a bad guard.

---

## 5. `OLLAMA_NUM_CTX` must be set explicitly, and history must stay inside it

Ollama's default context is small, and it derives one from VRAM if you say
nothing. When a conversation outgrows the window, the oldest messages are
dropped, starting with the system prompt, because the runner only pins four
tokens.

The last thing in the system prompt is the block every alibi answer is read
off. So the failure is: no error, and suspects quietly start improvising their
whereabouts again. Which is the exact failure the case generator exists to
prevent, and it reads as hallucination rather than as memory loss.

**Rules:**

- `OLLAMA_NUM_CTX` stays explicit in every request.
- `HISTORY_TOKEN_BUDGET` stays comfortably below it, leaving room for the group
  turn prompt (about 700 tokens) and the reply.
- `_compact_history_if_needed()` decides what is forgotten, and it is never the
  system prompt.

---

## 6. `Main.GRID` and `CaseGenerator.GRID` must stay identical

Two copies of the nine-room layout, deliberately. The generator keeps its own
so it stays a closed system with no scene-tree dependency, which is what makes
it testable a thousand times a second.

If they drift, the generator will produce schedules for rooms that do not exist,
or fail to use rooms that do.

**Related and equally important:** the upper-floor room names in
`ManorBuilder.FLOORS` are deliberately kept **out** of both grids. A room the
generator has never heard of cannot end up in a schedule, an alibi, a witness
list or as the murder room. That is what keeps every suspect downstairs without
one line of change to the generator. Do not "fix" this.

---

## 7. Debug keys must be capable of disappearing entirely

`GameManager.DEBUG_KEYS`. When false, the actions are never registered, so the
keys do nothing at all. There is no hidden binding to find in a shipped build.

Ctrl+1 prints the entire truth table. Ctrl+2 dumps a raw prompt payload. Either
one hands a player far more than any exploit in the dialogue ever could.

**Rules:**

- Every debug key is registered inside `if DEBUG_KEYS:`.
- Every handler short-circuits on `GameManager.DEBUG_KEYS` **before** calling
  `is_action_pressed()`, because asking about an action that does not exist
  raises an error.
- Pass `exact_match = true`, or a plain `1` fires the Ctrl+1 action.

---

## 8. `CaseGenerator` stays out of the scene tree

`extends RefCounted`. No signals, no autoload references, no Ollama, no UI.

That is what lets `CaseGeneratorTest` build a thousand cases in a loop without
building a single mansion. Reach for `GameManager` from inside it once, and the
test scene stops being possible.

If you need game state in there, pass it in as an argument.

---

## 9. Anything the player reasons about is drawn from the case RNG

Not from a global `randi()`.

The dropped personal item at the crime scene is drawn from the case RNG,
because replaying a case code has to produce the same item. It is a fact of the
mystery, not set dressing.

**The test:** could a player use this to work out who did it? If yes, it comes
from the case RNG. If it is purely cosmetic, a global random is fine.

---

## The short checklist

Before opening a pull request:

- [ ] Touched `CaseGenerator.gd`, `CHARACTERS` or case codes?
      **Run `CaseGeneratorTest.tscn`, expect 1000/1000.**
- [ ] Touched the guard or its keyword lists? **Run `GuardTest.tscn`.**
- [ ] Touched history or group prompts? **Run `DialogueOptTest.tscn`.**
- [ ] Added a character? Slot from `NEXT_FREE_SLOT`, incremented, appended.
- [ ] Added randomness the player can reason about? From the case RNG.
- [ ] Added a debug aid? Behind `DEBUG_KEYS`.
- [ ] Changed a tuned constant? Updated the comment saying what was measured.
