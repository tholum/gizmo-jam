#!/usr/bin/env python3
"""Publish game packs: build them, sign a new catalog, upload.

The catalog (games/gizmo-jam/updates/catalog-<channel>.json) lists every
published game with the exact size and SHA-256 of its pack. The game loads a
signed pack only if a catalog signed with a trusted key vouches for it, and
fetches games it lacks from a party host or from the URL listed here.

Dry run by default: builds the packs, writes and signs the new catalog under
builds/release/catalog/, and prints what it would upload. Add --publish to
upload: packs first (never overwritten), the catalog last.

    python3 tools/release_games.py --game sumo                 # dry run
    python3 tools/release_games.py --game sumo --publish
    python3 tools/release_games.py --remove sumo --publish     # unlist a game
    python3 tools/release_games.py --web --publish             # the browser build

The browser build that party hosts serve must be the host's exact core build,
so publish it with --web for every core release (tools/release.py). --web also
uploads the standalone export, including catalog games, to
games/gizmo-jam/web/<version>/play/ (wasm, pck and js gzipped, served with
Content-Encoding: gzip). The website's "Play on the web" button opens
play/index.html there, where the game plays solo.

Each publish raises the catalog's serial; the game refuses a catalog with a
lower serial than one it has seen, so an old catalog cannot be replayed to
bring back a pack with a known problem. A game is republished only with a
higher version in its game.json, and games marked "publish": false (the
example game) are refused.

Signing reuses tools/release.py: the same key, envelope and trusted keys.

After the catalog is live, --publish refreshes the website catalog on stable.
It also builds the Android app with every published game built in and releases
it on Google Play (tools/play_publish.py),
so both a core release and a new game reach phones with no extra step.
--no-android skips that. An Android failure never undoes the catalog: the
script says so and how to retry.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release  # noqa: E402

ROOT = release.ROOT
PACKS_PREFIX = "games/gizmo-jam/packs"
WEB_PREFIX = "games/gizmo-jam/web"
IMMUTABLE = "public, max-age=31536000, immutable"
# Browser build file types; the big ones are uploaded gzipped.
WEB_TYPES = {".html": "text/html; charset=utf-8", ".js": "application/javascript", ".wasm": "application/wasm",
             ".pck": "application/octet-stream", ".png": "image/png"}
GZIPPED = {".js", ".wasm", ".pck"}
MAX_PACK = 64 * 1024 * 1024


def catalog_key(channel):
    return f"{release.UPDATES_PREFIX}/catalog-{channel}.json"


def pack_key(game_id, version):
    return f"{PACKS_PREFIX}/{game_id}/{version}/{game_id}.pck"


def live_catalog(url, trusted):
    """The verified live catalog payload, or None when there is none yet."""
    request = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "gizmojam-release"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read(1 << 20)
    except urllib.error.HTTPError as error:
        if error.code in (403, 404):
            return None
        raise SystemExit(f"could not read the live catalog: HTTP {error.code}")
    return release.verify_envelope(json.loads(body), trusted)


def play_url(version):
    return f"{release.PUBLIC_BASE}/{WEB_PREFIX}/{version}/play/index.html"


def play_files(web_dir, version):
    """(local, key, content type, cache, encoding) for the unpacked browser
    build, gzipping the big files into builds/release/play-gz/."""
    out = ROOT / "builds/release/play-gz"
    out.mkdir(parents=True, exist_ok=True)
    files = []
    for path in sorted(web_dir.iterdir()):
        if path.suffix not in WEB_TYPES or not path.is_file():
            continue
        local, encoding = path, ""
        if path.suffix in GZIPPED:
            local = out / (path.name + ".gz")
            local.write_bytes(gzip.compress(path.read_bytes(), compresslevel=9, mtime=0))
            encoding = "gzip"
        files.append((local, f"{WEB_PREFIX}/{version}/play/{path.name}", WEB_TYPES[path.suffix], IMMUTABLE, encoding))
    if not any(f[1].endswith("/index.html") for f in files):
        raise SystemExit(f"{web_dir} has no index.html")
    return files


def pack_entry(game, pack, base_url):
    data = pack.read_bytes()
    if len(data) > MAX_PACK:
        raise SystemExit(f"{pack} is larger than the game accepts ({MAX_PACK} bytes)")
    return {"version": game["version"], "net": int(game["net"]), "core_min": int(game.get("core_min", 0)),
            "size": len(data), "sha256": hashlib.sha256(data).hexdigest(),
            "url": f"{base_url}/{pack_key(game['id'], game['version'])}",
            "info": {k: str(game["info"][k]) for k in ("number", "title", "tags", "blurb")}}


def next_catalog(live, added, removed, channel):
    """The catalog to publish. `live` is the current payload or None; `added`
    maps id -> new entry; `removed` lists ids to unlist."""
    games = dict(live["games"]) if live else {}
    for game_id, entry in added.items():
        old = games.get(game_id)
        if old and release.version_key(entry["version"]) <= release.version_key(old["version"]):
            raise SystemExit(f"{game_id} {entry['version']} is not newer than the published {old['version']}; bump its game.json version")
        games[game_id] = entry
    for game_id in removed:
        if game_id not in games:
            raise SystemExit(f"{game_id} is not in the catalog")
        del games[game_id]
    catalog = {"schema": 1, "game": release.GAME_ID, "kind": "catalog", "channel": channel,
               "serial": (int(live["serial"]) if live else 0) + 1, "games": games}
    if live and "web" in live:
        catalog["web"] = live["web"]
    return catalog


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", action="append", default=[], metavar="ID", help="publish games/ID (repeatable)")
    parser.add_argument("--remove", action="append", default=[], metavar="ID", help="unlist a game (repeatable)")
    parser.add_argument("--web", action="store_true", help="publish the browser build for this core build")
    parser.add_argument("--publish", action="store_true", help="upload; without it this is a dry run")
    parser.add_argument("--channel", default="stable")
    parser.add_argument("--key", default=str(release.DEFAULT_KEY), help="private signing key (default %(default)s)")
    parser.add_argument("--godot", help="Godot binary passed to tools/build.py")
    parser.add_argument("--skip-build", action="store_true", help="reuse packs already in builds/packs/")
    parser.add_argument("--no-android", action="store_true", help="do not build and publish the Android app afterwards")
    parser.add_argument("--notes", default="", help="release notes for Google Play (max 500 characters)")
    args = parser.parse_args(argv)
    if not args.game and not args.remove and not args.web:
        raise SystemExit("nothing to do: give --game ID, --remove ID or --web")
    key = Path(args.key)
    if not key.exists():
        raise SystemExit(f"signing key {key} not found (see README: Releases)")
    if key.stat().st_mode & 0o077:
        raise SystemExit(f"{key} is readable by other users; chmod 600 it")
    trusted = release.embedded_keys()
    if release.key_id(key) not in trusted:
        raise SystemExit("the signing key is not in scripts/update_keys.gd; the game would reject this catalog")

    base_url = release.PUBLIC_BASE
    added = {}
    packs = {}
    for game_id in args.game:
        game = json.loads((ROOT / "games" / game_id / "game.json").read_text())
        if game.get("publish") is False:
            raise SystemExit(f"games/{game_id}/game.json says \"publish\": false")
        if game.get("id") != game_id:
            raise SystemExit(f"games/{game_id}/game.json has id {game.get('id')!r}")
        if not args.skip_build:
            command = [sys.executable, str(ROOT / "tools/build.py"), "--pack", game_id]
            if args.godot:
                command += ["--godot", args.godot]
            subprocess.run(command, check=True)
        pack = ROOT / "builds/packs" / f"{game_id}-{game['version']}.pck"
        if not pack.exists():
            raise SystemExit(f"missing {pack}; run without --skip-build")
        added[game_id] = pack_entry(game, pack, base_url)
        packs[game_id] = pack

    live = live_catalog(f"{base_url}/{catalog_key(args.channel)}", trusted)
    print("No live catalog yet: this will be the first." if live is None else f"Live catalog: serial {live['serial']}, {len(live['games'])} games")
    catalog = next_catalog(live, added, args.remove, args.channel)
    if args.channel == "stable":
        import release_site
        try:
            release_site.game_content(catalog)
        except (OSError, ValueError, KeyError, TypeError) as error:
            raise SystemExit(f"Website catalog: {error}") from None

    web = None
    web_upload = []
    if args.web:
        version, build = release.read_project_version()
        if not args.skip_build:
            command = [sys.executable, str(ROOT / "tools/build.py"), "--web"]
            if args.godot:
                command += ["--godot", args.godot]
            for game_id, entry in sorted(catalog["games"].items()):
                game_file = ROOT / "games" / game_id / "game.json"
                if not game_file.is_file():
                    raise SystemExit(f"cannot bundle catalog game {game_id}: {game_file.relative_to(ROOT)} is missing")
                game = json.loads(game_file.read_text())
                if game.get("version") != entry["version"] or game.get("net") != entry["net"]:
                    raise SystemExit(f"cannot bundle {game_id}: local version and net must match the new catalog")
                if int(entry["core_min"]) > build:
                    raise SystemExit(f"cannot bundle {game_id}: needs core build {entry['core_min']}")
                command += ["--bundle", game_id]
            subprocess.run(command, check=True)
        archive = ROOT / "builds" / f"GizmoJam-web-{version}.zip"
        if not archive.exists():
            raise SystemExit(f"missing {archive}; run without --skip-build")
        data = archive.read_bytes()
        web_key = f"{WEB_PREFIX}/{version}/{archive.name}"
        web = {"build": build, "size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "url": f"{base_url}/{web_key}"}
        catalog["web"] = web
        play_dir = ROOT / "builds/web-play" / version if catalog["games"] else ROOT / "builds/web"
        if not play_dir.is_dir():
            raise SystemExit(f"missing {play_dir}; run without --skip-build to export the standalone web build")
        web_upload = [(archive, web_key, "application/zip", IMMUTABLE, "")] + play_files(play_dir, version)

    envelope = release.sign_manifest(catalog, key)
    release.verify_envelope(envelope, trusted)
    out = ROOT / "builds/release/catalog"
    out.mkdir(parents=True, exist_ok=True)
    (out / f"catalog-{args.channel}.json").write_text(json.dumps(envelope, indent=2) + "\n")
    (out / f"catalog-{args.channel}.payload.json").write_text(json.dumps(catalog, indent=2) + "\n")
    print(json.dumps(catalog, indent=2))

    plan = [(packs[g], pack_key(g, added[g]["version"]), "application/octet-stream", IMMUTABLE, "") for g in added] + web_upload
    for local, key_name, _type, _cache, _encoding in plan:
        try:
            with urllib.request.urlopen(urllib.request.Request(f"{base_url}/{key_name}", method="HEAD"), timeout=15):
                raise SystemExit(f"{base_url}/{key_name} already exists; packs are never overwritten. Bump the version.")
        except urllib.error.HTTPError as error:
            if error.code not in (403, 404):
                raise SystemExit(f"could not check {base_url}/{key_name}: HTTP {error.code}")
    plan.append((out / f"catalog-{args.channel}.json", catalog_key(args.channel), "application/json", "no-cache", ""))
    for local, key_name, content_type, cache, encoding in plan:
        print(f"{'UPLOAD' if args.publish else 'would upload'}  {local.relative_to(ROOT)}  ->  s3://{release.BUCKET}/{key_name}  ({content_type}; {cache}{'; ' + encoding if encoding else ''})")
    if args.channel == "stable":
        print(f"{'THEN' if args.publish else 'would then'}  refresh the public website catalog")
    if not args.no_android:
        import play_publish
        print(f"{'THEN' if args.publish else 'would then'}  build the Android app with serial {catalog['serial']} and release it to Google Play ({play_publish.TRACK})")
    if not args.publish:
        print("Dry run: nothing uploaded. Re-run with --publish to upload.")
        return
    env = release.publisher_env()
    bucket = env.get("S3_BUCKET", release.BUCKET)
    for local, key_name, content_type, cache, encoding in plan[:-1]:
        if encoding:
            release.aws(env, "s3", "cp", str(local), f"s3://{bucket}/{key_name}", "--content-type", content_type,
                        "--cache-control", cache, "--content-encoding", encoding, "--only-show-errors")
        else:
            release.upload(env, bucket, local, key_name, content_type, cache)
        print(f"uploaded {key_name}")
    for entry in list(added.values()) + ([web] if web else []):
        with urllib.request.urlopen(urllib.request.Request(entry["url"], method="HEAD"), timeout=30) as response:
            if int(response.headers.get("Content-Length", -1)) != entry["size"]:
                raise SystemExit(f"{entry['url']} has the wrong size; catalog NOT published")
    if web:
        with urllib.request.urlopen(urllib.request.Request(play_url(version), method="HEAD"), timeout=30) as response:
            if response.status != 200:
                raise SystemExit(f"{play_url(version)} is not readable; catalog NOT published")
    local, key_name, content_type, cache, _encoding = plan[-1]
    release.upload(env, bucket, local, key_name, content_type, cache)
    print(f"uploaded {key_name}. Catalog serial {catalog['serial']} is live.")
    if web:
        print(f"Play on the web: {play_url(version)}")
    website_error = None
    if args.channel == "stable":
        try:
            release_site.sync_after_release(env, bucket)
        except SystemExit as error:
            website_error = error
            print(error, file=sys.stderr)
    if not args.no_android:
        publish_android(catalog["serial"], args.godot, args.notes)
    if website_error:
        raise SystemExit(1)


def publish_android(serial, godot=None, notes=""):
    """Phones get the new catalog's games: build the app and release it."""
    import play_publish
    retry = f"python3 tools/play_publish.py --serial {serial}"
    try:
        command = [sys.executable, str(ROOT / "tools/build.py"), "--android", "--serial", str(serial)]
        if godot:
            command += ["--godot", godot]
        subprocess.run(command, check=True)
        aab, meta = play_publish.built_bundle()
        play_publish.publish(aab, int(meta["version_code"]), meta["version"], notes=notes)
    except (subprocess.CalledProcessError, play_publish.PlayError) as error:
        raise SystemExit(f"Catalog serial {serial} is live, but the Android app was NOT published: {error}\nRetry with: {retry}")


if __name__ == "__main__":
    main()
