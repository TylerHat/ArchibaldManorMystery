# The case generator

Every launch, the game invents a complete murder and then proves it is
solvable. This is `Scripts/CaseGenerator.gd`, and it is the reason two suspects
contradicting each other means anything at all.

---

## 1. Why it exists

Before it, every suspect improvised their whereabouts. Ask twice and you got
two answers. Two suspects contradicting each other told you nothing, because
both were making it up. There was one fixed scenario and one fixed murderer,
and after two playthroughs you had seen all of it.

Now the game holds the **ground truth**: exactly which room every person was
standing in, for each of eight half-hour slots. Every innocent recites theirs
honestly. Exactly one person is lying, about exactly one block. And the
generator refuses to hand over a case until it has checked that at least one
innocent can prove the lie.

That guarantee is the pillar the whole game stands on. Everything in
`TODO.md` is measured against whether it breaks it.

---

## 2. Shape of the file

```gdscript
class_name CaseGenerator
extends RefCounted
```

`RefCounted`, not `Node`. It is **not in the scene tree**. No signals, no
autoload references, no Ollama, no UI. Pure data in, pure data out.

That is what makes it testable in bulk. `CaseGeneratorTest.gd` generates a
thousand complete cases in a loop and asserts every rule on each, without
building a single mansion.

**Keep it that way.** If you find yourself wanting to reach `GameManager` from
inside this file, the thing you want belongs on the calling side.

---

## 3. The evening

```gdscript
const SLOT_COUNT := 8
const SLOT_TIMES := ["8:00", "8:30", "9:00", "9:30", "10:00", "10:30", "11:00", "11:30"]
```

Eight slots of thirty minutes, 8:00pm to midnight.

**Slot 0 is dinner.** Every suspect and the victim are in the Dining Room. That
gives the whole house one shared agreed reference point ("we all rose from
dinner at half past"), guarantees the murder cannot happen before the party has
assembled, and starts everybody with one corroborated block.

```gdscript
const MURDER_SLOT_MIN := 2
const MURDER_SLOT_MAX := 6
```

The murder never happens during dinner and never in the final slot. There
always has to be a before and an after to reason about.

Other constants worth knowing:

| Constant | Value | Means |
|---|---|---|
| `INERTIA` | 0.55 | chance a suspect stays put rather than moving on. Guests settle into a room |
| `MAX_PER_ROOM` | 3 | crowd cap, so alibis stay meaningful |
| `MAX_ATTEMPTS` | 400 | how many candidate cases it will throw away before giving up |
| `NO_MURDER_ROOMS` | Hall, Dining Room | too public |

---

## 4. Weapons and methods

`WEAPONS` is twelve dictionaries. Each has:

```gdscript
{
    "name": "the fireplace poker",
    "home_room": "Lounge",
    "methods": ["ambush", "struggle", "staged"],
    "strength": "medium",
    "wound": "a heavy blow to the back of the head",
    "trace": "soot trodden into the rug",
}
```

`home_room` is the load-bearing field. **The murder room is never the weapon's
home room.** Whoever used it went to that room first, and there is a matching
clue there: an empty table where the weapon should be. Two ends of the same
thread, and if the murder happened in the same room as the weapon lives, that
clue is worthless.

`METHODS` maps `ambush`, `struggle`, `poison`, `staged` to a description of how
the killing went, which drives what the body looks like and what evidence gets
scattered at the scene.

A nice piece of emergent design: Agnes Thorne keeps the Conservatory, where the
garden wire and the stone planter live. Whenever the generator picks either
weapon she becomes the most incriminated person in the house through no fault
of her own. A recurring red herring the system produces for free.

---

## 5. How generation works

Generate, validate, and throw it away if anything is off. Roughly four attempts
on average, so the whole thing finishes in well under a frame.

```gdscript
static func generate(active_ids: Array, rng: RandomNumberGenerator = null) -> Dictionary
```

Per attempt:

1. Pick a murderer from the active cast, at random.
2. Pick a murder slot in range, a weapon, and a method that weapon supports.
3. Pick a murder room that is not public and not the weapon's home room.
4. **Route the victim.** Dinner, then a detour, then the room he dies in. The
   detour is the point: "when did you last see Lord Archibald" is only
   interesting if he was seen in more than one place.
5. **Route the murderer.** They must pass through the weapon's home room before
   the killing, and be alone with the victim at the murder slot.
6. **Route every innocent.** A random walk over the room grid with `INERTIA`,
   respecting the crowd cap, and forbidden from entering the murder room after
   the killing.
7. **Build the lie.** Pick a block of slots covering the murder slot, and a
   room the murderer claims to have been in instead. That room must have had at
   least one innocent standing in it at the murder moment, and those innocents
   become the `witness_ids`.
8. **Pick the dropped item's owner.**
9. Validate. If clean, return. Otherwise throw it all away and go again.

### The dropped item, and a nice piece of tuning

Half the point of the personal item at the scene is that it is *not* an answer.
So it is weighted 4 in 5 toward an innocent who genuinely passed through that
room, not a straight coin flip.

The reasoning: an innocent only passes through the murder room in about half of
cases, since the sealed-room rule means they can only do it *before* the
killing. Every time there is no candidate, it falls back to the murderer. An
even flip on top of that lands high, which makes the item close to a pointer at
the killer. Leaning the other way brings it back to roughly 50/50, which is
what a red herring needs to be: informative, but not something you can act on
alone.

It is also drawn from the **case** RNG rather than a global one, on purpose.
This is a fact of the mystery, not set dressing, so replaying a case code has
to produce the same item. Anything the player reasons about belongs in that
RNG.

---

## 6. What comes out

```gdscript
{
    "murderer_id":       "sterling",
    "evidence_owner_id": "whitmore",
    "murder_slot":       4,
    "murder_room":       "Study",
    "weapon":            { ...one WEAPONS entry, deep-copied... },
    "method":            "ambush",
    "victim_path":       ["Dining Room", "Dining Room", "Lounge", ...],   # 8 rooms
    "true_paths":        { "sterling": [...8...], "whitmore": [...8...] },
    "claimed_paths":     { ...same, but the murderer's lie substituted in... },
    "diverge_from":      3,
    "diverge_to":        5,
    "claimed_room":      "Library",
    "witness_ids":       ["whitmore", "reeves"],
    "seed":              482913,
    "attempts":          3,
}
```

`true_paths` is what really happened. `claimed_paths` is identical except for
the murderer's lie block. Everything the game says about anybody's evening is
read out of one of these two.

The weapon is `.duplicate(true)`d because `const` containers are read-only in
Godot 4.4+ and this dictionary is handed out to the rest of the game.

---

## 7. Validation, the important part

`validate(c, active_ids)` returns an array of human-readable problems. Empty
means sound. Every rule the design depends on is checked here rather than
assumed, so the test scene can hammer the generator and catch a regression the
moment it appears.

The checks, in the generator's own words:

**Physical possibility**

- murder slot in range, murder room not public, murder room is not the weapon's
  home room, method is one this weapon supports
- every path is exactly 8 slots and starts at dinner
- nobody teleports: every consecutive pair of rooms must be adjacent on the
  grid
- nobody stands in one room all night

**The victim**

- was in the murder room when he died
- moved somewhere before he died

**Means and opportunity**

- the murderer was at the scene
- nobody else was standing in the murder room at the murder slot
- nobody entered the murder room *after* the killing (this is the sealed-room
  rule, and it is what makes the closed-door story in the prompts true)
- the murderer passed through the weapon's home room

**The lie**

- every innocent's claimed path equals their true path. Innocents do not lie
- the murderer's story is itself walkable
- the lie covers the murder slot
- the murderer does not admit to being at the scene
- the murderer's story is identical to the truth outside the lie block

**Solvability**

- `witness_ids` is not empty. In the code's own words:
  `"NOBODY can contradict the murderer - case is unwinnable"`
- every listed witness really was in the claimed room at the murder slot
- at least one witness's **spoken account** actually contradicts the alibi

That last one is subtler than it looks. It is not enough for a witness to have
been there. What they will actually *say*, once their path is collapsed into
blocks of prose, has to contain the contradiction. A witness who was there but
whose account glosses over it is no use to the player.

---

## 8. Turning a path into speech

The raw path is eight room names. Nobody talks like that. Three helpers turn it
into something a suspect can say:

| Function | Does |
|---|---|
| `blocks(path)` | collapses consecutive identical rooms into `{room, from_slot, to_slot}` |
| `block_time(b)` | renders one block as "half past nine to half past ten" |
| `account_blocks(c, id, path)` | blocks plus, for each, who else was in the room |
| `companions(c, id, b)` | who shared that block |
| `last_saw_victim(c, id)` | the last slot this person was in a room with the victim |

`GameManager.evening_account(id)` uses these to write the block of text that
goes into that suspect's system prompt, and `_schedule_recall()` uses them to
answer a specific time question exactly.

---

## 9. Dr Blackwood, the one special case

`expert_claim_slot(c, expert_id)` exists because one character has a mechanical
power nobody else has.

The body gives you a **90-minute window** for the time of death
(`death_window()`). Dr Blackwood, a forensic pathologist, can narrow it to a
**single half hour**, which usually clears two or three people outright. She is
the only character whose occupation lets her do it.

Which makes her the most dangerous person in the house when she is guilty. She
lies about it with a straight professional face, and the lie is picked to put
her somewhere she has a witness. The catch: her stated time will not fit the
window the body itself suggests. Examine the body first and you can catch her
without needing anybody's help.

`GameManager.EXPERT_ID` is `"blackwood"`. If you retire that character, this
mechanic needs a new owner or removing.

---

## 10. Case codes

A case code looks like `482913-171`. Two numbers: the **seed**, and a
**bitmask of the cast**.

```gdscript
func case_code() -> String:
    var mask := 0
    for c in CHARACTERS:
        if active_character_ids.has(String(c["id"])):
            mask |= 1 << int(c["slot"])
    return "%d-%d" % [case_seed, mask]
```

Paste it into the selection screen and you get that exact mystery back: same
murderer, same schedules, same weapon, same dropped item. It also re-ticks the
suspect boxes for you.

**The cast is part of the code for a real reason.** The generator draws every
decision from one RNG, so the same seed with a different set of suspects
produces a completely different mystery. A seed alone would look reproducible
and quietly not be.

### Slots, and the bug that created them

The bitmask is built from each character's permanent `slot` number, **not**
from their position in the `CHARACTERS` array.

It was positional once, and that was a real bug rather than a theoretical one:
editing the roster silently repointed every code ever generated at a different
cast. The code still parsed, still produced a plausible-looking house, and was
quietly the wrong mystery. Silent is the worst available failure here, because
reproducing a case exactly is the only thing a case code is for.

With slots, the array can be reordered, added to, or have characters removed,
and old codes keep meaning what they meant.

The rules that follow from this are in
[`../rules/02-project-invariants.md`](../rules/02-project-invariants.md) and
are worth memorising:

- **Slot numbers are permanent and are never reused.**
- Retiring a character **burns their slot forever**. `NEXT_FREE_SLOT` records
  what to use next and which numbers are already burned.
- A code referencing a retired slot is refused with "code is from an older
  cast" rather than decoded into whoever happens to sit there now.
- `GameManager._ready()` asserts slot uniqueness at startup, and
  `CaseGeneratorTest` checks it too.

A bare seed with no cast is accepted, and keeps whatever suspects you have
ticked. That is a deliberate "replay this mystery with a different house" move
rather than a malformed code.

`MAX_SEED` is 1,000,000, kept small purely so the code is short enough to read
aloud or type from a screenshot. A million cases per cast is far more than
anyone will play.

---

## 11. If you change anything here

**Run `Scenes/CaseGeneratorTest.tscn` with F6. Every time. No exceptions.**

Expect `1000/1000 valid`. It also prints distribution statistics, dumps three
full sample cases including the schedule text each suspect would be given, and
round-trips 200 case codes.

A generator bug does not crash. It produces a mystery that cannot be solved, or
one where the contradiction the player is hunting for does not exist. The
player finds out an hour in. That is the whole reason the test scene is 453
lines long.

The design document, still accurate, is
[`../plans/procedural-cases.md`](../plans/procedural-cases.md).
