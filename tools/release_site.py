#!/usr/bin/env python3
"""Refresh the public website catalog from the live signed stable releases."""
import argparse
import datetime
import json
from pathlib import Path
import re
import tempfile
import urllib.error
import urllib.request

import release

SOURCE = release.ROOT / "web/site"
PREVIEW = release.ROOT / "builds/release/site/catalog.json"
BASE = f"{release.PUBLIC_BASE}/games/gizmo-jam/"
SITE_PREFIX = "games/gizmo-jam/site"
CATALOG_KEY = f"{SITE_PREFIX}/catalog.json"
CATALOG_URL = f"{release.PUBLIC_BASE}/{CATALOG_KEY}"
CACHE_IMMUTABLE = "public, max-age=31536000, immutable"
CACHE_CATALOG = "no-cache"
MISSING = (403, 404)


def checked_text(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"expected nonempty text, got {value!r}")


def game_content(pack_catalog):
    """Select the public games and turn local image paths into Wasabi URLs."""
    source = json.loads((SOURCE / "catalog.json").read_text(encoding="utf-8"))
    games = source["minigames"]
    ids = [game["id"] for game in games]
    if not ids or len(ids) != len(set(ids)) or any(not re.fullmatch(r"[a-z0-9-]+", i) for i in ids):
        raise ValueError("website minigame IDs must be unique lowercase slugs")
    packs = pack_catalog["games"]
    listed = {game["id"].replace("-", "_") for game in games if game.get("desktopLibrary")}
    if missing := packs.keys() - listed:
        raise ValueError(f"add website entries for {', '.join(sorted(missing))} to web/site/catalog.json")
    source["minigames"] = [
        game for game in games if not game.get("desktopLibrary") or game["id"].replace("-", "_") in packs
    ]
    for game in source["minigames"]:
        for field in ("name", "caption", "description", "controls"):
            checked_text(game[field])
        if "touchControls" in game:
            checked_text(game["touchControls"])

    assets = {}

    def image_url(filename):
        if not re.fullmatch(r"img/[a-z0-9][a-z0-9-]*\.webp", filename):
            raise ValueError(f"invalid website screenshot path: {filename!r}")
        path = SOURCE / filename
        digest = release.sha256_file(path)
        key = f"{SITE_PREFIX}/img/{digest}/{path.name}"
        assets[key] = path
        return f"{release.PUBLIC_BASE}/{key}"

    for shot in source["extraScreenshots"]:
        checked_text(shot["caption"])
    for shot in [game["screenshot"] for game in source["minigames"]] + source["extraScreenshots"]:
        checked_text(shot["alt"])
        width, height = shot["width"], shot["height"]
        if type(width) is not int or type(height) is not int or min(width, height) <= 0:
            raise ValueError(f"invalid website screenshot dimensions for {shot['file']}")
        shot["file"] = image_url(shot["file"])
        sources = shot.get("sources", {})
        if any(not re.fullmatch(r"[1-9][0-9]*", size) or int(size) >= width for size in sources):
            raise ValueError(f"invalid responsive widths for {shot['file']}")
        shot["sources"] = {size: image_url(filename) for size, filename in sources.items()}
    return source, assets


def build_catalog(manifest, pack_catalog):
    from release_games import WEB_PREFIX, play_url

    catalog, assets = game_content(pack_catalog)
    version = manifest["version"]
    if not release.SEMVER.fullmatch(version):
        raise ValueError(f"invalid website release version: {version!r}")
    web_url = pack_catalog["web"]["url"]
    web_version = web_url.rsplit("/", 2)[-2]
    if (not release.SEMVER.fullmatch(web_version) or
            web_url != f"{release.PUBLIC_BASE}/{WEB_PREFIX}/{web_version}/GizmoJam-web-{web_version}.zip"):
        raise ValueError(f"unexpected browser archive URL: {web_url}")
    catalog["release"].update(
        version=version,
        date=datetime.date.fromisoformat(manifest["released"]).isoformat(),
        baseUrl=BASE,
        webPath=play_url(web_version).removeprefix(BASE),
        downloadPath="releases/{version}/{filename}",
    )
    for filename, (platform, _, _) in release.ARTIFACTS.items():
        artifact = manifest["platforms"][platform]
        if artifact["url"] != f"{BASE}releases/{version}/{filename}":
            raise ValueError(f"unexpected download URL: {artifact['url']}")
        catalog["release"]["downloads"][platform].update(
            filename=filename, sizeMb=round(artifact["size"] / 1_000_000)
        )
    return catalog, assets


def live_inputs(trusted):
    from release_games import catalog_key, live_catalog

    manifest = release.live_manifest(f"{release.PUBLIC_BASE}/{release.UPDATES_PREFIX}/stable.json", trusted)
    packs = live_catalog(f"{release.PUBLIC_BASE}/{catalog_key('stable')}", trusted)
    for payload in (manifest, packs):
        if payload is not None and (payload.get("schema"), payload.get("game"), payload.get("channel")) != (
            release.SCHEMA, release.GAME_ID, "stable"
        ):
            raise ValueError("unexpected stable release metadata")
    if packs is not None and packs.get("kind") != "catalog":
        raise ValueError("unexpected stable pack catalog")
    return manifest, packs


def request(url, method="GET"):
    return urllib.request.urlopen(
        urllib.request.Request(url, method=method, headers={"Cache-Control": "no-cache", "Origin": "https://timholum.com"}),
        timeout=20,
    )


def current_catalog():
    try:
        with request(CATALOG_URL) as response:
            if response.headers.get("Access-Control-Allow-Origin") not in ("*", "https://timholum.com"):
                raise ValueError(f"{CATALOG_URL} is missing CORS access for timholum.com")
            return response.headers["ETag"], response.read()
    except urllib.error.HTTPError as error:
        if error.code not in MISSING:
            raise
        return None, None


def image_size(url):
    try:
        with request(url, "HEAD") as response:
            return int(response.headers.get("Content-Length", -1))
    except urllib.error.HTTPError as error:
        if error.code not in MISSING:
            raise
        return None


def sync(env=None, bucket=release.BUCKET, allow_incomplete=False):
    """Use the latest signed pointers. A concurrent catalog write forces a fresh read."""
    trusted = release.embedded_keys()
    for _ in range(4):
        etag, old = current_catalog() if env is not None else (None, None)
        manifest, packs = live_inputs(trusted)
        if not manifest or not packs or "web" not in packs:
            message = "The website catalog needs both a live stable desktop release and a browser build."
            if allow_incomplete:
                print(message)
                return
            raise ValueError(message)

        catalog, assets = build_catalog(manifest, packs)
        data = (json.dumps(catalog, indent=2, ensure_ascii=False) + "\n").encode()
        if env is None:
            PREVIEW.parent.mkdir(parents=True, exist_ok=True)
            PREVIEW.write_bytes(data)
            print(f"Dry run: wrote {PREVIEW.relative_to(release.ROOT)}. Nothing uploaded.")
            return

        for key, path in assets.items():
            url = f"{release.PUBLIC_BASE}/{key}"
            size = image_size(url)
            if size is None:
                release.upload(env, bucket, path, key, "image/webp", CACHE_IMMUTABLE)
                print(f"uploaded {key}")
                size = image_size(url)
            if size != path.stat().st_size:
                raise ValueError(f"wrong size for website screenshot {url}")

        if old == data:
            print(f"Website catalog is current: {CATALOG_URL}")
            return

        # Put a complete catalog only after every referenced screenshot is readable.
        # The ETag prevents an overlapping release from overwriting a newer snapshot.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "catalog.json"
            path.write_bytes(data)
            condition = ("--if-match", etag) if etag else ("--if-none-match", "*")
            result = release.aws(
                env, "s3api", "put-object", "--bucket", bucket, "--key", CATALOG_KEY, "--body", str(path),
                "--content-type", "application/json", "--cache-control", CACHE_CATALOG, *condition, check=False,
            )
        if not result.returncode:
            if current_catalog()[0] is None:
                raise ValueError(f"{CATALOG_URL} is not publicly readable")
            print(f"Published website catalog: {CATALOG_URL}")
            return
        if "(PreconditionFailed)" not in result.stderr and "(ConditionalRequestConflict)" not in result.stderr:
            raise ValueError(result.stderr.strip())
    raise ValueError("website catalog changed during all publish attempts")


def sync_after_release(env, bucket):
    try:
        sync(env, bucket, allow_incomplete=True)
    except (OSError, ValueError, KeyError, TypeError, SystemExit) as error:
        raise SystemExit(
            f"The signed release is live, but the website catalog could not be refreshed: {error}\n"
            "Retry with: python3 tools/release_site.py --publish"
        ) from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true", help="upload the website catalog and screenshots to Wasabi")
    args = parser.parse_args()
    try:
        env = release.publisher_env() if args.publish else None
        sync(env, env.get("S3_BUCKET", release.BUCKET) if env is not None else release.BUCKET)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Website catalog: {error}\n")


if __name__ == "__main__":
    main()
