#!/usr/bin/env python3
"""Cross-version online rounds: this build against Gizmo Jam 0.2.0.

Every build must keep hosting, joining and playing the built-in games with
0.2.0 (protocol 2, no capabilities). This runs tests/online_round.gd (one Live
Wire round: register, game switch, steering, a mid-round quit, results,
lobby) with the roles split between this tree and the 0.2.0 source, in both
directions, and fails on any ERROR line from either side.

The 0.2.0 source is taken from git (commit 62ed1fe by default) into a temporary
folder and imported once. `--binary PATH` also runs the published 0.2.0
executable as the old side.
"""
import argparse
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--godot", default=os.environ.get("GODOT", str(ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64")))
parser.add_argument("--old", default="62ed1fe", help="git revision of the old release (default: 0.2.0)")
parser.add_argument("--binary", help="also run this exported old build as the old side")
args = parser.parse_args()

# Lines both sides log in every run that are not caused by the mix. Godot
# prints the first at exit when a node is freed with a signal still pointed
# at it; it appears in all-0.2.0 runs too.
KNOWN = ["Attempt to disconnect a nonexistent connection"]


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def command(side, role, port):
    kind, where = side
    tail = ["--script", "res://tests/online_round.gd", "--", f"--role={role}", f"--port={port}"]
    if kind == "binary":
        # An exported build has no res://tests; give it the old tree's script.
        return [where[0], "--headless", "--audio-driver", "Dummy", "--script", str(where[1] / "tests/online_round.gd"), "--", f"--role={role}", f"--port={port}"]
    return [args.godot, "--headless", "--path", str(where), "--audio-driver", "Dummy"] + tail


def run(label, sides, folder):
    port = free_port()
    processes = []
    try:
        for role, side in zip(["host", "player", "quitter"], sides):
            log = open(Path(folder) / f"{label}-{role}.log", "w+")
            processes.append((role, side, subprocess.Popen(command(side, role, port), stdout=log, stderr=subprocess.STDOUT), log))
            time.sleep(1.0 if role == "host" else 0.5)
        ok = True
        for role, side, process, log in processes:
            try:
                code = process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                code = -1
            log.seek(0)
            output = log.read()
            errors = [l for l in output.splitlines() if "ERROR" in l and not any(k in l for k in KNOWN)]
            passed = code == 0 and f"ONLINE_{role.upper()}_PASS" in output and not errors
            print(f"  {label} {role} ({side[0]}): {'pass' if passed else 'FAIL'}")
            if not passed:
                ok = False
                print(output)
        return ok
    finally:
        for role, side, process, log in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            log.close()


with tempfile.TemporaryDirectory(prefix="gizmojam-compat-") as folder:
    old = Path(folder) / "old"
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
    new_side = ("new", ROOT)
    old_side = ("old", old)
    runs = [
        ("new-host", [new_side, old_side, new_side]),
        ("old-host", [old_side, new_side, new_side]),
        ("old-guests", [new_side, old_side, old_side]),
    ]
    if args.binary:
        binary = ("binary", (str(Path(args.binary).resolve()), old))
        runs += [("binary-guest", [new_side, binary, new_side]), ("binary-host", [binary, new_side, new_side])]
    results = [run(label, sides, folder) for label, sides in runs]
    if not all(results):
        raise SystemExit("Cross-version online round failed")
print("COMPAT PASS")
