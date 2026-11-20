#!/usr/bin/env python3
"""Gameplay assertions for both games plus two real multi-process ENet tests.

The six-process test starts the server, sends one client with an old protocol
number (it must be turned away with the version message), then five real
clients. See tests/network_peer.gd for what the six peers check.

The last stages are online Live Wire rounds between real copies of the game
scene, driven through its buttons, key and gamepad events: three machines
(tests/run_online.py), then a host with two players on its screen and a guest
(tests/run_gamepad_online.py). tests/test_gamepads.gd covers several gamepads
on one machine offline.

LAN discovery is checked between two real game processes, once over loopback
with junk packets sprayed at the listener and once by real broadcast.
"""
import argparse
import json
import os
import shutil
from pathlib import Path
import json
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
# Hide real gamepads from every Godot the tests start (and the scripts they
# run inherit it): a controller on the desk must not move test players. The
# gamepad tests drive simulated pads instead.
os.environ.setdefault("SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT", "0x0001/0x0001")
parser = argparse.ArgumentParser()
parser.add_argument("--godot", default=os.environ.get("GODOT", str(ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64")))
args = parser.parse_args()
base = [args.godot, "--headless", "--audio-driver", "Dummy", "--path", str(ROOT)]

subprocess.run([sys.executable, str(ROOT / "tests/test_play_publish.py")], check=True)

def verify(result):
    print(result.stdout)
    if result.returncode or "SCRIPT ERROR" in result.stdout or "ERROR:" in result.stdout:
        raise SystemExit("Godot test failed")

verify(subprocess.run(base + ["--script", "res://tests/test_round.gd"], text=True,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20))
verify(subprocess.run(base + ["--script", "res://tests/test_livewire.gd"], text=True,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60))
for game_test in (
    "bumper_cars/tests/rules_test.gd",
    "sumo/tests/rules_test.gd",
    "orb_racing/tests/race_test.gd",
    "stampede_sheriff/tests/rules_test.gd",
    "plate_panic/tests/rules_test.gd",
    "salvage_line/tests/rules_test.gd",
    "salvage_line/tests/arena_test.gd",
    "popcorn_catch/tests/rules_test.gd",
    "knockdown_carnival/tests/rules_test.gd",
    "sky_stack/tests/rules_test.gd",
    "domino_dash/tests/rules_test.gd",
    "freezer_door/tests/rules_test.gd",
    "bandwagon/tests/rules_test.gd",
    "hat_clause/tests/rules_test.gd",
):
    verify(subprocess.run(base + ["--script", "res://games/" + game_test], text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60))
verify(subprocess.run(base + ["--script", "res://tests/test_presentation.gd"], text=True,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20))
# Several gamepads on one machine: joining, both games' controls, leaving.
pads = subprocess.run(base + ["--script", "res://tests/test_gamepads.gd"], text=True,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
verify(pads)
if "GAMEPAD_TESTS PASS" not in pads.stdout:
    raise SystemExit("Gamepad tests failed")
# Layout at every supported window size (geometry only when headless).
verify(subprocess.run(base + ["--script", "res://tests/screen_sizes.gd"], text=True,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120))
verify(subprocess.run(base + ["--script", "res://tests/screen_sizes.gd", "--", "--spin-hit-only",
                              "--handheld", "--safe-inset=120", "--sizes=1024x576"], text=True,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20))
verify(subprocess.run(base + ["--script", "res://tests/test_discovery.gd"], text=True,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30))
# Touch controls: real touch events on a phone (with and without a camera
# cut-out), and no touch layer on desktop.
for touch_args in (["--handheld"], ["--handheld", "--safe-inset=120"], []):
    touch = subprocess.run(base + ["--script", "res://tests/test_touch.gd", "--",
                                   "--no-update-check"] + touch_args, text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    verify(touch)
    if "TOUCH_TESTS_PASS" not in touch.stdout:
        raise SystemExit("Touch tests failed")

# Game packs: build the example pack, then the logic without a network.
subprocess.run([sys.executable, str(ROOT / "tools/build.py"), "--godot", args.godot, "--pack", "example"],
               check=True, stdout=subprocess.DEVNULL)
packs_unit = subprocess.run(base + ["--script", "res://tests/test_packs.gd"], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
verify(packs_unit)
if "PACK_TESTS PASS" not in packs_unit.stdout:
    raise SystemExit("Pack tests failed")

# Updater: Godot-side logic, plus envelopes signed by tools/release.py (openssl)
# with a throwaway key, checked by the game's verifier.
sys.path.insert(0, str(ROOT / "tools"))
import release  # noqa: E402
with tempfile.TemporaryDirectory(prefix="gizmojam-update-") as folder:
    folder = Path(folder)
    key = folder / "fixture.key"
    subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(key)],
                   check=True, capture_output=True)
    (folder / "public.pem").write_text(release.public_pem(key))
    (folder / "key_id.txt").write_text(release.key_id(key))
    (folder / "GizmoJam-Linux.x86_64").write_bytes(b"linux build")
    manifest = release.build_manifest("1.2.3", 7, {"GizmoJam-Linux.x86_64": folder / "GizmoJam-Linux.x86_64"},
                                      "https://example.invalid/releases/1.2.3", "Openssl-signed · ünïcode notes", "test")
    envelope = release.sign_manifest(manifest, key)
    release.verify_envelope(envelope, {release.key_id(key): release.public_pem(key)})
    (folder / "good.json").write_text(json.dumps(envelope))
    manifest["build"] = 8
    envelope["payload"] = release.base64.b64encode(json.dumps(manifest).encode()).decode()
    (folder / "tampered.json").write_text(json.dumps(envelope))
    result = subprocess.run(base + ["--script", "res://tests/test_update.gd", "--", f"--fixtures={folder}"], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    verify(result)
    if "UPDATE_TESTS_PASS" not in result.stdout:
        raise SystemExit("Updater tests failed")
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]

colors = subprocess.run(
    base + ["--script", "res://tests/test_party_colors.gd", "--", f"--port={port}"],
    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45,
)
verify(colors)
if "PARTY_COLORS_PASS" not in colors.stdout:
    raise SystemExit("Party colors test failed")

processes = []
with tempfile.TemporaryDirectory(prefix="gizmojam-network-") as folder:
    try:
        for index in range(6):
            role = "host" if index == 0 else "client"
            log = open(Path(folder) / f"peer-{index}.log", "w+")
            command = base + ["--script", "res://tests/network_peer.gd", "--",
                              f"--role={role}", f"--index={index}", f"--port={port}"]
            processes.append((subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT), log))
            if index == 0:
                time.sleep(0.4)
                stale = subprocess.run(base + ["--script", "res://tests/network_peer.gd", "--",
                                               "--role=stale", f"--port={port}"], text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)
                print(f"Old-build client:\n{stale.stdout}")
                if stale.returncode or "STALE_CLIENT_PASS" not in stale.stdout or "ERROR:" in stale.stdout:
                    raise SystemExit("Version-mismatch test failed")
        failed = False
        for index, (process, log) in enumerate(processes):
            code = process.wait(timeout=30)
            log.seek(0)
            output = log.read()
            print(f"Peer {index}:\n{output}")
            if code or "PASS" not in output or "ERROR:" in output:
                failed = True
        if failed:
            raise SystemExit("Six-player network test failed")
    finally:
        for process, log in processes:
            if process.poll() is None:
                process.kill()
                process.wait()
            log.close()

def free_udp_ports(count):
    """Distinct free UDP ports, held open together so none repeats."""
    socks = [socket.socket(socket.AF_INET, socket.SOCK_DGRAM) for _ in range(count)]
    try:
        for sock in socks:
            sock.bind(("0.0.0.0", 0))
        return [sock.getsockname()[1] for sock in socks]
    finally:
        for sock in socks:
            sock.close()

def junk_packets():
    """Malformed and hostile packets the listener must drop without errors,
    plus one well-formed beacon from an incompatible build."""
    good = {"magic": "GIZMOJAM", "v": 1, "id": "00c0ffee", "name": "JUNK", "port": 7777,
            "players": 1, "max": 6, "round": False, "game": "Spin Cycle"}
    packets = [b"", b"\xff" * 3000, b"x" * 1400, bytes(range(256)), b"not json",
               b"[" * 400 + b"]" * 400, b'{"magic":"GIZMOJAM","v":1e999,"name":"X"}',
               b'{"magic":"GIZMOJAM","v":2,"name":"\\u0000"}']
    for change in [{"port": 1}, {"players": 9}, {"magic": "OTHER"}, {"extra": True}, {"name": ["x"]}]:
        packets.append(json.dumps({**good, **change}).encode())
    oversized = {**good, "name": "Z" * 600}
    packets.append(json.dumps(oversized).encode())
    return packets

OLD_BUILD = json.dumps({"magic": "GIZMOJAM", "v": 999, "name": "OLDBUILD"}).encode()

def discovery_run(label, target, best_effort=False, junk=False):
    game_port, discovery_port = free_udp_ports(2)
    common = [f"--port={game_port}", f"--discovery={discovery_port}"]
    if target:
        common.append(f"--target={target}")
    if best_effort:
        common.append("--best-effort")
    processes = []
    outputs = {}
    with tempfile.TemporaryDirectory(prefix="gizmojam-discovery-") as folder:
        try:
            for role in ["host", "browser"]:
                log = open(Path(folder) / f"{role}.log", "w+")
                extra = ["--junk"] if junk and role == "browser" else []
                command = base + ["--script", "res://tests/discovery_peer.gd", "--", f"--role={role}"] + common + extra
                processes.append((role, subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT), log))
                time.sleep(0.8)
            deadline = time.time() + 40
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as spray:
                while time.time() < deadline and processes[1][1].poll() is None:
                    if junk:
                        for packet in junk_packets() + [OLD_BUILD]:
                            spray.sendto(packet, ("127.0.0.1", discovery_port))
                    time.sleep(0.4)
            codes = {}
            for role, process, log in processes:
                codes[role] = process.wait(timeout=max(1, deadline - time.time()))
                log.seek(0)
                outputs[role] = log.read()
                print(f"Discovery {label} {role}:\n{outputs[role]}")
        finally:
            for _, process, log in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                log.close()
    clean = all("ERROR:" not in out and "SCRIPT ERROR" not in out for out in outputs.values())
    browser = outputs.get("browser", "")
    if best_effort and "BROADCAST_NOT_RECEIVED" in browser and clean and codes.get("browser") == 0:
        print(f"Discovery {label}: broadcast did not arrive here; reported, not failed.")
        return
    if (any(codes.values()) or not clean or "BROWSER_PASS" not in browser
            or "HOST_PASS" not in outputs.get("host", "")):
        raise SystemExit(f"Discovery test failed ({label})")
    print(f"Discovery {label}: PASS")

# Deterministic: beacons go to 127.0.0.1 by unicast. Junk is sprayed at the
# listener the whole time and must be ignored without any error output.
discovery_run("loopback", "127.0.0.1", junk=True)
# Real broadcast to 255.255.255.255 and each interface. Some sandboxes and CI
# runners block broadcast, so this one reports instead of failing.
discovery_run("broadcast", "", best_effort=True)

online = subprocess.run([sys.executable, str(ROOT / "tests/run_online.py"), "--godot", args.godot], text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
print(online.stdout)
if online.returncode or "ONLINE ROUND PASS" not in online.stdout:
    raise SystemExit("Online Live Wire round failed")
# A host with a second gamepad player and a remote guest.
pad_online = subprocess.run([sys.executable, str(ROOT / "tests/run_gamepad_online.py"), "--godot", args.godot], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
print(pad_online.stdout)
if pad_online.returncode or "GAMEPAD ONLINE PASS" not in pad_online.stdout:
    raise SystemExit("Gamepad online round failed")
# Packs in real parties: downloads from the host, a 0.2.0 guest sitting out,
# unsigned packs and consent. Also plays against the 0.2.0 source.
parties = subprocess.run([sys.executable, str(ROOT / "tests/run_packs.py"), "--godot", args.godot, "--no-build"], text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
print(parties.stdout)
if parties.returncode or "PACKS PASS" not in parties.stdout:
    raise SystemExit("Pack parties failed")
# A real browser guest, when Node and Chrome are installed (exports the web build).
if shutil.which("node") and Path(os.environ.get("CHROME", "/usr/bin/google-chrome")).exists():
    browser = subprocess.run([sys.executable, str(ROOT / "tests/run_browser.py"), "--godot", args.godot], text=True,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
    print(browser.stdout)
    if browser.returncode or "BROWSER GUEST PASS" not in browser.stdout:
        raise SystemExit("Browser guest test failed")
else:
    print("Browser guest test skipped: needs node and Google Chrome")
print("ALL TESTS PASS")
