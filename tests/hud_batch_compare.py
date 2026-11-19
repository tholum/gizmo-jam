#!/usr/bin/env python3
"""Per-pixel comparison of two tests/hud_batch_shots.gd output folders.

    python3 tests/hud_batch_compare.py BEFORE_DIR AFTER_DIR [--crops OUT_DIR]

For every PNG present in both folders (same relative path) prints the max and
mean absolute per-channel difference, how many pixels differ by more than 2,
8 and 32 levels, and the bounding box of the worst pixels. With --crops it
also writes, per page, a side-by-side crop (before | after | diff x8) around
the worst pixel, for a human to look at.

Exit status 1 if any page has a pixel differing by more than --fail (default
64 levels), the size of a visible change rather than antialiasing noise.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("before")
    ap.add_argument("after")
    ap.add_argument("--crops")
    ap.add_argument("--fail", type=int, default=64)
    args = ap.parse_args()
    before, after = Path(args.before), Path(args.after)
    crops = Path(args.crops) if args.crops else None
    if crops:
        crops.mkdir(parents=True, exist_ok=True)
    worst = 0
    pages = sorted(p.relative_to(before) for p in before.rglob("*.png"))
    if not pages:
        print("no PNGs under", before)
        return 1
    for rel in pages:
        other = after / rel
        if not other.exists():
            print(f"{rel}: missing in {after}")
            worst = 999
            continue
        a = np.asarray(Image.open(before / rel).convert("RGB")).astype(np.int16)
        b = np.asarray(Image.open(other).convert("RGB")).astype(np.int16)
        if a.shape != b.shape:
            print(f"{rel}: size {a.shape} vs {b.shape}")
            worst = 999
            continue
        d = np.abs(a - b)
        per_px = d.max(axis=2)
        mx = int(d.max())
        worst = max(worst, mx)
        counts = [int((per_px > t).sum()) for t in (2, 8, 32)]
        line = (f"{str(rel):28s} max={mx:3d} mean={d.mean():.5f} "
                f"px>2={counts[0]:6d} px>8={counts[1]:5d} px>32={counts[2]:4d}")
        if mx > 0:
            ys, xs = np.nonzero(per_px == mx)
            line += f" worst@({xs[0]},{ys[0]})"
        print(line)
        if crops and mx > 0:
            ys, xs = np.nonzero(per_px == mx)
            cx, cy = int(xs[0]), int(ys[0])
            h, w = per_px.shape
            x0, y0 = max(0, cx - 40), max(0, cy - 40)
            x1, y1 = min(w, cx + 40), min(h, cy + 40)
            tiles = [a[y0:y1, x0:x1], b[y0:y1, x0:x1], np.clip(d[y0:y1, x0:x1] * 8, 0, 255)]
            strip = np.concatenate(tiles, axis=1).astype(np.uint8)
            img = Image.fromarray(strip).resize((strip.shape[1] * 4, strip.shape[0] * 4), Image.NEAREST)
            img.save(crops / (str(rel).replace("/", "_")))
    print(f"WORST {worst}")
    return 1 if worst > args.fail else 0


if __name__ == "__main__":
    sys.exit(main())
