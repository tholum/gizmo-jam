#!/usr/bin/env python3
"""Export native desktop builds with Godot 4.5.1 and installed export templates."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--godot", default=os.environ.get("GODOT") or shutil.which("godot") or shutil.which("godot4") or str(ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64"))
parser.add_argument("--platform", choices=["all", "linux", "windows", "macos"], default="all")
args = parser.parse_args()
base = [args.godot, "--headless", "--path", str(ROOT)]
subprocess.run(base + ["--editor", "--import", "--quit"], check=True)
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
