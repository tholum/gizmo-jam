# Making a game

Every minigame after Spin Cycle and Live Wire is a **game pack**: everything
under `games/<id>/`, built into one `.pck` file that the game loads at run
time. `games/example/` (Pulse, a small rhythm game) is a complete, working
pack to copy.

## 1. Start from the example

```sh
cp -r games/example games/sumo
```

Then in `games/sumo/`:

- `game.json`: set `id` to the folder name (lowercase letters, digits and
  underscores, at most 24), and set `version`, `info` (the menu card) and
  `actions`. Remove `"publish": false`.
- `module.gd`: change `ID` and `INFO` to match, and the `preload` paths to
  `res://games/sumo/...`.

`game.json` fields:

| Field | Meaning |
|---|---|
| `id` | Wire id. Never changes once published. |
| `version` | Semver. Raise it for every publish. |
| `net` | Players can play together only with the same `net`. Raise it when a new version cannot play online with the old one (a changed snapshot, new actions, different rules). |
| `core_min` | The lowest Gizmo Jam build (`application/config/build`) the game runs on. Players on older builds see *Needs update*. |
| `actions` | Input names `Session.send_input()` accepts for this game, at most 16. |
| `input_budget` | Input messages per player per second the host accepts; the rest are dropped. |
| `info` | `number`, `title`, `tags`, `blurb` for the card, and an optional `voice` cue id. |

## 2. The three parts

- **Model** (`model.gd`): the whole simulation. Only the host runs `step()`;
  guests rebuild it from `snapshot()` twenty times a second. Keep snapshots
  well under 1 KB compressed, and take all randomness from the seeded `rng`.
  The required members are listed at the top of `games/example/model.gd`.
- **Arena** (`arena.gd`): the 3D scene. Create it when the module is staged
  and free it when it is not, so a large library costs nothing until played.
  Put its `Environment` on its own camera. Required members are listed at the
  top of `games/example/arena.gd`.
- **Module** (`module.gd`): the glue main.gd calls: HUD, keys, rules, results.
  The full surface is documented at the top of `scripts/game_spin_cycle.gd`.

Rules for pack code:

- Only files inside `res://games/<id>/` go in the pack. You may `preload` core
  scripts (`scripts/ui_kit.gd`, the `hud_*` parts, `runner_visual.gd`), but
  nothing from another pack. The core interface only ever grows, so code that
  runs on `core_min` keeps running on later builds.
- No `class_name`: global class names come from a project-wide cache that a
  pack cannot change. Use `preload` paths.
- Packs cannot be unloaded. A new version of a game already loaded takes
  effect the next time Gizmo Jam starts.

## 3. Try it

```sh
python3 tools/build.py --pack sumo --dev-install
```

This builds `builds/packs/sumo-<version>.pck`, checks it the way the game will,
and copies it to the `dev-games` folder in the game's data folder. Turn on
**Developer mode** (bottom-right of the menu) and the game appears with an
UNTRUSTED badge. Play it solo, or host a party: friends in developer mode are
asked whether to accept it and then get it from your computer. After a
rebuild, restart Gizmo Jam to load the new pack; friends are asked again,
since it is a different file.

When running from the editor or `godot --path .`, the source files in
`games/` are used directly once the pack is loaded, so edits show up after a
restart without rebuilding. The core's file checks only run fully in an
exported build.

## 4. Publish

```sh
python3 tools/release_games.py --game sumo            # dry run
python3 tools/release_games.py --game sumo --publish
```

See *Releases → Game packs* in the README. Before publishing, play an online
round between the newest and the previous published build of the game.
