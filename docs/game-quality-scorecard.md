# Gizmo Jam game quality scorecard

Use this for Gizmo Jam party play, with Spin Cycle as the comparison round. Score multiplayer rounds at normal settings and viewing sizes. Use one-player sessions to isolate controls, scoring, and balance issues.

| Category | Weight | What to record |
| --- | ---: | --- |
| Fun and replay | 25 | Voluntary rematches, excitement and frustration, something to improve on the next round, and whether players who fall behind still have meaningful choices. Record engagement and time spent waiting after an early exit. |
| Controllability | 20 | How easily players start, stop, turn, recover, and trigger their main action. Count missed and unwanted inputs. Check keyboard, D-pad and stick, and two-thumb touch. Time button-to-visible-response on local and guest setups when possible. |
| Graphics | 15 | Cohesive art and lighting, clear silhouettes, contrast and legible HUD. Ask players to point to their character and the next obstacle or target at normal phone size and from the couch, including during crowded play. |
| Animation and smoothness | 15 | Readable windup, impact, recovery, and transitions. Check that motion and sound reinforce hits, scoring, and action readiness. Watch for snapping, stutter, jitter, and disruptive flashes during busy moments. Compare local and guest captures and record frame times on representative hardware. |
| Clarity and accessibility | 15 | Whether a first-timer can tell you how to win in about 10 seconds and complete their first deliberate action. Check whether warnings, player identity, scoring, and results are understandable with sound muted and without relying on color alone. |
| Technical reliability | 10 | Start, finish, rematch, and reconnect. Verify correct scoring and player counts, independent inputs, no stuck inputs after focus loss, and matching host and guest results. |

Use whole-number ratings. Multiply each rating by its weight and divide by five.

| Rating | Anchor |
| ---: | --- |
| 0 | Unusable or broken in a supported case. |
| 1 | Severe, recurring problems interfere with play. |
| 2 | Playable with frequent friction or coaching. |
| 3 | Consistently usable in an ordinary round. |
| 4 | Holds up in crowded moments and across the tested setups. |
| 5 | Consistently excellent across tested age groups, devices, and lineups. Cite the evidence. |

Use **—** for missing evidence and report **points earned / weight tested**. Fun and replay require people playing. Screenshots support graphics judgments, clips support motion judgments, and automated tests establish behavior under their test conditions. Use **80/100** as a starting polish target, with **at least 3/5** for controls and clarity. Treat repeatable blocking input, scoring, visibility, or round completion failures as priorities regardless of the total.

## Run a comparison

1. Recruit children, teens, adults, and older adults with varied gaming experience. Give each person two rounds per assigned game and rotate game order. Use Spin Cycle on the same device and settings. Let players use the game's own instructions in the first round, then note any coaching they need.
2. Record time to explain the goal, time to first deliberate action, visible mistakes, and what each person says caused their score or loss. Offer an optional third round and record the choice privately. Report replay choices as counts by age group and input method, including which issues recur within a group.
3. Check **2 humans**, **3 humans**, **4 humans**, and **6 humans** with no bots, plus **2 humans + 2 bots** and **4 humans + 1 bot**. Prioritize hands-on sessions with three humans and zero bots, and two humans and two bots. Check whether each player has a fair chance to score and stays involved as the group size changes. Record the lineup for every result.
4. Compare a full round and the busiest 10 seconds on desktop, a physical phone, and a supported low-end device. Record device, settings, render scale, p95/p99 frame time, and the count of frames over twice the device's frame budget. Use about 16.7 ms for a 60 Hz desktop target and 33.3 ms for a 30 Hz Low target. Review the same seeded event and lineup before and after each fix.
5. Save one line per issue or measured outcome. Fix repeatable blockers and mixed-age control or clarity problems first. Repeat the same scenario after the change.

| Game and build | Category and rating | Device, input, lineup | Age group and experience | Observation, count, or capture | Next fix |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

### Capture frame timing

Run the probe with a display and the device's normal graphics driver. Point `--packs-dir` at an isolated test profile with candidate PCKs in `dev-games`. The probe advances a fixed-seed six-seat bot round and writes screenshots and frame timing to `test-output/iterations/<iteration>/`.

```sh
godot --path . --audio-driver Dummy --disable-vsync --resolution 1280x720 --script tests/graphics_probe.gd -- \
  --game=orb_racing --iteration=orb-before --size=1280x720 --level=low \
  --start-at=12 --packs-dir=/path/to/test-profile --dev-mode --no-update-check
```

For Spin Cycle use `--game=twisted`. Use the same driver, resolution, graphics setting, and starting point for before and after captures. Rate motion from gameplay footage as well as timing. Software rendering and simulated touch can reproduce layout findings, while device performance and touch comfort need physical hardware.

## First polish passes to evaluate

| Game | What to compare before and after |
| --- | --- |
| Spin Cycle | Whether a player can still see the next rod during the hit flash. |
| Live Wire | Whether the surge outline and score remain visible over bright territory and simultaneous callouts. |
| Bumper Cars | Whether players can track their car and recognize the unsafe ring using an edge pattern. |
| Sumo | Whether a player can pick out their fighter and the shove windup in a pile. |
| Orb Racing | Whether the brighter local ring and larger race number help players pick out their orb on the grid. |
| Stampede Sheriff | Whether sheriff and critter silhouettes remain distinct in a herd, and a player can tell which critters a clap moved. |
| Plate Panic | Whether the local player tag helps players match their robot to their numbered pocket. Check marble contrast and wedge aim next. |
| Salvage Line | Whether players can follow their tug and tow rope, then distinguish which ropes can be cut. |
