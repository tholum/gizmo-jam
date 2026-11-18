#!/usr/bin/env python3
"""Windows self-update under Wine, with real Windows exports (headless).

Wine is not Windows; this checks the Windows code path (rename the running
.exe to .old, move the new one in, relaunch, delete .old after the new version
confirms) and the failed-start restore, not real NTFS locking or antivirus.

    python3 tests/update_wine.py --godot <godot> [--reuse-builds]

Uses a throwaway WINEPREFIX under /tmp and stops game processes only with
`taskkill /PID <pid>` for the exact Windows PIDs it started or read from the
game's "started OK" marker.
"""
import argparse
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
import release  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--godot", default=os.environ.get("GODOT", str(ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64")))
parser.add_argument("--reuse-builds", action="store_true")
parser.add_argument("--key", default=str(release.DEFAULT_KEY))
args = parser.parse_args()

BUILDS = ROOT / "test-output/update-wine/builds"
EXE = "GizmoJam.exe"
A_VERSION, A_BUILD = release.read_project_version()
B_VERSION, B_BUILD = "0.2.1", A_BUILD + 1


def build_versions():
    if args.reuse_builds and (BUILDS / "A" / EXE).exists() and (BUILDS / "B" / EXE).exists():
        return
    BUILDS.mkdir(parents=True, exist_ok=True)
    saved = {p: p.read_bytes() for p in (ROOT / "project.godot", ROOT / "export_presets.cfg")}
    try:
        for label, version, build in (("A", A_VERSION, A_BUILD), ("B", B_VERSION, B_BUILD)):
            text = saved[ROOT / "project.godot"].decode()
            text = text.replace(f'config/version="{A_VERSION}"', f'config/version="{version}"')
            text = text.replace(f"config/build={A_BUILD}\n", f"config/build={build}\n")
            (ROOT / "project.godot").write_text(text)
            subprocess.run([sys.executable, str(ROOT / "tools/build.py"), "--godot", args.godot, "--platform", "windows"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
            (BUILDS / label).mkdir(exist_ok=True)
            shutil.copy2(ROOT / "builds/windows" / EXE, BUILDS / label / EXE)
    finally:
        for path, data in saved.items():
            path.write_bytes(data)


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


def main():
    build_versions()
    a_sha = release.sha256_file(BUILDS / "A" / EXE)
    b_sha = release.sha256_file(BUILDS / "B" / EXE)
    work = Path(tempfile.mkdtemp(prefix="gizmojam-wine-"))
    env = dict(os.environ, WINEPREFIX=str(work / "prefix"), WINEDEBUG="-all")
    subprocess.run(["wineboot", "-i"], env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
    user = next(p for p in (work / "prefix/drive_c/users").iterdir() if p.name != "Public")
    data = user / "AppData/Roaming/Godot/app_userdata/Gizmo Jam"
    serve = work / "serve"
    serve.mkdir()
    shutil.copy2(BUILDS / "B" / EXE, serve / "GizmoJam-Windows.exe")
    # A Windows program that exits at once, standing in for a build that crashes.
    shutil.copy2(work / "prefix/drive_c/windows/system32/hostname.exe", serve / "crash.exe")
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    for name, binary in (("good.json", "GizmoJam-Windows.exe"), ("crash.json", "crash.exe")):
        m = release.build_manifest(B_VERSION, B_BUILD, {"windows": serve / binary}, base, "Wine test", "test")
        m["platforms"]["windows"]["url"] = f"{base}/{binary}"
        (serve / name).write_text(json.dumps(release.sign_manifest(m, args.key)))
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", str(serve)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"http.server pid {server.pid}; WINEPREFIX {work / 'prefix'}")
    windows_pids = set()
    processes = []

    def start(game_dir, manifest):
        shutil.rmtree(data, ignore_errors=True)
        log = open(work / f"{game_dir.name}.log", "wb")
        process = subprocess.Popen(["wine", str(game_dir / EXE), "--headless", "--audio-driver", "Dummy", "--",
                                    f"--update-manifest={base}/{manifest}", "--update-channel=test", "--update-autoclick"],
                                   env=env, stdout=log, stderr=subprocess.STDOUT)
        processes.append((process, log))
        return process

    def logs():
        return "\n".join(p.read_text(errors="replace") for p in sorted((data / "logs").glob("*.log"))) if (data / "logs").exists() else ""

    def game(name):
        folder = work / name
        folder.mkdir()
        shutil.copy2(BUILDS / "A" / EXE, folder / EXE)
        return folder

    try:
        print("--- success")
        folder = game("success")
        process = start(folder, "good.json")
        marker = wait_for(lambda: (m := read_json(data / "update_started.json")) and m.get("build") == B_BUILD and m, 180, "B's started marker")
        windows_pids.add(int(marker["pid"]))
        assert process.wait(timeout=60) == 0, "A did not exit after B confirmed"
        assert release.sha256_file(folder / EXE) == b_sha, "exe on disk is not B"
        wait_for(lambda: not (folder / (EXE + ".old")).exists(), 30, "removal of GizmoJam.exe.old")
        assert sorted(p.name for p in folder.iterdir()) == [EXE]
        wait_for(lambda: f"Gizmo Jam v{B_VERSION} build {B_BUILD} (exported)" in logs(), 20, "B's version line")
        print(f"  B (Windows pid {marker['pid']}) reports v{marker['version']} build {marker['build']}; .old removed")
        print("PASS success")
        subprocess.run(["wine", "taskkill", "/F", "/PID", str(marker["pid"])], env=env, capture_output=True)

        print("--- failed-start")
        folder = game("failed")
        process = start(folder, "crash.json")
        wait_for(lambda: "closed before it reached the menu; previous version restored" in logs(), 180, "restore")
        assert release.sha256_file(folder / EXE) == a_sha, "A was not restored"
        assert sorted(p.name for p in folder.iterdir()) == [EXE], sorted(p.name for p in folder.iterdir())
        marker = read_json(data / "update_started.json")
        print("PASS failed-start")
        if marker:
            subprocess.run(["wine", "taskkill", "/F", "/PID", str(marker["pid"])], env=env, capture_output=True)
        print("UPDATE_WINE_PASS success-failedstart")
    finally:
        for process, log in processes:
            if process.poll() is None:
                process.kill()  # the exact wine loader process we started
                process.wait()
            log.close()
        if server.poll() is None:
            server.terminate()
            server.wait(timeout=10)
        subprocess.run(["wineserver", "-w"], env=env, timeout=60)
        if os.environ.get("KEEP_E2E"):
            print("kept", work)
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
