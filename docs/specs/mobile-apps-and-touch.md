# Gizmo Jam: phone-friendly web, Android and iOS apps

Status: 2026-11-18. Implemented: store-app switches (4), touch controls (5),
handheld scale, safe-area inset and compact game cards (6, partial), Android
build and Play publishing (7). Not yet: iOS (8), experiments M2–M5 on real
phones, portrait card, tablet layout. Builds on
`game-packs-and-browser-guests.md` (registry, packs, web build), and amends its
non-goal "Phones, touch or gamepad input" for touch only.

## 1. Goals

1. The web build plays well on a phone held sideways: touch controls, readable
   text and buttons a finger can hit.
2. An official Android app on Google Play.
3. An official iOS app on the App Store, after Android, if it stays cheap.
4. Phones play in the same parties as PCs, against any build since 0.2.0.

## 2. Priority rule (do not trade away)

**Desktop and web are first class. The mobile apps are second class.**

- With the mobile gate off (3.1), desktop and web behave, look and perform
  exactly as before: same layouts, same scale rule, same defaults, no extra
  nodes, no per-frame cost. Section 9 makes this a test.
- A desktop or web release never waits for a store review or a mobile fix.
- Where the two pull in different directions, desktop and web win and the
  mobile apps get a separate code path.
- Network messages are unchanged. Touch input is translated into the existing
  actions (`jump`, `duck`, `left`/`right`/`up`/`down`, `dash`), so no peer,
  0.2.0 included, can tell a phone from a keyboard.
- All the constraints of the packs spec still hold: LAN play offline on ENet,
  0.2.0 compatibility, nothing slower on old PCs.

## 3. Platforms and gates

### 3.1 Two flags

A new `scripts/platform.gd` decides once, at start-up:

| Flag | True when |
|---|---|
| `mobile_app` | `OS.has_feature("android")` or `OS.has_feature("ios")` |
| `handheld` | `mobile_app`, or the web build on a device whose primary pointer is coarse (`matchMedia("(pointer: coarse)")`), i.e. a phone or tablet browser |

- `handheld` turns on the touch controls (5) and the handheld layout (6).
- `mobile_app` turns off everything a store app must not do (4).
- A touchscreen laptop reports a fine primary pointer, so it keeps the desktop
  experience. Keyboard input keeps working everywhere, including on phones
  with a keyboard attached.
- A `--handheld` user argument forces the flag on desktop, for tests and
  screenshots only.

### 3.2 Where the code lives

New files hold the new behaviour: `platform.gd`, `touch_controls.gd`,
`handheld_layout.gd`. Changes to existing files are limited to gated hooks
(`if Platform.handheld: ...`), the same pattern as today's `on_web`.

## 4. Store apps: everything built in

Decided by Tim: the mobile apps are official store apps with every game
built in.

- **All games bundled.** The Android and iOS export presets include
  `games/*` (except `games/example`). At start-up the registry scans
  `res://games/*/game.json` and registers each one like a built-in game
  (`trust = "builtin"`, empty `sha256`, its own `net`). `compatible()`
  already matches on `id` and `net`, so a bundled game plays with a PC that
  has the same game as a signed pack.
- **Off in the apps:** pack manager and catalog download, the self-updater,
  update notices, developer mode and unsigned packs, the file server and
  browser guests. New games and fixes arrive as store updates.
- **Consequence:** the apps never download code and never update themselves,
  which is what Google Play and App Store policy require. They make no
  internet connections at all, only LAN game traffic. That keeps the privacy
  answers simple: no data collected.
- **Lagging versions.** A store build may trail the desktop release by days.
  When the host picks a game the phone does not have, or has at an older
  `net`, the phone reports `needs_update` and sits out with a bot in its seat
  (packs spec 5.4). No new mechanism is needed.
- **Phone as host.** Proposed: a phone may host a normal ENet party, without
  browser guests. PC guests missing a game the phone picked get it from the
  download server, since the phone runs no file server (packs spec 5.3).
  *(Open decision 1.)*
- **Discovery.** Phones send and hear the existing UDP beacon (Android: see
  7.2; iOS: see 8.2). Joining by address always works.

## 5. Touch controls

A `CanvasLayer` created only when `handheld` is on, above the HUD. When it is
off, it does not exist.

### 5.1 Spin Cycle

- **Right half of the screen:** tap to jump.
- **Left half:** hold to duck, release to stand.
- Faint labelled zones (an up wedge and a down wedge, the same colours as the
  HUD's JUMP and DUCK plates) show during the countdown and the first round,
  then fade to an outline.
- Jump and duck keep their current rule: jump overrides a held duck, and the
  duck resumes on landing.
- Alternatives if playtests disagree: two large buttons, or swipe up and
  down. *(Open decision 2.)*

### 5.2 Live Wire

- **A floating stick on the left half:** it appears where the thumb lands.
  The angle snaps to one of eight directions with a dead zone and some
  hysteresis, so it doesn't flicker on an edge. Each change is sent as
  presses and releases of the four direction actions, exactly as two held
  keys would be.
- **A dash button at bottom right**, sized at least 64 dp, with the dash
  cooldown ring drawn round it (the same hex ring as the HUD plate).
- The rate of direction changes stays inside the existing input budget (240
  a second): changes are sent only when the snapped direction changes, at
  most once per physics frame.

### 5.3 Menu keys

- **Esc:** a pause button in the top corner on the opposite side from the
  clock.
- **Tab (hold):** hold the pause button, or tap a player plate, to show
  names.
- **F11:** not shown; the apps always run fullscreen.
- Menu buttons already respond to taps through Godot's touch-to-mouse
  emulation. Hover sounds and outlines are skipped on handheld, since there
  is no hover.

### 5.4 Lifecycle

- Losing focus (`NOTIFICATION_APPLICATION_PAUSED` or `FOCUS_OUT`) releases
  every held input, as losing window focus already does.
- The screen stays on during a round (`DisplayServer.screen_set_keep_on`).
- A phone backgrounded mid-round may drop its connection; the existing rule
  applies: a bot takes its seat for the rest of the round, and it rejoins
  between rounds.

## 6. Handheld layout

The scale rule `min(w / 1440, h / 900)` clamped to 0.85–1.5 is tuned for
monitors. On a 6" phone it makes 14 px text about 1 mm tall. It does not
change for desktop or web; handheld gets its own profile.

- **Scale.** Size the UI by physical size: `DisplayServer.screen_get_dpi()`
  natively, `devicePixelRatio` on the web. Target body text of about 2.5 mm
  and touch targets of at least 9 mm (48 dp). In practice the UI is drawn
  around 1.6–2× larger than desktop at the same pixel count.
- **Safe area.** Lay out against `DisplayServer.get_display_safe_area()`, so
  nothing sits under a notch, a camera hole or the gesture bar.
- **Orientation.** Landscape only: sensor landscape in the apps, and a
  "turn your phone" card in a portrait browser.
- **Menus.** Use the existing compact rhythm for short windows, with one
  column of cards and the arena behind instead of beside. Name and address
  fields scroll above the on-screen keyboard.
- **Round HUD.** The six plates shrink to a single strip along the top edge
  (colour, score or tiles, coil or dash ring), out from under the thumbs. The
  call-out moves just under that strip. The clock and standings stay in a
  corner.
- **Live Wire camera.** It already widens to keep the board between the HUD
  bands. On handheld the bands are the top strip and the two thumb zones.
  Test M5 decides whether 169 tiles are readable on a 6" screen. If not,
  handheld uses a slightly closer camera that follows the player, with the
  whole board shown during surges.
- **Tablets.** Proposed: a short side over about 12 cm uses the desktop
  layout with touch controls. *(Open decision 3.)*

## 7. Android

### 7.1 Build

- Godot 4.5.1 Android export templates. This machine has only the web
  templates, plus a JDK and `adb`, and no Android SDK.
- A gradle build (needed to set the target SDK level Play currently
  requires), arm64-v8a, Compatibility renderer. Check the requirement for 16 KB
  memory pages.
- Permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
  `CHANGE_WIFI_MULTICAST_STATE`. Nothing else.
- Package name `com.timholum.gizmojam` (chosen in Play Console 2026-11-18;
  permanent). Play automatic protection is off, deliberately: Play does not
  modify the bundle, and sideloaded APKs keep working.
- `version_code` = `application/config/build`, `version_name` =
  `config/version`.
- The upload keystore lives outside the repo (for example `~/.config/gizmo-jam/`,
  chmod 600), and Play App Signing holds the release key. Never commit
  either.
- `tools/build.py --android` produces an APK (for sideloading at LAN parties,
  no store needed) and an AAB (for Play).

### 7.2 LAN discovery on Android

Android Wi-Fi drivers can drop broadcast packets unless the app holds a
multicast lock. Godot's Android socket layer takes one when a socket enables
broadcast. Today's listener in `discovery.gd` only binds, so on Android it
also calls `set_broadcast_enabled(true)`. Test M2 confirms it.

### 7.3 Play Store

- Store listing, screenshots (from the `--handheld` screenshot run), content
  rating, data safety ("no data collected"), and a short privacy policy page on
  timholum.com.
- **No 12-tester closed test.** That rule covers only personal accounts
  created after November 2023. Tim's Play account is an organization account
  verified with a D-U-N-S number, so the app can go to production after the
  normal review. A short closed or internal test with the LAN group is still
  worth running first.

## 8. iOS

### 8.1 Build

- Godot exports an Xcode project, which is compiled and signed on macOS.
  Proposed: GitHub Actions macOS runners (free for the public repo), with the
  signing certificate and profile as repository secrets, uploading to
  TestFlight. A Mac is still useful for on-device debugging.
- Info.plist: `NSLocalNetworkUsageDescription` (iOS asks before any LAN
  traffic), landscape only, the audio session set to ambient so the game
  respects the silent switch.

### 8.2 LAN discovery on iOS

Sending or receiving broadcast on iOS needs the
`com.apple.developer.networking.multicast` entitlement, which must be
requested from Apple and can take weeks. Until it is granted, iPhones join by
address only, and the Join Party dialog says so instead of showing an empty
list.

## 9. Desktop and web unchanged: how it is checked

- `tests/run_tests.py`, `run_online.py`, `run_latency.py`, `run_packs.py` and
  `run_browser.py` pass with no changes to their expectations.
- **Pixel check:** the screen-size and UI screenshot runs at their existing
  desktop sizes give byte-identical images before and after each phase.
- **Frame-time check:** the graphics probe at Low on two llvmpipe threads stays
  within run-to-run noise of the README table.
- The browser test runs once more with a fine pointer (unchanged desktop web)
  and once with a coarse pointer emulated in headless Chrome (handheld web).

## 10. Experiments before building (phase M0)

| # | Question |
|---|---|
| M1 | Does an Android APK built from this tree reach the menu, play a solo round, and join a PC's ENet party and finish a round? |
| M2 | Does an Android phone on the same Wi-Fi hear the discovery beacon, with and without `set_broadcast_enabled(true)` on the listener? |
| M3 | Frame rate of Spin Cycle and Live Wire at Low and Balanced on a mid-range and a cheap Android phone; this sets the default graphics level for the apps. |
| M4 | Does the web build reach the menu and play sound in Android Chrome and in iPhone Safari, both from the https website and from a host's plain-HTTP LAN address? iPhone Safari has known Godot problems with memory limits and sound. |
| M5 | Mock-up with forced `--handheld` on a real phone: is Live Wire's board readable, and do the thumb zones feel right? |

If M4 fails on iPhone Safari, phone-friendly web is Android-only, and iPhone
players get the App Store app instead.

## 11. Phases

| Phase | Contents | Estimate |
|---|---|---|
| M0 | Section 10 experiments; amend this spec | 1 day |
| M1 | `platform.gd`, the gates, the `--handheld` flag, the section 9 checks | 0.5–1 day |
| M2 | Touch controls and lifecycle (5) | 2–3 days |
| M3 | Handheld layout (6), screenshot runs at phone sizes | 3–4 days |
| M4 | Android app: bundled games, store-app switches (4), build and Play (7) | 1–2 days, plus the closed-test wait |
| M5 | Phone web polish from M4/M0 findings | 1–2 days |
| M6 | iOS (8) | 2–3 days, plus the entitlement and review waits |

M2 and M3 are shared by phone web, Android and iOS. Each phase ends with the
section 9 checks green.

## 12. Open decisions

1. May a phone host a party? (Proposed: yes, ENet only.)
2. Spin Cycle controls: screen halves (proposed), two buttons, or swipes.
3. Tablets: desktop layout with touch controls (proposed), or handheld.
4. Default graphics level in the apps (after M3).
5. Whether iOS is done at all, and when.

## 13. Store declarations: requirements (do not break)

Tim answered Google Play's content-rating questionnaire (IARC) on 2026-11-18,
and the privacy policy at <https://timholum.com/games/gizmo-jam/privacy/>
describes what the game sends. **Every store build must keep these answers
true.** A change that would make one false is blocked until the declaration,
the privacy policy and this section are updated first, before that build
ships. Releases go to Play automatically (`release_games.py --publish`), so
nobody gets a second look at a build before it ships: this section is the
check.

### 13.1 Content rating answers

| Question | Answer | What keeps it true |
|---|---|---|
| Violence, blood or gore | **Yes: mild cartoon violence** (recommended over the original No, because robots are knocked down, bowled off the belt, zapped and shoved) | No blood, gore, human characters hurt, or realistic violence. If any appear, re-answer. |
| Fear | No | No horror imagery or disturbing sounds. |
| Sexuality, suggestiveness, dating | No | None, in any art, text or audio. |
| Gambling (themes, simulated, real) | No | No casino or bingo mechanics, loot boxes, wagers or random paid rewards. |
| Offensive language | No | No profanity or slurs in any shipped text or voice line, including announcer lines generated in `tools/generate_audio.py`. |
| Drugs, alcohol, tobacco | No | No references, even jokes or props. |
| Crude humour | No | No belching, flatulence or vomiting gags. |
| Digital purchases, cash rewards, NFTs | No | No in-app purchases, ads that pay out, crypto or tradable items. Adding purchases means Google Play Billing, a new declaration and a privacy policy update. |
| Users interact (voice, text, images, audio) | Yes | Player names now; text chat planned. |
| Block users | No | See 13.2. Must become Yes before chat ships in a store build. |
| Report users or content | No | See 13.2. Must become Yes before chat ships in a store build. |
| Chat moderation | No | See 13.2. Must become Yes before chat ships in a store build. |
| Interactions limited to invited friends | Yes | Parties are joined only on the host's network or with its address. **No public matchmaking, public lobbies or random-join** in store builds. An internet relay with room codes (packs spec section 8) keeps this true; a public server list does not. |
| Shares precise location | No | Never read or send GPS or precise location. No location permission in the Android manifest. |
| Nazi symbols; content against Korean national identity | No | None. |

### 13.2 Chat in the store apps

Google Play's user-generated content policy and Apple's App Review guideline
1.2 require any store app where users exchange content to have:

1. a way to **report** a message and a player;
2. a way to **block** a player, which hides their messages and name for the
   blocker;
3. **filtering** of objectionable text, at least a profanity and slur filter
   applied on the receiving device, plus a way to act on reports;
4. published rules for acceptable content, which the player agrees to before
   using chat;
5. a way to contact us, already on the privacy policy page.

Until all five exist, **chat is compiled out of or disabled in store builds**
(`PackManager.store_app`), even if desktop and web have it. When chat ships to
phones:

- re-answer 13.1 (block, report, moderation: Yes);
- update the privacy policy, which currently says "no accounts, chat or in-game
  purchases": say who sees messages, that they travel only between party
  members' devices, and whether anything is stored;
- re-check Play's Data safety form (13.3).

Player names are already shared text. Store builds keep the existing
length and character cleaning (`Discovery.clean()`), and must add the 13.2
filter to names when chat ships.

### 13.3 Data safety and privacy

- **Data safety form:** no data collected, no data shared. This holds because
  the store apps send nothing to us or to third parties: no analytics, crash
  SDK, ads SDK, accounts or internet requests. Party traffic goes only between
  players' devices.
- **Do not add** any SDK or library that phones home (analytics, crash
  reporting, ads, attribution, social login, cloud saves) to a store build
  without first updating the Data safety form and the privacy policy.
- **Android permissions** stay limited to `INTERNET`, `ACCESS_NETWORK_STATE`,
  `ACCESS_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE`. Any new permission
  needs a reason written here and a store declaration review. Location,
  contacts, microphone, camera and storage need new declarations; microphone
  would also mean voice chat, which falls under 13.2.
- **The privacy policy must stay accurate.** Any new network use, in any
  version (desktop, web or mobile), is added to the policy before release. The
  policy lives in the separate site repo:
  `Timholumcom/games/gizmo-jam/privacy/index.html`.

### 13.4 Checks a release must pass (to automate)

To add to `tools/build.py --android` so a violation fails the build instead of
reaching Play:

- The built APK's permissions are exactly the four above (`aapt2 dump
  badging`).
- No known analytics, ads or crash-reporting packages are in the dex or native
  libraries.
- If the chat feature exists in the source tree, store builds have it off
  unless a `STORE_CHAT_READY` flag says 13.2 is done.

### 13.5 Target audience: 13 and over

Tim set the Play target audience to 13–15, 16–17 and 18+ on 2026-11-18, and
deliberately **not** 12 or under, so the Families policy does not apply.

- **The store listing must not market the app to children.** Its text and
  graphics are about friends and parties: no "for kids" or "for the whole
  family" wording, and no child-oriented imagery. Answer Play's "unintentionally
  appeals to children" question honestly. If Google decides the app appeals to
  children, the Families rules below apply anyway.
- **If the audience is ever widened to include under-13s**, the Families policy
  applies first ([Play Console Help](https://support.google.com/googleplay/android-developer/answer/9893335)).
  Its main points: only Families-certified ad SDKs; COPPA and GDPR compliance;
  and, for any feature that lets users share freeform content (chat), an
  in-app online-safety reminder before a child uses it, controls for parents to
  turn it off or limit it, and an "adult action" (PIN, password and so on)
  before a child can exchange personal information. Since August 2026, apps
  built mainly for chatting with strangers or anonymously may not target
  children at all.
- **Chat for 13+** still needs everything in 13.2.
