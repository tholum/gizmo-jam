#!/usr/bin/env python3
"""Game packs in real parties: downloads, trust, and sitting out.

Builds the example game pack (tools/build.py --pack example), signs a test
catalog for it with a throwaway key, and runs two parties of three processes
(tests/pack_round.gd):

  signed  host with the pack installed, a guest without it, and a real
          Gizmo Jam 0.2.0 guest (tests/legacy_guest.gd in the 0.2.0 source)
  dev     host with the pack as an unsigned developer pack, a guest in
          developer mode and one without

Each process gets its own packs folder (--packs-dir) and trusts only the
test key. No real catalog, key or settings file is touched.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import release  # noqa: E402  (signing helpers)

parser = argparse.ArgumentParser()
parser.add_argument("--godot", default=os.environ.get("GODOT", str(ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64")))
parser.add_argument("--old", default="62ed1fe", help="git revision of 0.2.0")
parser.add_argument("--scenario", choices=["all", "signed", "dev", "web"], default="all")
parser.add_argument("--no-build", action="store_true", help="reuse builds/packs/example-*.pck")
parser.add_argument("--exported", help="an exported debug build of this tree to run as host and guest instead of the source")
args = parser.parse_args()
KNOWN = ["Attempt to disconnect a nonexistent connection"]


def free_port(kind):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def build_pack():
    game = json.loads((ROOT / "games/example/game.json").read_text())
    out = ROOT / "builds/packs" / f"example-{game['version']}.pck"
    if not args.no_build or not out.exists():
        subprocess.run([sys.executable, str(ROOT / "tools/build.py"), "--godot", args.godot, "--pack", "example"],
                       check=True, stdout=subprocess.DEVNULL)
    return game, out


def signed_catalog(game, pack, key):
    data = pack.read_bytes()
    catalog = {"schema": 1, "game": "gizmo-jam", "kind": "catalog", "channel": "stable", "serial": 1,
               "games": {"example": {"version": game["version"], "net": game["net"], "core_min": game["core_min"],
                                     "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                                     "url": "http://127.0.0.1:9/example.pck",
                                     "info": {k: game["info"][k] for k in ("number", "title", "tags", "blurb")}}}}
    return release.sign_manifest(catalog, key)


def install_signed(folder, game, pack, envelope):
    sha = hashlib.sha256(pack.read_bytes()).hexdigest()
    games = folder / "packs" / "games" / "example"
    games.mkdir(parents=True)
    shutil.copy2(pack, games / f"{sha}.pck")
    (folder / "packs" / "catalog.json").write_text(json.dumps(envelope))
    (folder / "packs" / "index.json").write_text(json.dumps({"example": {
        "sha256": sha, "size": pack.stat().st_size, "version": game["version"], "net": game["net"]}}))


def run_party(label, roles, folder):
    """roles: (role, tree, extra args). Returns True if every role passed."""
    port = free_port(socket.SOCK_DGRAM)
    file_port = free_port(socket.SOCK_STREAM)
    browser_port = free_port(socket.SOCK_STREAM)
    processes = []
    try:
        for role, tree, extra in roles:
            log = open(folder / f"{label}-{role}.log", "w+")
            tail = ["--", f"--role={role}", f"--scenario={label}", f"--port={port}", f"--file-port={file_port}",
                    f"--browser-port={browser_port}", f"--page-origin=http://127.0.0.1:{file_port}"] + extra
            if tree == ROOT and args.exported:
                # An exported build has no res://tests; its core checks run for real.
                command = [args.exported, "--headless", "--audio-driver", "Dummy", "--script", str(ROOT / "tests/pack_round.gd")] + tail
            else:
                script = "res://tests/pack_round.gd" if tree == ROOT else str(ROOT / "tests/legacy_guest.gd")
                command = [args.godot, "--headless", "--path", str(tree), "--audio-driver", "Dummy", "--script", script] + tail
            processes.append((role, subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT), log))
            time.sleep(1.5 if role == "host" else 0.6)
        ok = True
        for role, process, log in processes:
            try:
                code = process.wait(timeout=150)
            except subprocess.TimeoutExpired:
                code = -1
            log.seek(0)
            output = log.read()
            errors = [l for l in output.splitlines() if "ERROR" in l and not any(k in l for k in KNOWN)]
            passed = code == 0 and f"PACK_{role.upper()}_PASS" in output and not errors
            print(f"  {label} {role}: {'pass' if passed else 'FAIL'}")
            if not passed:
                ok = False
                print(output)
        return ok
    finally:
        for role, process, log in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            log.close()


game, pack = build_pack()
results = []
with tempfile.TemporaryDirectory(prefix="gizmojam-packs-") as tmp:
    folder = Path(tmp)
    key = folder / "test-signing.key"
    release.generate_key(key)
    public = folder / "test-signing.pub"
    public.write_text(release.public_pem(key))
    trust = [f"--trust-key={public}", "--catalog-url=http://127.0.0.1:9/catalog.json", "--no-update-check"]
    if args.scenario in ("all", "signed"):
        old = folder / "old"
        old.mkdir()
        archive = subprocess.run(["git", "-C", str(ROOT), "archive", args.old], check=True, stdout=subprocess.PIPE).stdout
        subprocess.run(["tar", "-x", "-C", str(old)], input=archive, check=True)
        # Godot sometimes crashes on exit after an import; what matters is the cache.
        for attempt in range(2):
            subprocess.run([args.godot, "--headless", "--path", str(old), "--editor", "--import", "--quit"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
            if (old / ".godot" / "global_script_class_cache.cfg").exists() or (old / ".godot" / "uid_cache.bin").exists():
                break
        else:
            raise SystemExit("could not import the old release")
        envelope = signed_catalog(game, pack, key)
        install_signed(folder / "s-host", game, pack, envelope)
        results.append(run_party("signed", [
            ("host", ROOT, [f"--packs-dir={folder / 's-host'}"] + trust),
            ("guest", ROOT, [f"--packs-dir={folder / 's-guest'}"] + trust),
            ("legacy", old, []),
        ], folder))
    if args.scenario in ("all", "dev"):
        dev = folder / "d-host" / "dev-games"
        dev.mkdir(parents=True)
        shutil.copy2(pack, dev / "example.pck")
        results.append(run_party("dev", [
            ("host", ROOT, [f"--packs-dir={folder / 'd-host'}", "--dev-mode"] + trust),
            ("devguest", ROOT, [f"--packs-dir={folder / 'd-dev'}", "--dev-mode"] + trust),
            ("nodev", ROOT, [f"--packs-dir={folder / 'd-nodev'}"] + trust),
        ], folder))
    if args.scenario in ("all", "web"):
        if args.scenario == "web":
            envelope = signed_catalog(game, pack, key)
        install_signed(folder / "w-host", game, pack, envelope)
        page = folder / "w-page"
        page.mkdir()
        (page / "index.html").write_text("<!doctype html><title>Gizmo Jam</title>")
        results.append(run_party("web", [
            ("host", ROOT, [f"--packs-dir={folder / 'w-host'}", f"--web-dir={page}"] + trust),
            ("guest", ROOT, [f"--packs-dir={folder / 'w-guest'}"] + trust),
            ("webguest", ROOT, [f"--packs-dir={folder / 'w-web'}"] + trust),
        ], folder))
if not all(results):
    raise SystemExit("Pack parties failed")
print("PACKS PASS")
