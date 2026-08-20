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

## Animation

`NPCCharacter.gd` plays a `Walk` clip while a suspect is moving and an `Idle`
clip while they're standing, if the model has them. Name matching ignores case
and any `Armature|` prefix, and also accepts `Walk_A`, `Walking`, `Run`,
`Idle_A`, `Stand`.

The Quaternius base characters ship with **no animations**, so for now they'll
stand in rest pose and slide. That's expected and nothing is broken. When you
want them moving properly, grab the
[Universal Animation Library](https://store.godotengine.org/asset/quaternius/universal-animation-library/)
(CC0, same author, same rig) and merge the clips onto the model in Blender.

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
