# Gizmo Jam quality review

The [scorecard](game-quality-scorecard.md) supplies the six categories and weights. Opus 5.5 and Sol 6.2 graded independently. The baseline is the local build based on `f547307`, including the optional lineups, player colors, and touch improvements.

## Baseline

Ratings are out of five. Each pair gives Opus first and Sol second. The subtotal is weighted, with 75 points assessed. Fun and replay are open for every game pending human play. Controls, motion, and first-round clarity are provisional because the evidence covers automation, software-rendered captures, and source behavior.

| Game | Controls | Graphics | Motion | Clarity | Reliability | Opus /75 | Sol /75 |
| --- | --- | --- | --- | --- | --- | ---: | ---: |
| Spin Cycle | 4 / 4 | 4 / 4 | 3 / 3 | 4 / 4 | 4 / 4 | 57 | 57 |
| Live Wire | 3 / 4 | 4 / 3 | 3 / 3 | 3 / 3 | 4 / 4 | 50 | 51 |
| Bumper Cars | 3 / 3 | 2 / 3 | 2 / 3 | 2 / 3 | 2 / 3 | 34 | 45 |
| Sumo | 3 / 3 | 3 / 4 | 2 / 3 | 3 / 3 | 3 / 4 | 42 | 50 |
| Orb Racing | 3 / 3 | 2 / 3 | 3 / 3 | 2 / 3 | 4 / 4 | 41 | 47 |
| Stampede Sheriff | 3 / 3 | 3 / 3 | 2 / 3 | 3 / 3 | 4 / 4 | 44 | 47 |
| Plate Panic | 3 / 3 | 3 / 3 | 2 / 3 | 3 / 2 | 4 / 4 | 44 | 44 |
| Salvage Line | 3 / 3 | 3 / 3 | 2 / 3 | 2 / 3 | 4 / 4 | 41 | 47 |

Bumper Cars had the lowest Opus grade and Plate Panic had the lowest Sol grade. Both reviewers observed small player silhouettes and cues that get lost in crowded play. Each pass records observable changes, reruns comparable checks, and updates a category when the new evidence supports a different rating.

## Pass 1 · Bumper Cars

| Game | Controls | Graphics | Motion | Clarity | Reliability | Opus /75 | Sol /75 |
| --- | --- | --- | --- | --- | --- | ---: | ---: |
| Bumper Cars | 3 / 3 | 3 / 4 | 2 / 3 | 3 / 4 | 3 / 4 | 42 (+8) | 53 (+8) |

Larger labels and dashed local-player halos help track the cars. Inward chevrons mark the next sinking ring, including in grayscale. Drivers near the rim get one **MOVE IN!** cue per ring, and shared screens use short seat labels. The other games retain their baseline grades.

The new rules suite passed 22 checks for ring timing, boost knockouts, vacant and solo seats, and snapshot parity. The full regression passed, including a Chrome LAN guest. Both 1280×720 desktop and 1024×576 simulated handheld captures show the warning. In a single 10-second software-rendered sample, p95/p99 were 27.10/32.21 ms before and 29.44/33.76 ms after. Neither sample had a frame over twice the 33.3 ms budget.

## Pass 2 · Sumo and Orb Racing

| Game | Controls | Graphics | Motion | Clarity | Reliability | Opus /75 | Sol /75 |
| --- | --- | --- | --- | --- | --- | ---: | ---: |
| Sumo | 3 / 3 | 3 / 4 | 3 / 4 | 3 / 4 | 3 / 4 | 45 (+3) | 56 (+6) |
| Orb Racing | 3 / 3 | 3 / 4 | 3 / 3 | 3 / 4 | 4 / 4 | 47 (+6) | 53 (+6) |

Sumo shows a local fighter's dashed ring, distinct windup chevrons and swing crest, and brief hit compression. Orb Racing reserves space for local racers' labels, draws a connector to displaced labels, labels each local player's next gate when routes differ, and tones down the infield sign. Its local label motion and intermittent rival labels remain items to watch in dense packs.

Matched desktop and handheld captures and short fixed-rate clips cover crowded racing and opposing shoves. The rules, pack builds, and full regression passed. Targeted assertions cover first-frame rival badges, overlapping shared-seat labels, split gates, rematch, and hit recovery. The clips show motion transitions at 30 FPS. Physical-device and guest motion performance remain open.

## Pass 3 · Plate Panic and Salvage Line

| Game | Controls | Graphics | Motion | Clarity | Reliability | Opus /75 | Sol /75 |
| --- | --- | --- | --- | --- | --- | ---: | ---: |
| Plate Panic | 3 / 3 | 3 / 3 | 2 / 3 | 4 / 3 | 4 / 4 | 47 (+3) | 47 (+3) |
| Salvage Line | 3 / 3 | 3 / 3 | 2 / 3 | 3 / 4 | 4 / 4 | 44 (+3) | 50 (+3) |

Plate Panic previews the actual wedge placement when ready and shows a slashed marker when blocked. The local tag shifts away from the rim and HUD. Salvage Line distinguishes rope states by shape, weight, and glyph size. Shared cut targets now use nested frames and separate captions. The cut itself still has little feedback at the rope.

Both pack builds, the full regression, and 18 targeted visual-state assertions passed. Those assertions cover wedge legality, cooldown, vacant pockets, guest ownership, all three rope states, and two local players sharing a cut target. Comparisons used the same staged scenes on desktop and simulated handheld.

## Pass 4 · Live Wire and Stampede Sheriff

| Game | Controls | Graphics | Motion | Clarity | Reliability | Opus /75 | Sol /75 |
| --- | --- | --- | --- | --- | --- | ---: | ---: |
| Live Wire | 3 / 4 | 4 / 4 | 3 / 3 | 4 / 4 | 4 / 4 | 53 (+3) | 57 (+6) |
| Stampede Sheriff | 3 / 3 | 3 / 3 | 2 / 3 | 4 / 4 | 4 / 4 | 47 (+3) | 50 (+3) |

Live Wire hatches the charging lanes and widens their bright bands as firing approaches. The stage note shares the surge cue during simultaneous events, leaving zap feedback and scores visible. Stampede Sheriff uses the model's facing for the clap preview, a floor marker for local sheriffs, and a neutral hit marker triggered by synchronized critter recovery.

Before-and-after clips cover crossing surges, territory under the warnings, and a clap in a herd. Grayscale comparisons show the new patterns. The full regression passed. The final layout sweep passed 14,396 checks, and the rebuilt Stampede pack passed 29 desktop and 23 simulated handheld smoke checks. The Opus subtotals here are calculated from the submitted category ratings using the scorecard weights.

## Pass 5 · Spin Cycle and Salvage Line

| Game | Controls | Graphics | Motion | Clarity | Reliability | Opus /75 | Sol /75 |
| --- | --- | --- | --- | --- | --- | ---: | ---: |
| Spin Cycle | 4 / 4 | 4 / 4 | 3 / 3 | 4 / 4 | 4 / 4 | 57 | 57 |
| Salvage Line | 3 / 3 | 3 / 3 | 3 / 4 | 3 / 4 | 4 / 4 | 47 (+3) | 53 (+3) |

Spin Cycle's stage status, incoming rod countdown, and impact text stay separate through the peak cue animation. The damage frame sits behind the HUD and follows the full viewport when the HUD is inset. Both graders observed better readability within Spin Cycle's existing grades. Salvage Line animates the two rope ends at a confirmed cut. Its arena fixture passed 17 assertions for actual cuts, manual releases, deliveries, snapshot ordering, expiry, and rematches.

## Baseline to final

| Game | Opus /75 | Sol /75 |
| --- | ---: | ---: |
| Spin Cycle | 57 → 57 | 57 → 57 |
| Live Wire | 50 → 53 | 51 → 57 |
| Bumper Cars | 34 → 42 | 45 → 53 |
| Sumo | 42 → 45 | 50 → 56 |
| Orb Racing | 41 → 47 | 47 → 53 |
| Stampede Sheriff | 44 → 47 | 47 → 50 |
| Plate Panic | 44 → 47 | 44 → 47 |
| Salvage Line | 41 → 47 | 47 → 53 |
| **Total /600** | **353 → 385** | **388 → 426** |

The evidence includes the automated rules and network runs, seeded comparisons, fixed-rate clips, and software-rendered frame timings. The remaining 25 points per game require mixed-age human play. Physical hardware and guest animation cadence still need direct observation.

The exploratory full-menu sweep at 1024×576 with a simulated 120 px inset flagged 44 checks on the baseline and 41 on the candidate. The remaining failures include menu button placement, playfield framing, and overlapping results actions. The focused Spin Cycle hit and cue test at that same inset passed all 15 checks. All six packs rebuilt and all eight games rendered in a clean core.

The final automated rules, layout, touch, LAN, and pack checks passed. The Chrome LAN guest check passed in a separate run against the same final source after the combined run stopped between the pack and browser checks.
