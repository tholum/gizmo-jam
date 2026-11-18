#!/usr/bin/env python3
"""Export native desktop builds and game packs with Godot 4.5.1.

    tools/build.py                       every desktop platform
    tools/build.py --platform linux      one platform
    tools/build.py --pack example        the game pack for games/example/
    tools/build.py --pack example --dev-install
                                         ...and copy it to user://dev-games, where
                                         the game loads it in developer mode
    tools/build.py --packs               a pack for every game in games/

Packs are written to builds/packs/<id>-<version>.pck. The core builds leave
out games/ (built-in games live in scripts/), so packs never ship inside them.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--godot", default=os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4") or str(ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64"))
parser.add_argument("--platform", choices=["all", "linux", "windows", "macos"], default="all")
parser.add_argument("--pack", action="append", default=[], metavar="ID", help="build the game pack for games/ID (repeatable)")
parser.add_argument("--packs", action="store_true", help="build a pack for every game in games/")
parser.add_argument("--dev-install", action="store_true", help="also install each pack as a developer pack")
args = parser.parse_args()
base = [args.godot, "--headless", "--path", str(ROOT)]
subprocess.run(base + ["--editor", "--import", "--quit"], check=True)

PACK_PRESET = "GamePack"


def pack_preset(game_id, index):
    """An export preset that keeps only games/<id>/ (plus what Godot converts)."""
    excluded = []
    for entry in sorted(ROOT.iterdir()):
        if entry.name.startswith(".") or entry.name == "games":
            continue
        excluded.append(entry.name + "/*" if entry.is_dir() else entry.name)
    for other in sorted((ROOT / "games").iterdir()):
        if other.is_dir() and other.name != game_id:
            excluded.append(f"games/{other.name}/*")
    return f"""
[preset.{index}]
name="{PACK_PRESET}"
platform="Linux"
runnable=false
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter="games/{game_id}/game.json"
exclude_filter="{",".join(excluded)}"
export_path=""
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false
script_export_mode=2

[preset.{index}.options]
custom_template/debug=""
custom_template/release=""
binary_format/embed_pck=false
binary_format/architecture="x86_64"
texture_format/s3tc_bptc=true
texture_format/etc2_astc=false
"""


def build_pack(game_id):
    game = json.loads((ROOT / "games" / game_id / "game.json").read_text())
    out_dir = ROOT / "builds" / "packs"
    out_dir.mkdir(parents=True, exist_ok=True)
    raw = out_dir / f"{game_id}.raw.pck"
    out = out_dir / f"{game_id}-{game['version']}.pck"
    presets = ROOT / "export_presets.cfg"
    original = presets.read_text()
    index = len(re.findall(r"^\[preset\.\d+\]$", original, re.M))
    try:
        presets.write_text(original.rstrip("\n") + "\n" + pack_preset(game_id, index))
        subprocess.run(base + ["--export-pack", PACK_PRESET, str(raw)], check=True)
    finally:
        presets.write_text(original)
    tool = base + ["--script", "res://tools/pack_tool.gd", "--", str(raw), str(out), game_id]
    if args.dev_install:
        tool.append("--dev-install")
    subprocess.run(tool, check=True)
    raw.unlink()
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"{out}  size={out.stat().st_size}  sha256={digest}")
    return out


pack_ids = list(args.pack)
if args.packs:
    pack_ids += sorted(p.name for p in (ROOT / "games").iterdir() if (p / "game.json").exists())
if pack_ids:
    for game_id in pack_ids:
        build_pack(game_id)
    raise SystemExit(0)
targets = {"linux": ("Linux", "GizmoJam.x86_64"),
           "windows": ("Windows", "GizmoJam.exe"),
           "macos": ("macOS", "GizmoJam.zip")}
for platform, (preset, name) in targets.items():
    if args.platform not in ("all", platform):
        continue
    folder = ROOT / "builds" / platform
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(base + ["--export-release", preset, str(folder / name)], check=True)
    shutil.copy2(ROOT / "README.md", folder / "README.txt")
    shutil.copy2(ROOT / "assets/fonts/LICENSE.txt", folder / "FONT-LICENSE.txt")
    shutil.copy2(ROOT / "assets/meshy/README.md", folder / "ASSET-CREDITS.txt")
    if platform == "linux":
        (folder / name).chmod(0o755)
    if platform != "macos":
        archive = ROOT / "builds" / ("GizmoJam-" + platform + ".zip")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
            for file in folder.iterdir():
                if file.is_file():
                    output.write(file, arcname=file.name)
        print(archive)
    else:
        with zipfile.ZipFile(folder / name, "a", zipfile.ZIP_DEFLATED) as output:
            output.write(folder / "README.txt", arcname="README.txt")
            output.write(folder / "FONT-LICENSE.txt", arcname="FONT-LICENSE.txt")
            output.write(folder / "ASSET-CREDITS.txt", arcname="ASSET-CREDITS.txt")
        print(folder / name)
