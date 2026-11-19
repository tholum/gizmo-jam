# Gizmo Jam

A Godot desktop party game for up to six players, in the spirit of early-2000s
console party minigames, with two playable minigames for six robot runners.
All models, environments, UI, and sounds are original.

- **01 Spin Cycle** — reaction and survival. Six robot runners stand side by
  side on one wide spiral ramp around a reactor tower, jumping over low orange
  rods and ducking under high violet rods as they sweep round. The ramp
  accelerates; the seventh hit eliminates you. The last survivor wins.
- **02 Live Wire** — territory and chaos. Six runners paint a 169-tile hex
  reactor floor for 90 seconds; whoever owns the most tiles at the buzzer wins.
  Running over a tile makes it yours. Closing a loop captures everything inside
  it and locks those tiles for about ten seconds. Red surge lines charge across
  the floor and then fire: anyone still standing on one is stunned and loses
  their largest patch. A dash on a short cooldown gets you out of trouble and
  shoves whoever is in the way. The last 20 seconds are overdrive: more surges,
  and nothing locks.

## Play

Native builds are in `builds/`:

- Windows x64: `windows/GizmoJam.exe` or `GizmoJam-windows.zip`.
- Linux x64: `linux/GizmoJam.x86_64` or `GizmoJam-linux.zip`.
- macOS Intel and Apple Silicon: `macos/GizmoJam.zip`, containing a universal app.

Windows and Linux builds include the game data in the executable. No Godot
installation is needed to play. Linux may need `chmod +x GizmoJam.x86_64`
after extraction. The macOS development build is ad-hoc signed and unnotarized;
macOS may require local approval before it will open. Public
distribution should use Developer ID signing and notarization on a Mac.

Choose a game by clicking its card on the main menu; the selected card is
outlined in lime, the arena behind the menu changes to match, and the choice is
remembered. Each card has a **How to Play** button. **Play Solo** plays the
selected game against five bots, and **Host Party** opens a lobby on it. Sumo
and Orb Racing are shown as coming soon. Menus also work from the keyboard: the
main action is focused, so **Enter** or **Space** confirms it.

Keyboard only. In every game **Esc** opens the menu, **Tab** (held) shows
names, and **F11** toggles fullscreen.

- **Spin Cycle:** **Space / Up** to jump; **hold S / Down** to duck. Jump
  temporarily overrides a held duck; holding duck resumes it after landing.
- **Live Wire:** **W A S D** or the **arrow keys** to run (hold two for a
  diagonal); **Space** to dash in the direction you are running. A direction
  held during the countdown counts from GO. Opening the menu, losing window
  focus or the end of the round lets go of everything.

### Spin Cycle HUD

During a round the HUD floats directly on the arena, with no panels. The
top-centre plate calls the next obstacle: an orange plate led by an up-pointing
wedge means **JUMP**, a violet plate led by a down-pointing wedge means **DUCK**.
Its chip counts down to impact and flips to **NOW!** when you need to act, and
the fuse bar under it fills as the rod closes in. Each runner has a plate along
the bottom in their own colour: a seven-block coil gauge that burns down one
block per hit (the number in its hub is the hits left), a large score, and a
name banner tagged **YOU**, **CPU** or **P2**–**P6**. Eliminated runners turn
grey and are stamped **OUT**. The top-left shows the round clock, the speed
multiplier and a stack of six bars, in seat order, comparing every runner's
score with the leader's. Press **Esc** for the menu, and hold **Tab** for names.

### Live Wire HUD

The same kit, laid out around the board so that no tile is ever covered.

- **Top-left:** the time remaining (it turns red and kicks every second for the
  last ten), a chip with the surge level (**Surge ×1 / ×2 / ×3**) in the stage
  colour, the stage name (warm-up, charged, overdrive · no locks) and the six
  standings bars, each as long as that runner's share of the leader's tiles.
- **Top-centre:** the surge call-out. It is empty until a line starts charging,
  then a gold **SURGE** plate drops in, led by a hex tile with a bolt, with the
  seconds until it fires and a fuse that fills. If *you* are standing on that
  line the plate turns red, grows, pulses and says **MOVE!**, and a thin hazard
  frame pulses around the screen until you step off. During the countdown the
  same slot shows the controls.
- **Feedback** pops just under the call-out, above the first row of tiles:
  **ZAPPED! −12 TILES** (with a screen rattle and the hazard frame),
  **LOOP! +9 LOCKED**, **DIRECT HIT!** when your dash shoves someone,
  **SHOVED!** when you are the one sent flying, and the stage changes.
- **Bottom:** six plates in seat order. The big number is the tiles that runner
  owns right now. The hex ring beside it is their dash: six blocks refill
  during the cooldown and the hub lights up with the dash chevrons when it is
  ready — on your own plate that is your dash, on the others it tells you who
  can shove you. A zapped runner's ring goes red under a **ZAP** stamp for as
  long as they are stunned. The leader carries a gold **1ST** tab and a
  gold-rimmed banner.

The round ends with **TIME’S UP!** over the frozen board, then the results:
winner or draw, and a table of tiles, peak tiles, loops closed, zaps taken and
shoves landed, on top of the finished floor. Behind the menu and the lobby, six
bots play an endless exhibition match on it.

## Updates

The game's version (for example **v0.2.0**) is shown small in the bottom-right
corner of the menu, lobby and results screens. Builds before v0.2.0 (the
2026-11-17 downloads, counted as 0.1.0) have no updater: replace them by hand
from <https://timholum.com/games/gizmo-jam/>.

From v0.2.0 on, the game checks for a new version once each time it starts, in
the background with a short timeout. Offline, or if anything goes wrong, it
shows nothing. **Check for updates: On/Off**, next to the version on the menu,
turns the check off; the setting is saved.

When a new version exists, a card in the top-right corner of the menu says
**Update available: v0.3.0**. **Notes** shows the release notes, **Later** hides
the card until the next launch, and **Update now** downloads the new build with
a progress bar, checks its size and SHA-256 against the signed manifest,
installs it next to the current one and restarts into it. The card never
appears during a round. In an online lobby or on online results it moves to the
bottom-right and installing is disabled until you leave the party, since
installing restarts the game. A download that finishes during a round waits as
**Ready to install** until you are back on the menu.

If anything fails, the card says what happened and offers the **Download page**.
In-place updates need a game folder you can write to: on Linux the folder that
holds `GizmoJam.x86_64`, on Windows the folder with `GizmoJam.exe`, and on macOS
the folder holding `Gizmo Jam.app` (for example Applications). macOS also
refuses to update an app it is running from a quarantined download location;
move the app to Applications first. A game run from source in the editor only
reports updates.

**Recovery.** The previous version is kept beside the new one
(`GizmoJam.x86_64.old`, `GizmoJam.exe.old`, or a hidden `.Gizmo Jam.app.old`)
until the new version reaches its menu, and is then deleted. If the new version
closes before reaching its menu, the old one puts itself back and says so. If
the new version never reached its menu (for example it crashed and you started
it again), it restores the previous version on that next start and launches it.
If even that fails, the previous version is still in the `.old` file or folder
and can be run directly.

## Graphics

The runners are six boxy toy robots, one per seat, each in the same saturated
colour as its HUD plate. They are one original Meshy-generated model, rigged
and animated: they jog, break into a sprint as the belt speeds up, leap the low
rollers, slide under the high ones, stagger when hit, and are bowled off down
the belt when their last coil goes. The winner cheers on a podium. In Live Wire
the same robots run flat out across the floor, lean into a dash, stagger when
shoved and reel on the spot, flashing white, when a surge catches them.

Spin Cycle's arena is a bright teal reactor shaft built in code from chunky flat-shaded
pieces: a glowing coolant core in a grey frame, a panelled conveyor deck with
painted chevrons that travel with the belt, light strips, yellow safety rails
and layered gantries fading into haze. Each rod is a striped roller on an arm:
a collar rides a rail on the core, a carriage rides the outer kerb. **Orange
rollers are low (jump), violet rollers are high (duck)**; nothing else in the
scene uses those two colours. Every runner has a ring in its colour on the deck
and a shadow that stays on the deck when it jumps. A lime bar across the deck
marks the line where the rollers meet the runners.

Live Wire's arena is a raised grey hex deck in the same teal reactor hall: cyan
light strips and orange safety rails round the rim, an emitter socket at both
ends of every line, reactor cores and gantries fading into haze. Tiles light up
in their owner's colour, locked tiles rise with a bright frame, a charging
surge is a hazard-striped cable between two emitters and a firing one is a fat
bolt. The hall swings to coral in overdrive.

**Graphics** has three levels, picked with the **Low / Balanced / High** keys at
the foot of the menu. All three use the same gameplay, collision timing and
network simulation.

- **High** adds 4× antialiasing, the full-detail robot mesh, a true silhouette
  shadow under every runner, drifting motes and a soft glow round the core (on
  Live Wire: antialiasing and the full-detail mesh; its tiles are unlit light
  panels).
- **Balanced** uses a lighter robot mesh (about 5,700 triangles) and soft blob
  shadows.
- **Low** is for old or weak GPUs, the Raspberry Pi and software rendering. On
  a GPU it keeps High's scenery, lighting and atmosphere: the full structure,
  all three gantry rings, the motes and glow veil, all three lights and the fog,
  High's full-detail robots over blob shadows, the deck's full pattern and the
  shade bands behind the HUD. The light and fog on the scenery are worked out
  ahead of time (per vertex, with the renderer's own formulas) instead of per
  pixel, and the deck's pattern is read from a texture made at start-up. What
  it gives up against High is MSAA, the silhouette shadows, a faint specular
  sheen and resolution: the 3D is drawn at 67% of the window's resolution and
  stretched up, while the HUD and menus stay at full resolution. That 3D
  resolution then follows the frame rate: it steps down when the game cannot
  hold 30 fps (never below 50%) and up when there is room (up to full); each
  round starts at 67%. On a software rasteriser Low is lighter still: the light
  robot mesh (about 2,100 triangles; the podium robot keeps Balanced's), a
  lighter cut of Spin Cycle's ramp and reactor frame, one ring of plain
  gantries, only the key light and no motes or veil. Rods keep their orange and
  violet, runners keep their team colours, and the jump, duck and hit poses are
  the same clips on the same clock on every level.

A new installation picks **High** on a hardware GPU and **Low** on a software
renderer (an adapter named llvmpipe, softpipe, SwiftShader, lavapipe or similar)
or a Raspberry Pi GPU (V3D or VC4).
The choice is saved as `graphics/level` in `user://settings.cfg`. A settings file
from an older build has only `graphics/detailed`, which is read as High (true) or
Balanced (false); new builds still write it for older builds to read.

Measured with the graphics probe at 1280x720 on Mesa llvmpipe under Xvfb, in a
full six-runner round (frames per second, ranges over interleaved runs; this
host had 24 cores and a load average of about 9–18):

| Round | llvmpipe threads | Low | Balanced | High |
| --- | --- | --- | --- | --- |
| Spin Cycle | all | 65 | 46–48 | 19 |
| Spin Cycle | 2 (a weak CPU) | 42 | 26 | 8 |
| Live Wire | all | 75–78 | 73–75 | 41 |
| Live Wire | 2 (a weak CPU) | 45–49 | 41 | 19 |

Low's 95th-percentile frame in Spin Cycle on two threads is 28 ms, against 44
ms on Balanced. Live Wire's room is already baked, unlit geometry, so Low gains
less there. The two-thread rows come from `LP_NUM_THREADS=2`, which stands in
for an old or heavily loaded machine.

On a Raspberry Pi 4 B (Mesa V3D, OpenGL ES 3.1; fan-cooled, no throttling),
fullscreen at 1280x720, Low runs Spin Cycle at about 34 fps with its 3D at
67-71% and Live Wire at about 48 fps at 87%; High manages 7 and 20 fps. Run the
Pi's output at 720p and let the TV scale it. A 30-second trace of either game
has no frame over twice the median once the countdown is over. What it took,
measured with `tests/perf_diag.gd` and `tests/quality_cost.gd` (A/B costs of
parts of a running round, and of each of High's features),
`tests/spike_trace.gd` (slow frames and what appeared in them),
`tests/low_bake_compare.gd` and `tests/low_vs_high.gd` (the looks):

- With the 3D in a SubViewport (`scripts/scaled_view.gd`), the root viewport
  draws only 2D, so outside tests it draws straight into the window instead of
  into a render target that is then copied to the screen: ~8 ms a frame on the
  Pi. (Tests read the screen back, so they keep it off.) The root viewport's own
  scaled 3D also cost ~9 ms there even for an empty scene.
- On V3D any lit material costs ~4 ms and the engine fog ~4.6 ms, so Low bakes
  High's three lights and its fog into unshaded scenery shaders (`BAKED_LIGHT`
  in `scripts/arena_kit.gd`). The Compatibility renderer treats ALBEDO as sRGB
  for every material, so the baked shaders convert with its own functions.
- The HUD's shapes are batched (`Kit.Batch`): a player plate is 7 draw calls
  instead of ~60, on every level.
- Both games draw everything that would compile a shader or rasterise glyphs on
  first use during the countdown (rods, bursts, trails, sparks, effect rings,
  3D and HUD call-outs, identity tags): each of those first appearances cost
  75-150 ms on the Pi.

The levers that made no measurable difference on llvmpipe (a cheaper deck
shader, vertex lighting, unshaded robots, fewer particles, hiding the sky dome)
are not used. Frame timings are machine-specific; more evidence is under
`test-output/iterations/` (`art-pass-*`). Meshy generation and asset-build helpers are
development-only and excluded from exports; `assets/meshy/README.md` records
asset provenance, budgets and the build steps.

## Screens and windows

The game fits windows from 1024x576 up to 2560x1440 and beyond, at shapes from
4:3 to 21:9, windowed or fullscreen, with no black bars. Every screen lays
itself out against the visible area and follows the window when it is resized,
mid-round included. The menus keep a column on the left and slide the arena into
the space beside it; on short windows they switch to a compact rhythm. The
round HUD keeps its corners, centres its call-outs, and lines the six player
plates up along the bottom: on a narrow window they shrink together so none
overlaps another, on a very wide one they stay centred.

Scale rule: the UI is drawn at min(width / 1440, height / 900) of its design
size, clamped to between 0.85 and 1.5. The lower bound keeps 14 px text at about
12 px on a 1024-pixel-wide window; the upper bound stops it ballooning on a
2560x1440 screen. The 3D cameras keep the 16:10 design's horizontal view on
narrower screens, so the line of runners and Live Wire's board never lose their
ends, and Live Wire's camera also widens on short screens to keep the whole
board between the HUD bands.

On first launch the window is sized to fit the screen's usable area (taskbars
and docks excluded) and centred: 1280x800 where it fits, smaller where it does
not, never below 1024x576. **F11** toggles fullscreen.

## Audio

An original announcer calls the countdown, speed-ups, knockouts, the final two
and the winner. Sound effects cover jumping, ducking, clears, hits, knockouts,
rod warnings, menus and victory. Live Wire adds the announcer lines "Live
Wire!", "Surge incoming!", "Zapped!", "Locked in!", "Ten seconds!" and "Time's
up!", and effects for the dash, a shove, the zap, the tile tick, the loop
lock-in, and a surge charging and firing. The repeating ones are rate-limited:
the tile tick plays at most about seven times a second, lines that charge or
fire together make one sound, and "Surge incoming!" is kept for the first surge
of a round and for lines that start under your own feet. All voice lines and
effects were generated with ElevenLabs and ship as `.ogg` files in
`assets/audio/`. **Sound: On/Off** in the menu mutes everything. To regenerate or add lines, edit the manifest in
`tools/generate_audio.py` and run it with `ELEVENLABS_API_KEY` set (`--force`
regenerates, `--reprocess` rebuilds from the cached downloads).

## Network play: one server, up to six people

1. The server person picks a game, enters a name and clicks **Host Party**. The
   dialog asks for the UDP port (default **7777**), then **Open Lobby**. Permit
   the game through the host computer's firewall (see **Firewall** below). The
   lobby says **Visible on your network** while nearby players can find the
   party.
2. Other players on the same network click **Join Party** and pick the party
   from the list. Each entry shows the host's name, players **n/6**, and
   whether the party is in the lobby or mid-round. Click it, or press
   **Enter** on it, to join. The lobby accepts players without host approval.
   Parties mid-round, full, or from a different game version are listed but
   cannot be joined until that changes. If the party is not listed (internet,
   VPN, or a network that blocks broadcast), type the join address from the
   host's lobby and the same port into the fields under the list, then
   **Connect**.
3. The lobby's **Next Game** panel shows which game is up. The party host can
   switch it there between rounds; everyone's lobby follows, arena included.
4. The party host clicks **Start for Everyone**. All connected players enter
   the same round automatically. Open seats become bots.
5. After the round, the party host can replay or return everyone to the lobby.
   Additional players can join between rounds. A disconnected player's runner
   becomes a bot for the rest of the round.

For LAN play the list is all you need. The lobby also shows the server's LAN
IP, with a copy button, for typing in by hand.
For internet play, use its public IP and forward the selected **UDP** port to
the server computer. A routable VPN can also connect friends. There is no
matchmaking, relay service, automatic NAT traversal, or invitation account
system. Networks behind carrier-grade NAT may need a VPN or a reachable server.
All players should use the same build. The server runs the only simulation of
either game and sends its state twenty times a second; clients draw from that
and submit nothing but their own inputs, which the server files under the
sender's own seat. Spin Cycle sends jump and duck. Live Wire sends a press
and a release for each held direction and a press for the dash; a game's
inputs are dropped while the other game is being played.

### LAN discovery

While a party is hosted, in the lobby and during rounds, the server sends a
small UDP beacon about once a second to discovery port **7778**: to
255.255.255.255 and to each network interface's subnet broadcast address, so a
computer on Wi-Fi and Ethernet at once, or with a VPN, reaches every LAN it is
on. The beacon carries only the host's display name, the game port, players
connected and the six-seat maximum, whether a round is running, the game name,
the game's network protocol version, and a random number chosen each time a
party opens. Nothing else about the computer or player is sent. Beacons stop
as soon as the party closes, the host leaves, or the game quits. The Join Party
dialog listens only while it is open, and ignores anything that is not exactly
a Gizmo Jam beacon. An entry disappears about 3.5 seconds after its beacon
stops. If another program on the same computer already uses port 7778 (often a
second copy of the game), the dialog says so and the address fields still
work.

### Firewall

- **Host computer:** allow the game to receive on the **UDP game port** (7777
  by default), as before, and to send UDP broadcast to port **7778**. Outbound
  traffic is normally allowed already.
- **Joining computers:** allow the game to receive **UDP port 7778** on the
  local/private network, or the party list stays empty. Windows usually asks the first
  time you open Join Party; choose **Private networks**. Joining by address
  does not need this.
- Discovery works within one network segment. Routers do not forward
  broadcast, and many guest Wi-Fi networks block traffic between devices; use
  the address fields there.

## Switch Host

The **party host** controls starting games, replaying, and returning the party
to the lobby. This role is separate from the computer running the network server.

- In the lobby, results, or **Esc → Party Controls**, click **Vote Host** beside
  the person who should take over. The proposer automatically votes yes.
- A strict majority of the **other players**, excluding the incumbent host,
  transfers control. With six humans this takes three votes; with two humans,
  the other person can take over. Bots do not vote. Each person gets one vote.
- The current host can hand over voluntarily using **Pass Host**.
- Votes expire after 25 seconds. If a remote party host disconnects, leadership
  passes to a remaining player automatically.

**The original server computer must remain running.** Voting transfers party
controls; it does not migrate the ENet server or its IP address. If that computer
closes the game or loses its connection, players return to the menu and must
host/join a new session. Online rounds continue while a party menu is open.

## Development

Open `project.godot` in **Godot 4.5.1 standard** (no .NET dependencies), then F6/F5
or run `godot --path .`. The compatibility renderer targets desktop OpenGL 3.3.
No external libraries or generation services are required to play. The original
Meshy-generated robot runner is bundled with the game.

Install the matching standard export templates through Godot's export-template
manager. Presets for all three desktops are in `export_presets.cfg`.

```sh
python3 tools/build.py --godot /path/to/godot
python3 tests/run_tests.py --godot /path/to/godot
```

The tests cover Spin Cycle's collision timing, scoring, seven-hit
elimination, rankings, snapshots, bot takeover, vote thresholds and vote
identity, and Live Wire's rules (`tests/test_livewire.gd`: claiming, loops and
locks, surges, dash and shove, overdrive, the packed snapshot, bots). They then
launch **six real Godot processes** (`tests/network_peer.gd`) for three rounds:
Live Wire on the real model, where every seat must move only the way its own
peer steers and the two dashes must land on their own seats; Spin Cycle
under a newly elected host; and Live Wire again, where one client disconnects
mid-round and its seat must become a bot on every remaining peer. Along the way
they check registration, game choice by the leader only, majority host
transfer, lobby return and relaunch. Last, `tests/run_online.py` plays one
online Live Wire round between **three copies of the real game**, driven
through its buttons and key events: the host switches games in the lobby, a
client's keys move its own runner and nobody else's in both the server's model
and its own snapshot copy, a player who leaves is replaced by a bot, and
everyone reaches the results and the lobby. `run_tests.py` runs it as its
last stage; on its own, and with screenshots of what the joining player sees
(`test-output/online-*.png`):

```sh
python3 tests/run_online.py --godot /path/to/godot
xvfb-run -a python3 tests/run_online.py --godot /path/to/godot --shots
```

LAN discovery is checked too: the beacon format and its strict validation
(malformed, oversized and hostile packets), soft failure when the discovery
port is taken, and expiry. Then **two real game processes** run, where one
hosts a party and the other finds it in the Join Party list, presses Enter on
the entry and checks the joined roster. That run sends beacons to 127.0.0.1 on
ports chosen by the test, with junk packets sprayed at the listener throughout,
so it is deterministic. A second run uses real broadcast and reports, rather
than fails, if the environment blocks it.

To verify the UI and render screenshots on Linux:

```sh
xvfb-run -a godot --path . --audio-driver Dummy --script tests/smoke_ui.gd
```

Additional presentation regressions check obstacle identity across menu/replay,
held duck at GO, client visual response, the robot's rig, clips and team tints,
what each quality level switches on (Low, Balanced and High), how old settings
files map to a level, the scale rule, and celebration cleanup:

```sh
.tools/Godot_v4.5.1-stable_linux.x86_64 --headless --path . --script tests/test_presentation.gd
xvfb-run -a .tools/Godot_v4.5.1-stable_linux.x86_64 --path . --audio-driver Dummy --disable-vsync --script tests/graphics_probe.gd -- --iteration=current
```

The graphics probe takes `--level=low|balanced|high` (or `--high`),
`--size=WxH` and `--game=twisted|livewire`. To measure at 1280x720, give Xvfb
and Godot the same size:

```sh
xvfb-run -a -s "-screen 0 1280x720x24" .tools/Godot_v4.5.1-stable_linux.x86_64 --path . --audio-driver Dummy --disable-vsync --resolution 1280x720 --script tests/graphics_probe.gd -- --iteration=low --level=low --size=1280x720
```

`tests/screen_sizes.gd` lays every screen of both games out at 1024x576,
1024x768, 1280x720, 1366x768, 1440x900, 1920x1080, 2560x1080 and 2560x1440,
resizing the window live between them, and checks that buttons and fields are
on screen and apart, dialogs fit, label text is at least 11 px, the HUD plates,
call-out, status and menu key do not collide, Spin Cycle's runners, action line
and incoming rod are in view above the plates, Live Wire's whole board is in
view and under no HUD widget, and the menus' runners or board stay clear of the
column. `run_tests.py` runs it headless (geometry only). With screenshots, in
`test-output/sizes/<W>x<H>/`:

```sh
xvfb-run -a -s "-screen 0 2560x1440x24" .tools/Godot_v4.5.1-stable_linux.x86_64 --path . --audio-driver Dummy --script tests/screen_sizes.gd -- --capture
```

Automated full matches use production key events: two Spin Cycle rounds,
a max-speed drill, and a 90-second solo Live Wire round in which an autopilot
runs, paints and dashes with W A S D and Space until the buzzer:

```sh
.tools/Godot_v4.5.1-stable_linux.x86_64 --path . --fixed-fps 60 --script tests/playthrough.gd
.tools/Godot_v4.5.1-stable_linux.x86_64 --path . --fixed-fps 60 --script tests/playthrough.gd -- --only=livewire
python3 tests/run_latency.py
```

The latency test routes two real ENet peers through a private delay/loss proxy;
it does not change host network configuration. Full-match automation is not a
human feel test. Hold **Tab** during play to inspect all runner names.

The graphics probe records frame timings and staged action/result screenshots.
Xvfb generally uses software rendering; use an accelerated display for GPU data.

The HUD widgets can be checked pixel for pixel after a change to how they
draw: `tests/hud_batch_shots.gd` renders every plate, status, cue and slam
state at 1280x720 and 1920x1080 and prints draw calls per widget;
`tests/hud_batch_compare.py` diffs two runs.

```sh
xvfb-run -a .tools/Godot_v4.5.1-stable_linux.x86_64 --path . --audio-driver Dummy --script tests/hud_batch_shots.gd -- --out=/tmp/hud_before
# ...change the drawing code, then shoot again to /tmp/hud_after...
python3 tests/hud_batch_compare.py /tmp/hud_before /tmp/hud_after --crops /tmp/hud_crops
```

The updater has unit tests in `tests/test_update.gd` (run by `run_tests.py`,
including manifests signed by `tools/release.py` with a throwaway key) and
these slower checks:

```sh
# The update card in every state, rendered on the real menu and lobby (test-output/update-*.png).
xvfb-run -a .tools/Godot_v4.5.1-stable_linux.x86_64 --path . --audio-driver Dummy --script tests/update_ui_shots.gd
# Linux end to end with real exports (~35 s): builds A (project version) and B (+1),
# serves B from a private 127.0.0.1 http.server and checks success, tampered
# manifest, bad hash, bad size, read-only folder, failed start, second-start restore.
python3 tests/update_e2e.py --godot .tools/Godot_v4.5.1-stable_linux.x86_64
# The Windows code path under Wine (headless, throwaway WINEPREFIX).
python3 tests/update_wine.py --godot .tools/Godot_v4.5.1-stable_linux.x86_64
# Real HTTPS against Wasabi using throwaway objects under games/gizmo-jam/updates/test/,
# deleted afterwards. Needs the publisher credentials; run update_e2e.py first.
python3 tests/update_wasabi.py
```

The end-to-end scripts sign their manifests with the release key, on a `test`
channel that the shipped game never accepts on its own. They temporarily bump
`project.godot` to build B and restore it afterwards. The test-only game
arguments are `--update-manifest=<url>` (another manifest URL; signatures are
still required, and plain `http://` is allowed only with it),
`--update-channel=<name>`, `--update-autoclick` (the card presses its own
**Update now** button) and `--no-update-check`.

The UI smoke test sends a keyboard event and follows menu → host → lobby →
round → party menu → results → lobby → menu. Images go to `test-output/`. The
Join dialog is captured searching (`join-dialog`), with parties listed
(`join-dialog-parties`), and with the discovery port taken (`join-dialog-busy`). It
also captures the HUD states a calm frame never shows (`countdown-slam`,
`countdown`, `clear`, `hit`, `eliminated`, `late`) and the solo winner screen
(`results-solo`). It then does the same for Live Wire: picking it on the menu
and in the lobby (`menu-livewire`, `rules-livewire`, `lobby-livewire`,
`lobby-guest`), the arena swap in every direction, a round played through real
key events (held directions, dash, pause, focus loss), every HUD state
(`livewire-countdown`, `-game`, `-surge`, `-danger`, `-zapped`, `-loop`,
`-overdrive`, `-final`, `-timeup`), the results (`livewire-results`,
`livewire-results-solo`), switching games between rounds, leaving, and a failed
connection. `-- --only=livewire` runs just that half.

File map:

- `scripts/main.gd` — screens, menus, the shared frame of the round HUD, and the
  hand-off to whichever game is being played. It knows the games only through
  the small surface described at the top of `scripts/game_spin_cycle.gd`.
- `scripts/game_spin_cycle.gd`, `scripts/game_livewire.gd` — one module per game:
  its model and arena, round HUD, key mapping, sounds, how-to-play dialog and
  results rows.
- `scripts/round_model.gd`, `scripts/livewire_model.gd` — the two independent
  simulations, with the same interface. `scripts/livewire_grid.gd` is the hex
  board shared by Live Wire's model and renderer.
- `scripts/arena.gd`, `scripts/livewire_arena.gd` — the 3D art of each game.
  Only the one that belongs to the game on screen is shown. `scripts/arena_kit.gd`
  holds Spin Cycle's building pieces and the shared shaders, and
  `scripts/runner_visual.gd` animates one robot runner for both games.
- `scripts/session.gd` — ENet, the roster, the game choice, input routing and
  host voting.
- `scripts/discovery.gd` — sends and receives the LAN party beacons.
- `scripts/updater.gd` — checks, downloads, verifies, installs and recovers
  updates. `scripts/update_core.gd` holds its pure logic (versions, manifest
  validation, signatures, swap plans), `scripts/update_notice.gd` draws the
  version tag and update card, and `scripts/update_keys.gd` lists the trusted
  release keys.
- `scripts/ui_kit.gd` — the shared palette, fonts and chunky drawing helpers,
  and `Batch`, which gathers a widget's shapes into one triangle list (the
  engine's own antialiasing geometry) so a HUD plate is a handful of draw
  calls rather than ~60. Widgets that redraw often call `Kit.begin(self)` at
  the top of `_draw()` and `flush()` at the end.
- `scripts/hud_*.gd` — the HUD widgets: `hud_cue` (the top-centre call-out, for
  rods and for surges), `hud_status` (clock, stage chip, standings), `hud_slam`
  (call-out text), `hud_plate` (Spin Cycle's player plate with the coil
  gauge) and `hud_wire_plate` (Live Wire's, with the hex dash ring).
- `scripts/audio.gd` — announcer and sound effects.

A third game needs a model with the same interface, an arena, a module with the
same surface, and an entry in `GAMES` and `ACTIONS` in `scripts/session.gd`.

## Releases

Each release has a version and a build number in `project.godot`:
`application/config/version` (semver, shown to players) and
`application/config/build` (an integer, raised by one every release; the game
compares builds, never version strings). The Windows and macOS version fields
in `export_presets.cfg` are empty, so exports take the project version.

To cut a release:

1. Bump `config/version` and `config/build` in `project.godot`, and commit.
2. Dry run: `python3 tools/release.py --godot <godot> --notes "What's new"`.
   It builds all three platforms with `tools/build.py`, writes and signs the
   manifest under `builds/release/<version>/`, checks the live manifest and the
   release folder, and prints every upload without making any.
3. Publish: run the same command with `--publish`. It loads the Wasabi
   credentials from `~/.config/wasabi-timholum/publisher.env` (never from
   `~/.aws`), refuses to run if `releases/<version>/` already exists or the
   version and build are not newer than the live manifest, uploads the three
   builds, checks them over public HTTPS, and uploads the manifest **last**.
4. Point the website's download links at the new release folder. The links in
   the separate site repo still use the dated
   `games/gizmo-jam/2026-11-17/` folder and must be changed by hand to
   `games/gizmo-jam/releases/<version>/` when the first release ships.

Wasabi layout, bucket `timholum.com`, region `us-central-1`, public base
`https://s3.us-central-1.wasabisys.com/timholum.com/`:

- `games/gizmo-jam/releases/<version>/GizmoJam-Windows.exe`,
  `GizmoJam-Linux.x86_64` and `GizmoJam-macOS.zip`: immutable, never overwritten.
- `games/gizmo-jam/updates/stable.json`: the signed manifest, `Cache-Control:
  no-cache`. Its URL is a constant in `scripts/update_core.gd`.

The manifest is JSON inside a signed envelope, so the signature and the
manifest are always uploaded together:

```json
{"format": "gizmo-signed-manifest/1", "alg": "rsa-pkcs1v15-sha256",
 "key_id": "gizmojam-e66eee89ecb223d4",
 "payload": "<base64 of the manifest bytes>", "signature": "<base64 RSA signature>"}
```

The payload it carries:

```json
{"schema": 1, "game": "gizmo-jam", "channel": "stable",
 "version": "0.3.0", "build": 3, "released": "2026-12-04",
 "notes": "New minigame: Sumo.", "min_updater_build": 0,
 "download_page": "https://timholum.com/games/gizmo-jam/",
 "platforms": {
   "windows": {"url": "https://…/releases/0.3.0/GizmoJam-Windows.exe", "size": 99636960, "sha256": "…"},
   "linux":   {"url": "https://…/releases/0.3.0/GizmoJam-Linux.x86_64", "size": 73176528, "sha256": "…"},
   "macos":   {"url": "https://…/releases/0.3.0/GizmoJam-macOS.zip", "size": 66192485, "sha256": "…"}}}
```

The game rejects any manifest that does not verify against a trusted key, is
for another `game` or `channel`, has an unknown `schema`, or is over 64 KiB.
It rejects any download whose size or SHA-256 differs from the signed values.
Builds older than `min_updater_build` are sent to the download page instead of
updating in place (`--min-updater-build`). Another game or channel can reuse the
same format with its own `game` id and `<channel>.json`.

### Signing key

The signature is RSA-3072, PKCS#1 v1.5 over SHA-256, made by `openssl` and
checked with Godot's `Crypto.verify`. The private key is at
`~/.config/gizmojam/release-signing.key` (mode 600, outside the repository);
only public keys are committed, in `scripts/update_keys.gd`. `tools/release.py`
refuses to sign with a key the game would not trust.

**Back the private key up now**, offline and encrypted (for example in a
password manager or on an encrypted USB drive). The bucket alone cannot push an
update: whoever holds this key can, so guard it like a password.

**Rotation**, while the old key still works:

1. Make a new key: `python3 tools/release.py --generate-key --key ~/.config/gizmojam/release-signing-2.key`.
   It prints the line to add to `scripts/update_keys.gd`. Keep both keys listed.
2. Release with the **old** key and `--next-key <new public key PEM file>`.
   Every game that installs or checks that manifest saves the announced key
   (in `user://update_keys.json`) and trusts it from then on.
3. Later releases are signed with the new key (`--key …-2.key`). Remove the old
   public key from `update_keys.gd` once no supported build needs it.

**If the key is lost or leaked**, installed games cannot be moved to a new key:
they trust only the keys they already know, so nothing signed with a new key
will install. Players must download the next version from the website once;
that build embeds the new key and updates normally from then on. If the key
leaked, also remove its entry from `update_keys.gd` in that build and delete
`stable.json` until the new build is published.

## Credits and licenses

Gizmo Jam is an independent game. Its code, models, environments, UI and
sounds were made for it. The code and those assets are released under the
MIT License (see `LICENSE`); the fonts keep their own licenses, below.

Built with [Godot](https://godotengine.org/) 4.5. The Lato fonts
are bundled under the license in `assets/fonts/LICENSE.txt`. The display face is
Kanit Black Italic (Copyright 2020 The Kanit Project Authors), bundled under the
SIL Open Font License 1.1 in `assets/fonts/Kanit-OFL.txt`. If that file is
missing the UI falls back to an emboldened, slanted Lato.
