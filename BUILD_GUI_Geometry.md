> # SUPERSEDED
>
> **Do not follow Part 4 of this document.** Hand-placing the 37 walls
> reproduces, node by node, geometry that `Main.gd` already generated
> correctly from the `GRID` constant.
>
> Use `Scripts/ManorBuilder.gd` instead. It is a `@tool` script, so the manor
> is generated live in the editor viewport from a `FLOORS` spec, the layout
> stays editable, and the shell collapses to 3 draw calls instead of ~47. Its
> output was diffed against the old `_build_wall_side()` box by box and is
> identical.
>
> See **`MANOR_BUILDER.md`** for setup and the `Main.gd` patch.
>
> Kept for reference only: the dimension tables and the wall-type breakdown in
> Part 3 are still accurate and useful.

---

# Building Archibald Manor by hand in the Godot editor

A step-by-step guide to replacing the code-generated mansion with real nodes
you can see, click, and drag.

Written for Godot 4.7. Every number in here was read directly out of your
`Main.gd`, so if you follow it exactly the hand-built mansion will be
pixel-identical to the one the code makes today.

---

## Read this first

Three things will save you a lot of pain.

**1. Your code doesn't just draw the mansion, it remembers it.**

`Main.gd` builds the world and then holds on to what it built:
`rooms_node`, `room_centers`, `grid_pos`, `front_door_node`, `player`, and
`npc_nodes`. Half the game reads those. Pathfinding, the "go to the library"
command, the Hall meetup rules, and the map panel all depend on
`room_centers` in particular.

So building the geometry in the editor is only half the job. The other half is
changing the code to *find* things instead of *making* them. Part 9 covers
exactly that, and it's a smaller change than you'd think.

**2. The suspects cannot be fully hand-placed, and you don't want them to be.**

Which suspects exist depends on the selection screen, which lets the player
pick 2 to 8 out of 12. Where they stand depends on the case the generator
produced that night. Neither is known until the game is running.

The right answer is a **reusable suspect scene**: you design one suspect in the
editor exactly how you like, save it as `Suspect.tscn`, and the code stamps out
copies of it. You get full visual control, the game keeps its variety. Part 8
covers this.

**3. There is a shortcut that skips most of the tedium.**

Building 37 walls and 9 floors by hand is roughly 138 nodes and a lot of typing.
Part 10 has a one-off script that generates all of them into your scene *once*,
after which you can move, edit, and re-texture them in the editor forever.

If you want the hand-building experience, work through Parts 1 to 8. If you
mainly want editable nodes without the RSI, jump to Part 10 and then come back
for Parts 8 and 9.

---

## The numbers

These come from the constants at the top of `Main.gd`.

| Name in code | Value | What it means |
|---|---|---|
| `CELL` | 12.0 | The inside width of one room |
| `PITCH` | 13.0 | Distance from one room's centre to the next |
| `WALL_H` | 3.0 | Wall height |
| `WALL_T` | 0.4 | Wall thickness |
| `DOOR_W` | 3.0 | Width of the gap left for a doorway |

The mansion is a 3x3 grid. Looking down from above, with **negative Z as
north** and **positive X as east**:

```
                        NORTH  (-Z)
        +-------------+-------------+-------------+
        |   Kitchen   |  Ballroom   |Conservatory |
        | (-13,-13)   |  (0,-13)    |  (13,-13)   |
        +-------------+-------------+-------------+
WEST    |   Lounge    | Dining Room |    Study    |    EAST
(-X)    |  (-13, 0)   |   (0, 0)    |   (13, 0)   |    (+X)
        +-------------+-------------+-------------+
        |Billiard Room|    Hall     |   Library   |
        |  (-13, 13)  |   (0, 13)   |  (13, 13)   |
        +-------------+-------------+-------------+
                        SOUTH  (+Z)
                            ^
                       front door
```

The numbers in brackets are each room's centre as **(X, Z)**. Y is always 0 at
floor level.

The front door is in the Hall's south wall, at **(0, 0, 19)**.

---

## Part 1: Set up the scene

1. Open your project in Godot.
2. In the **FileSystem** dock (bottom left), double-click `Scenes/Main.tscn`
   to open it. Right now it's nearly empty, because everything is built by code.
3. Look at the **Scene** dock (top left). You'll see the root node.
4. Select the root node.
5. Press **Ctrl+A** (or click the **+** button at the top of the Scene dock).
   This opens **Create New Node**.
6. Type `Node3D` in the search box, select it, click **Create**.
7. The new node appears as a child. Double-click its name and rename it to
   exactly **`Rooms`**. Capital R, no spaces. The code looks for this name.

Everything you build goes inside `Rooms`.

> **Why the name matters:** in Part 9 you'll change `Main.gd` to do
> `rooms_node = $Rooms`. If the name is different, that line returns null and
> the game crashes on startup.

---

## Part 2: Build one wall, properly

Do this once, slowly. Every other wall is a copy of it.

### 2a. Create the body

1. Select the **`Rooms`** node.
2. Press **Ctrl+A**, search `StaticBody3D`, click **Create**.
3. Rename it to `Wall_H_Segment`.

`StaticBody3D` means "solid, doesn't move." That's what stops the player
walking through it.

### 2b. Give it a shape you can see

1. Select `Wall_H_Segment`.
2. Press **Ctrl+A**, search `MeshInstance3D`, click **Create**. It becomes a
   child of the wall.
3. With `MeshInstance3D` selected, look at the **Inspector** on the right.
4. Find the property called **Mesh**. It says `<empty>`.
5. Click the dropdown arrow next to it and choose **New BoxMesh**.
6. A small box icon appears. **Click on that box icon** to expand its settings.
7. You'll now see a **Size** property with X, Y, Z fields.
8. Set Size to **X = 4.5, Y = 3, Z = 0.4**.

You should see a flat wall panel appear in the 3D viewport.

### 2c. Give it a colour 9d8749c7

1. Still on the `MeshInstance3D`, scroll down the Inspector to the section
   called **Geometry**. Expand it if it's collapsed.
2. Find **Material Override**. Click its dropdown and choose
   **New StandardMaterial3D**.
3. Click on the material icon that appears, to expand it.
4. Find **Albedo** near the top, and expand that.
5. Click the **Color** swatch. A colour picker opens.
6. There's a hex field at the bottom of the picker. Type **`EBE6D9`** and press
   Enter. That's your wall colour.

> **Watch out:** use **Material Override**, not "Surface Material Override".
> Material Override is the one your code uses, and it's simpler.

### 2d. Give it collision

The mesh is just something to look at. Without a collision shape the player
walks straight through it.

1. Select the parent `Wall_H_Segment` node again (not the MeshInstance3D).
2. Press **Ctrl+A**, search `CollisionShape3D`, click **Create**.
3. With `CollisionShape3D` selected, find **Shape** in the Inspector.
4. Click its dropdown, choose **New BoxShape3D**.
5. Click the shape icon to expand it.
6. Set **Size** to **X = 4.5, Y = 3, Z = 0.4**. The exact same numbers as
   the mesh.

> **The single most common mistake:** the mesh size and the collision size
> drifting apart. If a wall looks solid but the player walks through it, or the
> player bumps into thin air, this is why. They must match.

Your node tree should now look like:

```
Rooms
 └─ Wall_H_Segment          (StaticBody3D)
	 ├─ MeshInstance3D      (BoxMesh, 4.5 x 3 x 0.4, cream material)
	 └─ CollisionShape3D    (BoxShape3D, 4.5 x 3 x 0.4)
```

### 2e. Save it as a reusable piece

1. **Right-click** on `Wall_H_Segment` in the Scene dock.
2. Choose **Save Branch as Scene**.
3. Save it as `Scenes/Pieces/Wall_H_Segment.tscn` (create the `Pieces` folder
   in the dialog if it doesn't exist).

The node in your tree now has a little "clapperboard" icon, meaning it's an
instance of a saved scene. **This is the important bit:** if you later change
the colour in `Wall_H_Segment.tscn`, every copy in your mansion updates at once.

---

## Part 3: Build the other three wall types

There are only **four** distinct wall shapes in the whole mansion. Repeat
Part 2 three more times with these sizes, saving each as its own scene:

| Save as | Mesh & collision size | Used for |
|---|---|---|
| `Wall_H_Segment.tscn` | `4.5, 3, 0.4` | The 14 short walls either side of an east-west doorway |
| `Wall_H_Solid.tscn` | `12, 3, 0.4` | The 5 unbroken walls running east-west |
| `Wall_V_Segment.tscn` | `0.4, 3, 4.5` | The 12 short walls either side of a north-south doorway |
| `Wall_V_Solid.tscn` | `0.4, 3, 12` | The 6 unbroken walls running north-south |

All four use the same cream colour, `EBE6D9`.

> **Why "H" and "V":** an H wall is wide in X and thin in Z, so it runs
> east-west and you walk through it going north or south. A V wall is the
> other way round. Getting these mixed up is the second most common mistake.

---

## Part 4: Place all 37 walls

Now the repetitive part. For each row in the table below:

1. In the **FileSystem** dock, find the right `.tscn` piece for that size.
2. **Drag it** from FileSystem onto the `Rooms` node in the Scene dock. This
   creates an instance.
3. Rename it to the node name in the table (double-click the name).
4. With it selected, in the **Inspector** find **Transform > Position**.
5. Type in the three numbers from the table.

> **Position is relative to the parent.** Because every wall is a direct child
> of `Rooms`, and `Rooms` sits at (0, 0, 0), the numbers in this table are the
> real world positions. If you nest walls inside other nodes, the numbers stop
> matching. Keep them all flat under `Rooms`.

> **A faster way to repeat:** place the first wall, then press **Ctrl+D** to
> duplicate it. The copy lands on the same parent with the same settings, and
> you only need to change the name and position. For a run of walls that differ
> in one axis only, this is much quicker than dragging from FileSystem each time.

| # | Node name | Size (X, Y, Z) | Position (X, Y, Z) |
|---|---|---|---|
| 1 | `Kitchen_south_a` | `4.5, 3, 0.4` | `-16.75, 1.5, -7` |
| 2 | `Kitchen_south_b` | `4.5, 3, 0.4` | `-9.25, 1.5, -7` |
| 3 | `Kitchen_east_a` | `0.4, 3, 4.5` | `-7, 1.5, -16.75` |
| 4 | `Kitchen_east_b` | `0.4, 3, 4.5` | `-7, 1.5, -9.25` |
| 5 | `Kitchen_north` | `12, 3, 0.4` | `-13, 1.5, -19` |
| 6 | `Kitchen_west` | `0.4, 3, 12` | `-19, 1.5, -13` |
| 7 | `Ballroom_south_a` | `4.5, 3, 0.4` | `-3.75, 1.5, -7` |
| 8 | `Ballroom_south_b` | `4.5, 3, 0.4` | `3.75, 1.5, -7` |
| 9 | `Ballroom_east_a` | `0.4, 3, 4.5` | `6, 1.5, -16.75` |
| 10 | `Ballroom_east_b` | `0.4, 3, 4.5` | `6, 1.5, -9.25` |
| 11 | `Ballroom_north` | `12, 3, 0.4` | `0, 1.5, -19` |
| 12 | `Conservatory_south_a` | `4.5, 3, 0.4` | `9.25, 1.5, -7` |
| 13 | `Conservatory_south_b` | `4.5, 3, 0.4` | `16.75, 1.5, -7` |
| 14 | `Conservatory_east` | `0.4, 3, 12` | `19, 1.5, -13` |
| 15 | `Conservatory_north` | `12, 3, 0.4` | `13, 1.5, -19` |
| 16 | `Lounge_south_a` | `4.5, 3, 0.4` | `-16.75, 1.5, 6` |
| 17 | `Lounge_south_b` | `4.5, 3, 0.4` | `-9.25, 1.5, 6` |
| 18 | `Lounge_east_a` | `0.4, 3, 4.5` | `-7, 1.5, -3.75` |
| 19 | `Lounge_east_b` | `0.4, 3, 4.5` | `-7, 1.5, 3.75` |
| 20 | `Lounge_west` | `0.4, 3, 12` | `-19, 1.5, 0` |
| 21 | `Dining Room_south_a` | `4.5, 3, 0.4` | `-3.75, 1.5, 6` |
| 22 | `Dining Room_south_b` | `4.5, 3, 0.4` | `3.75, 1.5, 6` |
| 23 | `Dining Room_east_a` | `0.4, 3, 4.5` | `6, 1.5, -3.75` |
| 24 | `Dining Room_east_b` | `0.4, 3, 4.5` | `6, 1.5, 3.75` |
| 25 | `Study_south_a` | `4.5, 3, 0.4` | `9.25, 1.5, 6` |
| 26 | `Study_south_b` | `4.5, 3, 0.4` | `16.75, 1.5, 6` |
| 27 | `Study_east` | `0.4, 3, 12` | `19, 1.5, 0` |
| 28 | `Billiard Room_south` | `12, 3, 0.4` | `-13, 1.5, 19` |
| 29 | `Billiard Room_east_a` | `0.4, 3, 4.5` | `-7, 1.5, 9.25` |
| 30 | `Billiard Room_east_b` | `0.4, 3, 4.5` | `-7, 1.5, 16.75` |
| 31 | `Billiard Room_west` | `0.4, 3, 12` | `-19, 1.5, 13` |
| 32 | `Hall_south_a` | `4.5, 3, 0.4` | `-3.75, 1.5, 19` |
| 33 | `Hall_south_b` | `4.5, 3, 0.4` | `3.75, 1.5, 19` |
| 34 | `Hall_east_a` | `0.4, 3, 4.5` | `6, 1.5, 9.25` |
| 35 | `Hall_east_b` | `0.4, 3, 4.5` | `6, 1.5, 16.75` |
| 36 | `Library_south` | `12, 3, 0.4` | `13, 1.5, 19` |
| 37 | `Library_east` | `0.4, 3, 12` | `19, 1.5, 13` |
Y is `1.5` for every single wall. That's because the wall is 3 units tall and
the mesh is centred on its own origin, so 1.5 puts its bottom exactly on the
floor at Y = 0.

---

## Part 5: Place the 9 floors

Same process. Make one floor piece first:

1. Select `Rooms`, press **Ctrl+A**, create a `StaticBody3D`, name it `Floor`.
2. Add a `MeshInstance3D` child, give it a **New BoxMesh**, set Size to
   **`13, 0.2, 13`**.
3. Add a **New StandardMaterial3D** as Material Override (colour comes later,
   per room).
4. Add a `CollisionShape3D` child of the StaticBody3D, **New BoxShape3D**,
   Size **`13, 0.2, 13`**.
5. Right-click, **Save Branch as Scene**, as `Scenes/Pieces/Floor.tscn`.

Then drag in nine copies and set name, position, and colour:

| Node name | Position (X, Y, Z) | Albedo colour |
|---|---|---|
| `Kitchen_Floor` | `-13, -0.1, -13` | `#D9CC99` |
| `Ballroom_Floor` | `0, -0.1, -13` | `#BFA6D9` |
| `Conservatory_Floor` | `13, -0.1, -13` | `#A6D9B2` |
| `Lounge_Floor` | `-13, -0.1, 0` | `#CC998C` |
| `Dining Room_Floor` | `0, -0.1, 0` | `#D9B280` |
| `Study_Floor` | `13, -0.1, 0` | `#998CBF` |
| `Billiard Room_Floor` | `-13, -0.1, 13` | `#668073` |
| `Hall_Floor` | `0, -0.1, 13` | `#BFB8A6` |
| `Library_Floor` | `13, -0.1, 13` | `#8C7359` |
> **Why floors are 13 wide but rooms are 12:** the floor is sized to `PITCH`
> (the spacing between room centres), not `CELL` (the room's inside width). That
> makes neighbouring floors butt up exactly against each other, with no missing
> strip of floor under the doorway gaps. Don't "fix" this to 12, you'll get
> holes you can fall through.

> **Setting a per-instance colour:** because all nine floors are instances of
> the same scene, you need to give each one its own material or they'll all
> change together. With the floor's `MeshInstance3D` selected, click the
> Material Override dropdown and choose **Make Unique** before setting the
> colour. If Make Unique isn't offered, right-click the instance in the Scene
> dock and enable **Editable Children** first.

### The ground plane

There's one more box, a large safety net under everything so nothing falls
into the void:

| Node name | Size | Position | Colour |
|---|---|---|---|
| `Ground` | `60, 0.2, 60` | `0, -0.6, 0` | `#1A1A1F` |

---

## Part 6: The front door

The front door is special: it has a script on it, and interacting with it opens
the accusation panel. That's the only way to win the game.

1. Select `Rooms`, press **Ctrl+A**, create a `StaticBody3D`.
2. Rename it to exactly **`FrontDoor`**.
3. Set its **Transform > Position** to **`0, 0, 19`**.
4. Attach the script: with `FrontDoor` selected, look at the Inspector for the
   **Script** property near the bottom. Click the dropdown, choose **Load**,
   and pick `Scripts/Door.gd`.
5. Add a `MeshInstance3D` child:
   - **New BoxMesh**, Size **`2.4, 2.7, 0.2`**
   - **Transform > Position** `0, 1.35, 0`
   - Material Override, **New StandardMaterial3D**, Albedo colour **`5C331A`**
     (a dark wood brown)
6. Add a `CollisionShape3D` child of `FrontDoor`:
   - **New BoxShape3D**, Size **`2.4, 2.7, 0.2`**
   - **Transform > Position** `0, 1.35, 0`

> **Where those numbers come from:** the door is `DOOR_W - 0.6` wide (3.0 minus
> 0.6 = 2.4) and `WALL_H - 0.3` tall (3.0 minus 0.3 = 2.7), so it sits inside
> the doorway gap with a small frame of clearance all round. The Y offset of
> 1.35 is half its height, lifting it so the bottom sits on the floor.

---

## Part 7: The player

1. Select the **root** node of Main.tscn (not `Rooms`).
2. Press **Ctrl+A**, create a `CharacterBody3D`.
3. Rename it to exactly **`Player`**.
4. Set **Transform > Position** to **`0, 0.05, 11`**.
   That's the Hall's centre (0, 13) moved 2 units north, which is where the
   code spawns you.
5. Attach `Scripts/Player.gd` via the Script property.
6. Add a `CollisionShape3D` child:
   - **New CapsuleShape3D**
   - Height **`1.8`**, Radius **`0.4`**
   - **Transform > Position** `0, 0.9, 0`
7. Add a `Camera3D` child of `Player`:
   - It **must be named exactly `Camera3D`**
   - **Transform > Position** `0, 1.6, 0`
   - Tick the **Current** checkbox in the Inspector
8. Add a `RayCast3D` child **of the Camera3D** (not of the Player):
   - It **must be named exactly `InteractRay`**
   - **Target Position** `0, 0, -3.5`
   - Make sure **Enabled** is ticked

Final structure:

```
Player                    (CharacterBody3D, Player.gd)
 ├─ CollisionShape3D      (CapsuleShape3D, h 1.8, r 0.4, at y 0.9)
 └─ Camera3D              (at y 1.6, Current = on)
     └─ InteractRay       (RayCast3D, target 0, 0, -3.5)
```

> **The names are not decoration.** `Player.gd` looks up `$Camera3D` and
> `$Camera3D/InteractRay` the moment it enters the scene. Misspell either, or
> parent the ray to the Player instead of the Camera, and interaction silently
> stops working with no error message.

---

## Part 8: The suspects

**This is the one part you should not fully hand-place**, and it's worth
understanding why before you build it.

The player picks 2 to 8 suspects out of 12 on the selection screen, and where
each one stands is decided by the case generator at runtime. So you can't know
in advance who exists or where they go.

What you *can* do is design the suspect in the editor and let the code stamp
out copies. You get complete visual control, the game keeps its variety.

### Build the template

1. Go to **Scene > New Scene** in the top menu.
2. Click **Other Node**, search `CharacterBody3D`, create it.
3. Rename the root to `Suspect`.
4. Attach `Scripts/NPCCharacter.gd` to it.
5. Add a `MeshInstance3D` child:
   - **New CapsuleMesh**, Height **`1.8`**, Radius **`0.4`**
   - **Transform > Position** `0, 0.9, 0`
   - Material Override, **New StandardMaterial3D** (colour is set per suspect
     by code, so any colour will do here)
6. Add a `CollisionShape3D` child of the root:
   - **New CapsuleShape3D**, Height **`1.8`**, Radius **`0.4`**
   - **Transform > Position** `0, 0.9, 0`
7. Add a `Label3D` child of the root:
   - Name it exactly **`NameLabel`**
   - **Transform > Position** `0, 2.15, 0`
   - **Font Size** `36`
   - **Outline Size** `10`
   - **Billboard** set to **Enabled** (this makes the name always face you)
8. Save the scene as `Scenes/Pieces/Suspect.tscn`.

This is now the thing you edit whenever you want suspects to look different.
Swap the capsule for a model, add a hat, add a shadow, whatever. Every suspect
in every game picks it up automatically.

---

## Part 9: The code changes

Geometry in the editor is only half the job. `Main.gd` currently *creates* all
of this, so if you leave it alone you'll get two mansions stacked on top of
each other.

Here is everything that has to change, in order.

### 9a. Stop building the world, find it instead

Replace the body of `_build_world()` with:

```gdscript
func _build_world() -> void:
	rooms_node = $Rooms
```

Then move the lighting into the editor so you don't lose it:

- Select the root node, **Ctrl+A**, create a `WorldEnvironment`.
  Give it a **New Environment**, set Background Mode to **Color**, background
  colour to `0D0D14`, Ambient Light source to **Color**, ambient colour to
  `8C8794`, and ambient energy to `0.7`.
- Select the root node, **Ctrl+A**, create a `DirectionalLight3D`.
  Set **Transform > Rotation** to `-55, -30, 0`, **Light > Energy** to `1.1`,
  and tick **Shadow > Enabled**.

### 9b. Keep the room maths, drop the room building

This is the part people get wrong. `room_centers` and `grid_pos` are pure
arithmetic and are used everywhere: pathfinding, `_room_at()`, the Hall meetup
checks, the map panel, NPC travel. **You still need them filled in.**

Change `_build_mansion()` to:

```gdscript
func _build_mansion() -> void:
	for row in range(GRID.size()):
		for col in range(GRID[row].size()):
			var rname: String = GRID[row][col]
			room_centers[rname] = _room_center(row, col)
			grid_pos[rname] = Vector2i(row, col)
```

That's the same loop as before with the `_build_room()` call removed. You can
now delete `_build_room()`, `_build_wall_side()`, and `_build_front_door()`
entirely, along with `add_solid_box()` if nothing else uses it.

### 9c. Find the front door

Wherever `front_door_node` was assigned, use:

```gdscript
front_door_node = $Rooms/FrontDoor
```

### 9d. Find the player

Replace the whole of `_spawn_player()` with:

```gdscript
func _spawn_player() -> void:
	player = $Player
```

Delete the rest of the old function. The hierarchy you built in Part 7 already
satisfies `Player.gd`'s `@onready` lookups, because nodes placed in the editor
exist before `_ready()` runs.

### 9e. Stamp out suspects from your scene

In `_spawn_npcs()`, replace the block that builds the body by hand. Add this
near the top of the file with your other constants:

```gdscript
const SUSPECT_SCENE := preload("res://Scenes/Pieces/Suspect.tscn")
```

Then inside the loop, instead of creating the `CharacterBody3D`,
`MeshInstance3D`, `CollisionShape3D` and `Label3D`, do:

```gdscript
		var npc := SUSPECT_SCENE.instantiate()
		npc.name = "NPC_" + c["id"]
		rooms_node.add_child(npc)
		npc.character_id = c["id"]
		npc.current_room = start_room
		npc.position = Vector3(center.x + offset.x, 0, center.z + offset.z)
		npc_nodes[c["id"]] = npc

		# Per-suspect colour and name still come from code, because they
		# differ per character and the cast changes every game.
		var mesh := npc.get_node("MeshInstance3D") as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = NPC_COLORS.get(c["id"], Color.WHITE)
		mesh.material_override = mat
		npc.get_node("NameLabel").text = c["name"]
```

Keep the `occupancy` / `angle` / `offset` maths above it exactly as it is.
That's what stops two suspects spawning inside each other.

### 9f. Check the main controller group

`Door.gd` finds the game via
`get_tree().get_first_node_in_group("main_controller")`. Make sure the root
node of Main.tscn is still in that group: select the root, open the **Node**
dock (next to the Inspector), click the **Groups** tab, and confirm
`main_controller` is listed. Add it if not.

---

## Part 10: The shortcut

If placing 46 boxes by hand sounds like a bad evening, this gets you the same
result in about two minutes, and you still end up with real, editable,
hand-movable nodes in your scene.

1. Create a new script anywhere in the project called `BuildOnce.gd`.
2. Paste this in:

```gdscript
@tool
extends Node3D
# ONE-OFF: builds the mansion geometry as real editor nodes, then you delete
# this script and never run it again. Everything it makes is fully editable
# by hand afterwards - this is a starting point, not a dependency.
#
# HOW TO USE:
#   1. Add a Node3D to Main.tscn, name it "Rooms", attach this script.
#   2. In the Inspector, tick "Build Now".
#   3. Detach the script (Script property -> Clear).
#   4. Save the scene. Done.

const CELL := 12.0
const PITCH := 13.0
const WALL_H := 3.0
const WALL_T := 0.4
const DOOR_W := 3.0
const WALL_COLOR := Color(0.92, 0.9, 0.85)

const GRID := [
	["Kitchen", "Ballroom", "Conservatory"],
	["Lounge", "Dining Room", "Study"],
	["Billiard Room", "Hall", "Library"],
]

const ROOM_COLORS := {
	"Kitchen": Color(0.85, 0.8, 0.6), "Ballroom": Color(0.75, 0.65, 0.85),
	"Conservatory": Color(0.65, 0.85, 0.7), "Lounge": Color(0.8, 0.6, 0.55),
	"Study": Color(0.6, 0.55, 0.75), "Dining Room": Color(0.85, 0.7, 0.5),
	"Billiard Room": Color(0.4, 0.5, 0.45), "Library": Color(0.55, 0.45, 0.35),
	"Hall": Color(0.75, 0.72, 0.65),
}

@export var build_now: bool = false:
	set(v):
		if v and Engine.is_editor_hint():
			_build()

func _owner() -> Node:
	# Nodes must have an owner set or they will not be saved into the .tscn.
	return get_tree().edited_scene_root

func _box(bname: String, size: Vector3, pos: Vector3, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = bname
	add_child(body)
	body.owner = _owner()
	body.position = pos

	var mi := MeshInstance3D.new()
	# Name the children explicitly. Nodes added from code without a name get
	# an auto-generated one like "@MeshInstance3D@2", which is legal but
	# horrible to hand-edit afterwards - and the whole point of this script is
	# that you edit the result by hand.
	mi.name = "MeshInstance3D"
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mi.material_override = mat
	body.add_child(mi)
	mi.owner = _owner()

	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	body.add_child(cs)
	cs.owner = _owner()
	return body

func _has_neighbor(row: int, col: int, dir: String) -> bool:
	match dir:
		"north": return row - 1 >= 0
		"south": return row + 1 <= 2
		"west": return col - 1 >= 0
		_: return col + 1 <= 2

func _build() -> void:
	for child in get_children():
		child.free()

	_box("Ground", Vector3(60, 0.2, 60), Vector3(0, -0.6, 0), Color(0.1, 0.1, 0.12))

	var half := CELL / 2.0
	var seg := (CELL - DOOR_W) / 2.0
	var off := DOOR_W / 2.0 + seg / 2.0

	for row in range(GRID.size()):
		for col in range(GRID[row].size()):
			var rname: String = GRID[row][col]
			var cx := (col - 1) * PITCH
			var cz := (row - 1) * PITCH
			_box(rname + "_Floor", Vector3(PITCH, 0.2, PITCH),
				Vector3(cx, -0.1, cz), ROOM_COLORS[rname])

			var dirs: Array[String] = ["south", "east"]
			if not _has_neighbor(row, col, "north"):
				dirs.append("north")
			if not _has_neighbor(row, col, "west"):
				dirs.append("west")

			for dir in dirs:
				if dir == "north" or dir == "south":
					var hn := _has_neighbor(row, col, dir)
					var z: float = cz + (-half if dir == "north" else half)
					var front: bool = rname == "Hall" and dir == "south" and not hn
					if hn or front:
						_box("%s_%s_a" % [rname, dir], Vector3(seg, WALL_H, WALL_T),
							Vector3(cx - off, WALL_H / 2.0, z), WALL_COLOR)
						_box("%s_%s_b" % [rname, dir], Vector3(seg, WALL_H, WALL_T),
							Vector3(cx + off, WALL_H / 2.0, z), WALL_COLOR)
						if front:
							var d := _box("FrontDoor", Vector3(DOOR_W - 0.6, WALL_H - 0.3, 0.2),
								Vector3(cx, (WALL_H - 0.3) / 2.0, z), Color(0.36, 0.2, 0.1))
							d.set_script(load("res://Scripts/Door.gd"))
					else:
						_box("%s_%s" % [rname, dir], Vector3(CELL, WALL_H, WALL_T),
							Vector3(cx, WALL_H / 2.0, z), WALL_COLOR)
				else:
					var hn2 := _has_neighbor(row, col, dir)
					var x: float = cx + (-half if dir == "west" else half)
					if hn2:
						_box("%s_%s_a" % [rname, dir], Vector3(WALL_T, WALL_H, seg),
							Vector3(x, WALL_H / 2.0, cz - off), WALL_COLOR)
						_box("%s_%s_b" % [rname, dir], Vector3(WALL_T, WALL_H, seg),
							Vector3(x, WALL_H / 2.0, cz + off), WALL_COLOR)
					else:
						_box("%s_%s" % [rname, dir], Vector3(WALL_T, WALL_H, CELL),
							Vector3(x, WALL_H / 2.0, cz), WALL_COLOR)

	print("Built ", get_child_count(), " pieces. Detach this script and save the scene.")
```

3. Add a `Node3D` to Main.tscn named `Rooms`, attach `BuildOnce.gd` to it.
4. In the Inspector you'll see a **Build Now** checkbox. Tick it.
5. Everything appears in the Scene dock as real, selectable, editable nodes.
6. **Clear the Script property** on `Rooms` so the tool script is gone.
7. Save the scene.

You now have exactly what you asked for: hand-editable geometry in the editor.
Move a wall, retexture a floor, delete a room, whatever you like. Then do
Parts 6 to 9 (front door script, player, suspect scene, and the code changes).

> **One small difference from Part 6:** this script places the `FrontDoor`
> body itself at Y 1.35 with its mesh centred at the origin, whereas Part 6 has
> you place the body at Y 0 with the mesh offset up by 1.35. The door ends up in
> exactly the same place in the world and behaves identically, so don't
> "correct" one to match the other unless you want to.

> **The `owner` line is the trick.** Nodes created by a script are invisible to
> the scene file unless their `owner` is set to the edited scene root. Without
> those three `owner = _owner()` lines, everything looks right in the editor and
> then vanishes the moment you save and reload.

---

## Part 11: Testing checklist

Work down this list. Each item catches a specific, common failure.

| Check | What's wrong if it fails |
|---|---|
| Press **F5**. The mansion appears once, not twice | You didn't remove the code that builds geometry (Part 9a/9b) |
| You can walk around and don't fall through the floor | Missing floor collision, or floors sized 12 instead of 13 |
| You can't walk through any wall | A CollisionShape3D size doesn't match its mesh |
| You can walk through all 12 doorways | A doorway wall was placed as Solid instead of Segment |
| Suspects appear in their rooms with coloured capsules and names | `Suspect.tscn` path wrong, or node names inside it don't match Part 9e |
| Walking into a suspect shows an interact prompt | `InteractRay` is parented to Player instead of Camera3D |
| Walking to the front door shows "Open the front door…" | `Door.gd` not attached, or root not in the `main_controller` group |
| Typing "go to the library" makes a suspect walk there | `room_centers` isn't being filled (Part 9b) |
| Press **Tab**, the map panel shows the right rooms | Same as above, `grid_pos` isn't being filled |

---

## Quick reference

**Godot shortcuts you'll use constantly**

| Key | Does |
|---|---|
| `Ctrl+A` | Add child node to whatever is selected |
| `Ctrl+D` | Duplicate the selected node |
| `Ctrl+S` | Save scene |
| `F` | Focus the 3D camera on the selected node |
| `F5` | Run the main scene |
| `F6` | Run the currently open scene |

**The five mistakes that cost the most time**

1. Mesh size and collision size not matching. Looks fine, behaves wrong.
2. Nesting nodes under extra parents, so positions become relative and
   everything lands in the wrong place. Keep walls flat under `Rooms`.
3. Renaming `Camera3D`, `InteractRay`, or `Rooms`. The scripts look these up
   by exact name and fail silently.
4. Using a Solid wall where a Segment belongs, sealing a doorway. The game
   still runs, suspects just can never reach that room.
5. Forgetting `owner` in a tool script, so everything disappears on reload.
