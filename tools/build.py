#!/usr/bin/env python3
"""Export native desktop builds and game packs with Godot 4.5.1.

    tools/build.py                       every desktop platform
    tools/build.py --platform linux      one platform
    tools/build.py --pack example        the game pack for games/example/
    tools/build.py --pack example --dev-install
                                         ...and copy it to user://dev-games, where
                                         the game loads it in developer mode
    tools/build.py --packs               a pack for every game in games/
    tools/build.py --web                 the browser build party hosts serve, in
                                         builds/web/ and as builds/GizmoJam-web-<version>.zip
    tools/build.py --android             the Android store app (.aab) and a sideload .apk,
                                         in builds/android/, with every published game built in

The Android app bundles exactly the games in the live signed catalog (pass
--bundle ID to choose by hand, --bundle none for only the built-in games), and
checks that each one's game.json matches the version that was published. Its
version code is build * 10000 + catalog serial * 10 + revision (--android-revision,
normally 0), so it rises with every core release and every game release. It is signed with the upload key named in
~/.config/gizmo-jam/android-upload.env (never in the repo); Google Play
re-signs it with the release key.

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
parser.add_argument("--web", action="store_true", help="build the browser version party hosts serve")
parser.add_argument("--android", action="store_true", help="build the Android store app (.aab) and a sideload .apk")
parser.add_argument("--bundle", action="append", default=[], metavar="ID",
                    help="Android: bundle games/ID instead of the live catalog's games (repeatable; 'none' for none)")
parser.add_argument("--serial", type=int, help="Android: catalog serial for the version code (default: the live catalog's)")
parser.add_argument("--android-revision", type=int, default=0, metavar="N",
                    help="Android: 0-9, for a rebuild of the same core and catalog (Play never takes a version code twice)")
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


def build_web():
    """The browser build: single-threaded, a shell that runs from a plain-HTTP
    LAN address (see web/shell.html). The zip is flat; the game unpacks it
    and checks every name (pack_manager.gd)."""
    folder = ROOT / "builds" / "web"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    subprocess.run(base + ["--export-release", "Web", str(folder / "index.html")], check=True)
    version = re.search(r'^config/version="([^"]+)"', (ROOT / "project.godot").read_text(), re.M).group(1)
    archive = ROOT / "builds" / f"GizmoJam-web-{version}.zip"
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
        for file in sorted(folder.iterdir()):
            if file.is_file():
                output.write(file, arcname=file.name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    print(f"{archive}  size={archive.stat().st_size}  sha256={digest}")
    return archive


ANDROID_ENV = Path.home() / ".config/gizmo-jam/android-upload.env"


def android_signing():
    """Godot reads the release keystore from these environment variables."""
    if not ANDROID_ENV.exists():
        raise SystemExit(f"{ANDROID_ENV} not found: it names the upload keystore (see docs/specs/mobile-apps-and-touch.md, 7.1)")
    if ANDROID_ENV.stat().st_mode & 0o077:
        raise SystemExit(f"{ANDROID_ENV} is readable by other users; chmod 600 it")
    env = dict(os.environ)
    for line in ANDROID_ENV.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            name, value = line.split("=", 1)
            env[name.strip()] = value.strip()
    return env


def android_bundle():
    """(game ids to bundle, catalog serial). The live catalog decides, so the app
    carries exactly what desktop players can get, at the published versions."""
    import sys
    sys.path.insert(0, str(ROOT / "tools"))
    import release
    import release_games
    live = release_games.live_catalog(release.PUBLIC_BASE + "/" + release_games.catalog_key("stable"), release.embedded_keys())
    serial = int(live["serial"]) if live else 0
    published = (live or {}).get("games", {})
    if args.bundle:
        ids = [] if args.bundle == ["none"] else list(args.bundle)
    else:
        ids = sorted(published)
    for game_id in ids:
        game_file = ROOT / "games" / game_id / "game.json"
        if not game_file.exists():
            raise SystemExit(f"cannot bundle {game_id}: games/{game_id}/game.json is not in this tree")
        game = json.loads(game_file.read_text())
        if game.get("publish") is False:
            raise SystemExit(f"cannot bundle {game_id}: its game.json says \"publish\": false")
        if game_id in published and not args.bundle:
            for field in ("version", "net"):
                if game.get(field) != published[game_id].get(field):
                    raise SystemExit(f"games/{game_id} is {field} {game.get(field)!r} but the catalog published "
                                     f"{published[game_id].get(field)!r}; publish it first (tools/release_games.py)")
    return ids, (args.serial if args.serial is not None else serial)


# Exactly what the Play declarations and the privacy policy allow; see
# docs/specs/mobile-apps-and-touch.md, 13.3. A new permission needs those
# updated first, then this list.
ANDROID_PERMISSIONS = {"android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE",
                       "android.permission.ACCESS_WIFI_STATE", "android.permission.CHANGE_WIFI_MULTICAST_STATE"}


# Hardware Android would otherwise require: landscape (from the landscape-only
# activity) and Wi-Fi (implied by the Wi-Fi permissions). Neither is needed to
# install: solo play needs no Wi-Fi, and every phone turns sideways. Google
# Play refuses to send a release for review while they restrict devices.
OPTIONAL_FEATURES = ["android.hardware.screen.landscape", "android.hardware.wifi"]
TEMPLATE_MANIFEST = ROOT / "android/build/AndroidManifest.xml"


def patch_android_manifest():
    """Marks OPTIONAL_FEATURES optional in the Gradle template's manifest, which
    Gradle merges into every export. android/ is not committed (Godot installs
    it), so this runs on every build. Returns True when it changed the file."""
    if not TEMPLATE_MANIFEST.exists():
        return False
    text = TEMPLATE_MANIFEST.read_text()
    missing = [f for f in OPTIONAL_FEATURES if f'android:name="{f}"' not in text]
    if not missing:
        return False
    lines = "".join(f'\n    <uses-feature android:name="{f}" android:required="false" />' for f in missing)
    text = re.sub(r"(<uses-feature\s+android:glEsVersion[^>]*/>)", lambda m: m.group(1) + lines, text, count=1)
    if not all(f'android:name="{f}"' in text for f in OPTIONAL_FEATURES):
        raise SystemExit(f"could not mark hardware features optional in {TEMPLATE_MANIFEST}")
    TEMPLATE_MANIFEST.write_text(text)
    return True


def check_android_permissions(apk):
    tools = sorted((Path.home() / "Android/Sdk/build-tools").glob("*/aapt2"))
    if not tools:
        raise SystemExit("aapt2 not found in ~/Android/Sdk/build-tools; cannot check the app's permissions")
    badging = subprocess.run([str(tools[-1]), "dump", "badging", str(apk)], check=True, capture_output=True, text=True).stdout
    found = set(re.findall(r"^uses-permission: name='([^']+)'", badging, re.M))
    if found != ANDROID_PERMISSIONS:
        raise SystemExit("Android permissions differ from the store declarations (spec 13.3): "
                         f"extra {sorted(found - ANDROID_PERMISSIONS)}, missing {sorted(ANDROID_PERMISSIONS - found)}")
    required = set(re.findall(r"^\s*uses-(?:implied-)?feature: name='([^']+)'", badging, re.M))
    blocked = sorted(required & set(OPTIONAL_FEATURES))
    if blocked:
        raise SystemExit(f"the app requires {blocked}; Google Play will not send it for review (see OPTIONAL_FEATURES)")
    print("Android permissions match the store declarations; no needless hardware requirements.")


def build_android():
    """The Android app: an .aab for Google Play and an .apk to sideload, both
    signed with the upload key. Patches the Android preset for this build only."""
    ids, serial = android_bundle()
    text = (ROOT / "project.godot").read_text()
    version = re.search(r'^config/version="([^"]+)"', text, re.M).group(1)
    build = int(re.search(r"^config/build=(\d+)", text, re.M).group(1))
    if serial >= 1000:
        raise SystemExit("catalog serial is 1000 or more; change the version-code rule in tools/build.py")
    if not 0 <= args.android_revision <= 9:
        raise SystemExit("--android-revision must be 0 to 9")
    code = build * 10000 + serial * 10 + args.android_revision
    env = android_signing()
    presets = ROOT / "export_presets.cfg"
    original = presets.read_text()
    match = re.search(r'^\[preset\.(\d+)\]\s*\nname="Android"', original, re.M)
    if not match:
        raise SystemExit('export_presets.cfg has no "Android" preset')
    index = match.group(1)
    head, options = f"[preset.{index}]", f"[preset.{index}.options]"
    folder = ROOT / "builds" / "android"
    folder.mkdir(parents=True, exist_ok=True)
    outputs = {}
    try:
        for fmt, ext in ((1, "aab"), (0, "apk")):
            patched = original
            start = patched.index(head)
            end = patched.find("\n[preset.", patched.index(options) + 1)
            end = len(patched) if end < 0 else end
            section = patched[start:end]
            # Leave out every game folder except the bundled ones.
            others = [f"games/{p.name}/*" for p in sorted((ROOT / "games").iterdir()) if p.is_dir() and p.name not in ids]
            section = re.sub(r'^exclude_filter="([^"]*)"',
                             lambda m: 'exclude_filter="' + ",".join([f for f in m.group(1).split(",") if f != "games/*"] + others) + '"',
                             section, count=1, flags=re.M)
            section = re.sub(r"^version/code=.*$", f"version/code={code}", section, count=1, flags=re.M)
            section = re.sub(r'^version/name=.*$', f'version/name="{version}"', section, count=1, flags=re.M)
            section = re.sub(r"^gradle_build/export_format=.*$", f"gradle_build/export_format={fmt}", section, count=1, flags=re.M)
            presets.write_text(patched[:start] + section + patched[end:])
            out = folder / f"GizmoJam-{version}.{ext}"
            if out.exists():
                out.unlink()
            # Godot reinstalls the template (undoing the manifest patch) on every
            # export given --install-android-build-template, so pass it only
            # when the template is missing, then patch and export again.
            export = base + ["--export-release", "Android", str(out)]
            if not TEMPLATE_MANIFEST.exists():
                subprocess.run(base + ["--install-android-build-template", "--export-release", "Android", str(out)],
                               check=True, env=env)
                out.unlink(missing_ok=True)
            patch_android_manifest()
            subprocess.run(export, check=True, env=env)
            if not out.exists():
                raise SystemExit(f"Godot did not write {out}")
            outputs[ext] = out
    finally:
        presets.write_text(original)
    check_android_permissions(outputs["apk"])
    print(f"Android {version} (version code {code}), games bundled: {', '.join(ids) or 'built-in only'}")
    for out in outputs.values():
        print(f"{out}  size={out.stat().st_size}  sha256={hashlib.sha256(out.read_bytes()).hexdigest()}")
    # What tools/play_publish.py uploads, and how it was built.
    aab = outputs["aab"]
    aab.with_suffix(".json").write_text(json.dumps({
        "version": version, "build": build, "version_code": code, "catalog_serial": serial, "games": ids,
        "sha256": hashlib.sha256(aab.read_bytes()).hexdigest()}, indent=2) + "\n")
    return outputs, code


if args.web:
    build_web()
    raise SystemExit(0)
if args.android:
    build_android()
    raise SystemExit(0)

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
