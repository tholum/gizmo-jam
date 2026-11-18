#!/usr/bin/env python3
"""End-to-end self-update test on Linux with real exported builds.

Builds version A (project version, e.g. 0.2.0 build 2) and version B (a
temporary bump to 0.2.1 build 3, restored afterwards), serves B and signed test
manifests from a private http.server on 127.0.0.1, and runs copies of A under
Xvfb with --update-manifest/--update-channel=test/--update-autoclick, so the
update card's own "Update now" button starts the real download/verify/swap/
relaunch path. Scenarios:

  success      A updates to B on disk (SHA-256), relaunches, B reaches its menu
               and reports v0.2.1 build 3, and B removes the kept old binary.
  tampered     manifest payload edited after signing: rejected, nothing shown.
  bad-hash     signed manifest with the wrong SHA-256: download rejected.
  bad-size     signed manifest with a smaller size: download rejected.
  read-only    game folder not writable: falls back to the download page.
  failed-start new binary exits before its menu: A restores itself.
  second-start B never reached its menu last time: B restores A and starts it.

Manifests are signed with the release key (~/.config/gizmojam/release-signing.key)
on the "test" channel, which the shipped game never accepts by default.

    python3 tests/update_e2e.py --godot <godot> [--reuse-builds]
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import release  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--godot", default=os.environ.get("GODOT", str(ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64")))
parser.add_argument("--reuse-builds", action="store_true", help="reuse test-output/update-e2e/builds from a previous run")
parser.add_argument("--key", default=str(release.DEFAULT_KEY))
args = parser.parse_args()

if not os.environ.get("DISPLAY"):
    # One Xvfb for the whole run, so every game process is our direct child
    # (or the child of one) and can be stopped by its exact PID.
    os.execvp("xvfb-run", ["xvfb-run", "-a", "-s", "-screen 0 1280x800x24", sys.executable] + sys.argv)

WORK = ROOT / "test-output/update-e2e"
BUILDS = WORK / "builds"
BIN = "GizmoJam.x86_64"
A_VERSION, A_BUILD = release.read_project_version()
B_VERSION, B_BUILD = "0.2.1", A_BUILD + 1
known_pids = set()


def sha(path):
    return release.sha256_file(path)


def build_versions():
    """Exports A as-is and B with a temporary version bump; restores the project."""
    if args.reuse_builds and (BUILDS / "A" / BIN).exists() and (BUILDS / "B" / BIN).exists():
        return
    BUILDS.mkdir(parents=True, exist_ok=True)
    saved = {p: p.read_bytes() for p in (ROOT / "project.godot", ROOT / "export_presets.cfg")}
    try:
        for label, version, build in (("A", A_VERSION, A_BUILD), ("B", B_VERSION, B_BUILD)):
            text = saved[ROOT / "project.godot"].decode()
            text = text.replace(f'config/version="{A_VERSION}"', f'config/version="{version}"')
            text = text.replace(f"config/build={A_BUILD}\n", f"config/build={build}\n")
            (ROOT / "project.godot").write_text(text)
            subprocess.run([sys.executable, str(ROOT / "tools/build.py"), "--godot", args.godot, "--platform", "linux"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
            (BUILDS / label).mkdir(exist_ok=True)
            shutil.copy2(ROOT / "builds/linux" / BIN, BUILDS / label / BIN)
            print(f"built {label}: v{version} build {build}  sha256 {sha(BUILDS / label / BIN)[:16]}…")
    finally:
        for path, data in saved.items():
            path.write_bytes(data)
    assert release.read_project_version() == (A_VERSION, A_BUILD), "project.godot was not restored"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def sign(path, manifest):
    path.write_text(json.dumps(release.sign_manifest(manifest, args.key)))


def userdata(home):
    return home / "godot/app_userdata/Gizmo Jam"


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def wait_for(condition, timeout, what):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(0.2)
    raise AssertionError(f"timed out waiting for {what}")


def ours(pid, folder):
    """True if pid is a game process running from this test's folder."""
    try:
        exe = os.readlink(f"/proc/{pid}/exe")
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace")
    except OSError:
        return False
    return str(folder) in exe or str(folder) in cmdline


def stop(pid, folder):
    """Kills exactly `pid`, and only if it is one of this test's game processes."""
    if pid and ours(pid, folder):
        os.kill(pid, signal.SIGKILL)
        for _ in range(50):
            try:
                if Path(f"/proc/{pid}/stat").read_text().split()[2] == "Z":
                    break
            except OSError:
                break
            time.sleep(0.1)


class Game:
    """A copy of build A in its own folder with its own user data directory."""

    def __init__(self, name, binary):
        self.folder = Path(tempfile.mkdtemp(prefix=f"gizmojam-e2e-{name}-"))
        self.dir = self.folder / "game"
        self.home = self.folder / "data"
        self.dir.mkdir()
        self.home.mkdir()
        self.exe = self.dir / BIN
        shutil.copy2(binary, self.exe)
        self.exe.chmod(0o755)
        self.log_path = self.folder / "game.log"
        self.process = None

    def run(self, *user_args):
        env = dict(os.environ, XDG_DATA_HOME=str(self.home))
        self.log = open(self.log_path, "ab")
        command = [str(self.exe), "--audio-driver", "Dummy", "--"] + list(user_args)
        self.process = subprocess.Popen(command, stdout=self.log, stderr=subprocess.STDOUT, env=env, cwd=self.folder)
        known_pids.add((self.process.pid, self.folder))
        return self

    def text(self):
        """stdout of the process we started, plus Godot's own log files, which
        also hold the output of versions the game relaunched itself."""
        parts = [self.log_path.read_text(errors="replace")]
        for log in sorted((userdata(self.home) / "logs").glob("*.log")):
            parts.append(log.read_text(errors="replace"))
        return "\n".join(parts)

    def wait_log(self, needle, timeout=60):
        return wait_for(lambda: needle in self.text(), timeout, f"log line {needle!r} in {self.log_path}")

    def files(self):
        return sorted(p.name for p in self.dir.iterdir())

    def close(self):
        if self.process and self.process.poll() is None:
            stop(self.process.pid, self.folder)
            self.process.wait()
        marker = read_json(userdata(self.home) / "update_started.json")
        if marker:
            stop(int(marker.get("pid", 0)), self.folder)
        if hasattr(self, "log"):
            self.log.close()


def scenario(name, function, games):
    print(f"--- {name}")
    try:
        function()
        print(f"PASS {name}")
    except Exception:
        print(f"FAIL {name}")
        if games:
            print(games[-1].text()[-4000:])
        raise


def main():
    if not Path(args.key).exists():
        raise SystemExit(f"release key {args.key} is needed to sign the test manifests")
    build_versions()
    a_bin, b_bin = BUILDS / "A" / BIN, BUILDS / "B" / BIN
    a_sha, b_sha = sha(a_bin), sha(b_bin)
    assert a_sha != b_sha
    serve = Path(tempfile.mkdtemp(prefix="gizmojam-e2e-serve-"))
    shutil.copy2(b_bin, serve / "GizmoJam-Linux.x86_64")
    crash = serve / "crash.x86_64"
    crash.write_text("#!/bin/sh\necho 'crash build: exiting before the menu'\nexit 3\n")
    port = free_port()
    base = f"http://127.0.0.1:{port}"

    def manifest(binary_name, **changes):
        m = release.build_manifest(B_VERSION, B_BUILD, {"linux": serve / binary_name}, base, "E2E test build", "test")
        m["platforms"]["linux"]["url"] = f"{base}/{binary_name}"
        m["platforms"]["linux"].update(changes)
        return m

    sign(serve / "good.json", manifest("GizmoJam-Linux.x86_64"))
    sign(serve / "bad-hash.json", manifest("GizmoJam-Linux.x86_64", sha256="0" * 64))
    sign(serve / "bad-size.json", manifest("GizmoJam-Linux.x86_64", size=1024))
    sign(serve / "crash.json", manifest("crash.x86_64"))
    tampered = json.loads((serve / "good.json").read_text())
    payload = json.loads(release.base64.b64decode(tampered["payload"]))
    payload["platforms"]["linux"]["url"] = f"{base}/evil.x86_64"
    tampered["payload"] = release.base64.b64encode(json.dumps(payload).encode()).decode()
    (serve / "tampered.json").write_text(json.dumps(tampered))

    server = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", str(serve)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server_pid = server.pid
    print(f"http.server pid {server_pid} on {base}")
    games = []

    def game(name, binary=a_bin):
        g = Game(name, binary)
        games.append(g)
        return g

    def flags(manifest_name):
        return [f"--update-manifest={base}/{manifest_name}", "--update-channel=test", "--update-autoclick"]

    try:
        wait_for(lambda: subprocess.run(["curl", "-sf", "-o", "/dev/null", f"{base}/good.json"]).returncode == 0, 10, "http.server")

        def success():
            g = game("success").run(*flags("good.json"))
            g.wait_log("[update] downloading")
            g.wait_log("[update] download verified")
            # A quits once B has written its "started OK" marker.
            assert g.process.wait(timeout=90) == 0, "A did not exit cleanly after the update"
            marker = wait_for(lambda: read_json(userdata(g.home) / "update_started.json"), 30, "B's started marker")
            assert marker["build"] == B_BUILD and marker["version"] == B_VERSION, marker
            b_pid = int(marker["pid"])
            assert b_pid != g.process.pid and ours(b_pid, g.folder), "relaunched B is not running"
            assert sha(g.exe) == b_sha, "binary on disk is not B"
            assert os.access(g.exe, os.X_OK), "new binary is not executable"
            g.wait_log(f"[update] Gizmo Jam v{B_VERSION} build {B_BUILD} (exported)")
            g.wait_log(f"[update] update to v{B_VERSION} confirmed")
            # B removes the kept previous version after confirming it started.
            wait_for(lambda: not (g.dir / (BIN + ".old")).exists(), 20, "removal of the old binary")
            wait_for(lambda: not (userdata(g.home) / "update_state.json").exists(), 10, "state cleared")
            g.wait_log("[update] up to date")
            assert g.files() == [BIN], g.files()
            print(f"  A pid {g.process.pid} exited; B pid {b_pid} reports v{marker['version']} build {marker['build']}; on-disk sha256 {b_sha[:16]}… = B")
            return g

        def tampered_case():
            g = game("tampered").run(*flags("tampered.json"))
            g.wait_log("[update] manifest rejected: signature does not verify")
            time.sleep(1.5)
            assert "update available" not in g.text() and "downloading" not in g.text()
            assert sha(g.exe) == a_sha and g.files() == [BIN]
            return g

        def bad_hash():
            g = game("bad-hash").run(*flags("bad-hash.json"))
            g.wait_log("SHA-256 mismatch). Nothing was changed.")
            assert sha(g.exe) == a_sha and g.files() == [BIN], g.files()
            assert not list((userdata(g.home) / "updates").glob("*")), "rejected download was left behind"
            return g

        def bad_size():
            g = game("bad-size").run(*flags("bad-size.json"))
            g.wait_log("[update] update failed: The download failed (larger than the signed size)")
            assert sha(g.exe) == a_sha and g.files() == [BIN]
            return g

        def read_only():
            g = game("read-only")
            g.dir.chmod(0o555)
            try:
                g.run(*flags("good.json"))
                g.wait_log("can't write to its folder")
                assert sha(g.exe) == a_sha and g.files() == [BIN]
            finally:
                g.dir.chmod(0o755)
            return g

        def failed_start():
            g = game("failed-start").run(*flags("crash.json"))
            g.wait_log("closed before it reached the menu; previous version restored", timeout=90)
            assert "crash build: exiting before the menu" in g.text()
            assert sha(g.exe) == a_sha, "previous version was not restored"
            assert g.files() == [BIN], g.files()
            assert g.process.poll() is None, "A should keep running and show the error"
            return g

        def second_start():
            # Leftovers of an update whose new version never reached its menu.
            g = game("second-start", b_bin)
            shutil.copy2(a_bin, g.dir / (BIN + ".old"))
            data = userdata(g.home)
            data.mkdir(parents=True)
            (data / "update_state.json").write_text(json.dumps({
                "phase": "swapped", "platform": "linux", "from_build": A_BUILD, "from_version": A_VERSION,
                "to_build": B_BUILD, "to_version": B_VERSION, "attempts": 1, "time": time.time()}))
            g.run("--no-update-check")
            g.wait_log("did not reach the menu last time; restoring")
            assert g.process.wait(timeout=30) == 0
            marker = wait_for(lambda: read_json(data / "update_started.json"), 60, "A's started marker")
            assert marker["build"] == A_BUILD, marker
            assert sha(g.exe) == a_sha and g.files() == [BIN], g.files()
            g.wait_log(f"[update] Gizmo Jam v{A_VERSION} build {A_BUILD} (exported)")
            g.wait_log(f"[update] update failed: v{B_VERSION} did not start, so v{A_VERSION} was put back")
            wait_for(lambda: not (data / "update_state.json").exists(), 10, "state cleared")
            return g

        for name, function in (("success", success), ("tampered", tampered_case), ("bad-hash", bad_hash),
                               ("bad-size", bad_size), ("read-only", read_only), ("failed-start", failed_start),
                               ("second-start", second_start)):
            scenario(name, function, games)
            games[-1].close()
        print("UPDATE_E2E_PASS success-tampered-badhash-badsize-readonly-failedstart-secondstart")
    finally:
        for g in games:
            g.close()
        for pid, folder in known_pids:
            stop(pid, folder)
        if server.poll() is None:
            os.kill(server_pid, signal.SIGTERM)
            server.wait(timeout=10)
        shutil.rmtree(serve, ignore_errors=True)
        for g in games:
            if os.environ.get("KEEP_E2E"):
                print("kept", g.folder)
            else:
                shutil.rmtree(g.folder, ignore_errors=True)


if __name__ == "__main__":
    main()
