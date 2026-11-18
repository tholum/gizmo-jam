#!/usr/bin/env python3
"""A real browser guest: headless Chrome joins a party hosted by this tree.

Exports the browser build (tools/build.py --web) unless --no-build, starts a
host (tests/pack_round.gd, scenario "browser") that serves it on this
machine's LAN address, then opens http://<LAN IP>:<port>/?name=BROWSER&join=1
in headless Chrome (tests/browser_guest.mjs). The page is a plain-HTTP LAN
address, as in a real party, so it also checks the shell's workarounds for
browsers' secure-context rules. The host checks that the page loaded from it,
joined over a WebSocket, was launched into a round, and that its Space presses
reached its seat.

Needs Node 22 and Google Chrome (CHROME=path to override). Screenshots and
the browser console go to test-output/browser/.
"""
import argparse
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--godot", default=os.environ.get("GODOT", str(ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64")))
parser.add_argument("--no-build", action="store_true")
args = parser.parse_args()


def free_port(kind):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("0.0.0.0", 0))
        return sock.getsockname()[1]


def lan_ip():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.connect(("10.255.255.255", 1))
            return sock.getsockname()[0]
        except OSError:
            return "127.0.0.1"


if not shutil.which("node"):
    raise SystemExit("node not found")
if not args.no_build or not (ROOT / "builds/web/index.html").exists():
    subprocess.run([sys.executable, str(ROOT / "tools/build.py"), "--godot", args.godot, "--web"], check=True, stdout=subprocess.DEVNULL)
out = ROOT / "test-output/browser"
shutil.rmtree(out, ignore_errors=True)
out.mkdir(parents=True)
ip = lan_ip()
port, file_port, browser_port, debug_port = free_port(socket.SOCK_DGRAM), free_port(socket.SOCK_STREAM), free_port(socket.SOCK_STREAM), free_port(socket.SOCK_STREAM)
with tempfile.TemporaryDirectory(prefix="gizmojam-browser-") as folder:
    host_log = open(out / "host.log", "w+")
    host = subprocess.Popen([args.godot, "--headless", "--path", str(ROOT), "--audio-driver", "Dummy",
                             "--script", "res://tests/pack_round.gd", "--", "--role=host", "--scenario=browser",
                             f"--port={port}", f"--file-port={file_port}", f"--browser-port={browser_port}",
                             f"--packs-dir={folder}", f"--web-dir={ROOT / 'builds/web'}", "--no-update-check"],
                            stdout=host_log, stderr=subprocess.STDOUT)
    print(f"host pid {host.pid}")
    browser = None
    try:
        time.sleep(3)
        url = f"http://{ip}:{file_port}/?name=BROWSER&join=1"
        print(f"browser opens {url}")
        browser = subprocess.Popen(["node", str(ROOT / "tests/browser_guest.mjs"), url, "35", str(out), str(debug_port)])
        code = host.wait(timeout=150)
    except subprocess.TimeoutExpired:
        code = -1
    finally:
        if host.poll() is None:
            host.kill()
            host.wait()
        if browser:
            try:
                browser.wait(timeout=90)
            except subprocess.TimeoutExpired:
                browser.kill()
                browser.wait()
    host_log.seek(0)
    output = host_log.read()
    host_log.close()
print(output)
console = (out / "console.log").read_text() if (out / "console.log").exists() else ""
print("browser console (tail):\n" + "\n".join(console.splitlines()[-25:]))
errors = [l for l in output.splitlines() if "ERROR" in l and "nonexistent connection" not in l]
if code != 0 or "PACK_HOST_PASS" not in output or errors:
    raise SystemExit("Browser guest test failed")
print("BROWSER GUEST PASS")
