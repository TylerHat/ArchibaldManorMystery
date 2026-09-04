# The manor and the world

The mansion, its walls and doorways, the furniture, the crime scene, and how
suspects walk around it. Everything physical.

---

## 1. The layout

The manor is a **3 by 3 grid of nine rooms**, all connected by open doorways.
It never changes size. If you leave a suspect out at the selection screen,
their room is simply empty.

```
        WEST                                    EAST
      ┌───────────────┬───────────────┬───────────────┐
NORTH │   Kitchen     │   Ballroom    │  Conservatory │   row 0
      ├───────────────┼───────────────┼───────────────┤
      │   Lounge      │  Dining Room  │    Study      │   row 1
      ├───────────────┼───────────────┼───────────────┤
SOUTH │ Billiard Room │     Hall      │   Library     │   row 2
      └───────────────┴──── front ────┴───────────────┘
                           door
        col 0            col 1            col 2
```

Defined twice, deliberately:

- `Main.GRID`, what gets built and walked around
- `CaseGenerator.GRID`, what the mystery reasons about

They are identical and must stay identical. The generator keeps its own copy so
it stays a closed system with no scene-tree dependency, which is what makes it
testable a thousand times a second.

**The Hall is special.** It is the front-centre room, so the front door can face
outward. It holds the front door (the only way to win), it is where the player
spawns, and it is the meetup room where suspects gather for a group
confrontation.

### The upper floor

There is a second floor, built at runtime by `Main._build_upper_floor()` from
`ManorBuilder`'s `FLOORS` spec: Master Bedroom, Nursery, Landing, Guest Room,
Stair Hall. A single flight of stairs climbs from the Hall's north-west corner.

**Those room names are deliberately kept out of `Main.GRID`, `Main.grid_pos`,
`Main.room_centers` and `CaseGenerator.GRID`.** The case generator is a closed
system over its own private nine-room grid, so a room it has never heard of
cannot end up in a schedule, an alibi, a witness list or as the murder room.
That is what keeps every suspect downstairs without one line of change to the
generator. Do not "fix" this by adding upstairs rooms to the generator's grid
unless you have read [`06-the-case-generator.md`](06-the-case-generator.md) and
mean to redesign the case system.

---

## 2. The numbers

All in `Main.gd`, mirrored in `ManorBuilder.gd`.

| Constant | Value | Means |
|---|---|---|
| `CELL` | 12.0 | inside width of one room, in metres |
| `PITCH` | 13.0 | centre-to-centre distance between two rooms |
| `WALL_H` | 3.0 | wall height |
| `WALL_T` | 0.4 | wall thickness |
| `DOOR_W` | 3.0 | width of the doorway gap |
| `WALL_SPAN` | `PITCH` | how far a wall runs along its own axis |
| `STOREY` | 3.2 | vertical distance between floor levels |

### Why `WALL_SPAN` is `PITCH` and not `CELL`

This is the most instructive bug in the repo and the comment on the constant
tells the story in full. Short version:

Walls used to be `CELL` long (12) sitting at `CELL/2` out from a room centre,
while rooms are `PITCH` apart (13). Every wall therefore stopped 1.0 metre short
of its neighbour and left a hole exactly at the corner. Sixteen of them on the
ground floor.

Measured by flood fill, the widest clear route from outside into a room was
0.76m against a 0.80m player capsule. You could see straight out through every
corner and only missed walking out through one by four centimetres.

At `PITCH` the walls sit on the room boundary, so each butts its neighbour end
to end with neither gap nor overlap. Not `PITCH + WALL_T`, which also seals the
corners but puts two same-facing coplanar surfaces in the same place at every
junction and makes the walls shimmer.

Two good things fall out of it: rooms become symmetric, and the doorway
waypoint (the midpoint between two room centres) lands exactly in the opening
rather than half a metre past it.

---

## 3. Who builds what

Three systems build the physical world, and they have a strict division of
labour.

### `ManorBuilder.gd`, the shell

A `@tool` script, meaning it runs in the editor as well as at runtime, so the
manor is drawn live in the viewport while you edit the spec.

**It owns:** floors, walls, doorway gaps, ceilings, stairs, per-room `Area3D`
volumes, room labels, collision.

**It never touches** anything under its `Decor` child node. Put furniture,
props and set dressing there. Rebuilding the shell will not disturb any of it.

The layout comes from the `FLOORS` constant, an array of one dictionary per
level with an `id`, a `level`, `enabled`, `emit`, and a `grid` of room names.
An empty string in the grid means no room there.

Note the ground floor entry has `"emit": false`. It is indexed but not built,
because `Main.gd` still builds the ground floor itself; the entry exists so
`room_centers` knows where the Hall is, which is what the stair flight measures
its rise from.

Full setup instructions: [`../reference/manor-builder.md`](../reference/manor-builder.md).

### `ManorDressing.gd`, the furniture

Everything is data. `Models/Furniture/furniture.json` lists, per room, which
model goes where in room-local coordinates. Adding a chair means adding four
numbers to that file, not touching the script.

Placement rules the layout data already respects, which are invisible from the
JSON alone and easy to break:

- Suspects wander within `NPCCharacter.WANDER_MARGIN` of a room's centre, so
  every solid piece sits in the band near the walls where nobody walks.
- The middle of every wall is a doorway. Nothing solid straddles one.
- `CrimeScene` puts the body at room centre plus `(3.9, -3.9)` and the weapon
  gap at `(-4.1, -4.1)`. Those two corners are kept clear in **every** room,
  because any of them can be the scene.

Format details: [`10-data-and-file-formats.md`](10-data-and-file-formats.md).

### `CrimeScene.gd`, the body and the evidence

Builds the physical crime scene for whatever case was generated: the body where
it fell, the weapon beside it, whatever the killing left behind, the dropped
personal item, and the gap in the room the weapon was taken from.

Everything is derived from `GameManager.case_data`, so the scene rearranges
itself every playthrough. It owns no input at all: every object it spawns is an
`Evidence` node, which the player's existing raycast already knows how to talk
to.

The five things it can place:

| Object | What it tells you |
|---|---|
| The body | the wound, whether there was a struggle, and a 90-minute window for the time of death |
| The weapon | and, crucially, which room it is normally kept in |
| The gap | in that home room, an empty table where the weapon should be. Two ends of the same thread |
| A dropped item | belongs to a guest. Roughly half the time an innocent's, so it is a conversation starter rather than an answer |
| Marks and an overturned chair | present only if the method was a struggle |

---

## 4. Room colors

`Main.ROOM_COLORS` gives each room a tint. `Main.NPC_COLORS` gives each suspect
one.

The suspect colors do double duty: they are the capsule color in the mansion
**and** the name color in the case notes, the dialogue log and the map. So every
one of them has to stay legible as text on a dark panel. Avoid near-black
shades.

The comment on `NPC_COLORS` notes that twelve is about the practical ceiling.
The gold, orange and tan trio is already the closest set in the palette. A
thirteenth suspect means reworking the palette rather than appending to it.

---

## 5. How suspects move

`NPCCharacter.gd`, one instance per suspect in the house. Two states.

### Wandering

The default. The suspect picks a random point inside their current room, walks
to it, waits between 1.0 and 3.5 seconds, and picks another.

Constraints that keep this from looking broken:

- `WANDER_MARGIN` (3.5) keeps them well inside the outer walls. This was raised
  from 2.0 when the manor was furnished: suspects now keep to the open middle
  and the whole perimeter belongs to the furniture, so nobody grinds against a
  bookcase. **These NPCs have no obstacle avoidance at all.** That is why the
  margin matters.
- `SEPARATION_RADIUS` and `SEPARATION_STRENGTH` provide simple steering so two
  suspects sharing a room drift apart rather than overlapping. The
  `CharacterBody3D` collision shape is the hard backstop underneath.

### Travelling

When you type "go to the library", `Main._parse_move_command()` recognises it
locally, `Main.command_npc_move()` computes a route, and
`NPCCharacter.begin_travel()` walks it.

The route is a **breadth-first search over the room grid**
(`Main._room_bfs_path()`), then converted into world waypoints by
`Main.get_room_travel_waypoints()`. Each waypoint is the midpoint between two
adjacent room centres, which is exactly where the doorway is, which is why the
`WALL_SPAN` fix above mattered for movement and not only for looks.

So a suspect walks room centre, doorway, room centre, doorway, room centre.
They never path around furniture, because they never need to: the route runs
down the middle of everything and the middle is kept clear.

### Animation

If a suspect's folder has a 3D model with an `AnimationPlayer`,
`NPCCharacter._ensure_animation()` looks for a clip named one of
`Idle`, `Idle_A`, `Idle_Loop`, `Stand`, `Breathing Idle` and one of
`Walk`, `Walk_A`, `Walk_Loop`, `Walking`, `Run`, `Running`, and plays the
appropriate one. If it finds neither, the model just slides, which looks fine
enough at this art level.

---

## 6. Furniture culling

`Main._process()` does one thing: hide furniture in rooms you cannot see.

`_rooms_in_sight()` works out which rooms are visible from the one you are
standing in (yours, plus what is visible through the doorways), and everything
else has its furniture hidden. Only recomputed when you change rooms, tracked
by `_culled_for_room`.

This is a real saving. The manor shell batches down to a handful of draw calls,
but the furniture is dozens of separate imported meshes.

---

## 7. The Hall meetup, physically

`Main.MEETUP_ROOM` is `"Hall"`. `Main.MAX_HALL_ATTENDEES` is currently **4**.

That number used to be 2, and it was a latency ceiling rather than a drama
choice: every line the detective said cost one sequential Ollama request per
attendee, and each of those re-read that suspect's whole history. Four
attendees measured about ten seconds of dead air per line.

Three changes lifted it: group lines are no longer copied into every attendee's
permanent memory (`GroupChat` renders the room on demand instead), the system
prompt now shares a cached prefix across all suspects, and
`OLLAMA_NUM_PARALLEL=4` gives each suspect their own cache slot. The full
measurement is in
[`../plans/dialogue-optimization-technical.md`](../plans/dialogue-optimization-technical.md).

Three-handed scenes are still the sharpest drama, one accuser and one defender
with you refereeing, but the room now allows four.

Walking into the Hall with attendees present changes the interact prompt to
**Address the room**. Nothing happens until you speak.

---

## 8. Changing the world

| To change... | Edit | Then |
|---|---|---|
| Room names or layout | `Main.GRID` **and** `CaseGenerator.GRID` together | run `CaseGeneratorTest.tscn` |
| Room size or wall thickness | `CELL`, `PITCH`, `WALL_T` in `Main.gd` and `ManorBuilder.gd` | check `NPCCharacter.ROOM_HALF`, which hardcodes `CELL/2` |
| Furniture | `Models/Furniture/furniture.json` | keep the centre and the two scene corners clear |
| Upper floor rooms | `ManorBuilder.FLOORS` | do **not** add them to either `GRID` |
| A room's color | `Main.ROOM_COLORS` | also check the map panel reads well |
| How far suspects wander | `NPCCharacter.WANDER_MARGIN` | they have no obstacle avoidance, so raising it means they will hit furniture |

`NPCCharacter.ROOM_HALF := 6.0` is a hardcoded copy of `Main.CELL / 2` and
carries a comment saying to keep it in sync. If you change `CELL`, change this
too. Nothing will warn you.
