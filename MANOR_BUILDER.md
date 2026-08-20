# ManorBuilder

Replaces both the runtime `_build_mansion()` code in `Main.gd` and the
hand-placement walkthrough in `BUILD_GUI_Geometry.md`.

**`BUILD_GUI_Geometry.md` is superseded. Do not keep working through Part 4.**
Placing those 37 walls by hand reproduces, node by node, geometry your own code
already generates correctly. You were four walls in. This gets you the rest for
free and keeps the layout editable.

---

## What it does

`ManorBuilder.gd` is a `@tool` script. Because of that one annotation the manor
is generated *in the editor*, so you can fly around it in the viewport, and
regenerated at runtime, so the game gets the same thing. The `FLOORS` spec at
the top of the file stays the single source of truth for the layout.

It owns floors, walls, doorway gaps, ceilings, stairs, stairwell openings,
per-room `Area3D` volumes, room labels and collision.

It never touches anything under the **`Decor`** child. Put furniture, props and
set dressing there and rebuilding the shell will not disturb it.

### Verified against your current geometry, then deliberately diverged

I first simulated both the existing `_build_wall_side()` logic and the new
emitter and diffed every box position and size. With the upper floor disabled
the output was **identical**: 48 boxes, 37 walls, split 14 / 12 / 6 / 5 across
the four wall sizes, matching the table in `BUILD_GUI_Geometry.md` exactly.

Then the corner gaps turned up, and it became clear that parity meant
"identically broken." The builder now fixes them, so the geometry is
intentionally no longer identical. See the next section.

## The corner gaps

`CELL` is 12 but `PITCH` is 13. Walls were built `CELL` long, so every wall
stopped 1.0 short of the next room's wall and left a hole exactly where the
corner should be. **16 of them on the ground floor**, one at each end of every
wall line.

I measured how bad it actually was with a 2D flood fill at 2.5cm resolution,
asking how wide a disc could travel from outside the manor to a room centre,
with the front door sealed so it did not dominate the result:

| Floor plan | Before | After |
|---|---|---|
| Ground floor, 3x3 rectangle | 0.76m clear | **sealed**, no sight line |
| Upper floor, plus shape | 1.08m clear | **sealed**, no sight line |

Your player capsule is 0.80m across. So on the ground floor as it stands you can
see out through the corners but not quite walk out, by 4cm. **I told you earlier
that you could walk out through any corner and that was wrong**, I had reasoned
it from the 1.0m plane gap without accounting for the perpendicular wall
partially blocking it. On the plus-shaped upper floor you plan to build, the
same defect measures 1.08m and is genuinely passable.

The fix, in its final form:

- **`WALL_SPAN = PITCH`** (13.0 instead of 12.0), and **every wall sits on the
  room boundary** at `PITCH/2` rather than `CELL/2`. Wall planes then line up
  exactly with floor slab edges, so a wall butts its neighbour end to end with
  neither gap nor overlap. The doorway opening stays exactly `DOOR_W`; the half
  segments grow from 4.5 to 5.0.
- **Colinear coplanar runs are merged** into single boxes. See the next section
  for why this is not just an optimisation.

Visible effect on the ground floor: corners are solid, and each room is about
0.5 wider on two sides. Nothing else about the layout moves.

## Z-fighting, and a wrong turn I took

For one revision this file used `WALL_SPAN = PITCH + WALL_T`, overlapping each
wall with its neighbour by a wall thickness. That also seals the corners, and I
described the overlap as costing nothing. **That was wrong, and it is what made
the walls shimmer.**

Overlapping two walls on the same plane puts two *same-facing* coplanar quads in
the same place. The depth test then has no basis to choose between them, picks a
winner per pixel, and the winner flips as the camera moves. Because each quad is
two triangles, what you see is the triangulation crawling across the wall. I
measured the total fighting surface at **96 m²** across the ground floor.

Two things matter for avoiding it:

- **Butting is safe, overlapping is not.** Faces that merely touch back to back
  never fight, because they face opposite directions and backface culling draws
  only one of them. Faces that overlap while facing the *same* way always fight.
- **Merge colinear runs.** The layout walk emits walls per room, so the manor's
  whole north face arrives as three boxes meeting end to end. Meeting is fine,
  but float rounding alone can turn a meeting into a hairline overlap. Merging
  removes the question: one run, one box, no internal seam to fight over.

Measured on the shipping configuration:

| | Ground floor | Upper floor (plus shape) |
|---|---|---|
| Wall boxes | 36 → **20** merged | 20 → **12** merged |
| Z-fighting surface | **0.00 m²** | **0.00 m²** |
| Sealed against flood fill | yes | yes |
| Doorway widths | all exactly 3.0m | all exactly 3.0m |

The merge is controlled by **Merge Wall Runs** in the Inspector, on by default.
Turn it off only to inspect the per-room segments the layout pass produced, and
expect the shimmer to come back when you do.

If you still see crawling artifacts anywhere after this, the other candidate is
shadow acne from the single `DirectionalLight3D` in `_build_world()`, which
looks similar but appears in shadowed areas rather than on wall seams. Raising
that light's `shadow_bias` and `shadow_normal_bias` is the fix for that one, and
it is unrelated to the geometry.

### What you gain

| | Before | After |
|---|---|---|
| Draw calls for the shell | ~47 (one material per box) | 3 (one MultiMesh per kind) |
| Wall boxes | 37 | 20 (colinear runs merged) |
| Materials | 47 unique `StandardMaterial3D` | 1 shared, per-instance vertex colours |
| Physics bodies | 47 `StaticBody3D` | 1 body, 47 shared-resource shapes |
| Visible in editor | no | yes |
| Change the layout | edit code, press Play | edit `FLOORS`, tick Rebuild |
| Second floor | not possible | data change plus the Phase 2 list below |

The materials point is the one that was quietly costing you. `add_solid_box()`
called `StandardMaterial3D.new()` per box, so 47 identical cream boxes became 47
distinct materials and Godot could not batch a single one of them. On a 6GB 4050
that is also holding llama3.2 in VRAM, that headroom is worth reclaiming.

---

## Setup

1. Copy `ManorBuilder.gd` into `Scripts/`.
2. Open `Scenes/Main.tscn`.
3. **Delete the four hand-placed walls** under `Rooms` (`Kitchen_south_a`,
   `Kitchen_south_b`, `Kitchen_east_a`, `Kitchen_east_b`) and the four
   auto-named leftovers (`4_5, 3, 0_4` and friends). Keep the `Rooms` node for
   now; the patch below repoints it.
4. Add a `Node3D` child of the root, rename it **`Manor`**, attach
   `ManorBuilder.gd` to it.
5. In the Inspector, tick **Rebuild Now**. The manor appears in the viewport.

The four `Scenes/Pieces/*.tscn` wall scenes are no longer referenced. Keep them
if you want them as a visual reference for wall dimensions, otherwise delete
them.

### Inspector options worth knowing

- **Save To Scene** (default off). Off means the shell renders in the viewport
  but is not written into `Main.tscn`, so the scene file stays tiny and the spec
  is the only source of truth. Turn it on when you want individual wall nodes in
  the Scene dock to select and tweak; they then get saved, and a later rebuild
  overwrites your tweaks.
- **Batch Meshes** (default on). Off gives you individually selectable
  `MeshInstance3D` nodes for debugging. Positions are identical either way, so
  flip freely.
- **Wall / Floor / Ceiling Material**. Drop your textured materials here when
  you have them. Keep it to one material per kind; that is what makes batching
  work. Per-room colour still comes through as vertex colour.
- **Merge Wall Runs** (default **on**). Collapses colinear coplanar wall
  segments into single boxes. This is what keeps the walls free of z-fighting,
  and it drops the ground floor from 36 boxes to 20 as a side effect. Leave it
  on unless you are specifically inspecting the unmerged segments.

---

## The `Main.gd` patch

Five edits. None of them touch dialogue, the case generator, or the UI.

### 1. Add a reference to the builder

Near the other node vars around line 94:

```gdscript
@onready var manor: ManorBuilder = $Manor
```

### 2. Strip world-building out of `_build_world()`

It should keep the environment and the directional light, and lose the last
five lines. Delete these:

```gdscript
	rooms_node = Node3D.new()
	rooms_node.name = "Rooms"
	add_child(rooms_node)

	# A large safety-net ground plane beneath everything.
	add_solid_box(rooms_node, "Ground", Vector3(60, 0.2, 60), Vector3(0, -0.6, 0), Color(0.1, 0.1, 0.12))
```

### 3. Replace `_build_mansion()` with an adopt step

Delete `_build_mansion()`, `_build_room()`, `_build_wall_side()`,
`_build_front_door()` and `add_solid_box()`. They are the only callers of each
other, so nothing else breaks. Add:

```gdscript
## The manor is generated by ManorBuilder (see MANOR_BUILDER.md). This just
## reads back what it built, so the rest of Main.gd keeps working against
## room_centers / grid_pos / rooms_node exactly as before.
func _adopt_manor() -> void:
	manor.rebuild()

	room_centers.clear()
	grid_pos.clear()
	var data := manor.get_room_data()
	for rname in data:
		room_centers[rname] = data[rname]["center"]
		grid_pos[rname] = data[rname]["grid"]

	front_door_node = manor.front_door_node
	# NPCs and evidence are parented to Decor rather than the generated Shell,
	# so a rebuild never deletes them out from under a running game.
	rooms_node = manor.get_node("Decor")
```

### 4. Call it from `_start_game()`

```gdscript
	_build_world()
	_adopt_manor()        # was: _build_mansion()
	_spawn_npcs()
```

### 5. Leave `GRID` where it is

`GRID` is still read by `_build_room_name_lookup()`,
`_build_move_command_regexes()`, `_room_bfs_path()` and `_build_map_panel()`.
Leave the constant in `Main.gd` for now. Phase 2 is where those move over to
the builder's data. Keeping the two in sync until then means editing the layout
in `ManorBuilder.FLOORS` and mirroring it in `Main.GRID`, which is mildly
annoying but keeps this change zero-risk.

### Check it worked

Press Play. The only visual differences should be solid corners and rooms very
slightly larger. Then verify:

- The front door still opens the accusation panel.
- "Go to the Library" still walks a suspect there through the doorways.
- The map panel (M) still highlights the right room.
- Suspects still spawn inside rooms rather than in walls.

If any of those fail, the likely cause is `rooms_node` being null, which means
the `Manor` node is not named exactly `Manor` or has no `Decor` child yet
(it is created on the first rebuild).

---

## Phase 2: the upstairs

The geometry is done. Flip `"enabled": true` on the `upper` floor in
`ManorBuilder.FLOORS` and you get four bedrooms, a landing, a stair hall, a
14-step flight up from the Hall, and a correctly cut stairwell opening in the
floor above it. I verified the flight lands at exactly y = 4.0 (the upper floor
level) and leaves 92% of the Stair Hall floor intact in a U around the opening.

**The gameplay code is not ready for it.** Five things in `Main.gd` assume a
single 3x3 floor, and all five will misbehave rather than crash, which is worse.
In dependency order:

| Function | Line | What breaks | Fix |
|---|---|---|---|
| `_room_at(pos)` | 1071 | Picks the nearest room centre in XZ only. Master Bedroom and Ballroom share an XZ position, so a suspect upstairs reads as being downstairs. | Use the `Area3D` room volumes the builder emits. They are in the `room_volume` group with a `room_name` meta, and they are the reason I included them. |
| `_room_bfs_path()` | 961 | Bounds-checks against `GRID.size()` and treats any orthogonal cell pair as connected. No concept of levels or stairs. | Switch to `manor.rooms_connected(a, b)` for the neighbour test and BFS over room names instead of `Vector2i` cells. |
| `get_room_travel_waypoints()` | 1013 | Uses the midpoint of two room centres as the doorway crossing. Between floors that midpoint is inside a wall, halfway up. | Special-case a stair link: route via the bottom of the flight, then the top. |
| `_has_neighbor()` | 586 | Hardcodes the 0..2 bounds. | Delete it and use the builder's `_has_neighbour`, which handles void cells and levels. |
| Map panel | 1281-1487 | Draws one 3x3 `GridContainer` straight from `GRID`. | Either a floor toggle, or two stacked grids. Cosmetic, do it last. |

Also worth deciding before you build it: suspects taking stairs need either a
real `NavigationRegion3D` with a link, or a scripted "walk to stair bottom,
teleport-and-fade, walk from stair top" cheat. For a murder mystery where the
player rarely watches a suspect traverse a whole floor, the cheat is probably
the right call and is an afternoon rather than a week.

**My advice: land Phase 1, play it, confirm nothing regressed, then start
Phase 2 as its own change.** The two are independent and mixing them makes any
regression much harder to attribute.

---

## Notes

- Room names must be unique across all floors, because `Main.gd` keys
  everything by name. The builder pushes a warning if you duplicate one.
- An empty string in a grid means "no room here". That is how the upper floor
  gets a smaller footprint than the ground floor, and a room next to a void cell
  correctly builds a solid exterior wall rather than a doorway.
- Room volumes sit on physics layer 3 by default with mask 0, so they never
  collide with the player or suspects. Change `room_volume_layer` if that layer
  is already spoken for.
- Ceilings are off by default. Turning them on will change your lighting, since
  the single `DirectionalLight3D` in `_build_world()` currently lights the
  interior from above through open tops.
