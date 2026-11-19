#!/usr/bin/env python3
"""A host with two players on one screen (keyboard + a second gamepad) and a
remote guest play one online Live Wire round, as two real copies of the game.
See tests/gamepad_online.gd for what each side checks."""
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
args = parser.parse_args()
base = [args.godot, "--headless", "--path", str(ROOT), "--audio-driver", "Dummy"]

with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]

processes = []
with tempfile.TemporaryDirectory(prefix="gizmojam-pads-") as folder:
    try:
        for role in ["host", "guest"]:
            log = open(Path(folder) / f"{role}.log", "w+")
            command = base + ["--script", "res://tests/gamepad_online.gd", "--", f"--role={role}", f"--port={port}"]
            processes.append((role, subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT), log))
            time.sleep(1.5 if role == "host" else 0.0)
        failed = False
        for role, process, log in processes:
            try:
                code = process.wait(timeout=90)
            except subprocess.TimeoutExpired:
                code = -1
            log.seek(0)
            output = log.read()
            print(f"{role}:\n{output}")
            if code or f"GAMEPAD_ONLINE_{role.upper()}_PASS" not in output or "ERROR:" in output:
                failed = True
        if failed:
            raise SystemExit("Gamepad online round failed")
    finally:
        for role, process, log in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            log.close()
print("GAMEPAD ONLINE PASS")
