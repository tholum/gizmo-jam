# Bumper Cars

Six cars share a floating dock with an open edge. Steer with WASD, the arrow
keys, a gamepad stick or D-pad, or the left touch zone. Space, A, or a tap on
the right touch zone boosts in the steering direction. Boost recharges in
3.6 seconds. Cars carry momentum and transfer it on contact, so passing
close to the edge is risky even after letting go of the controls.

The outermost ring flashes amber for four seconds before sinking. Any car
still on that ring falls into the water.

| Seconds from GO | Playable radius | Event |
| ---: | ---: | --- |
| 0 | 14.0 | All five removable rings are in play |
| 22 | 11.7 | First ring sinks |
| 42 | 9.4 | Second ring sinks |
| 60 | 7.1 | Third ring sinks |
| 76 | 4.9 | Fourth ring sinks |
| 89 | 2.9 | Only the centre remains |
| 102 | 2.9 | Time limit |

The last car afloat wins immediately. At the time limit, the surviving car
with the most knockouts wins. Equal survivors share the win. If all remaining
cars fall together, the cars that went out last draw. The host simulates
movement and collisions and sends the same round state to every guest. Bots
fill open seats and look ahead to brake for the edge and move inward before
a ring sinks.

## Build and play locally

```sh
python3 tools/build.py --pack bumper_cars --dev-install
```

Launch Gizmo Jam, turn on Developer mode, and select **Bumper Cars**. Pick
**Play Solo** to face bots or **Host a Party** to play with friends. Developer
packs follow the download and consent flow in the [game pack guide](making-a-game.md).

## Assets

The pack includes a Meshy bumper-car model with seat-colour materials. The
original preview and refine tasks are recorded in the [Meshy task ledger](../tools/meshy_tasks.json).
The game copy uses 1K embedded textures. ElevenLabs generated the announcer,
impact, boost, ring warning, ring drop, and splash audio. The dock and water
are rendered in Godot.
