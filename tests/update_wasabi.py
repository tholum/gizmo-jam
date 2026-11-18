#!/usr/bin/env python3
"""Real HTTPS check against Wasabi, using throwaway objects under
games/gizmo-jam/updates/test/ only (never stable.json or releases/).

Uploads build B (from tests/update_e2e.py's builds) plus a signed and a tampered
"test"-channel manifest, runs exported build A against them under Xvfb, checks
that A updates itself to B over HTTPS and rejects the tampered manifest, then
deletes exactly the objects it uploaded.

    python3 tests/update_e2e.py --godot <godot>     # builds A and B first
    python3 tests/update_wasabi.py
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import release  # noqa: E402

if not os.environ.get("DISPLAY"):
    os.execvp("xvfb-run", ["xvfb-run", "-a", sys.executable] + sys.argv)

BUILDS = ROOT / "test-output/update-e2e/builds"
BIN = "GizmoJam.x86_64"
PREFIX = "games/gizmo-jam/updates/test"
RUN = time.strftime("%Y%m%d-%H%M%S")
KEYS = {"binary": f"{PREFIX}/{RUN}/GizmoJam-Linux.x86_64", "good": f"{PREFIX}/{RUN}/manifest.json",
        "tampered": f"{PREFIX}/{RUN}/tampered.json"}
URL = {name: f"{release.PUBLIC_BASE}/{key}" for name, key in KEYS.items()}


def wait_for(condition, timeout, what):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.3)
    raise AssertionError(f"timed out waiting for {what}")


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def run_game(binary, manifest_url, folder):
    game = folder / "game"
    data = folder / "data"
    game.mkdir(parents=True)
    data.mkdir()
    shutil.copy2(binary, game / BIN)
    (game / BIN).chmod(0o755)
    log = open(folder / "game.log", "wb")
    process = subprocess.Popen([str(game / BIN), "--audio-driver", "Dummy", "--", f"--update-manifest={manifest_url}",
                                "--update-channel=test", "--update-autoclick"],
                               env=dict(os.environ, XDG_DATA_HOME=str(data)), stdout=log, stderr=subprocess.STDOUT)
    userdata = data / "godot/app_userdata/Gizmo Jam"

    def text():
        logs = sorted((userdata / "logs").glob("*.log")) if (userdata / "logs").exists() else []
        return "\n".join([(folder / "game.log").read_text(errors="replace")] + [p.read_text(errors="replace") for p in logs])
    return process, log, game, userdata, text


def stop(pid, folder):
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
    except OSError:
        return
    if str(folder) in exe:
        os.kill(pid, signal.SIGKILL)


def main():
    a_bin, b_bin = BUILDS / "A" / BIN, BUILDS / "B" / BIN
    if not (a_bin.exists() and b_bin.exists()):
        raise SystemExit("run tests/update_e2e.py first to build A and B")
    b_version, b_build = "0.2.1", release.read_project_version()[1] + 1
    work = Path(tempfile.mkdtemp(prefix="gizmojam-wasabi-"))
    manifest = release.build_manifest(b_version, b_build, {"linux": b_bin}, "", "Wasabi HTTPS test", "test")
    manifest["platforms"]["linux"]["url"] = URL["binary"]
    envelope = release.sign_manifest(manifest, release.DEFAULT_KEY)
    (work / "manifest.json").write_text(json.dumps(envelope))
    tampered = dict(envelope)
    payload = json.loads(release.base64.b64decode(envelope["payload"]))
    payload["notes"] = "edited after signing"
    tampered["payload"] = release.base64.b64encode(json.dumps(payload).encode()).decode()
    (work / "tampered.json").write_text(json.dumps(tampered))
    env = release.publisher_env()
    bucket = env.get("S3_BUCKET", release.BUCKET)
    uploaded = []
    pids = []
    try:
        for name, local, ctype in (("binary", b_bin, "application/octet-stream"), ("good", work / "manifest.json", "application/json"),
                                   ("tampered", work / "tampered.json", "application/json")):
            release.upload(env, bucket, local, KEYS[name], ctype, "no-cache")
            uploaded.append(KEYS[name])
            print(f"uploaded s3://{bucket}/{KEYS[name]}")
        with urllib.request.urlopen(urllib.request.Request(URL["good"], method="HEAD"), timeout=30) as response:
            print(f"public HTTPS HEAD {URL['good']}: {response.status}, Cache-Control {response.headers.get('Cache-Control')}")

        print("--- https-success")
        process, log, game, userdata, text = run_game(a_bin, URL["good"], work / "success")
        pids.append((process.pid, work / "success"))
        wait_for(lambda: "[update] download verified" in text(), 300, "HTTPS download and verification")
        assert process.wait(timeout=90) == 0
        marker = wait_for(lambda: (m := read_json(userdata / "update_started.json")) and m.get("build") == b_build and m, 60, "B marker")
        pids.append((int(marker["pid"]), work / "success"))
        assert release.sha256_file(game / BIN) == release.sha256_file(b_bin)
        wait_for(lambda: f"Gizmo Jam v{b_version} build {b_build} (exported)" in text(), 30, "B version line")
        print(f"  {[line for line in text().splitlines() if 'downloading' in line][0]}")
        print(f"  relaunched pid {marker['pid']} reports v{marker['version']} build {marker['build']}")
        print("PASS https-success")
        log.close()

        print("--- https-tampered")
        process, log, game, userdata, text = run_game(a_bin, URL["tampered"], work / "tampered")
        pids.append((process.pid, work / "tampered"))
        wait_for(lambda: "[update] manifest rejected: signature does not verify" in text(), 60, "rejection")
        assert release.sha256_file(game / BIN) == release.sha256_file(a_bin)
        print("PASS https-tampered")
        log.close()
        print("UPDATE_WASABI_PASS https-success-tampered")
    finally:
        for pid, folder in pids:
            stop(pid, folder)
        for key in uploaded:
            release.aws(env, "s3api", "delete-object", "--bucket", bucket, "--key", key)
            print(f"deleted s3://{bucket}/{key}")
        left = release.aws(env, "s3api", "list-objects-v2", "--bucket", bucket, "--prefix", f"{PREFIX}/{RUN}/", "--output", "json").stdout
        print("remaining under test prefix:", json.loads(left or "{}").get("KeyCount", 0))
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
