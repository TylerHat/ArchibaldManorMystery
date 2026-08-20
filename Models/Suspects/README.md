# Suspect models

Each suspect has a folder here, named after their id in `GameManager.CHARACTERS`.
Put one model file in a folder and that suspect starts using it. Leave a folder
empty and that suspect stays the colored capsule they've always been.

You can do this one suspect at a time. The game runs fine with eleven capsules
and one model.

## How to add a model

1. Find the suspect's folder below. Each one has a `_WHO.txt` telling you who
   lives there and which file from your Quaternius pack I'd suggest.
2. Copy the `.blend` file into that folder. Just drop it in — the filename
   doesn't matter.
3. Switch to the Godot editor and let it finish importing (it shells out to
   Blender, so the first one takes a few seconds).
4. Run the game.

That's it. No code to edit, no scene to wire up.

**Accepted formats:** `.blend`, `.glb`, `.gltf`, `.fbx`. `.obj` and `.dae` will
load but have no skeleton, so they can never animate.

**One model per folder.** If you put two in, the alphabetically first one wins.

**`.blend` needs Blender installed** and pointed at in Godot's editor settings,
which you already have set up. If you'd rather not depend on that, open the
`.blend` in Blender and export a `.glb` into the folder instead.

## Who goes where

| Folder | Suspect | Job | Suggested model |
|---|---|---|---|
| `blackwood/` | Dr. Evelyn Blackwood | Forensic Pathologist | `Doctor_Female_Young.blend` |
| `sterling/` | Marcus Sterling | Investment Banker | `Suit_Male.blend` |
| `ashford/` | Victoria Ashford | Art Dealer | `Suit_Female.blend` |
| `carter/` | Samuel "Sam" Carter | Private Investigator | `Casual3_Male.blend` |
| `whitmore/` | Eleanor Whitmore | Political Consultant | `OldClassy_Female.blend` |
| `reeves/` | Thomas "Tom" Reeves | Estate Manager | `Casual_Male.blend` |
| `cross_natalie/` | Natalie Cross | Investigative Journalist | `Casual2_Female.blend` |
| `cross_eugene/` | Eugene Cross | Butler | `OldClassy_Male.blend` |
| `moreau/` | Emma Moreau | Ghostwriter | `Casual_Female.blend` |
| `varga/` | Count Lucian Varga | "Gentleman of Independent Means" | `Wizard.blend` |
| `pike/` | Desmond "Giggles" Pike | Children's Entertainer | `Casual_Bald.blend` |
| `thorne/` | Agnes Thorne | Head Gardener | `Worker_Female.blend` |

These are suggestions, not requirements — swap freely. Two notes on the awkward
ones: the pack has no clown, so Desmond is going to need a costume built in
Blender or a recolor, and `Wizard.blend` is the closest thing to a theatrical
cape the pack offers for the Count.

## Sizing and facing

Models are automatically rescaled to 1.8m and stood on the floor, so they line
up with their collision capsule and fit through the manor's doorways whatever
scale they were authored at.

If something looks wrong, everything adjustable lives in `suspect_models.cfg`
next to this file:

| Problem | Fix |
|---|---|
| Everyone faces backwards / moonwalks | Set `rot_y=180.0` in `[default]` |
| Feet sink into or float above the floor | Nudge `y_offset` |
| One suspect is comically large or small | Give them their own section with a `scale` |
| You already sized it correctly in Blender | Set `auto_fit_height=false` |

Changes to that file take effect on the next run — no reimport needed.

## Colors and textures

**These models have no textures, and cannot have any.** The meshes carry no UV
layer at all, so there is nothing for a texture to map onto. All colour comes
from flat materials - `Skin`, `Face`, `Hair` and a few clothing ones. That flat
look is the art style, not a broken import.

The `Texture.png` reference inside each .blend is a dead end: it points at
`//<non-breaking-space>/Blender/DavidThorn/Library/Large/Texture.png`, a path
from the original artist's machine, and no material actually uses it. Tracking
down that PNG will not give you textured characters.

### Recolouring

Every character in the pack ships with `Skin` set to `#1f1f1f`, so out of the
box their heads and hands are black silhouettes. `suspect_models.cfg` fixes
that per suspect, and doubles as a way to tell them apart:

```
[thorne]
color_skin="#c98c62"
color_hair="#6b4a2a"
```

Any key `color_<material>` retints the material of that name, matched
case-insensitively. An unknown name is ignored, so a stray key can't break a
model, and a material you don't name keeps the colour the artist gave it.

Material names differ per model - only these exist to be recoloured:

| Model | Materials |
|---|---|
| `Casual_*`, `Casual2_*`, `Casual3_*` | Skin, Shirt, Pants, Belt, Face, Hair |
| `Suit_Male`, `Suit_Female` | Skin, Black, Belt, Shirt, Details, Face, Hair |
| `OldClassy_Male`, `OldClassy_Female` | Skin, Pants, Shirt, Detail, Belt, Face, Hat, Hair |
| `Doctor_Female_Young` | Skin, Main, Black, Brown, Face, Hair |
| `Wizard` | Skin, Clothes, Belt, Gold, Hat, Face, Hair |
| `Worker_Female` | Skin, Shirt, Vest, Pants, Face, Hair |

Two things worth knowing. `Face` is the eye whites, not the face - leave it
alone. And `Skin` covers hands and bare legs as well as the head, so you can't
give someone a white greasepaint face without whitening the rest of them.

Colours are applied per instance via `set_surface_override_material()`, so two
suspects sharing the same .blend get their own palettes with no bleed between
them. Changes take effect on the next run - no reimport.

## Animation

`NPCCharacter.gd` plays a `Walk` clip while a suspect is moving and an `Idle`
clip while they're standing. Name matching ignores case and any `Armature|`
prefix, and also accepts `Walk_A`, `Walking`, `Run`, `Idle_A`, `Stand`.

Your pack ships **17 clips on every character**, so this works with no setup:

```
Death  Defeat  Idle  Jump  PickUp  Punch  RecieveHit  Roll  Run
Run_Carry  Shoot_OneHanded  SitDown  StandUp  SwordSlash  Victory
Walk  Walk_Carry
```

`Idle` and `Walk` are matched automatically. The others are there if you want
them later — `SitDown`/`StandUp` for suspects in the lounge, `Victory` or
`Defeat` for the accusation resolution.

## How it actually works

- `Scripts/SuspectModel.gd` — looks in a suspect's folder, loads whatever it
  finds, applies the config, falls back to the capsule.
- `Scripts/Main.gd` → `_spawn_npcs()` — calls `SuspectModel.build_visual()`
  instead of building a capsule inline. The collision capsule and the floating
  name label are untouched.
- `Scripts/NPCCharacter.gd` — drives idle/walk off the body's actual speed.

The per-suspect colors in `Main.NPC_COLORS` are still used for the dialogue UI
and the notes tabs. They only tint the body while a suspect is still a capsule.

## Exporting

`suspect_models.cfg` is a plain text file, not an imported resource. If you
ever export a build, make sure `*.cfg` is included in the export filters or the
tuning values will silently fall back to their defaults.
