# Adding a character

Adding a thirteenth suspect, start to finish. Follow this in order. Two of the
steps have consequences that are permanent and one of them fails silently, so
do not improvise the order.

Read [`../rules/02-project-invariants.md`](../rules/02-project-invariants.md)
first if you have not.

---

## 0. Decide whether you should

The roster is 12 against a cap of 8 in the house per game. That gap is the
point: no playthrough sees everyone, and who is *missing* changes the case as
much as who is present.

Two costs of a thirteenth:

**Colors.** `Main.NPC_COLORS` is at its practical limit. Every suspect's color
does double duty as their body in the mansion and their name in the case notes,
so it has to be distinct at a glance *and* legible as text on a dark panel. The
gold, orange and tan trio is already the closest set. A thirteenth means
reworking the palette rather than appending to it.

**Training data.** A new character has no captured replies, so the fine-tuned
model has never seen their voice. They will inherit whichever voice dominates
the set until you harvest them. Budget for that.

Neither is a reason not to. Both are reasons to plan it.

---

## 1. Pick a slot number

Open `Scripts/GameManager.gd` and find:

```gdscript
const NEXT_FREE_SLOT := 15
```

**That is your slot number.** Take it, then increment the constant to 16.

Why this matters, in one paragraph: case codes encode the cast as a bitmask
over slot numbers. Slots are permanent and are **never reused**. Retiring a
character burns their slot forever. If you hand a burned slot to somebody new,
every case code ever generated that referenced it silently decodes to a
different person. The code still parses, still produces a plausible house, and
is quietly the wrong mystery. That is the worst available failure here, because
reproducing a case exactly is the only thing a case code is for.

`GameManager._ready()` asserts slot uniqueness at startup and
`CaseGeneratorTest.tscn` checks it too, so a duplicate is caught. A *reused*
slot is not detectable by either.

---

## 2. Append to `CHARACTERS`

**Append to the END of the array.** Never insert in the middle. The array order
is not what case codes use any more, but plenty of other things iterate it in
order and there is no reason to churn it.

```gdscript
{
    "id": "kellaway",
    "slot": 15,
    "name": "Auguste Kellaway",
    "short": "Auguste",
    "first_name": "Auguste",
    "job": "Piano Tuner",
    "personality": "...",
    "flavor": "...",
    "room": "Ballroom",
},
```

| Field | What it is |
|---|---|
| `id` | lowercase, no spaces. Used for the model folder name, the config section, colors, and every dictionary key. Never change it after the fact |
| `slot` | the permanent number from step 1 |
| `name` | full display name. Goes into the prompt and the UI |
| `short` | what other suspects call them. Used for name matching and coloring |
| `first_name` | used for accusation matching, so "I accuse Auguste" works |
| `job` | one line. Read by the reply guard, see step 6 |
| `personality` | **this is the character.** See below |
| `flavor` | one background detail. Doubles as the motive if they turn out to be the murderer |
| `room` | fallback home room only. The generator normally decides where they stand |

### Writing the personality

This is the part that decides whether the character works, and the project has
learned some things.

**Strong, simple, repeatable premises hold up far better on a 3B model than
subtle ones.** "Speaks in gothic pronouncements" is easy to sustain across a
long interview. "Sophisticated and cultured, but manipulative beneath the
surface" is not; it collapses into generic politeness within four exchanges.

**Comedy in the voice, rigour in the facts.** Three of the current twelve are
comic characters, and every one of them still gets a real schedule from the
generator and recites it honestly. The clown's alibi is exactly as checkable as
the banker's. That is what keeps this a mystery rather than a sketch.

**Nothing supernatural, ever.** Count Varga claims to have been alive since
1608, and the fact that he is entirely a man committed to a bit is
load-bearing. A literal vampire could be in two places at once, and the moment
that is true, schedules stop constraining anybody and the case stops being
solvable by reasoning.

**Give them a reason to be useful.** The best additions have a mechanical
function, not just a voice:

- Emma Moreau, ghostwriter, can quote what another suspect told her privately,
  which drops material into the Contradictions section without the player
  having to stage a Hall confrontation.
- Agnes Thorne was arranging the flowers through dinner and nobody registered
  her, so she is the only person who can report what was said at that table
  without having been a participant.
- Dr Blackwood can narrow the time of death. That one is hardcoded, see step 7.

**The test:** could you swap this personality for any of the other twelve and
not notice the difference in a reply? If yes, it is generic, and generic is how
thirteen characters collapse into one voice.

---

## 3. Give them a color

`Scripts/Main.gd`, `NPC_COLORS`:

```gdscript
"kellaway": Color(0.3, 0.75, 0.9),
```

Requirements:

- clearly distinct from all twelve existing colors, and especially from the
  gold / orange / tan cluster
- legible as **text on a dark panel**, so nothing near black
- not so close to a room color that a capsule vanishes into a wall

---

## 4. Create their model folder

```
Models/Suspects/kellaway/
├─ .gitkeep
└─ _WHO.txt
```

`_WHO.txt` follows the existing pattern:

```
Auguste Kellaway
Job: Piano Tuner

Drop ONE model file in this folder (.blend, .glb, .gltf or .fbx).
The filename does not matter - the game picks up whatever is here.

Suggested from your Quaternius pack: <something>.blend
```

**The game runs fine with an empty folder.** `SuspectModel.gd` falls back to a
colored capsule, and the fallback is fully supported, which is what lets you
swap a cast over one person at a time.

If you do drop a model in, add a section to
`Models/Suspects/suspect_models.cfg` if it needs tuning:

```ini
[kellaway]
scale=1.05
y_offset=0.0
rot_y=180.0
color_shirt="#5f6b42"
```

`rot_y=180` is the default and is there because Godot treats -Z as forward
while these models are authored facing +Z. Without it every suspect walks
backwards.

**You can only recolor a material the model actually has.** The comments in
that file list each model's real material names, read straight out of the
`.blend` files rather than guessed. `color_shirt` on a model with no material
called Shirt does nothing at all, silently.

Full details: `Models/Suspects/README.md` and
[`10-data-and-file-formats.md`](10-data-and-file-formats.md).

---

## 5. Check the cap

```gdscript
const MAX_ACTIVE_SUSPECTS := 8
```

Adding a thirteenth character does **not** change this and should not. The
roster being bigger than the cap is the design.

Eight is also about where a night stops being enjoyable: every extra suspect is
another full interview, another notes tab, and another color to keep apart.

---

## 6. Check the reply guard

The guard has three lists that interact with the roster, and a new character
can trip one.

**`INVENTED_STAFF`** rejects a reply mentioning a housekeeper, maid, footman,
valet, cook, butler, servant, groundskeeper, coachman, constable, sergeant or
chauffeur, because those people do not exist in the house.

But `_job_on_the_cast(word)` checks whether any active suspect's `job` contains
that word first. So if your new character is the **cook**, the word "cook" stops
being an invention and the guard correctly allows it.

**So: if your character's job is one of those words, you get this for free. If
their job is a synonym the list does not know about, add it.**

**`RELATIVES`** only rejects a relative attributed to *somebody else*. A
suspect's own family is their own business and the detective is entitled to
ask. That distinction cost eight of twenty-six exchanges in one log before it
was fixed, and a guard that eats honest answers is worse than no guard, because
the failure is invisible and reads as a bad model.

**Name matching.** `_relative_of_someone_else()` and `_reply_breaks_character()`
build regular expressions from every active character's `short` and
`first_name`. A new character with a name that is also a common word (a suspect
called "Hope", say) will cause false positives. Test for it.

---

## 7. Special mechanics, if any

If your character has a power like Dr Blackwood's:

```gdscript
const EXPERT_ID := "blackwood"
```

There is exactly one of these hardcoded today, and it is referenced by
`CaseGenerator.expert_claim_slot()` as well. If you are adding a second special
ability, do not add a second constant; generalise it into a field on the
character dictionary, or you will have this problem again at the third one.

---

## 8. Test it

In this order.

**Run `Scenes/CaseGeneratorTest.tscn` (F6).** Expect `1000/1000 valid`. This
catches a duplicate slot, an out-of-range slot, and a case-code round trip that
no longer works.

**Run `Scenes/GuardTest.tscn` (F6).** Catches a name that collides with the
guard's keyword lists.

**Play a game with them in it.** Tick them on the selection screen, walk up,
and ask five questions:

1. "Where were you at ten o'clock?" should give an exact room and time read
   off their schedule
2. "Who else was there?" should name real people who really were
3. "Tell me about yourself" should sound like nobody else on the roster
4. "How well did you know Lord Archibald?" should use their `flavor`
5. Something hostile should stay in character rather than becoming polite and
   modern

**Play a game where they are the murderer.** Force it by rolling until Ctrl+1
names them. Check that their one lie is consistent when you come back to it
from a different angle, and that a witness really can contradict it.

**Read the dialogue log.** Tick the log box before starting. The generic-voice
problem does not show up in five questions; it shows up when you read thirty
lines together and cannot tell who is speaking.

---

## 9. Get them into the training data

The fine-tuned model has never seen this character. Until you fix that, they
will drift toward whichever voice dominates the existing set.

The fast route:

1. In game, with the new character in the house, press **Ctrl+3** to export the
   active characters' system prompts.
2. `python Training/harvest.py`, which asks the whole prompt bank unattended.
3. Judge the replies in the browser reviewer.
4. `python Training/harvest_to_dataset.py`, `build_dataset.py`, `audit.py`.
5. Retrain.

Full instructions: [`08-ai-training-and-tuning.md`](08-ai-training-and-tuning.md).

**Rotate the cast while harvesting.** Eight of thirteen go in the house. Always
take the same eight and five characters end up with no data at all.

---

## 10. The full checklist

- [ ] Took `NEXT_FREE_SLOT` and incremented it
- [ ] Appended to the END of `CHARACTERS`, never inserted
- [ ] All nine fields filled in
- [ ] Personality is a strong simple premise, not a subtle one
- [ ] Nothing supernatural that would break schedules
- [ ] Added to `Main.NPC_COLORS`, distinct and legible on dark
- [ ] Created `Models/Suspects/<id>/` with `.gitkeep` and `_WHO.txt`
- [ ] Added a `suspect_models.cfg` section, if they have a model
- [ ] Checked their job against `INVENTED_STAFF`
- [ ] Checked their name does not collide with a guard keyword
- [ ] `CaseGeneratorTest.tscn` passes 1000/1000
- [ ] `GuardTest.tscn` passes
- [ ] Played them innocent, and played them guilty
- [ ] Read a dialogue log and could tell them apart from the others
- [ ] Harvested training data for them

---

## Removing a character

Delete their entry from `CHARACTERS`. That is all the code needs.

**Do not reduce `NEXT_FREE_SLOT`, and never give their slot to anybody else.**
Add a comment recording that the slot is burned and who used to have it. Old
case codes referencing it are then correctly refused with "code is from an
older cast", which is exactly the behaviour you want, rather than being decoded
into whoever happens to sit there now.

Leave their `Models/Suspects/<id>/` folder or delete it; nothing reads it once
the character is gone.

If they were `EXPERT_ID`, that mechanic now has no owner. Reassign it or remove
it.
