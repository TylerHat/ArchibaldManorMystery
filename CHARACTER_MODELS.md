# Giving the suspects real bodies

Everything is wired up already. Once you apply the small `Main.gd` patch in
Part 6, adding a character model is one step:

> **Drop a `.glb` file into `res://Models/Suspects/` named after the character
> id. Press Play.**

That is the whole workflow. The ids are:

```
blackwood      sterling       ashford        carter
whitmore       reeves         cross_natalie  cross_eugene
moreau         varga          pike           thorne
```

So `Models/Suspects/varga.glb` becomes Count Lucian Varga. Any suspect without
a file keeps their coloured capsule, so you can add all twelve one at a time
and the game never breaks in between.

### What it handles for you

You do not have to get the model "right" before dropping it in.

- **Size.** Models arrive at absurdly different scales. Every one is measured
  and rescaled to 1.8m, the same height as the player.
- **Feet on the floor.** Lots of models are centred on the hips, so they sink
  into or hover above the ground. The model is shifted so the bottom of it
  rests on y = 0.
- **Animation names.** Mixamo calls its clip `mixamo.com`, Quaternius calls it
  `CharacterArmature|Walk`, someone else calls it `idle_01`. The code looks for
  keywords rather than exact names, so all of them work. If a model has only
  one animation, that one gets used.
- **Looping.** Downloaded clips often arrive set to play once and then freeze
  on the last frame, which looks like the character died mid-step. Both clips
  are forced to loop.
- **Foot speed.** The walk clip is time-scaled to the character's actual
  movement speed, so they do not skate.

The one thing you may have to set by hand is **facing**, covered in Part 7.

---

## Part 1: Where to get models

### My actual recommendation

You need **twelve characters who look like they belong to the same cast.** That
matters more than any individual model looking good. Twelve models from twelve
different artists will look like a bug, not a manor party.

So:

1. **Quaternius modular packs for eleven of them.** One art style, mix and match
   parts for variety.
2. **Mixamo for animations**, applied to all of them.
3. **Sketchfab only for the two you cannot fake**, probably the clown and maybe
   the vampire, and only if the modular kit really cannot get there.

Do the whole cast in capsule-replacements first at low effort, see them standing
in a room together, then upgrade. A consistent cast of simple models beats a
mixed bag of nice ones.

### The sites, ranked for this project

**[Quaternius](https://quaternius.com/) — start here. Free, CC0.**

CC0 means public domain: no attribution, no strings, commercial use fine. Every
pack ships **FBX, OBJ, .blend and glTF**, and glTF is exactly what you want.
Rigged and animated already.

Look at **Ultimate Modular Men Pack** and **Ultimate Modular Women Pack** first.
Modular means separate heads, hair, torsos and legs you can recombine, which is
how you get twelve distinct people in one consistent style. **Animated Men /
Women Pack** and **Universal Base Characters** are the non-modular equivalents.
The **RPG Character Pack** is 6 rigged, animated, textured characters if you
want something to test with in the next five minutes.

**[Kenney](https://kenney.nl/assets/blocky-characters) — free, CC0, very cheap.**

[Blocky Characters](https://kenney.nl/assets/blocky-characters) (18 characters)
and [Mini Characters](https://kenney.nl/assets/mini-characters) are chunky and
stylised, close to Clue board game pieces, which honestly suits a comedic
mystery. Also modular. Lowest polygon count of anything here, which matters for
you specifically (see Part 8).

**[Mixamo](https://www.mixamo.com/) — free with an Adobe ID. The animation
source, not really the model source.**

Confirmed still running and still free; no Creative Cloud subscription needed,
and downloads are royalty free for commercial use. Two things it does:

- **Auto-rigger.** Upload any humanoid model that has no skeleton and it adds
  one. Bipedal humanoids only, and it wants a neutral pose, a clean mesh, and no
  floating parts or props. This is how you rescue a good-looking static model.
- **Animation library.** Thousands of motion-capture clips. Idle, walking,
  talking gestures, looking around, arms crossed. This is where your suspects
  get personality.

**[Sketchfab](https://sketchfab.com/) — huge, use with care.**

Filter to **Downloadable** and set the licence filter to CC0 or CC-BY. Every
model has its own licence, so check each one, and CC-BY means you owe the artist
a credit line. Polygon counts vary wildly. Use it for the specific things a
modular kit cannot make, like an actual circus clown.

**[itch.io](https://itch.io/game-assets/free/tag-3d) — grab bag.** Lots of small
free and cheap character packs, quality varies, licences vary.

### One caution about AI model generators

Tools like Meshy and Tripo will happily generate "a Victorian butler" in a
minute. The meshes are usually not rigged, often have messy topology, and animate
badly. If you try one, plan on running it through the Mixamo auto-rigger, and
expect a fight.

---

## Part 2: Your first model, the fast way

Fifteen minutes, no Blender.

1. Go to **[Quaternius RPG Character Pack](https://quaternius.com/packs/rpgcharacters.html)**.
2. Download it. Unzip it.
3. Open the **glTF** folder. You want the `.glb` files.
4. In Windows Explorer, open your project's `Models` folder and make a new
   folder inside it called `Suspects`.
5. Copy one `.glb` in and rename it to a character id, exactly. For example
   `blackwood.glb`. Lowercase, no spaces.
6. Alt-tab to Godot. It picks up the new file on its own after a second.
7. Press Play, start a game with Lord Blackwood in the cast, and go find him.

If he is standing there, animated, facing you, you are done and every other
character is the same five steps.

---

## Part 3: Mixamo, for animations and for rigging

Use this once you have bodies and want them to actually behave.

### Getting animations onto a model

1. Go to **[mixamo.com](https://www.mixamo.com/)** and sign in with a free
   Adobe ID.
2. Click **Upload Character** and give it your `.glb` or `.fbx`.
3. If it has no skeleton, Mixamo walks you through the auto-rigger: you click
   on the chin, wrists, elbows, knees and groin, and it builds the skeleton.
4. Once rigged, browse the animation list on the left. Search **idle**, pick one
   you like, then search **walking** and pick one.
5. For each: click **Download**, and set
   - Format: **FBX Binary (.fbx)**
   - Skin: **With Skin** for the first one, **Without Skin** for the rest
   - Frames per Second: 30
   - Keyframe Reduction: none

### The catch, and how to deal with it

Mixamo gives you one animation per download, each as its own file. Godot needs
them in one file per character. Two options:

**Easy option:** download only the **idle** animation with skin, and use that
one file. Your suspects will stand and breathe convincingly and slide when they
walk. Honestly, for a game where suspects mostly stand in rooms being
interrogated, this is a completely defensible place to stop.

**Proper option:** combine them in Blender. Part 5.

---

## Part 4: Blender, and your Godot setup

You mentioned Blender is attached to your Godot 4.7. That means Godot can import
`.blend` files directly, and you can skip exporting entirely: save the `.blend`
into `Models/Suspects/` and Godot converts it on import.

To confirm it is set up: **Editor Settings > FileSystem > Import > Blender**, and
check **Blender Path** points at your Blender install folder.

**My advice: use `.glb` anyway, most of the time.** Direct `.blend` import is
convenient while you are actively editing a character, but `.glb` is more
predictable, imports faster, and is what every tutorial assumes. Use `.blend`
while iterating and export a `.glb` when you are happy.

(If you do use `.blend`, note the loader tries `.glb`, `.gltf`, `.tscn` and
`.fbx` in that order. To use a `.blend`, add a `file` override in
`SuspectModels.OVERRIDES`, e.g. `"varga": {"file": "varga.blend"}`.)

---

## Part 5: Combining Mixamo animations in Blender

Only needed if you want proper walk cycles. Skip on a first pass.

1. Open Blender. Delete the default cube: click it, press **X**, confirm.
2. **File > Import > FBX**, choose your **with skin** download (the idle one).
3. **File > Import > FBX** again, choose the **without skin** walk download.
   You now have two skeletons stacked on each other. That is expected.
4. At the bottom of the screen, change one editor to the **Nonlinear Animation**
   view. You will see the animation strips.
5. Click your main character's armature in the scene list on the right.
6. In the Nonlinear Animation panel, click **Push Down** next to each action to
   turn it into a strip.
7. **Double click each strip's name and rename it.** Call them exactly `Idle`
   and `Walk`. This is the step people skip and then wonder why nothing works.
8. Delete the second, now-empty armature.
9. Select both the mesh and the armature, press **Ctrl+A**, choose **All
   Transforms**. This bakes in any leftover scale or rotation.
10. **File > Export > glTF 2.0 (.glb)**. In the panel on the right:
    - Format: **glTF Binary (.glb)**
    - Under **Include**, tick **Selected Objects**
    - Under **Animation**, tick **Animations**, and tick **Export NLA strips**
11. Save it as `<character_id>.glb` into `Models/Suspects/`.

**The single most common cause of a mangled character in Godot is skipping step
9.** Leftover scale or rotation on the armature is what makes limbs stretch and
twist on import.

---

## Part 6: The `Main.gd` patch

Two edits.

### 1. Create the folder

Make `Models/Suspects/` inside your project. Godot ignores empty folders, so
either put your first `.glb` in straight away or drop a blank `.gitkeep` in it,
the way `Models/` already has one.

### 2. Swap the capsule for the model loader

In `_spawn_npcs()`, find this block:

```gdscript
		var mesh := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.height = 1.8
		cap.radius = 0.4
		mesh.mesh = cap
		mesh.position.y = 0.9
		var mat := StandardMaterial3D.new()
		mat.albedo_color = NPC_COLORS.get(c["id"], Color.WHITE)
		mesh.material_override = mat
		npc.add_child(mesh)
```

Replace all of it with these two lines:

```gdscript
		# Loads Models/Suspects/<id>.glb if it exists, otherwise builds the
		# original coloured capsule. See CHARACTER_MODELS.md.
		SuspectModels.build_visual(npc, c["id"], NPC_COLORS.get(c["id"], Color.WHITE))
		npc.bind_model()
```

Leave the `CollisionShape3D` and the `Label3D` below it exactly as they are. The
collision capsule stays a capsule on purpose: it is invisible, it is what the
movement and separation code is tuned against, and swapping it for a
mesh-shaped collider would make suspects snag on doorframes.

Then copy `SuspectModels.gd` and the updated `NPCCharacter.gd` into `Scripts/`.

### Check it worked

Press Play before adding any model at all. You should see the exact same
coloured capsules as before. That confirms the fallback path is healthy, which
is the thing you want working when you are halfway through adding twelve models.

---

## Part 7: When something looks wrong

| What you see | Why | Fix |
|---|---|---|
| Suspect slides backwards while facing you | The model faces the opposite way to what Godot expects | In `SuspectModels.OVERRIDES`, add `"varga": {"yaw": 0.0}`. If that is worse, try `90.0` or `-90.0` |
| Suspect faces sideways while walking | Same thing, quarter turn | Try `"yaw": 90.0`, then `-90.0` |
| Still a capsule | Filename does not match the id, or the extension is wrong | Check spelling exactly, lowercase, `.glb`. `cross_natalie.glb`, not `Natalie.glb` |
| Standing perfectly still, no breathing | No animations in the file, or none matched | Check Godot's Output panel; the code prints which animations it found. Add `"idle": "<exact name>"` to the override |
| Frozen in a T-pose with arms out | The only animation is the rest pose | Get an idle from Mixamo |
| Feet sunk into the floor or floating | Auto-fit could not measure the model | Add `"y_offset": 0.15` to the override and adjust |
| Limbs stretched or twisted | Transforms not applied before export | Blender, Part 5 step 9 |
| Way too big or small | Auto-fit failed, usually no mesh found | Check Output for the warning; make sure you exported the mesh, not just the armature |
| One character noticeably shorter | Their model's proportions differ, so head-height fitting reads oddly | `"scale": 1.05` in the override |
| Name label floating oddly | Model is much wider than the capsule | Fine to ignore, or adjust `label.position.y` in `_spawn_npcs()` |
| Godot hangs on import | Very high polygon model from Sketchfab | Decimate it in Blender, or pick a different model |

Everything in the override table goes in one place, near the top of
`SuspectModels.gd`:

```gdscript
const OVERRIDES := {
	"varga": {"scale": 1.08, "yaw": 0.0},
	"pike":  {"idle": "CharacterArmature|Idle"},
}
```

---

## Part 8: Keep an eye on the polygon budget

This matters more for you than for most people. Your 6GB RTX 4050 is holding
llama3.2 in VRAM at the same time as rendering the manor, so the graphics budget
is whatever Ollama is not using, roughly 3GB.

Rough guidance:

- **Under 10,000 triangles per character** is comfortable. Quaternius and Kenney
  models are far below this.
- **Sketchfab models are often 50,000 to 200,000 triangles each.** Eight of those
  on screen will cost you.
- **Textures matter more than triangles for VRAM.** A 4096x4096 texture is 64x
  the memory of a 512x512 one. Most stylised characters look identical at 1024.
  You can force this per file in Godot: click the texture in the FileSystem
  dock, open the **Import** tab, and set a size limit.
- Only up to 8 suspects are ever in the house at once, so budget for 8, not 12.

If you notice dialogue getting slower after adding models, that is the two
workloads fighting over VRAM, and shrinking textures is the first thing to try.

---

## Sources

- [Mixamo FAQ, Adobe](https://helpx.adobe.com/creative-cloud/faq/mixamo-faq.html)
- [Quaternius](https://quaternius.com/)
- [Quaternius RPG Character Pack](https://quaternius.com/packs/rpgcharacters.html)
- [Kenney, Blocky Characters](https://kenney.nl/assets/blocky-characters)
- [Kenney, Mini Characters](https://kenney.nl/assets/mini-characters)
- [Blender to Godot animated character export workflow](https://supermatrix.studio/blog/best-workflow-for-exporting-animated-characters-from-blender-to-godot)
