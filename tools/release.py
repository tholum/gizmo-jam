#!/usr/bin/env python3
"""Build, sign and publish a Gizmo Jam release to Wasabi.

Dry run by default: builds, writes and signs the manifest under
builds/release/<version>/, and prints what it would upload. Add --publish to
upload. Uploads go to games/gizmo-jam/releases/<version>/ (never overwritten),
then the signed manifest games/gizmo-jam/updates/<channel>.json goes up last.

    python3 tools/release.py --notes "New minigame: Sumo."            # dry run
    python3 tools/release.py --notes "New minigame: Sumo." --publish

Signing uses openssl with the private key at ~/.config/gizmojam/release-signing.key
(RSA, PKCS#1 v1.5, SHA-256), which the game checks against the public keys in
scripts/update_keys.gd. The key never leaves that file and is never printed.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
GAME_ID = "gizmo-jam"
BUCKET = "timholum.com"
ENDPOINT = "https://s3.us-central-1.wasabisys.com"
PUBLIC_BASE = f"{ENDPOINT}/{BUCKET}"
RELEASES_PREFIX = "games/gizmo-jam/releases"
UPDATES_PREFIX = "games/gizmo-jam/updates"
DOWNLOAD_PAGE = "https://timholum.com/games/gizmo-jam/"
ENVELOPE_FORMAT = "gizmo-signed-manifest/1"
SIGNATURE_ALG = "rsa-pkcs1v15-sha256"
SCHEMA = 1
DEFAULT_KEY = Path.home() / ".config/gizmojam/release-signing.key"
PUBLISHER_ENV = Path.home() / ".config/wasabi-timholum/publisher.env"
AWS = shutil.which("aws") or str(Path.home() / ".local/bin/aws")
# Release file name -> (platform key, build.py output, content type).
ARTIFACTS = {
    "GizmoJam-Windows.exe": ("windows", "builds/windows/GizmoJam.exe", "application/vnd.microsoft.portable-executable"),
    "GizmoJam-Linux.x86_64": ("linux", "builds/linux/GizmoJam.x86_64", "application/octet-stream"),
    "GizmoJam-macOS.zip": ("macos", "builds/macos/GizmoJam.zip", "application/zip"),
}
SEMVER = re.compile(r"^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})(?:-([0-9A-Za-z.-]{1,16}))?$")


# --- Versions -------------------------------------------------------------------

def read_project_version(project=ROOT / "project.godot"):
    """(version, build) from [application] config/version and config/build."""
    text = Path(project).read_text()
    version = re.search(r'^config/version="([^"]*)"', text, re.M)
    build = re.search(r"^config/build=(\d+)", text, re.M)
    if not version or not build:
        raise SystemExit("project.godot needs application/config/version and application/config/build")
    if not SEMVER.match(version.group(1)):
        raise SystemExit(f"config/version {version.group(1)!r} is not semver (1.2.3 or 1.2.3-beta.1)")
    return version.group(1), int(build.group(1))


def version_key(version):
    match = SEMVER.match(version)
    if not match:
        return (-1, -1, -1, 0, "")
    major, minor, patch, pre = match.groups()
    # A release outranks its own prereleases.
    return (int(major), int(minor), int(patch), 0 if pre else 1, pre or "")


# --- Manifest and signing ---------------------------------------------------------

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(version, build, files, base_url, notes="", channel="stable", released=None,
                   min_updater_build=0, next_key=None, download_page=DOWNLOAD_PAGE):
    """files maps release file name -> local path; base_url is the release folder URL."""
    platforms = {}
    for name, path in files.items():
        platform = ARTIFACTS[name][0] if name in ARTIFACTS else name
        platforms[platform] = {"url": f"{base_url.rstrip('/')}/{name}",
                               "size": os.path.getsize(path), "sha256": sha256_file(path)}
    manifest = {"schema": SCHEMA, "game": GAME_ID, "channel": channel, "version": version,
                "build": build, "released": released or datetime.date.today().isoformat(),
                "notes": notes, "min_updater_build": min_updater_build,
                "download_page": download_page, "platforms": platforms}
    if next_key:
        manifest["next_key"] = next_key
    return manifest


def _openssl(args, data=None):
    result = subprocess.run(["openssl"] + args, input=data, capture_output=True)
    if result.returncode:
        # stderr from openssl never contains key material.
        raise SystemExit("openssl failed: " + result.stderr.decode(errors="replace").strip())
    return result.stdout


def public_pem(private_key):
    return _openssl(["pkey", "-in", str(private_key), "-pubout"]).decode()


def key_id(private_key=None, public_key_pem=None):
    """"gizmojam-" + first 16 hex digits of SHA-256 of the DER public key."""
    if public_key_pem is None:
        der = _openssl(["pkey", "-in", str(private_key), "-pubout", "-outform", "DER"])
    else:
        der = _openssl(["pkey", "-pubin", "-outform", "DER"], public_key_pem.encode())
    return "gizmojam-" + hashlib.sha256(der).hexdigest()[:16]


def sign_manifest(manifest, private_key):
    """Returns the envelope dict published as <channel>.json."""
    payload = json.dumps(manifest, indent=2, ensure_ascii=False).encode() + b"\n"
    with tempfile.TemporaryDirectory() as folder:
        data = Path(folder) / "payload.json"
        data.write_bytes(payload)
        signature = _openssl(["dgst", "-sha256", "-sign", str(private_key), str(data)])
    return {"format": ENVELOPE_FORMAT, "alg": SIGNATURE_ALG, "key_id": key_id(private_key),
            "payload": base64.b64encode(payload).decode(), "signature": base64.b64encode(signature).decode()}


def verify_envelope(envelope, trusted):
    """trusted maps key id -> PEM. Returns the manifest or raises SystemExit."""
    if envelope.get("format") != ENVELOPE_FORMAT or envelope.get("alg") != SIGNATURE_ALG:
        raise SystemExit("unknown manifest format")
    pem = trusted.get(envelope.get("key_id"))
    if not pem:
        raise SystemExit(f"manifest key {envelope.get('key_id')!r} is not trusted")
    payload = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(envelope["signature"], validate=True)
    with tempfile.TemporaryDirectory() as folder:
        (Path(folder) / "key.pem").write_text(pem)
        (Path(folder) / "payload").write_bytes(payload)
        (Path(folder) / "sig").write_bytes(signature)
        result = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(Path(folder) / "key.pem"),
                                 "-signature", str(Path(folder) / "sig"), str(Path(folder) / "payload")],
                                capture_output=True)
    if result.returncode:
        raise SystemExit("manifest signature does not verify")
    return json.loads(payload)


def embedded_keys(path=ROOT / "scripts/update_keys.gd"):
    """Key id -> PEM, parsed from the game's trusted key list."""
    text = Path(path).read_text()
    return {m.group(1): m.group(2) for m in re.finditer(r'"([^"]+)":\s*"""(-----BEGIN PUBLIC KEY-----.*?-----END PUBLIC KEY-----\n?)"""', text, re.S)}


# --- Wasabi -----------------------------------------------------------------------

def publisher_env():
    """Environment for the aws CLI, from publisher.env, without printing it."""
    if not PUBLISHER_ENV.exists():
        raise SystemExit(f"missing {PUBLISHER_ENV}")
    env = dict(os.environ)
    for profile_var in ("AWS_PROFILE", "AWS_DEFAULT_PROFILE"):
        env.pop(profile_var, None)
    for line in PUBLISHER_ENV.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.removeprefix("export ").split("=", 1)
        env[name.strip()] = value.strip().strip('"').strip("'")
    # Never fall back to the stale ~/.aws/credentials profile.
    env["AWS_SHARED_CREDENTIALS_FILE"] = os.devnull
    env["AWS_CONFIG_FILE"] = os.devnull
    env.setdefault("AWS_DEFAULT_REGION", env.get("AWS_REGION", "us-central-1"))
    return env


def aws(env, *args, check=True):
    command = [AWS, "--endpoint-url", env.get("AWS_ENDPOINT_URL", ENDPOINT)] + list(args)
    result = subprocess.run(command, env=env, capture_output=True, text=True)
    if check and result.returncode:
        raise SystemExit(f"aws {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result


def prefix_exists(env, bucket, prefix):
    result = aws(env, "s3api", "list-objects-v2", "--bucket", bucket, "--prefix", prefix, "--max-keys", "1",
                 "--output", "json")
    return bool(json.loads(result.stdout or "{}").get("Contents"))


def live_manifest(url, trusted):
    """The verified live manifest, or None when there is none yet."""
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "gizmojam-release"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read(1 << 16)
    except urllib.error.HTTPError as error:
        if error.code in (403, 404):
            return None
        raise SystemExit(f"could not read the live manifest: HTTP {error.code}")
    return verify_envelope(json.loads(body), trusted)


def upload(env, bucket, local, key, content_type, cache_control):
    aws(env, "s3", "cp", str(local), f"s3://{bucket}/{key}", "--content-type", content_type,
        "--cache-control", cache_control, "--only-show-errors")


# --- Main ---------------------------------------------------------------------------

def generate_key(path):
    path = Path(path)
    if path.exists():
        raise SystemExit(f"{path} already exists; refusing to overwrite a release key")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    old = os.umask(0o077)
    try:
        _openssl(["genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:3072", "-out", str(path)])
    finally:
        os.umask(old)
    path.chmod(0o600)
    print(f"Wrote {path} (mode 600). Back it up offline. Add this public key to scripts/update_keys.gd:")
    print(f'\t"{key_id(path)}": """{public_pem(path)}""",')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--notes", default="", help="short release notes shown in the game (max 4000 chars)")
    parser.add_argument("--publish", action="store_true", help="upload; without it this is a dry run")
    parser.add_argument("--channel", default="stable", help="update channel (default stable)")
    parser.add_argument("--min-updater-build", type=int, default=0,
                        help="builds older than this are sent to the download page instead of updating in place")
    parser.add_argument("--next-key", help="public key PEM file to announce for key rotation")
    parser.add_argument("--key", default=str(DEFAULT_KEY), help="private signing key (default %(default)s)")
    parser.add_argument("--godot", default=os.environ.get("GODOT"), help="Godot binary passed to tools/build.py")
    parser.add_argument("--skip-build", action="store_true", help="reuse the builds already in builds/")
    parser.add_argument("--generate-key", action="store_true", help="create the signing key once, then exit")
    args = parser.parse_args(argv)

    if args.generate_key:
        generate_key(args.key)
        return
    if len(args.notes) > 4000:
        raise SystemExit("--notes is longer than 4000 characters")
    if not re.match(r"^[a-z0-9-]{1,32}$", args.channel):
        raise SystemExit("--channel must be lowercase letters, digits and dashes")
    key = Path(args.key)
    if not key.exists():
        raise SystemExit(f"signing key {key} not found (see README: Releases)")
    if key.stat().st_mode & 0o077:
        raise SystemExit(f"{key} is readable by other users; chmod 600 it")
    trusted = embedded_keys()
    kid = key_id(key)
    if kid not in trusted:
        raise SystemExit(f"key {kid} is not in scripts/update_keys.gd; the game would reject this release")
    next_key = None
    if args.next_key:
        pem = Path(args.next_key).read_text()
        next_key = {"id": key_id(public_key_pem=pem), "public_key": pem}

    version, build = read_project_version()
    print(f"Release v{version} build {build}, channel {args.channel}, signed by {kid}")
    if not args.skip_build:
        command = [sys.executable, str(ROOT / "tools/build.py")]
        if args.godot:
            command += ["--godot", args.godot]
        subprocess.run(command, check=True)
    files = {}
    for name, (_platform, built, _type) in ARTIFACTS.items():
        path = ROOT / built
        if not path.exists():
            raise SystemExit(f"missing {built}; run without --skip-build")
        files[name] = path

    release_prefix = f"{RELEASES_PREFIX}/{version}"
    manifest_key = f"{UPDATES_PREFIX}/{args.channel}.json"
    base_url = f"{PUBLIC_BASE}/{release_prefix}"
    manifest = build_manifest(version, build, files, base_url, args.notes, args.channel,
                              min_updater_build=args.min_updater_build, next_key=next_key)
    envelope = sign_manifest(manifest, key)
    verify_envelope(envelope, trusted)
    out = ROOT / "builds/release" / version
    out.mkdir(parents=True, exist_ok=True)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / f"{args.channel}.json").write_text(json.dumps(envelope, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))
    print(f"Signed manifest: {out / (args.channel + '.json')}")

    live = live_manifest(f"{PUBLIC_BASE}/{manifest_key}", trusted)
    if live is None:
        print("No live manifest yet: this will be the first release on this channel.")
    else:
        print(f"Live manifest: v{live['version']} build {live['build']}")
        if build <= int(live["build"]) or version_key(version) <= version_key(str(live["version"])):
            raise SystemExit(f"v{version} build {build} is not newer than the live v{live['version']} build {live['build']}; bump config/version and config/build in project.godot")

    for name in files:
        try:
            with urllib.request.urlopen(urllib.request.Request(f"{base_url}/{name}", method="HEAD"), timeout=15):
                raise SystemExit(f"{base_url}/{name} already exists; releases are never overwritten. Bump the version.")
        except urllib.error.HTTPError as error:
            if error.code not in (403, 404):
                raise SystemExit(f"could not check {base_url}/{name}: HTTP {error.code}")

    plan = [(path, f"{release_prefix}/{name}", ARTIFACTS[name][2], "public, max-age=31536000, immutable")
            for name, path in files.items()]
    plan.append((out / f"{args.channel}.json", manifest_key, "application/json", "no-cache"))
    for local, key_name, content_type, cache in plan:
        print(f"{'UPLOAD' if args.publish else 'would upload'}  {local.relative_to(ROOT)}  ->  s3://{BUCKET}/{key_name}  ({content_type}; {cache})")
    if not args.publish:
        print("Dry run: nothing uploaded. Re-run with --publish to upload.")
        return

    env = publisher_env()
    bucket = env.get("S3_BUCKET", BUCKET)
    if prefix_exists(env, bucket, release_prefix + "/"):
        raise SystemExit(f"s3://{bucket}/{release_prefix}/ already exists; releases are never overwritten. Bump the version.")
    for local, key_name, content_type, cache in plan[:-1]:
        upload(env, bucket, local, key_name, content_type, cache)
        print(f"uploaded {key_name}")
    # Check every build is publicly readable and intact before pointing players at it.
    for name, path in files.items():
        url = f"{base_url}/{name}"
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=30) as response:
            if int(response.headers.get("Content-Length", -1)) != path.stat().st_size:
                raise SystemExit(f"{url} has the wrong size; manifest NOT published")
    local, key_name, content_type, cache = plan[-1]
    upload(env, bucket, local, key_name, content_type, cache)
    print(f"uploaded {key_name} (last)")
    print(f"Published v{version} build {build}. Update the website's download links to {base_url}/")


if __name__ == "__main__":
    main()
