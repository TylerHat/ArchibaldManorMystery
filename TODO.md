# TODO: ideas to make Archibald Manor more interesting

Rules and features only — nothing here is about art, models, or scenery.

Each idea says what the **rule** is, **why** it's worth doing, and what it does to
**solvability**, since "every case is always catchable" is the pillar the whole
generator is built on and none of this is worth breaking it for.

**The one-line diagnosis of the current game:** exactly one person in the house
lies, and their lie is about the murder. So "who is lying" and "who is the
murderer" are the same question, and once you find the contradiction there is
nothing left to do but walk to the door. Most of what follows is about putting
distance between those two questions.

**If you only do three:** #1 (innocent secrets), #4 (accusation with stakes),
#8 (present evidence).

---

## A. Make lying interesting again

### 1. Innocent suspects with something to hide
**Rule:** the generator picks 1–2 innocents and gives each a *shameful but not
murderous* secret — an affair, a theft from the house, a gambling debt, going
through the victim's desk. That suspect lies about exactly one block of their
evening to conceal it. Their lie must **not** cover the murder slot, and must be
separately resolvable: if you confront them with the witness who saw them
elsewhere, they confess the lesser thing rather than the murder.

**Why:** this is the biggest single upgrade available. Right now the deduction
is "find the liar." With this it becomes "find the liar *whose lie is about the
murder*" — which is a real detective problem. It also makes the middle of a game
feel like progress instead of noise: you catch someone, you get a confession,
and it isn't the answer.

**Solvability:** protected as long as (a) no innocent's false block overlaps the
murder slot, and (b) each innocent lie has its own witness. Add both to
`validate()`. The murderer stays the only person lying *about the murder slot*,
so the existing guarantee is untouched.

### 2. Loyalty pairs — someone covers for someone else
**Rule:** Natalie Cross and Eugene Cross already share a surname; give the
generator an optional relationship (siblings, lovers, employer/employee, debtor)
and a chance that A falsely places themselves *with* B to give B an alibi B
didn't ask for. If B is the murderer, the murderer now has a corroborated lie
and you have to break two people instead of one. If B is innocent, it's the
cruellest red herring in the game.

**Why:** a second person's story that doesn't match reality, for a reason that
isn't guilt. Listed as out of scope in the plan doc — it's the obvious next step
now the truth table exists.

**Solvability:** needs a third party who saw the real situation, or the pair
becomes unbreakable. Generator constraint: at least one uninvolved witness
contradicts the covering account.

### 3. Hearsay has consequences
**Rule:** what you tell a suspect, they may repeat. If you say "Marcus told me he
was in the Study," that goes into Marcus's *and* the listener's world. The
murderer specifically is told to bank anything they learn about what others are
saying and adjust their deflection — not their alibi, which stays fixed.

**Why:** information becomes a resource you can spend or leak. It makes the
choice of *what to reveal in the Hall* a real decision rather than free.

**Solvability:** safe, provided the murderer's core lie is still forbidden to
change. Only their deflections adapt.

### 4. The murderer acts while you investigate
**Rule:** the murderer isn't a static puzzle. If you name their witness in a Hall
scene with the murderer present — "Eleanor says she was in the Library and never
saw you" — you've told the killer who the danger is. Consequences, escalating:
they start pre-emptively discrediting that witness ("she'd been drinking"), or
the dropped item vanishes from the scene if you haven't examined it yet, or
in the harshest version the witness is found dead and their testimony is gone.

**Why:** it makes the Hall mechanic genuinely double-edged, which is what it
needs — right now gathering people has no downside.

**Solvability:** must guarantee a fallback route (a second witness, or the
expert's time of death). Never let a player's mistake make a case unwinnable —
make it *harder*, not impossible.

---

## B. Make the ending mean something

### 5. The accusation has to be a case, not a name
**Rule:** at the door you present three things: **who**, **the room they lied
about being in**, and **the person who proves it**. All three right = a clean
conviction. Name right but reasoning wrong = they walk, or you get a lesser
ending. Optionally add the weapon for the Clue feel.

**Why:** right now wrong guesses are free, so eight names at the door beats
detective work. This makes the win condition test whether you actually
*understood* the case, and turns your notes into the thing you win with.

**Solvability:** unchanged — every element you must name is already generated
and already discoverable.

### 6. Limited accusations
**Rule:** one formal accusation, or two on an easier setting. A wrong one ends
the case (with the reveal) rather than shrugging.

**Why:** stakes. Pairs naturally with #5, and with a "are you sure?" summary
screen that reads your case back to you before you commit.

### 7. Case closed — the reconstruction
**Rule:** on any ending, play back the real night slot by slot against what you
believed: the moment the truth was first available to you, the contradiction you
found (or walked past), how many questions you spent, whether you ever examined
the body, who you wrongly suspected. Finish with a rating.

**Why:** it's the payoff, and it's what makes someone hit Play Again. It also
turns the existing ground-truth table into an ending rather than a debug key.

---

## C. Give the detective more verbs

### 8. Present evidence to a suspect
**Rule:** anything in your Scene tab can be shown to someone: "show the letter
opener to Victoria," or a UI button in the interview. It enters the prompt as a
physical fact happening now (the bracketed-action machinery already does exactly
this). Rules attached: showing the murderer their own dropped item is a heavy
rattle; showing the expert the body's window while she's lying about it is the
one thing that can crack her; showing a weapon to whoever it belongs near gets
a real reaction.

**Why:** the crime scene is currently a reading exercise. This makes it
ammunition, and it's the cheapest big win on the list — most of the plumbing
exists.

### 9. Quote from your notes
**Rule:** pick a line a suspect actually said, from your notes, and read it back
at them or at someone else. The quoted text is passed as a verbatim,
game-verified fact, so it bypasses the anti-invention guard that currently makes
suspects deny things you *claim* they said.

**Why:** today you can be gaslit by your own suspects — you know Marcus said it,
he denies it, and the game sides with him. A quote the game itself vouches for
fixes that and makes the notes a weapon.

### 10. Search rooms
**Rule:** rooms hold findable things beyond the murder room: a burned letter in a
fireplace, a hidden ledger, a cleaned-up stain, an item stashed where someone's
schedule actually took them. The generator plants one or two along the
murderer's real route and one along a red-herring route.

**Why:** gives you a reason to walk the whole house instead of the shortest path
between capsules, and gives you leads you found yourself rather than were told.

**Solvability:** strictly additive — never the *only* route to the answer.

### 11. Control the house
**Rule:** you can confine a suspect to a room, or forbid two from being together,
and the constable (#14) enforces it. The flip side is the interesting part:
suspects you leave alone together **compare stories**, and afterwards their
accounts start agreeing on details they shouldn't. The murderer exploits this
deliberately.

**Why:** turns the existing "go to the hall" order into a resource-management
layer, and gives the murderer something to do with your inattention.

### 12. Interrogation stances
**Rule:** the same question asked warmly, coldly, or as a bluff gets different
results. Track a hidden per-suspect rapport: press someone too hard too early
and they go monosyllabic for a while; earn trust and they volunteer gossip about
someone else. Innocents reward patience, the murderer is safest when you're
polite to them.

**Why:** makes *how* you interrogate matter, not just what you ask. Fits the
existing prompt architecture — it's a paragraph in the system prompt keyed off
one number.

---

## D. Give the world more to find

### 13. Generated motives, with physical traces
**Rule:** retire the fixed `flavor` string as the motive. Generate one per game
from a pool, and plant its evidence: a changed will naming a beneficiary, a
cancelled cheque, a threatening letter, a story about to run. Two or three
suspects get motive traces so motive alone never convicts.

**Why:** the plan doc marks this out of scope, but motive is currently the one
part of the mystery that never changes, and it's the part players find most
satisfying to discover. It also gives the endgame reveal something to say that
you didn't already know.

**Solvability:** motive is colour on top of the timeline proof, never a
substitute for it — otherwise the timeline stops mattering.

### 14. A constable you can spend
**Rule:** a police officer in the Hall who is not a suspect and not a
conversation — he's a set of services with costs. Run a background check on one
suspect (reveals their secret from #1 or motive from #13). Search one room
thoroughly (finds what #10 planted). Hold someone in the Hall so they stop
moving. Each takes time on the clock (#16), and you can't do all of them.

**Why:** you asked about police characters — this is the version that adds rules
rather than another person to talk to. It's also the natural home for a hint
system that doesn't feel like a hint system.

### 15. What people noticed about each other
**Rule:** the schedule already knows exactly who shared a room with whom. Have
the generator attach one *behavioural* observation to a real shared slot: someone
seemed rattled, was out of breath, had changed their jacket, was carrying
something, left in a hurry. Weight them so the murderer generates one shortly
after the murder — and give one or two innocents a harmless one so it isn't a
tell.

**Why:** companions are currently pure alibi bookkeeping. This turns "who were
you with" into a question worth asking twice, and produces the classic mystery
beat: a witness who saw something meaningful without knowing it was meaningful.

**Solvability:** additive; a shortcut to the answer, not a requirement.

### 16. A clock
**Rule:** the police take the case at noon. You have N questions, or real minutes,
and things cost: a private question is cheap, a Hall round is expensive, a
constable service costs a chunk. When time runs out you accuse with what you have.

**Why:** every other idea on this list gets sharper when you can't do all of
them. Make it an optional difficulty rather than the default.

### 17. Difficulty presets that change the generator, not the UI
**Rule:** wire difficulty into the constraints. Easy — three witnesses, a 2-slot
lie, expert always present, generous clock. Hard — a single 1-slot lie, exactly
one witness, more innocents with uncorroborated slots, secrets (#1) on, expert
may be absent, no debug overlay.

**Why:** the generator is already constraint-driven, so this is close to free,
and it's the cheapest replayability on the list.

### 18. An anonymous note
**Rule:** at a fixed beat — say after your sixth question, or when the clock is
half gone — a note appears under the door. It says one thing that is *true but
partial*: "Ask the butler what he was carrying at ten." Drawn from the ground
truth, never from the solution directly.

**Why:** pacing. Middles sag; this is a cheap, deniable nudge that also makes the
house feel like it contains someone else's agenda.

---

## Quick wins vs. big builds

| Idea | Effort | Impact |
|---|---|---|
| 8 Present evidence | low | high |
| 9 Quote from notes | low | high |
| 17 Difficulty presets | low | medium |
| 18 Anonymous note | low | medium |
| 5 Accusation as a case | medium | high |
| 6 Limited accusations | low | medium |
| 7 Reconstruction ending | medium | high |
| 15 What people noticed | medium | high |
| 13 Generated motives | medium | high |
| 12 Interrogation stances | medium | medium |
| 10 Search rooms | medium | medium |
| 16 A clock | medium | medium |
| 1 Innocent secrets | high | very high |
| 14 Constable services | high | high |
| 2 Loyalty pairs | high | high |
| 11 Control the house | high | medium |
| 3 Hearsay consequences | high | medium |
| 4 Murderer counterplay | high | high |

## Two things to hold onto

- **Every case stays winnable.** Anything that can remove a route to the truth
  needs a guaranteed fallback and a rule in `validate()`.
- **The 3B model is the budget.** Each of these is a paragraph competing for the
  same context window, and the schedule block at the end of the prompt is the
  part that must never get crowded out. Prefer rules the game enforces in code
  over rules the model is asked to remember.
