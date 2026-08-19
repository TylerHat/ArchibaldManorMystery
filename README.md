# Archibald Manor: A Clue Mystery

A 3D first-person murder-mystery game built in Godot 4.7. You're the
detective. Lord Reginald Archibald has been murdered in his own manor, and
one of his guests did it. Question them, catch them in a lie, and make your
accusation at the front door.

There are 12 suspects on the roster, and at most 8 of them are in the manor
on any one night. Every time you launch the game (or hit "Play Again"), you
first pick which 2 to 8 are there - either with quick "Random N" buttons or
by checking specific suspects yourself. The screen opens on a random legal
cast of 8, so a fresh launch is already a fresh mystery.

The roster being bigger than the cap is the point: no single playthrough
sees everyone, and who is *missing* changes the case as much as who is
present. The murderer is then picked at random from among just the guests
who came, so it could be Marcus one game and Count Varga the next.

## Requirements

1. **Godot 4.7** (this project was targeted at 4.7, matching what you have
   installed).
2. **Ollama**, running locally, with the model pulled:
   ```
   ollama pull llama3.2:3b
   ```
   Ollama needs to be running (`ollama serve`, or just have the Ollama app
   open) before you press Play - the game talks to it at
   `http://127.0.0.1:11434/api/chat`. If it can't reach Ollama, the dialogue
   box will show a clear error message telling you to check that Ollama is
   running, rather than failing silently.

## How to run it

Open Godot 4.7, choose "Import", and select the `project.godot` file in
this folder. Press Play (F5). The main scene is `Main.tscn`, which first
shows a suspect-selection screen, then builds the mansion and UI in code
(there's nothing else to wire up). The window opens maximized and the 3D
view/UI stretch to fill whatever size you resize it to (no black ba6.rs).

## Controls

- **WASD** - walk
- **Space** - jump
- **Mouse** - look around
- **Left click or E** - interact with whatever's in front of you (a suspect
  or the front door)
- Any time a suspect's name comes up in conversation or in your case notes
  - whether it's the person you're talking to, or someone else they
  mention - it's colored to match that suspect's body color in the
  mansion, so you can immediately tell who's who while you read.
- **Telling a suspect where to go** - type a movement instruction instead of
  a question in any conversation ("go to the library", "wait in the study")
  and they'll walk there through the mansion's doorways. This is handled
  locally, so it costs no thinking time and they don't answer it in
  character - you just get a short acknowledgement.
- **Hall meetups** - send suspects to the Hall one at a time and they'll
  gather there (two of them; a third will refuse in character). Walk into
  the Hall yourself with both present and the interact prompt changes to
  **Address the room**. See "Confronting them together" below.
- **Doing things, not just saying them** - put an action in round brackets and
  it's treated as something you physically do, rather than words you say out
  loud: `(I give Tom a high five)`, `(leans in) So where were you at eleven?`,
  `(slides the photograph across the table)`. Suspects react to it as a real
  event and can answer with a short gesture of their own - `(nods) I never left
  the study`. Actions render in italics so they read differently from speech.

  This works the same way in a private interview and in a Hall meetup. In the
  Hall an action is always seen by the whole room, so everyone present reacts
  to it - even if you named one person in the brackets.

  It only covers things **you** do, right now. Claims about the past
  (`(Victoria already confessed)`) are still refused by suspects who don't
  remember them - that guard is what stops you inventing evidence, so it stays.
  One quirk of the convention: a genuine aside like `I said (and I quote)
  nothing` is read as an action, since there's no way to tell the two apart.
- **Tab** - open/close your case notes. Each suspect gets their own tab
  down the left side; click one to see their notes on the right, organized
  into four sections:
  - **Timeline** - their claimed whereabouts/alibi around the time of the
	murder
  - **Potential Reason to Kill** - any motive that's come up (grudges,
	money, secrets, relationships)
  - **Slipups** - anything suspicious, evasive, defensive, or inconsistent
	in how they answered
  - **Contradictions** - points where their account conflicts with what
	another guest said in front of them in the Hall, or where their public
	story differs from what they told you privately

  This is AI-generated from that suspect's interview, filtering out small
  talk. Summaries are generated lazily, per tab: clicking a suspect's tab
  only asks Ollama to (re)summarize them if you've talked to them more
  since the last summary, so browsing notes doesn't slow down normal
  questioning. If a summary ever fails to generate, that tab falls back to
  showing the suspect's raw Q&A instead of nothing.

  Each suspect's tab is colored to match their capsule color in the
  mansion (and their name in the notes is colored the same way), tabs for
  suspects you haven't talked to yet are dimmed, and a small red dot
  appears on any tab whose Slipups section has real content - so you can
  tell at a glance who's worth pressing further without opening every tab.
- **Ctrl+1** - toggle a debug overlay in the top-right corner that shows you
  who the murderer is for the current game (plus the weapon/time flavor
  details), so you can test without interrogating the whole cast every
  time. The murderer is also printed to the Godot output console at
  startup either way. This is a testing aid - remove the `"toggle_debug"`
  line in `scripts/GameManager.gd`'s `_setup_input_map()` (and the
  matching block in `scripts/Main.gd`) before sharing a build with anyone
  you want to keep guessing.
- **Esc** - release the mouse / close whichever panel is open

## How it works

- The mansion is a 3x3 grid of 9 rooms (Kitchen, Ballroom, Conservatory,
  Lounge, Dining Room, Study, Billiard Room, Hall, and the Library), all
  connected by open doorways. All of it is built procedurally out of simple
  boxes and capsules in `scripts/Main.gd` - no external 3D models required.
  The grid itself never changes size; if you leave a suspect out at the
  selection screen, their room is just left empty.
- Each suspect you selected stands in their own room. Walk up and interact
  to open a text chat with them. Case notes tabs, the debug overlay, and the
  murderer pool are all limited to the suspects you picked that game.
- Every question you type is sent to a local `llama3.2:3b` model via
  Ollama, along with that character's personality, job, and a system prompt
  describing the case. Each character remembers your prior conversation
  with *them specifically* (so you can follow up and press them). In a
  private interview they don't hear what you asked anyone else - only you
  do, via your Tab case notes. The Hall is the exception: anything said
  there is heard by everyone standing in the room.
- One suspect is secretly the murderer each game. Their prompt tells them
  to lie and stay composed, but also tells them they're not a professional
  liar - if you press hard, contradict them, or come back to the same
  question from a different angle, they may slip.
- When you're ready, walk to the front door (in the Hall) and interact with
  it to open the accusation box. Type a suspect's name (first name, last
  name, or nickname all work) and submit. Wrong guesses just let you keep
  investigating; the right guess ends the case and shows you the
  murderer's motive.

## Confronting them together

Interrogating suspects one at a time only ever gets you one side of a
story. To catch someone in a lie you generally need the person who can
contradict them standing in the same room.

- **Gathering.** Tell suspects "go to the hall" in their own conversations,
  one at a time. The Hall holds two of them; a third will refuse rather than
  crowd in. A three-handed scene - you and two suspects - is deliberate: one
  accuses, one defends, and you referee. It's also twice as fast as a
  four-way, since every attendee costs one more request per line you say.
- **Starting.** Walk into the Hall with both of them there and interact.
  Nothing happens until *you* speak - they'll stand there indefinitely
  otherwise.
- **Taking turns.** Say something to the room and each un-silenced suspect
  answers once, in turn, each hearing what the ones before them just said.
  The order rotates every round so the same person isn't always first to
  set the tone.
- **Controlling the floor.** Start a line with a suspect's name to aim it at
  them alone ("Marcus, where were you at 11:30?"). Type orders to manage the
  room:

  | Order | Effect |
  |---|---|
  | `Marcus, be quiet` | drops him from the rotation - he still hears everything |
  | `Marcus, go ahead` | restores him and gives him the floor now |
  | `Everyone be quiet except Marcus` | silences the room but one |
  | `Everyone may speak` | clears the mute list |
  | `Marcus, leave` | sends him back to his own room |

  Each suspect also has a Silence / Let speak button above the log. Orders
  are recognised locally, so they cost no thinking time and never get
  answered in character. A line with a question mark in it is always treated
  as a question, so "Marcus, why were you so quiet last night?" asks him
  rather than silencing him.
- **Why it works.** Innocent suspects are told to speak up when they hear
  something they know to be false; the murderer is told that attention is
  dangerous and that they may deflect it onto someone else. Letting someone
  stew through two rounds and then giving them the floor is a real tactic -
  they've heard everything said while they were silent.
- **Afterwards.** Everything said in the Hall goes into your case notes,
  tagged with who was standing there. That's what feeds the
  **Contradictions** section: a story told privately and then told
  differently in front of witnesses is exactly what you're hunting for.

## Procedural cases (in progress)

`PLAN_ProceduralCases.md` describes the work to make every playthrough generate
its own murder - different room, weapon, method, time, and a real per-suspect
schedule for the evening - rather than reusing one fixed scenario.

**Phase 5 is in — the system is complete.** Every case now has a **case code**
like `482913-171`, shown on the selection screen after each game, in the Ctrl+1
overlay, in the console at startup, and at the top of the dialogue log. Paste it
into the "Case code" box on the selection screen to play that exact mystery
again — same murderer, same schedules, same weapon, same dropped item.

The code carries the cast as well as the seed, and re-ticks the suspect boxes
for you. That isn't cosmetic: the generator draws every decision from one RNG,
so the same seed with a different set of suspects produces a completely
different mystery. A seed alone would look reproducible and quietly not be.

Dialogue logs now include the full **ground truth table** — every suspect's real
movements slot by slot, plus the exact account each one was given. A line can
only be called a hallucination against what that character was actually told, so
the log is now self-contained: you can audit a conversation weeks later without
having the game open.

**Phase 4 is in.** Two things:

**A "The Scene" tab** at the top of your case notes (Tab), holding everything
you've examined, word for word. Unlike the suspect tabs it isn't AI-summarized
— it's what you saw yourself, so you can trust it against anything you're told.

**Dr Blackwood can narrow the time of death.** The body gives you a 90-minute
window; she gives you a single half hour, which usually clears two or three
people outright. She's the only character whose occupation lets her do this —
so ask her about the body, whether or not you've seen it.

Which also makes her the most dangerous person in the house when she's guilty.
She'll lie about it with a straight professional face, and the lie is picked to
put her somewhere she has a witness. The catch: her stated time won't fit the
window the body itself suggests. Examine the body first and you can catch her
without needing anyone's help.

**Phase 3 is in.** The crime scene is now a real place you can walk into. The
body lies in whichever room the generator chose, with the weapon beside it, and
you can examine all of it:

- **The body** - the wound, whether there was a struggle, and a *90-minute*
  window for the time of death. Not the exact time; narrowing that is Phase 4.
- **The weapon** - and, crucially, which room it's normally kept in. Whoever
  used it went there first. There's a matching clue in that room: an empty
  table where it should be. Two ends of the same thread.
- **A dropped personal item** belonging to one of the guests. Half the time
  it's the murderer's; the rest of the time it belongs to an innocent who
  genuinely was in that room earlier and will say so. It's a conversation
  starter, not an answer.
- **Marks on the floor**, and an overturned chair if there was a fight.

Walk up to anything and press **E**. Examined evidence is remembered for the
case notes (Phase 4 puts it on screen).

**Phase 2b is in.** Suspects now answer from a real timeline instead of making
it up. Ask anyone where they were at half past ten and you get the same answer
every time, because it's read off a generated schedule rather than invented.
Every innocent tells the truth; exactly one person in the house is lying, about
exactly one half-hour block, and at least one innocent was standing in the room
they claim and will say so if you put the two of them in the Hall together.

That's the point of the whole system: before this, two suspects contradicting
each other meant nothing, because both were improvising.

**Phase 2a** put the generated case into the game: the murder room,
weapon, method and time change every launch, and each suspect stands in the
room their schedule ended the night in rather than a fixed home room. Two
suspects can share a room, and some rooms will be empty - that's the schedule
showing through. The story is now that the body was found the *next morning*
and nobody has been allowed to leave, which is why everyone is still where they
spent the evening.

Suspects don't yet know their own schedules - ask one where they were and
they'll still improvise. That's Phase 2b.

Press **Ctrl+1** for the full truth table: the murderer, weapon and its home room,
the lie they're telling, who can disprove it, and every suspect's movements
slot by slot (rooms abbreviated to two letters, `[]` marking the murder).

**Phase 1** is the generator underneath it. `Scripts/CaseGenerator.gd`
builds and validates a complete case: 8 slots of 30 minutes from 8:00pm to
midnight, everyone at dinner in the Dining Room for the first slot, then a
walkable path per suspect through the mansion. It guarantees the murderer had
means (they passed through the room the weapon is kept in), opportunity (alone
with the victim), and a catchable lie (at least one innocent was actually in
the room the murderer claims to have been in).

To check it, open `Scenes/CaseGeneratorTest.tscn` and press **F6**. It builds
1000 cases, asserts every rule, prints distribution stats, and dumps three full
sample cases - including a preview of the schedule text each suspect will
eventually be given. Expect `1000/1000 valid`. Playing the game normally is
completely unaffected by this scene.

## Design notes / assumptions

- Your uploaded character sheet had **8 suspects** (Dr. Evelyn Blackwood,
  Marcus Sterling, Victoria Ashford, Samuel "Sam" Carter, Eleanor Whitmore,
  Thomas "Tom" Reeves, Natalie Cross, and Eugene Cross) rather than 7, so
  all 8 went into the game, each with their own room, and the Hall serves as
  the 9th room / entryway with the front door.
- **Four more were added later**, taking the roster to 12 against a cap of 8
  in the house per game (`GameManager.MAX_ACTIVE_SUSPECTS`). Three of them
  deliberately shift the register: the original eight are grounded
  professionals, and the comedy works because they go on playing it completely
  straight around a Count and a clown.

  The rule the comic characters are written to is **comedy in the voice, rigour
  in the facts**. Every one of them still gets a real schedule from the
  generator and still recites it honestly. The clown's alibi is exactly as
  checkable as the banker's, which is what keeps this a mystery rather than a
  sketch. It also turns out that strong, simple, repeatable premises hold up
  *better* on llama3.2:3b than subtle ones - "speaks in gothic pronouncements"
  is far easier for a 3B to sustain across a long interview than "sophisticated
  and cultured, but manipulative beneath the surface".

  - **Emma Moreau**, Ghostwriter hired to write the victim's memoirs. Eleven
	months in the house with a tape recorder, and she interviewed most of the
	guests too. The most mechanically useful character on the roster: she can
	quote what another suspect told her privately, which drops material into the
	Contradictions section without the player having to stage a Hall
	confrontation to get it. Nobody else can do that.
  - **Count Lucian Varga**, Gentleman of Independent Means (since 1608, he
	says). A man completely committed to the bit, **not** anything actually
	supernatural, and that distinction is load-bearing. A literal vampire could
	be in two places at once, and the moment that is true, schedules stop
	constraining anyone and the case stops being solvable by reasoning. His
	account of the evening is as checkable as anyone else's. The joke is that a
    simple question returns four sentences of gothic declamation wrapped around
    an entirely accurate answer. He takes the murder personally, as a
    professional insult - less horrified by the death than by the amateurism.
  - **Desmond "Giggles" Pike**, Children's Entertainer. Booked for a party at
	this address that does not appear to exist, told to wait in the kitchen, and
	still waiting nine hours later. Written as the most sensible person in the
	house rather than a sinister one: the joke is the gap between how he looks
	and how utterly ordinary he is, which lasts far longer than a creepy-clown
	bit. That also makes him the most reliable witness on the roster, and the
	player has to see past the greasepaint to notice.
  - **Agnes Thorne**, Head Gardener, born on the estate. Twenty-five, born in
	the gardener's cottage, trained by her mother who held the post before her
    and died a few months ago. Deliberately **not** a joke: the Count and the
    clown are funnier when one person is completely unbothered by either. She
    was arranging the table flowers through dinner and nobody registered her as
    being in the room, so she is the only character who can report what was said
    at that table without having been a participant. Note that she keeps the
    Conservatory, where the generator stores the garden wire and the stone
    planter - so whenever it picks either weapon she becomes the most
    incriminated person in the house through no fault of her own, a recurring
    red herring the case system produces for free.

- **Case codes are keyed on permanent slots, not array position.** Each
  character carries a `"slot"` number that is assigned once and never reused,
  and `case_code()` builds its cast bitmask from those.

  This was originally positional, and that was a real bug rather than a
  theoretical one: editing the roster silently repointed every code ever
  generated at a different cast. The code still parsed, still produced a
  plausible-looking house, and was quietly the wrong mystery. Silent is the
  worst available failure here, because reproducing a case exactly is the only
  thing a case code is for.

  With slots, the array can be reordered, added to, or have characters removed
  and old codes keep meaning what they meant. Retiring a character burns their
  slot forever; `NEXT_FREE_SLOT` in `GameManager.gd` records what to use next
  and which numbers are already burned. A code referencing a retired slot is
  now refused with "code is from an older cast" on the selection screen, rather
  than decoded into whoever happens to sit there now.

  `Scenes/CaseGeneratorTest.tscn` checks all of this: slot uniqueness, a
  200-cast encode/decode round trip, and that a retired slot is actually
  rejected. `GameManager._ready()` also asserts slot uniqueness at startup.

- Art is intentionally simple low-poly primitives (colored boxes for rooms,
  colored capsules with floating name labels for suspects) rather than
  custom 3D models or downloaded asset packs, per your preference.
- The victim, murder weapon, and time of death are invented flavor details
  (randomized weapon/time each game) used only to give the murderer
  something specific to protect - the win condition only checks *who*, not
  weapon or room.
