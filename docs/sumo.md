# Sumo

Six robots compete on a fixed, raised ring for 90 seconds. A ring-out earns one
point for the last opponent to land a shove in the preceding two seconds.
Self-falls with no recent opponent shove award no point. Robots return near
the center after 1.4 seconds with brief protection. The highest score wins,
and an equal top score is a draw.

Steer with WASD, arrow keys, a stick, a D-pad, or a left-thumb drag. Release
movement to plant your feet and resist shoves. Space, pad A, or a right tap
throws a directional palm shove after a visible windup. It takes 1.4 seconds
to recharge. During the spawn shield, a robot can move but cannot give or
receive a shove.

The host resolves all shoves on the same tick before moving fighters and
awarding points. The arena shows shove windups, braced fighters, ring-outs,
and protected respawns. The score plates show points and shove readiness.

Run the rules test from the repository root with Godot 4.5.1.

```sh
godot --headless --path . --script res://games/sumo/tests/rules_test.gd
python3 tools/build.py --pack sumo
```
