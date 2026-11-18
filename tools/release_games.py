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

Each publish raises the catalog's serial; the game refuses a catalog with a
lower serial than one it has seen, so an old catalog cannot be replayed to
bring back a pack with a known problem. A game is republished only with a
higher version in its game.json, and games marked "publish": false (the
example game) are refused.

Signing reuses tools/release.py: the same key, envelope and trusted keys.
"""
import argparse
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
    web = live.get("web") if live else None
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
    if web:
        catalog["web"] = web
    return catalog


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game", action="append", default=[], metavar="ID", help="publish games/ID (repeatable)")
    parser.add_argument("--remove", action="append", default=[], metavar="ID", help="unlist a game (repeatable)")
    parser.add_argument("--publish", action="store_true", help="upload; without it this is a dry run")
    parser.add_argument("--channel", default="stable")
    parser.add_argument("--key", default=str(release.DEFAULT_KEY), help="private signing key (default %(default)s)")
    parser.add_argument("--godot", help="Godot binary passed to tools/build.py")
    parser.add_argument("--skip-build", action="store_true", help="reuse packs already in builds/packs/")
    args = parser.parse_args(argv)
    if not args.game and not args.remove:
        raise SystemExit("nothing to do: give --game ID or --remove ID")
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
    envelope = release.sign_manifest(catalog, key)
    release.verify_envelope(envelope, trusted)
    out = ROOT / "builds/release/catalog"
    out.mkdir(parents=True, exist_ok=True)
    (out / f"catalog-{args.channel}.json").write_text(json.dumps(envelope, indent=2) + "\n")
    (out / f"catalog-{args.channel}.payload.json").write_text(json.dumps(catalog, indent=2) + "\n")
    print(json.dumps(catalog, indent=2))

    plan = [(packs[g], pack_key(g, added[g]["version"]), "application/octet-stream", "public, max-age=31536000, immutable") for g in added]
    for local, key_name, _type, _cache in plan:
        try:
            with urllib.request.urlopen(urllib.request.Request(f"{base_url}/{key_name}", method="HEAD"), timeout=15):
                raise SystemExit(f"{base_url}/{key_name} already exists; packs are never overwritten. Bump the version.")
        except urllib.error.HTTPError as error:
            if error.code not in (403, 404):
                raise SystemExit(f"could not check {base_url}/{key_name}: HTTP {error.code}")
    plan.append((out / f"catalog-{args.channel}.json", catalog_key(args.channel), "application/json", "no-cache"))
    for local, key_name, content_type, cache in plan:
        print(f"{'UPLOAD' if args.publish else 'would upload'}  {local.relative_to(ROOT)}  ->  s3://{release.BUCKET}/{key_name}  ({content_type}; {cache})")
    if not args.publish:
        print("Dry run: nothing uploaded. Re-run with --publish to upload.")
        return
    env = release.publisher_env()
    bucket = env.get("S3_BUCKET", release.BUCKET)
    for local, key_name, content_type, cache in plan[:-1]:
        release.upload(env, bucket, local, key_name, content_type, cache)
        print(f"uploaded {key_name}")
    for game_id, entry in added.items():
        with urllib.request.urlopen(urllib.request.Request(entry["url"], method="HEAD"), timeout=30) as response:
            if int(response.headers.get("Content-Length", -1)) != entry["size"]:
                raise SystemExit(f"{entry['url']} has the wrong size; catalog NOT published")
    local, key_name, content_type, cache = plan[-1]
    release.upload(env, bucket, local, key_name, content_type, cache)
    print(f"uploaded {key_name} (last). Catalog serial {catalog['serial']} is live.")


if __name__ == "__main__":
    main()
