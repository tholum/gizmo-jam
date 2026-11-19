#!/usr/bin/env python3
"""Build the Android app and publish it to Google Play.

    tools/play_publish.py --check             read-only: can we reach the app on Play?
    tools/play_publish.py                     build (tools/build.py --android) and upload
    tools/play_publish.py --skip-build        upload the .aab already in builds/android/
    tools/play_publish.py --track production  choose the track (default: TRACK below)

tools/release_games.py --publish runs this after every catalog it publishes,
which covers both kinds of release: a core release publishes the web build
through it first, and a game release publishes the pack. A failure here never
undoes the desktop or web release; re-run this script to retry.

Credentials: a Google Cloud service account with the Play Developer API,
invited in Play Console with release permissions on the app. Its JSON key is
~/.config/gizmo-jam/play-service-account.json (chmod 600), never in the repo.

While the app has never been rolled out, Google only accepts draft releases
from the API: the upload lands as a draft and Play Console's "Review and roll
out" publishes it. After the first roll-out every release goes out on its own,
after Google's review.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "com.timholum.gizmojam"
# Where releases go. "internal" until the phone controls are done; then
# "production" (see docs/specs/mobile-apps-and-touch.md, 7.3).
TRACK = "internal"
KEY_FILE = Path.home() / ".config/gizmo-jam/play-service-account.json"
API = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PACKAGE}"
UPLOAD = f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PACKAGE}"


class PlayError(Exception):
    pass


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


def access_token(key_file=KEY_FILE):
    """An OAuth token for the service account (signed JWT bearer grant)."""
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    if not key_file.exists():
        raise PlayError(f"{key_file} not found (see this script's docstring)")
    if key_file.stat().st_mode & 0o077:
        raise PlayError(f"{key_file} is readable by other users; chmod 600 it")
    account = json.loads(key_file.read_text())
    now = int(time.time())
    head = _b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    claims = _b64(json.dumps({"iss": account["client_email"], "aud": account["token_uri"], "iat": now, "exp": now + 3600,
                              "scope": "https://www.googleapis.com/auth/androidpublisher"}).encode())
    private_key = serialization.load_pem_private_key(account["private_key"].encode(), None)
    signature = _b64(private_key.sign(head + b"." + claims, padding.PKCS1v15(), hashes.SHA256()))
    form = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                   "assertion": (head + b"." + claims + b"." + signature).decode()}).encode()
    status, body = _request("POST", account["token_uri"], form, {"Content-Type": "application/x-www-form-urlencoded"})
    if status != 200:
        raise PlayError(f"sign-in refused: {body.get('error')} {body.get('error_description', '')}")
    return body["access_token"]


def _request(method, url, data=None, headers=None, timeout=60):
    request = urllib.request.Request(url, data, headers or {}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"error": {"message": raw[:300].decode(errors="replace")}}


class Edit:
    """One Play "edit": changes made inside it take effect only on commit."""

    def __init__(self, token):
        self.token = token
        self.id = None

    def call(self, method, path, payload=None, timeout=60):
        headers = {"Authorization": "Bearer " + self.token}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        status, body = _request(method, API + path, data, headers, timeout)
        if status >= 300:
            error = body.get("error", {})
            raise PlayError(f"{method} {path}: HTTP {status} {error.get('status', '')} {error.get('message', '')}".strip())
        return body

    def __enter__(self):
        self.id = self.call("POST", "/edits", {})["id"]
        return self

    def __exit__(self, kind, value, trace):
        if self.id and kind is not None:
            try:
                self.call("DELETE", f"/edits/{self.id}")
            except PlayError:
                pass

    def tracks(self):
        return self.call("GET", f"/edits/{self.id}/tracks").get("tracks", [])

    def upload_bundle(self, aab):
        url = f"{UPLOAD}/edits/{self.id}/bundles?uploadType=media"
        headers = {"Authorization": "Bearer " + self.token, "Content-Type": "application/octet-stream"}
        status, body = _request("POST", url, aab.read_bytes(), headers, timeout=900)
        if status >= 300:
            error = body.get("error", {})
            raise PlayError(f"bundle upload: HTTP {status} {error.get('status', '')} {error.get('message', '')}".strip())
        return int(body["versionCode"])

    def set_track(self, track, code, name, status, notes):
        release = {"name": name, "versionCodes": [str(code)], "status": status}
        if notes:
            release["releaseNotes"] = [{"language": "en-US", "text": notes[:500]}]
        self.call("PUT", f"/edits/{self.id}/tracks/{track}", {"track": track, "releases": [release]})

    def commit(self):
        self.call("POST", f"/edits/{self.id}:commit")
        self.id = None


def check():
    with Edit(access_token()) as edit:
        tracks = edit.tracks()
        edit.call("DELETE", f"/edits/{edit.id}")
        edit.id = None
    print(f"Play access OK for {PACKAGE}. Tracks:")
    for track in tracks:
        for release in track.get("releases", []) or [{}]:
            if release:
                print(f"  {track['track']}: {release.get('name', '?')} codes {release.get('versionCodes', [])} {release.get('status', '')}")
            else:
                print(f"  {track['track']}: empty")


def publish(aab, code, name, track=TRACK, notes="", upload=True):
    """Uploads `aab` and releases it to `track` (to every user of that track).
    With upload=False, releases a build Play already has (promotion). Falls
    back to a draft while the track has never been rolled out."""
    token = access_token()
    for status in ("completed", "draft"):
        try:
            with Edit(token) as edit:
                if upload:
                    uploaded = edit.upload_bundle(aab)
                    if uploaded != code:
                        raise PlayError(f"Play read version code {uploaded} from the bundle, expected {code}")
                edit.set_track(track, code, name, status, notes)
                edit.commit()
            break
        except PlayError as error:
            if status == "completed" and "draft" in str(error).lower():
                print("Play accepts only drafts until the app's first roll-out; uploading as a draft.")
                continue
            raise
    if status == "draft":
        where = "Release > Production" if track == "production" else f"Testing > {track.capitalize()} testing"
        print(f"Uploaded {name} (code {code}) to {track} as a DRAFT. Publish it once in Play Console: "
              f"{where} > Review and roll out (Send for review). Later releases go out on their own.")
    else:
        print(f"Released {name} (code {code}) to the {track} track. Google reviews it, then it goes out on its own.")
    return status


def built_bundle():
    """The .aab tools/build.py --android wrote for this version, and its sidecar
    (version code, bundled games, SHA-256)."""
    text = (ROOT / "project.godot").read_text()
    version = re.search(r'^config/version="([^"]+)"', text, re.M).group(1)
    aab = ROOT / "builds/android" / f"GizmoJam-{version}.aab"
    info = aab.with_suffix(".json")
    if not aab.exists() or not info.exists():
        raise PlayError(f"missing {aab} or its .json; build it with tools/build.py --android")
    meta = json.loads(info.read_text())
    if hashlib.sha256(aab.read_bytes()).hexdigest() != meta.get("sha256"):
        raise PlayError(f"{aab} does not match {info.name}; rebuild it")
    return aab, meta


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="read-only access check, changes nothing")
    parser.add_argument("--track", default=TRACK, choices=["internal", "alpha", "beta", "production"])
    parser.add_argument("--skip-build", action="store_true", help="upload the .aab already built")
    parser.add_argument("--promote", action="store_true",
                        help="put the build already uploaded for this version on --track, without uploading again")
    parser.add_argument("--serial", type=int, help="catalog serial for the version code (default: the live catalog's)")
    parser.add_argument("--android-revision", type=int, default=0, help="0-9: rebuild of the same core and catalog")
    parser.add_argument("--notes", default="", help="release notes (max 500 characters)")
    parser.add_argument("--godot", help="Godot binary passed to tools/build.py")
    args = parser.parse_args(argv)
    try:
        if args.check:
            check()
            return
        if args.promote:
            aab, meta = built_bundle()
            publish(aab, int(meta["version_code"]), meta["version"], args.track, args.notes, upload=False)
            return
        if not args.skip_build:
            command = [sys.executable, str(ROOT / "tools/build.py"), "--android"]
            if args.godot:
                command += ["--godot", args.godot]
            if args.serial is not None:
                command += ["--serial", str(args.serial)]
            if args.android_revision:
                command += ["--android-revision", str(args.android_revision)]
            subprocess.run(command, check=True)
        aab, meta = built_bundle()
        publish(aab, int(meta["version_code"]), meta["version"], args.track, args.notes)
    except PlayError as error:
        raise SystemExit(f"Google Play: {error}")


if __name__ == "__main__":
    main()
