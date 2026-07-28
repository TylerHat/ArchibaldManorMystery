# Archibald Manor: A Clue Mystery

A 3D first-person murder-mystery game built in Godot 4.7. You're the
detective. Lord Reginald Archibald has been murdered in his own manor, and
one of his 8 guests did it. Question them, catch them in a lie, and make
your accusation at the front door.

The murderer is picked at random every time you launch the game (or hit
"Play Again"), so it could be Marcus one game and Victoria the next.

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
this folder. Press Play (F5). The main scene is `Main.tscn`, which builds
the entire mansion and UI in code on startup (there's nothing else to wire
up). The window opens maximized and the 3D view/UI stretch to fill
whatever size you resize it to (no black bars).

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
- **Tab** - open/close your case notes. Each suspect gets their own tab
  down the left side; click one to see their notes on the right, organized
  into three sections:
  - **Timeline** - their claimed whereabouts/alibi around the time of the
	murder
  - **Potential Reason to Kill** - any motive that's come up (grudges,
    money, secrets, relationships)
  - **Slipups** - anything suspicious, evasive, defensive, or contradictory
    in how they answered

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
- **F1** - toggle a debug overlay in the top-right corner that shows you
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
- Each of the 8 suspects stands in their own room. Walk up and interact to
  open a text chat with them.
- Every question you type is sent to a local `llama3.2:3b` model via
  Ollama, along with that character's personality, job, and a system prompt
  describing the case. Each character remembers your prior conversation
  with *them specifically* (so you can follow up and press them), but
  characters don't hear what you asked other suspects - only you do, via
  your Tab case notes.
- One suspect is secretly the murderer each game. Their prompt tells them
  to lie and stay composed, but also tells them they're not a professional
  liar - if you press hard, contradict them, or come back to the same
  question from a different angle, they may slip.
- When you're ready, walk to the front door (in the Hall) and interact with
  it to open the accusation box. Type a suspect's name (first name, last
  name, or nickname all work) and submit. Wrong guesses just let you keep
  investigating; the right guess ends the case and shows you the
  murderer's motive.

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
