# Original Meshy assets

Generated for Gizmo Jam on 2026-11-17 with the local Meshy account. The game
ships no credentials and makes no requests at runtime.

| Asset | Use | Meshy pipeline | Size in game |
| --- | --- | --- | --- |
| `runner.glb` | The robot runner: all six seats, the menu line-up and the podium | text-to-image concept (`gpt-image-2`, A-pose) → image-to-3D (Meshy 7.1, remeshed to 14,000 triangles, 2K PBR textures) → auto-rig (24-bone biped) → nine library animations | 14,520 triangles and 12,801 vertices on High; 5,676 triangles on Balanced; 2,143 on Low; 1.9 MB |
| `runner_runner_albedo.png` | Neutral base colour, extracted from the GLB on import | derived from Meshy's 2K base colour | 1024×1024 |
| `runner_runner_mask.png` | R: body shell that takes the team colour. G: glowing eyes and antenna tip. B: glossy face glass | derived from the base colour and the mesh | 1024×1024 |

The arena itself (core, ramp, rods, railings, backdrop) is not Meshy output; it
is built in code by `scripts/arena.gd` from the pieces in `scripts/arena_kit.gd`.

## How the robot is used

- **One model, six colours.** The robot was generated with a pure red body on
  dark grey joints, so the body can be keyed out. `tools/runner_textures.py`
  replaces the red with its brightness and writes the mask; the runner shader
  (`RUNNER_SHADER` in `scripts/arena_kit.gd`) multiplies the masked area by the
  seat colour. That colour is `Arena.team_color()`, the same value the HUD
  plates use.
- **Rigid shell.** Meshy's automatic skin weights bend the head and torso like
  rubber. `tools/build_runner.py` re-binds the shell parts (head, torso, hands,
  boots) to one bone each and leaves smooth weights only on the dark joints.
- **Clips.** `idle`, `jog`, `run`, `jump`, `duck`, `hit`, `hit_low`, `victory`
  and `knockdown`, re-baked at 30 fps from Meshy's library actions Idle_02,
  Run_02, RunFast, Jump_Over_Obstacle_2, slide_right, Hit_Reaction,
  Hit_Reaction_to_Waist, Cheer_with_Both_Hands_Up and Knock_Down. Travel is
  removed (the robots run in place on a moving belt), the slide is held as a
  loop and snapped to the floor, and the jump clip keeps only its pose: the game
  adds the jump arc from the simulation's jump clock and seeks the clip by
  normalised jump time, so the picture stays in step with collision online.
- **Balanced mesh.** At load, `scripts/runner_visual.gd` builds a lighter mesh
  with the engine's simplifier, which only drops vertices and never blends UVs.
  An edge-collapse decimation in Blender smeared the texture across Meshy's
  fragmented UV atlas, so it is not used.
- **Low mesh.** The same simplifier with a 60° normal merge angle offers a step
  at 2,143 triangles that keeps the head a clean box; at the default 25° the
  step below Balanced (2,838) dents it. Low's podium robot uses Balanced's mesh.

## Rebuilding

Sources are kept under `tools/meshy-source/robot/` (excluded from exports and
from Godot's importer): the two animation downloads, which also carry the mesh
and rig, and the 2K base colour.

```sh
python3 -I tools/runner_textures.py
blender --background --python-exit-code 1 --python tools/build_runner.py
godot --headless --path . --import
```

`tools/runner_textures.py` needs numpy, Pillow and scipy. To inspect the result,
`tools/art-probe/blender_sheet.py` renders a contact sheet of every clip, and
`tools/art-probe/closeup.gd` and `hero.gd` render staged close-ups in the game.

## Meshy tasks and credits

`tools/meshy_art.py` is the task ledger: it records every task under a name in
`tools/meshy_tasks.json` (`art_pass`) before anything else happens, refuses to
POST a name twice, and reads the key from `~/.config/meshy/api_key` at call
time. Prompts, payloads and task IDs are all in that file.

| Task | Endpoint | Credits | Outcome |
| --- | --- | --- | --- |
| `concept_robot_a` | text-to-image | 9 | Used: the robot concept |
| `robot_model` | image-to-3D | 30 | Used |
| `robot_rig` | rigging | 5 | Used |
| `robot_anims_core` | animation, 10 actions | 30 | Used: 7 of the 10 clips |
| `robot_anims_extra` | animation, 4 actions | 12 | Used: 2 of the 4 clips |
| `concept_robot_b` | text-to-image | 9 | Rejected: thin limbs, no joints to key |
| `concept_a`, `concept_b` | text-to-image | 18 | Superseded: helmeted runner, dropped on an art-direction change |
| `runner_model`, `runner_rig` | image-to-3D, rigging | 35 | Superseded, as above |
| `runner_anims_core`, `runner_anims_extra` | animation | 42 | Superseded, as above |
| `concept_pylon` | text-to-image | 9 | Unused: no pylon prop was built |
| **Total** | | **199** | |

The earlier `runner_helmet` and `reactor_pylon` assets (2026-11-16) were removed
with the capsule runners they belonged to; their task records remain at the top
of `tools/meshy_tasks.json`.
