# Plan: Procedural Case Generation

Goal: every playthrough generates its own murder — different room, weapon,
method, time, and a different set of per-suspect schedules — while the eight
characters and their personalities stay exactly as they are.

## Decisions

| Question | Answer |
|---|---|
| What varies per game | Per-suspect schedules + murder scene facts |
| Timeline resolution | 8 slots x 30 min, 8:00pm to midnight |
| Alibi model | Full ground truth (real location table) |
| Data source | Authored tables + code (no LLM in the generation path) |
| Crime scene | Full — body, weapon, scattered evidence |
| Solvability | Always catchable |
| Suspect placement | The room their schedule ended in |
| Interrogation happens | The next morning, shortly after the body is found |
| Win condition | Name the killer only (unchanged) |

Characters, personalities, and their fixed `flavor` motives stay as-is, per the
original brief that the characters themselves can stay the same.

---

## 1. Where the project stands

**Phase 1 is built and merged.** `Scripts/CaseGenerator.gd` generates and
validates complete cases; `Scenes/CaseGeneratorTest.tscn` hammers it. Nothing
in the running game references it yet — that is deliberate, and it is what
Phase 2a changes.

Still live in `GameManager.gd`, to be replaced as the phases land:

- `MURDER_ROOM := "the Billiard Room"` — fixed forever
- `WEAPON_OPTIONS` / `TIME_OPTIONS` — 5 and 4 strings, flavour only
- `CHARACTERS[i]["room"]` — each suspect's permanent room
- **No schedule data at all.** Ask a suspect where they were and llama invents
  an answer on the spot. Nothing in the game knows whether it's true, which is
  why the Contradictions section in the case notes can only ever compare two
  improvisations against each other.

---

## 2. The truth table

### Time slots

8 slots of 30 minutes, 8:00pm to midnight, on the night of the murder:

```
slot:  0     1     2     3     4     5     6     7
time:  8:00  8:30  9:00  9:30  10:00 10:30 11:00 11:30
```

**Slot 0 is dinner.** Every suspect and the victim are in the Dining Room. It
gives the house one shared reference point everyone agrees on, stops the murder
happening before the party has assembled, and starts everyone with one
corroborated block.

The murder happens in **slots 2 through 6** — five possible times, against the
current three. The body is found the following morning, which is what justifies
the coarse time-of-death window in Phase 3.

### Ground truth

A path is 8 room names, one per slot, for every active suspect **and for the
victim**. The victim having a path matters: "when did you last see Lord
Archibald" becomes a question with a real, checkable answer, and several
suspects can genuinely have seen him alive after another claims he'd gone up.

### Generation constraints

1. **Legal movement** — same room or orthogonally adjacent on the 3x3 grid.
2. **Movement inertia** (~55% stay put) — guests settle rather than drift. This
   is what keeps schedules compressing to a handful of prompt lines.
3. **Dinner** — slot 0 fixed for everyone.
4. **The murderer is alone with the victim** at the murder slot.
5. **Nobody else is in that room** at that slot.
6. **The murderer passes through the weapon's home room** beforehand.
7. **Corroboration** — two people in a room in the same slot alibi each other.

### The solvability rule

> **Every innocent's claimed path is identical to their true path. Only the
> murderer's diverges — over one contiguous 1-2 slot block covering the murder.**

The murderer is therefore the only person in the house who *can* be
contradicted, so every contradiction the player finds is real. The generator
also requires that at least one innocent was actually in the room the murderer
claims, guaranteeing an eyewitness exists. Innocents can still look guilty —
thin alibis, unlucky solo slots — but pressing them never yields a
contradiction. That's the intended texture: several plausible suspects, one
provable liar.

---

## 3. Murder scene facts

Weapons are dictionaries, not strings — `home_room`, `wound`, `trace`,
`strength`, and which `methods` they permit. `home_room` is the best clue the
generator produces: whoever used the candlestick had to pass through the Dining
Room, and constraint 6 guarantees the murderer did.

Methods: `ambush` / `struggle` / `poison` / `staged`, gated per weapon. Drives
the body description and which evidence spawns.

Murder room: any of the 8 non-Hall, non-Dining rooms, never the weapon's home
room (that would make constraint 6 vacuous).

---

## 4. Build order

Phase 1 is done. Each remaining phase leaves the game playable.

### Phase 1 — Generator, nothing wired up ✅ DONE

`Scripts/CaseGenerator.gd`, `Scripts/CaseGeneratorTest.gd`,
`Scenes/CaseGeneratorTest.tscn`.

**Test:** run the test scene (F6). Expect `1000/1000 valid`.

### Phase 2a — Case data reaches the game

- `GameManager` holds `case_data`, populated in `start_new_game()` by calling
  `CaseGenerator.generate()`.
- `MURDER_ROOM`, `WEAPON_OPTIONS`, `TIME_OPTIONS` are retired; murder room,
  weapon and time now come from the generated case.
- `_build_system_prompt()` uses the generated room/weapon/time. **Schedules are
  deliberately NOT added yet** — that's 2b. This keeps the change small enough
  that a failure is unambiguous.
- `Main._spawn_npcs()` places each suspect in the room their schedule ended in,
  instead of the hard-coded `CHARACTERS[i]["room"]`.
- Ctrl+1 debug overlay extended to dump the full truth table.

One narrative seam to close: the body is found the next morning, but everyone
is standing where they ended the night. The prompt says so explicitly — nobody
has been allowed to leave the manor, and they've settled back into the rooms
they spent the evening in. Without that line, a suspect will happily explain
they've just come down from bed and undercut their own placement.

**Test:** launch, press Ctrl+1, walk the manor. Everyone should be in the room their
schedule ends in; two suspects sharing an end room stand together. The murder
room and weapon should differ every launch. Dialogue still improvises alibis —
that's expected at this phase.

### Phase 2b — Schedules go into the prompts ✅ DONE

Building this surfaced a flaw in the Phase 1 design that the original
validation could not see.

Run-length encoding a schedule by **room alone** leaks companionship across
time. If the murderer claims the Kitchen for the half hour of the killing, and
an innocent walks into that Kitchen an hour later, the innocent's collapsed
account reads *"the Kitchen, 10:30 to midnight, with Victoria"* — so the one
witness guaranteed to break the alibi confirms it instead. Every case still
validated; every case was unwinnable in play.

Two fixes, both now asserted by the test scene:

1. **`account_blocks()`** splits on room *or* companion-set change, so arrival
   and departure times are visible. Costs ~2 more prompt lines per suspect
   (mean 5.8, max 8).
2. **The witness must be in the claimed room at the murder slot itself**, not
   merely somewhere in the lie block — the murderer often walks into the room
   they're claiming later in the same block, quite innocently. This took the
   guarantee from 98.3% to 100% over 25,000 generated cases.

`validate()` now checks the witness's *spoken account* actually contradicts the
alibi, rather than just checking positions on the grid.

- `_build_system_prompt()` gains a run-length encoded evening block; murderer
  gets the claimed version plus the secret.
- `private_recap()` extended to reinforce the relevant block during group scenes.
- Must sit alongside the existing **PHYSICAL ACTIONS** block (the bracketed
  stage-direction feature) without the two rules fighting — both are exceptions
  to "don't accept things you don't remember", so they need to read as one
  coherent set rather than three separate carve-outs.

**Test:** the real one. Ctrl+1 for the truth table, then ask several suspects where
they were at a given time and check against it. Then haul two into the Hall and
see whether the murderer's story survives contact with someone who was in the
room they claim. This is the phase most likely to need prompt iteration, which
is exactly why it's isolated.

### Phase 3 — Crime scene ✅ DONE

`Scripts/CrimeScene.gd` builds the scene; `Scripts/Evidence.gd` is a
StaticBody3D exposing `get_interact_prompt()` / `interact()`, exactly like
`Door.gd` — so `Player.gd`'s existing centre-screen raycast picked it up with
no changes to the player at all.

Five examinables, all generated: the body (wound, method, 90-minute death
window), the weapon (naming its home room), an empty table in that home room,
a dropped personal item, floor marks, plus an overturned chair on `struggle`.

The personal item is a coin flip between the murderer and an innocent who
*genuinely* passed through the murder room — never one who didn't, since that
would be the game itself lying to the player.

One thing measurement caught: in 65% of generated cases at least one suspect
ends the night standing in the murder room (up to three of them). The scene is
therefore pushed to a room corner, ~3.9 units out, clear of both the walls and
the ~3.0 ring `_spawn_npcs()` fans suspects onto. Placed centrally it would
have spawned suspects inside the body most games.

**Test:** find the body in the generated murder room, examine everything, check
descriptions agree with the Ctrl+1 truth table. Then go to the weapon's home room
and find the gap it left.

### Phase 4 — Evidence notes and Evelyn

Evidence section in the Tab notes panel. Evelyn Blackwood narrows the body's
90-minute time-of-death window to a single 30-minute slot — she's the only
character who can, it falls straight out of her occupation, and if she's the
murderer her "expert" narrowing is a lie the physical evidence disagrees with.

**Test:** examine the body, ask Evelyn, confirm she narrows correctly — or
lies in her own favour when guilty.

### Phase 5 — Polish

Seed display and seed entry on the selection screen (replay a case, or report a
bad one). Dialogue log records the truth table alongside the transcript.

---

## 5. Files

| File | Change |
|---|---|
| `Scripts/CaseGenerator.gd` | ✅ built — generates + validates the truth table |
| `Scripts/CaseGeneratorTest.gd` + `Scenes/CaseGeneratorTest.tscn` | ✅ built — bulk validation harness |
| `Scripts/GameManager.gd` | 2a: holds `case_data`, retires the fixed consts. 2b: schedule blocks in prompts. 4: evidence log |
| `Scripts/Main.gd` | 2a: NPC placement + Ctrl+1 overlay. 3: spawn crime scene, examine prompt. 4: Evidence tab |
| `Scripts/CrimeScene.gd` | 3: **new** — body, weapon, evidence props |
| `Scripts/NPCCharacter.gd` | 2a: minor — starting room from the schedule |
| `README.md` | documented per phase |

---

## 6. How much variety this buys

One suspect's evening is a 7-step walk out of the Dining Room on the 3x3 room
graph — on the order of 14,000 paths before constraints. Across a house of up
to eight suspects the joint space is astronomically large.

Scene facts alone: 8 rooms x 5 murder slots x ~11 weapons x up-to-4 methods —
roughly 1,100 distinct murders, before schedules, before which suspects you
picked, before who among them did it.

You will not see the same case twice.

---

## 7. Risks

- **A 3B model reciting a schedule accurately.** The main risk. Mitigated by
  short run-length-encoded blocks, schedule placed late in the prompt, a single
  contiguous divergence for the murderer, and reinforcement in group recaps. If
  it drifts, raise `INERTIA` for fewer, longer blocks rather than cutting slots.
- **Prompt rule collision.** The system prompt now carries three related
  exceptions — don't invent, accept the detective's physical actions, recite
  your schedule. Phase 2b has to unify them, not stack them.
- **Suspects volunteering their whole schedule** when asked something else.
  Needs an explicit "answer only what you're asked" line.
- **A near-miss red herring being too convincing.** Tunable via `MAX_PER_ROOM`
  and how many innocents may have uncorroborated slots.

---

## 8. Deliberately out of scope

- **Motives.** Each character keeps their single fixed `flavor`. Easy to add
  motive pools later; the generator would pick one per game like a weapon.
- **Relationship web.** No generated who-covers-for-whom.
- **Automated contradiction verifier.** The Contradictions section stays
  LLM-driven — though it should improve on its own, since innocents will now
  say the same true thing every time instead of drifting.
- **Clue-style accusation.** Winning still requires naming the killer only.
