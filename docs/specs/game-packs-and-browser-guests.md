# Gizmo Jam: game packs, on-demand games and browser guests

Status: draft, 2026-11-18. Nothing here is implemented. The assumptions behind
the design were tested with throwaway experiments on Godot 4.5.1; section 9
records the results, and the sections they changed are amended.

## 1. Goals

1. Each minigame ships as its own pack. A release that only adds a game means
   publishing one pack, not a new build of everything.
2. A player does not need every game installed. When the party leader picks a
   game someone lacks, their build fetches it, from the host PC or from the
   download server, and the party carries on.
3. Packs are signed. A signed pack loads silently. An unsigned pack can load
   only in developer mode, after explicit consent, with a visible UNTRUSTED
   flag. This is the route for testing games in development without publishing.
4. A browser player can join a party hosted by a PC build on the same LAN, with
   no internet connection.

## 2. Constraints (do not trade these away)

- **LAN play stays fully offline** and stays on ENet between PC builds.
- **0.2.0 builds (ENet, protocol 2) must still host, join and play** Spin Cycle
  and Live Wire with every later build. No existing `@rpc` method changes its
  name, arguments or position in the name-sorted RPC list.
- **Old hardware.** Target machines are 10+ years old (about 5000 PassMark).
  Nothing in this work may add per-frame cost to a native round. File serving
  and hashing never run on the main thread during a round.
- **Each native build stays one self-contained executable** that the existing
  self-updater can swap. No GDExtension libraries.
- **Host is always a PC build.** Browsers cannot listen for connections or
  hear the UDP discovery beacon.

## 3. Non-goals

- Internet play for browsers (section 8, deferred).
- WebRTC. Not needed on a LAN; revisit only for section 8.
- Sandboxing pack code. Godot has none; see 6.4.
- Phones, touch or gamepad input.

## 4. Game registry and packs

### 4.1 Today

- `scripts/session.gd` hard-codes `GAMES`, `ACTIONS` and `INPUT_BUDGET`.
- `scripts/main.gd` hard-codes `GAME_MODULES` (preloads of
  `game_spin_cycle.gd`, `game_livewire.gd`) and owns both arenas directly
  (`main.arena`, the `LiveArena` instance). Game modules reach back into
  `main` for them.
- The module interface is documented at the top of `game_spin_cycle.gd`.

### 4.2 Registry

A new `scripts/game_registry.gd` owns the list of games. Everything that reads
`Network.GAMES`, `ACTIONS`, `INPUT_BUDGET` or `GAME_MODULES` reads the registry
instead. An entry:

| Field | Meaning |
|---|---|
| `id` | Wire id. Never changes once shipped (`twisted`, `livewire`). |
| `version` | Semver of the pack. |
| `net` | Integer. Two builds can play a game together only when `id` and `net` match. |
| `core_min` | Lowest core build number the pack runs on. |
| `actions` | Input actions accepted by `send_input()`. |
| `input_budget` | Accepted input messages per peer per second. |
| `info` | Menu card: number, title, tags, blurb, voice cue. |
| `entry` | Path of the module script inside the pack. |
| `trust` | `builtin`, `signed` or `untrusted`. Set by the loader, never by the pack. |
| `sha256` | Hash of the pack file (empty for built-ins). |

Registry states for a game on this machine: `installed`, `available` (in the
catalog, not downloaded), `needs_core_update` (`core_min` above this build),
`downloading`.

### 4.3 Pack layout

A pack is a Godot `.pck`. One file serves Windows, Linux, macOS and the browser.

```
res://games/<id>/game.json     the registry fields above, minus trust and sha256
res://games/<id>/module.gd     the game module (same interface as today)
res://games/<id>/...           model, arena, HUD, audio, meshes
```

- A game owns its arena. `main.gd` stops creating arenas; the module creates
  its own in `stage()` and frees it when the game is no longer selected.
- A pack may depend on core scripts (`ui_kit.gd`, `arena_kit.gd`, the `hud_*`
  parts, `runner_visual.gd`) and on nothing in another pack.
- **No `class_name` in pack scripts.** Global classes only resolve if the pack
  replaces the core's class cache file, which 5.2 forbids. Packs use `preload`
  paths, as the game modules already do.
- Pack and core need not use the same script export mode (tested both ways).
- **The core interface is a contract.** Core changes that a shipped pack can
  see must be additive. A breaking change raises the core build and every pack
  that needs it raises `core_min`.

### 4.4 Built-in games

Spin Cycle and Live Wire move to `res://games/twisted/` and
`res://games/livewire/` but stay inside the core executable, with `net` 1
matching 0.2.0. They are registry entries with `trust = builtin`. This keeps
0.2.0 compatibility and means a fresh install can play with no downloads.

### 4.5 Storage

- Installed packs: `user://games/<id>/<sha256>.pck`, with the signed catalog
  that vouches for them at `user://games/catalog.json`.
- Developer packs: `user://dev-games/*.pck` (section 6).
- Removing a game deletes its file. Built-ins cannot be removed.
- **A new pack loads without a restart; a newer version of a pack already
  loaded in this run does not.** Godot cannot unload a pack, and the ways of
  forcing a reload swap code under live objects. An updated pack is downloaded
  and verified straight away and takes effect on the next start; the lobby
  says "restart to update" and the player sits that game out until then.

### 4.6 Build tooling

`tools/build.py` gains `--packs`: export the core without `games/*` other than
the built-ins, and one `.pck` per remaining game. `tools/release.py` gains pack
upload and catalog signing (5.1). A pack is produced in two steps, and the
result is byte-reproducible:

1. `--export-pack` with a preset in "all resources" mode whose exclude filter
   covers everything outside `games/<id>/`. ("Selected resources" mode drags
   in core scripts and textures the game's scenes depend on.)
2. A `PCKPacker` repack that drops the project-wide files every export adds:
   `project.binary`, `.godot/uid_cache.bin`,
   `.godot/global_script_class_cache.cfg` and the project icon.

## 5. Signed catalog and on-demand download

### 5.1 Catalog

One signed file lists every published game. It reuses the updater's envelope
(`gizmo-signed-manifest/1`, RSA PKCS#1 v1.5 SHA-256, keys from
`scripts/update_keys.gd`, same `next_key` rotation) with its own payload:

```json
{"schema": 1, "game": "gizmo-jam", "kind": "catalog", "channel": "stable",
 "serial": 14,
 "games": {
   "sumo": {"version": "1.0.0", "net": 1, "core_min": 3,
            "size": 412345, "sha256": "…", "url": "https://…/packs/sumo-1.0.0.pck",
            "info": {"number": "03", "title": "SUMO", "tags": "…", "blurb": "…"}}}}
```

- Published next to the update manifest as `updates/catalog-<channel>.json`.
  It is a separate file so 0.2.0's updater never sees it.
- `serial` only goes up. A build remembers the highest serial it has accepted
  and refuses a lower one, so an old signed pack with a known bug cannot be
  replayed.
- Verification lives in `update_core.gd` beside `open_envelope()`, as pure
  logic with tests, like the existing manifest code.
- The game fetches the catalog on start when online (same timing as the update
  check) and keeps the last good copy for offline use.

### 5.2 Accepting a pack

A pack file is loaded only after all of these pass, in this order:

1. Its catalog entry exists in a catalog that verified against a trusted key.
2. `core_min` is not above this build.
3. Declared size is within `MAX_PACK` (proposed 64 MB) and the transfer is cut
   off at the declared size.
4. SHA-256 of the file equals the catalog's.
5. The pack's file table is read without loading it, and every path is inside
   `res://games/<id>/`, `res://.godot/imported/` or `res://.godot/exported/`
   (where Godot puts converted textures and scenes) and does not already exist
   in the core. Any other path rejects the pack.
6. Its `game.json` agrees with the catalog on `id`, `version` and `net`.

A failure discards the file and shows a plain message in the lobby. Steps 3–5
run on a worker thread.

Packs are always loaded with `load_resource_pack(path, false)`. With the
default (`true`) a pack replaces core scripts, including ones compiled later
in the run; `false` keeps every core path. The path check in step 5 is still
required, because `false` does not stop a pack adding new paths.

### 5.3 Where the bytes come from

The source is only a courier; step 5.2 decides trust.

1. **The host PC**, when in a party. Fast, and works with no internet.
2. **The download server** (`url` from the catalog).

The host answers a guest's request with its own signed catalog as well as the
pack, so a guest with no internet and an older catalog can still verify. The
guest applies the serial rule to the host's catalog like any other.

Transfers use the host's file server (7.2), never the game connection.

### 5.4 Lobby behaviour

- The leader can pick any game the **host** has installed.
- Each member's build reports one of: `ready`, `downloading NN%`,
  `needs update` (core too old, or a 0.2.0 build), `declined` (6.3),
  `failed`. The lobby shows it beside the name.
- Start waits while anyone is `downloading`, with the button reading
  "Waiting for N". The leader may press **Start anyway**. *(Recommended
  default; not yet confirmed by Tim.)*
- A member who is not `ready` when the round starts sits it out: they stay in
  the party, see a "sitting this one out" screen, and a bot plays their seat.
  The host does not send them the launch message or snapshots.

### 5.5 Game library screen

Lists every catalog game with size and state, with install and remove. Lower
priority than 5.1–5.4: on-demand download makes it optional until the library
is large.

## 6. Unsigned packs and developer mode

### 6.1 Rule

Signed packs load silently. Unsigned packs never load silently.

### 6.2 Developer mode

- A setting, off by default, behind a confirmation that states the risk.
- Off: unsigned packs are refused outright, including ones offered by a host.
- On: every pack in `user://dev-games/` appears in the menu with an
  **UNTRUSTED** badge. Steps 2, 3, 5 and 6 of 5.2 still apply (using the
  pack's own `game.json`); steps 1 and 4 do not.

### 6.3 Sharing an unsigned pack with the party

- The host needs developer mode on to pick one.
- Each guest with developer mode on gets an in-page prompt naming the game,
  the host's player name and the pack hash, and must accept before anything
  downloads. Consent is stored per hash; a rebuilt pack asks again.
- Guests with developer mode off, or who decline, sit the round out (5.4).
- The UNTRUSTED badge stays on the menu card, the lobby and in a corner of the
  round HUD for everyone in the round.

### 6.4 What the warning must say

A pack is GDScript with the same access as the game itself: it can read and
write files and start programs. The prompt says so in those terms and ends
with "Only accept this from someone you trust." No softer wording.

### 6.5 Later, if prompts become tedious

A separate dev signing key trusted only when developer mode is on, applied by
`tools/build.py` automatically. Not part of this work.

## 7. Mixed versions and browser guests

### 7.1 Capabilities (native peers)

- After the existing `_register`/`_roster` exchange, a new build sends a hello
  listing its core build and installed games (`id`, `net`, `version`,
  `sha256`, `trust`). The host replies with its own, plus the file-server port.
- **No new `@rpc` methods.** These messages go as raw packets
  (`SceneMultiplayer.send_bytes` / `peer_packet`), one stable entry point with
  a version byte and a message kind. Test T7 confirms a 0.2.0 peer ignores
  them harmlessly.
- A protocol-2 peer that sends no hello within 3 seconds is a legacy 0.2.0
  build: games `twisted` and `livewire` at `net` 1, nothing else.
- The host sends `_launch` only to peers that can play the chosen game. This
  matters for 0.2.0: given an unknown game id it would start the round on its
  previously selected game.
- The discovery beacon is unchanged.

### 7.2 Host file server

Two TCP listeners on the host, started when a party opens: files on one port
(proposed 7780, shown in the lobby) and the browser guests' WebSocket on the
next (7781). One shared port was tested and does not work: Godot's WebSocket
cannot take over a connection whose request line has already been read.

| Path | Serves |
|---|---|
| `GET /catalog` | The host's signed catalog envelope. |
| `GET /packs/<sha256>.pck` | A pack the host has installed, or the unsigned pack currently picked when the host is in developer mode. Nothing else. |
| `GET /` and static files | The browser build, when "Browser guests" is on. |
| WebSocket port | The browser guests' game connection. |

- Accept loop and file reads run on a worker thread, with a per-connection
  rate cap while a round is in progress.
- Plain HTTP by design: this is LAN-only and nothing served is secret. Packs
  are protected by the signature, not the transport.

### 7.3 Transport seam

`session.gd` keeps all party logic and talks to peers through a small
send/receive layer with two backends:

- **ENet backend:** the existing RPCs, byte for byte.
- **Web backend:** one WebSocket per browser guest, binary frames carrying a
  version byte, a message kind and a `var_to_bytes` payload decoded without
  objects. Kinds mirror the existing RPCs (register, roster, launch, input,
  state, lobby, votes) plus the 7.1 hello.

Browser guests get peer ids from a range ENet never issues. Existing tests
(`run_tests.py`, `run_online.py`, `run_latency.py`) must pass unchanged.

### 7.4 Browser build

- A Web export preset, single-threaded (a plain-HTTP LAN page has no
  cross-origin isolation, so no threads). Measured size: 39.8 MB, 11.9 MB
  gzipped; the file server should send it gzipped.
- **A stock Godot web export refuses to start on a plain-HTTP LAN address**
  ("Secure Context" check), and its audio then fails because browsers disable
  AudioWorklet there. It reached the main menu only with a custom HTML shell
  that removes the check and stubs the audio worklet, using the older
  ScriptProcessor audio driver. Whether sound actually plays that way is
  untested. This is the main open risk for browser guests; the fallbacks are a
  silent browser build or dropping 7.4.
- Required web-only changes found so far: skip `_fit_window()`; disable the
  updater (it ran and fetched the live manifest); hide Host Party and the LAN
  party search; default graphics to Low (it picked High).
- Differences from native: no updater, no discovery, no hosting, no solo party
  hosting; it joins the party at the address it was loaded from. Graphics
  default to Low.
- It is always the host's exact core, so there is no core mismatch. Packs load
  from the host's `/packs/` like a native guest.
- The web build ships as a separate download the host fetches once and caches,
  so updater downloads stay small. It is listed in the signed catalog like a
  pack.
- Guidance in the lobby: the browser is the guest option. On old PCs the
  native build is expected to be clearly smoother.

## 8. Internet play for browsers (deferred)

A browser on an https page cannot connect to a home PC directly, so this needs
a hosted piece. Proposed first step: a small relay with room codes on the
existing server, reusing the 7.3 web messages. Add WebRTC only if measured
latency through the relay is a problem. Not scheduled.

## 9. Test results (2026-11-18)

Throwaway experiments on Godot 4.5.1, against both the 0.2.0 source and the
published 0.2.0 Linux binary. The existing test suite passed in the test copy
first. Harness and logs: `/tmp/gjfeas.1uDb` (temporary).

| # | Question | Result |
|---|---|---|
| T1 | Does a separate `.pck` of scripts and assets load in an exported release build and call core scripts? | **Pass.** A stub module in a pack loaded in the published 0.2.0 binary and used `ui_kit.gd`. `class_name` does not work in packs (4.3). |
| T2 | Can a pack's file list be read before loading, and core files protected? | **Pass.** A GDScript reader lists a pack's paths in under 1 ms and refused a pack carrying `ui_kit.gd`. `replace_files=false` keeps core files; the default replaces them (5.2). |
| T3 | Can tooling build a pack with only one game's files? | **Pass with a strip step** (4.6). Scenes land in `.godot/exported/`, which 5.2 now allows. |
| T4 | Load a pack mid-session; replace a loaded pack? | **Partial.** Loading mid-round took 0.2 ms. Replacing a loaded pack needs a restart (4.5). |
| T5 | Does the game export to Web and reach the menu; does a pack load there? | **Partial.** Menu reached and a pack loaded over HTTP, but only after the changes in 7.4. Sound unverified. |
| T6 | ENet server and WebSocket listener in one host, browser client over `ws://` from a LAN address? | **Pass on two ports.** One shared port fails (7.2). |
| T7 | Do raw `send_bytes` packets leave a 0.2.0 peer undisturbed? | **Pass**, both directions, source and published binary: registration, a full Live Wire round, a mid-round quit, return to lobby, no new log lines on the 0.2.0 side. Adding one `@rpc` instead also completed rounds but logged 24–35 engine errors per run, which supports the no-new-RPC rule. Confirmed: a 0.2.0 guest sent `_launch` for an unknown game starts its previously selected game (7.1). |
| T8 | Does serving a 40 MB file from a thread hitch the host? | **Pass.** p99 frame time 17.7 ms during transfer against 17.6 ms idle; confirmed pinned to one core. Headless and loopback, so no render cost and no real LAN. |

Still untested:

- Browser frame rate on a ~5000-PassMark PC. Tim measures this by hand with
  the web build; if Low cannot hold a steady frame rate, 7.4 is dropped.
- Whether sound plays in the browser on a plain-HTTP LAN address.
- Whether the binary script format ties a pack to one engine version. Assume
  it does: an engine upgrade means rebuilding every pack.

Note: the published 0.2.0 binary was built from commit `9e095e5`, not
`62ed1fe`. The two differ in `scripts/` only by a file rename and comments.

## 10. Phases

| Phase | Contents | Estimate |
|---|---|---|
| 0 | Section 9 tests; amend this spec | done |
| 1 | Registry (4.2), games own their arenas (4.3), built-ins moved (4.4), capabilities (7.1). No packs yet. Ships as a normal release and proves 0.2.0 compatibility. | 3–4 days |
| 2 | Pack format, build tooling, signed catalog, verification, download from server and host, lobby states (4.5–5.4, 7.2 pack paths) | 4–5 days |
| 3 | Developer mode and unsigned packs (6) | 1 day |
| 4 | Transport seam, web export, browser guests on LAN (7.2–7.4) | 5–6 days |
| 5 | Game library screen (5.5) | 1–2 days |

Each phase ends with `tests/run_tests.py` green and a cross-version online
round against 0.2.0.

## 11. Open decisions

1. Start-while-downloading rule (5.4): wait with override is assumed.
2. Whether internet play for browsers (8) is wanted at all.
3. `MAX_PACK` size (64 MB proposed) and the file-server ports (7780/7781 proposed).
4. If browser sound cannot be made to work on a plain-HTTP LAN address: ship
   browser guests silent, or drop them.

## 12. As built (2026-11-18)

Where the implementation differs from the design above:

- **Built-in games stayed in `scripts/`** rather than moving to
  `res://games/<id>/` (4.4). Tests and the 0.2.0-compatible code paths refer
  to them there, and nothing about packs needs them moved. `games/` holds pack
  games only and is excluded from the core export.
- **Every build plays the built-in games** (net 1), so a member counts as
  ready for them before its capabilities arrive. A 0.2.0 member is otherwise
  recognised after 3 s of silence (7.1).
- **Member states**: `ready`, `joining`, `missing`, `downloading`,
  `verifying`, `asking` (waiting on consent) hold up Start; `needs_update`,
  `restart`, `declined`, `untrusted` (developer mode off), `failed` sit out.
  A leader who is sitting out gets **End round** to bring everyone back.
- **Guests download exactly the host's file**: the catalog entry is looked up
  by id and SHA-256 of the host's pack. Order: own catalog, the host's
  `/catalog`, the published catalog.
- **Unsigned packs received from a host** are kept for the session only;
  consent is remembered per SHA-256 in the packs folder.
- **Version 0.3.0, build 3** is the first core with packs; the example game
  has `core_min` 3 and `"publish": false`.
- **Publishing**: `tools/release_games.py` (separate from `tools/release.py`).
- **Verified in an exported release build**: the core's file list is read
  from the executable (162 files, no `games/`); a pack carrying a core script,
  and one reusing a converted resource path the core has, are both refused.
