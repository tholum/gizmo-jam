# Orb Racing

Six ghosting orbs start abreast on a rounded circuit with a north chicane. Steer in screen directions with WASD, arrows, a stick, a D-pad, or a left-thumb drag. Space, pad A, or a right tap spends one boost charge. A second press during a boost extends it. Each orb starts with one charge and can carry two. Gold charge strips alternate sides and can refill each orb once per lap.

Cross the start line to begin the first lap. Six numbered route gates follow it, then the start line counts the lap. A crossing counts when the center of the orb sweeps forward through the marked road width. The simulation runs at 60 Hz and records the fraction of the step at which the third lap ends. Finishers rank by that time. Unfinished orbs rank by completed laps and centerline distance clamped between the last cleared gate and the next required gate. The race clock stops 12 seconds after the first finisher or 100 seconds after GO, whichever comes first.

The track geometry in `track.gd` supplies timing lines, charge strips, the starting grid, the grass shoulder and rail limits to both the model and the arena. The arena uses one fixed orthographic camera and batches static track art into a single mesh. The core supplies the touch and local-controller routing as well as countdown, boost, pickup, lap and results sounds.

## Local verification

From the repository root, point `godot` to a Godot 4.5.1 binary.

```sh
godot=/path/to/Godot_v4.5.1-stable_linux.x86_64
"$godot" --headless --path . --editor --import --quit
"$godot" --headless --path . --script res://games/orb_racing/tests/race_test.gd
python3 tools/build.py --godot "$godot" --pack orb_racing
```

Use a temporary core project without game source to smoke-test the built pack.

```sh
smoke=$(mktemp -d)
cp -a project.godot scripts scenes assets "$smoke/"
"$godot" --headless --path "$smoke" --editor --import --quit
"$godot" --headless --fixed-fps 60 --path "$smoke" \
  --script "$PWD/games/orb_racing/tests/pack_smoke.gd" -- \
  "--pack=$PWD/builds/packs/orb_racing-1.0.0.pck" --no-update-check
"$godot" --headless --fixed-fps 60 --path "$smoke" \
  --script "$PWD/games/orb_racing/tests/pack_smoke.gd" -- \
  "--pack=$PWD/builds/packs/orb_racing-1.0.0.pck" --no-update-check --handheld --safe-inset=32
```

The race test exercises timing-line width and order, the finish window and hard cap, boost and rails, a full race using eight-way input, and seeded bot races with compressed snapshot round trips. The pack smoke test mounts the PCK via the core Pack Manager, then exercises solo start, keyboard and independent pads or handheld touches, and the race results. To capture the rendered grid, race and results, run the smoke script with a display and pass `--capture-dir=/path/to/existing/directory` after `--`.
