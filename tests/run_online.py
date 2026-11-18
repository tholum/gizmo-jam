#!/usr/bin/env python3
"""One online Live Wire round between three real copies of the game.

Each process runs the production main scene; see tests/online_round.gd for the
script they follow and what is checked. Headless by default. To also save what
the joining player sees (test-output/online-*.png), give the three windows a
display:

    xvfb-run -a python3 tests/run_online.py --shots
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
parser.add_argument("--shots", action="store_true", help="render windows and save the player's screenshots")
args = parser.parse_args()
base = [args.godot, "--path", str(ROOT), "--audio-driver", "Dummy"]
if not args.shots:
    base.insert(1, "--headless")

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]

ROLES = ["host", "player", "quitter"]
processes = []
with tempfile.TemporaryDirectory(prefix="gizmojam-online-") as folder:
    try:
        for role in ROLES:
            log = open(Path(folder) / f"{role}.log", "w+")
            command = base + ["--script", "res://tests/online_round.gd", "--", f"--role={role}", f"--port={port}"]
            if args.shots:
                command.append("--shots")
            processes.append((role, subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT), log))
            # The host must be listening first, and the player takes the seat before the quitter.
            time.sleep(1.0 if role == "host" else 0.5)
        failed = False
        for role, process, log in processes:
            try:
                code = process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                code = -1
            log.seek(0)
            output = log.read()
            print(f"{role}:\n{output}")
            if code or f"ONLINE_{role.upper()}_PASS" not in output or "ERROR:" in output:
                failed = True
        if failed:
            raise SystemExit("Online Live Wire round failed")
    finally:
        for role, process, log in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            log.close()
print("ONLINE ROUND PASS")
