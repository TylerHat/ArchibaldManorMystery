# Test script — Phases 2a, 2b and 3

Work through these in order. They're arranged to fail fast: if Test 0 is
broken, nothing after it will tell you anything useful.

Keep **Ctrl+1** open for most of this. It shows the ground truth, and almost every
check below is "does what the game says match what Ctrl+1 says".

---

## Before you start

- [ ] Ollama is running (`ollama serve` or the app open)
- [ ] On the suspect-selection screen, **turn the dialogue log ON** — it writes
      every line to a markdown file so you can review wording afterwards
      instead of trying to remember it
- [ ] Know your two debug keys: **Ctrl+1** = truth table, **Ctrl+2** = dump the next
      group prompt payload to the Godot console

**Pick 3 suspects, not 8.** Everything below needs you to talk to the murderer
and one specific witness. With eight in the house you'll spend the whole test
walking. Three gives you a murderer, a witness, and one bystander.

---

## Test 0 — The generator itself

Open `Scenes/CaseGeneratorTest.tscn`, press **F6**, read the Godot output.

- [ ] Says `1000/1000 valid`
- [ ] `room grid matches Main.gd  OK`
- [ ] "schedule lines per suspect" is roughly **5–6 mean, 8 max**
- [ ] Under **"who ends up guilty"**, every suspect's percentage is in normal
      range and the last line reads `murderer draw is uniform`. If any row is
      flagged `<-- SKEWED`, the murderer selection is biased — report it
- [ ] In the sample cases, the **COVER STORY** and **THE WITNESS** blocks both
      have a line marked `<-- at the murder`, and they disagree: the murderer
      claims a room, the witness is in that same room at that moment *without*
      the murderer listed

That last point is the whole game. If those two blocks agree, stop — the case
is unwinnable and nothing else is worth testing.

**If it fails:** the failure prints the seed and the offending case.

---

## Test 1 — Phase 2a: placement and variety

Launch, press **Ctrl+1**, don't talk to anyone yet.

- [ ] The overlay lists murderer, weapon, weapon's home room, method, the lie,
      who disproves it, and one row per suspect
- [ ] Walk the manor. **Each suspect is standing in the room their schedule row
      ends in** (last column of their row, two-letter abbreviation)
- [ ] Some rooms are empty. That's correct, not a bug
- [ ] If two suspects share an end room, they're **standing apart, not inside
      each other**

Now quit and relaunch **three times**, same suspects each time:

- [ ] Murder room changes
- [ ] Weapon changes
- [ ] Murder time changes
- [ ] Suspects are standing in different rooms

**Red flag:** same murder room three launches running with different suspects
selected. That suggests `case_data` isn't being regenerated.

---

## Test 2 — Phase 2b: do they know where they were?

This is the core of Phase 2b. Read Ctrl+1 first and write down the **murderer**,
the **witness**, and the **murder time**.

### 2.1 — An innocent tells a consistent story

Go to the bystander (not the murderer, not the witness). Type these one at a
time:

```
Where were you last night?
```
```
Where were you at <MURDER TIME>?
```
```
Who were you with then?
```
```
When did you last see Lord Archibald?
```

- [ ] Every answer matches their Ctrl+1 row
- [ ] The companions they name match Ctrl+1 (people in the same room, same slot)
- [ ] They do **not** recite their whole evening in response to the first
      question — they should answer it, not deliver an itinerary

Now ask the **same question a different way**:

```
Remind me — you said you were in the <ROOM>. What time was that?
```

- [ ] Same answer as before. No drift.

### 2.2 — The murderer holds one lie

Go to the murderer. Same four questions.

- [ ] They name the **claimed room** from Ctrl+1 for the murder window
- [ ] Every *other* part of their evening matches their true Ctrl+1 row — only the
      one block should be false
- [ ] They do not volunteer that anything is unusual

Now press:

```
Are you sure? Someone else says they were in the <CLAIMED ROOM> at that time.
```
```
Who exactly was with you in the <CLAIMED ROOM>?
```

- [ ] They **hold the story**. They may get defensive or rattled — that's
      intended — but they should not switch to a different room
- [ ] They do not confess

**This is the most likely thing to be wrong.** If the murderer invents a third
room, or changes their story between the two questions, that's a real bug in
the prompt, not model noise.

### 2.3 — The weapon trail

Ask anyone whose Ctrl+1 row shows them in the **weapon's home room**:

```
Were you in the <WEAPON HOME ROOM> last night?
```

- [ ] They say yes, and the timing matches Ctrl+1

Ask someone whose row shows they were **never** there:

```
Were you in the <WEAPON HOME ROOM> last night?
```

- [ ] They say no. They should not invent a visit to be helpful.

---

## Test 3 — Phase 2b: the confrontation

The payoff. Ctrl+1 tells you who's under "Disproved by" — that's your witness.

1. Talk to the murderer, type: `go to the hall`
2. Talk to the witness, type: `go to the hall`
3. Walk into the Hall yourself and interact — prompt should read
   **Address the room**

Then say to the room:

```
Where were you both at <MURDER TIME>?
```

- [ ] Both answer, one after the other
- [ ] Murderer repeats the claimed room — **the same one they told you
      privately**
- [ ] Witness places themselves in that same room

If the witness doesn't immediately object, press it:

```
<WITNESS NAME>, was <MURDERER NAME> in the <CLAIMED ROOM> with you or not?
```

- [ ] The witness says no / that they didn't see them
- [ ] The murderer reacts — denies, insists, or claims they must have just
      missed each other. It should **not** switch rooms and **not** confess
      immediately

Then open **Tab → the murderer's notes**:

- [ ] The **Contradictions** section names the disagreement

**If the witness agrees the murderer was there**, that is the single most
important bug to report. It's the failure mode I hit while building this. Press
**Ctrl+2**, ask again, and send me the console dump.

---

## Test 4 — Phase 3: the crime scene

Ctrl+1 tells you the murder room and the weapon's home room.

### 4.1 — The scene

Walk to the murder room. The body is in a **corner**, not the middle.

- [ ] Prompt reads `Examine the body`, press **E**
- [ ] Wound description is consistent with the weapon in Ctrl+1 (no gunshot from a
      candlestick)
- [ ] Method matches Ctrl+1 (`struggle` should mention a fight)
- [ ] Time-of-death window is a **90-minute range**, and the real murder time
      from Ctrl+1 falls inside it
- [ ] It says something like "someone who knows what they're looking at could
      narrow it" — that's the Phase 4 hook, correct to see now

Examine the rest:

- [ ] **The weapon** — matches Ctrl+1, and names its home room correctly
- [ ] **Marks on the floor**
- [ ] **A dropped item** — names a possession, not a person
- [ ] **An overturned chair** — only if Ctrl+1 says `method: struggle`

### 4.2 — The other end of the weapon thread

Go to the weapon's home room.

- [ ] There's an **empty table** to inspect
- [ ] It names the missing weapon, and it's the same weapon as at the scene

### 4.3 — It doesn't get in the way

- [ ] If a suspect is standing in the murder room, they're **not** overlapping
      the body, and you can still talk to them
- [ ] **Esc** closes the examine panel and gives you the mouse back
- [ ] Examining the same thing twice doesn't break anything

---

## Test 4.5 — Phase 4: evidence notes and the pathologist

**Include Evelyn Blackwood in your cast for this one.**

### The Scene tab

Press **Tab**. Above the suspects there's a **The Scene** tab.

- [ ] Before examining anything, it's dimmed and tells you to go find the body
- [ ] After examining things, it lists them in the order you found them, in
      full — not summarized
- [ ] It doesn't pause to "think" the way a suspect tab does (nothing is sent
      to Ollama for this pane)

### Evelyn, innocent

Check Ctrl+1 — she should **not** be the murderer for this part. Ask her:

```
You examined the body. When did he die?
```

- [ ] She gives a **specific half-hour time**, not a range
- [ ] It matches the true murder time in Ctrl+1
- [ ] That time falls inside the 90-minute window the body itself gave you

### Evelyn, guilty

Relaunch until Ctrl+1 shows her as the murderer, then examine the body first
and ask her the same question.

- [ ] She still answers confidently and specifically — no hedging
- [ ] Her stated time is **outside** the body's 90-minute window. That's the
      tell, and you can spot it from your own notes
- [ ] Check Ctrl+1: at the time she names, she really was with someone. The lie
      is buying her an alibi, not just muddying the water

Then press her:

```
The body says he died between <WINDOW>. Your time doesn't fit that.
```

- [ ] She gets rattled, but doesn't immediately confess or change her figure

---

## Test 5 — End to end

- [ ] Accuse the right person at the front door → you win
- [ ] Accuse the wrong person → you keep playing
- [ ] Hit **Play Again**, pick a different number of suspects → new case, new
      murder room, no leftovers from the previous game (especially: no second
      body, no old evidence)

---

## Not implemented yet — don't report these

These are Phase 5 and are *expected* to be missing:

- No seed display, no seed entry — you can't replay or report a specific case
- The dialogue log doesn't record the truth table alongside the transcript
- Suspects don't know about the physical evidence — examining the dropped item
  doesn't let you confront its owner with it in any mechanical sense (you can
  still ask, they just have no special knowledge of it)

---

## Telling a real bug from a 3B model being a 3B model

Worth separating, because llama3.2:3b will wobble and not all of it is broken
plumbing.

**Model noise — annoying, not a bug:**

- Slightly reworded answers to the same question
- Vague time references ("earlier", "after dinner") instead of clock times
- Over-long or over-short replies
- Some purple prose

**Real bugs — worth reporting:**

- A suspect names a room **not in their Ctrl+1 row** at all
- A suspect names a **companion who wasn't there** per Ctrl+1
- An **innocent's** story changes between two askings
- The **murderer changes which room they claim**
- The witness **corroborates** the murderer's alibi
- Anyone mentions a person who isn't in the house
- Body/weapon/method descriptions disagree with Ctrl+1
- The examine panel traps the mouse, or Esc doesn't close it

For anything in the second list, the dialogue log file plus the Ctrl+1 contents are
enough for me to work from — and if it's a group scene, the **Ctrl+2** console dump
is the single most useful thing you can send.
