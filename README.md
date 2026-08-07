# Archibald Manor: A Clue Mystery

A 3D first-person murder-mystery game built in Godot 4.7. You're the
detective. Lord Reginald Archibald has been murdered in his own manor, and
one of his guests did it. Question them, catch them in a lie, and make your
accusation at the front door.

Every time you launch the game (or hit "Play Again"), you first pick which
2 to 8 of the 8 suspects are actually in the manor that night - either with
quick "Random N" buttons or by checking specific suspects yourself. The
murderer is then picked at random from among just that group, so it could
be Marcus one game and Victoria the next.

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
view/UI stretch to fill whatever size you resize it to (no black bars).

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
  details), so you can test without interrogating all 8 suspects every
  time. The murderer is also printed to the Godot output console at
  startup either way. This is a testing aid - remove the `"toggle_debug"`
  line in `scripts/GameManager.gd`'s `_setup_input_map()` (and the
  matching block in `scripts/Main.gd`) before sharing a build with anyone
  you want to keep guessing.
- **Esc** - release the mouse / close whichever panel is open

## How it works

- The mansion is a 3x3 grid of 9 rooms (Kitchen, Ballroom, Conservatory,
  Lounge, Study, Dining Room, Billiard Room, Library, and the Hall), all
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
  all 8 are in the game, each with their own room, and the Hall serves as
  the 9th room / entryway with the front door.
- Art is intentionally simple low-poly primitives (colored boxes for rooms,
  colored capsules with floating name labels for suspects) rather than
  custom 3D models or downloaded asset packs, per your preference.
- The victim, murder weapon, and time of death are invented flavor details
  (randomized weapon/time each game) used only to give the murderer
  something specific to protect - the win condition only checks *who*, not
  weapon or room.
