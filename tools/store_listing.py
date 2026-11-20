#!/usr/bin/env python3
"""Publish the Google Play store listing: text, icon, feature graphic, screenshots.

    tools/store_listing.py --review-clear --capture  re-take and publish after verifying no active review
    tools/store_listing.py --review-clear            publish builds/store/ and the text below
    tools/store_listing.py --dry-run     show what would change, upload nothing

Screenshots come from tools/store_shots.gd: the real game in phone mode
(--handheld: touch controls, larger UI), bots in every seat, under a virtual
display, at 1920x1080 (Play allows at most 2:1). The icon is assets/icon.svg as a full square, since
Play rounds the corners itself. The feature graphic is a clean frame from a
round with the title over it (see make_art()).

Listing rules (docs/specs/mobile-apps-and-touch.md, 13.5): the audience is 13+
and the listing must not market to children.

Needs the service account to have "Manage store presence" on the app in Play
Console, in addition to the release permissions tools/play_publish.py uses.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import play_publish  # noqa: E402
from play_publish import Edit, PlayError, UPLOAD, _request  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
STORE = ROOT / "builds/store"
SHOTS = STORE / "shots"
LANGUAGE = "en-US"
GODOT = ROOT / ".tools/Godot_v4.5.1-stable_linux.x86_64"
FONT = ROOT / "assets/fonts/Kanit-BlackItalic.ttf"

TITLE = "Gizmo Jam"
SHORT = "A bunch of short minigames to play together on your LAN."
FULL = """A bunch of short minigames. Play together on your LAN from a PC, a web browser or Android.

There are only two games right now, maybe more as time goes on. You get what you get. It's free: play it if you want, or don't, I don't care. I'm just playing with AI and having fun."""
WEBSITE = "https://timholum.com/games/gizmo-jam/"
EMAIL = "privacy@timholum.com"

# Screenshot files in store order; the -clean frames are only for the feature graphic.
SCREENSHOTS = ["2-spin-cycle.png", "4-live-wire.png", "3-spin-cycle.png", "5-live-wire.png", "1-menu.png"]


def capture():
    shutil.rmtree(SHOTS, ignore_errors=True)
    subprocess.run(["xvfb-run", "-a", "-s", "-screen 0 1920x1080x24", str(GODOT), "--path", str(ROOT),
                    "--audio-driver", "Dummy", "--resolution", "1920x1080", "--script", "res://tools/store_shots.gd",
                    "--", "--handheld"],
                   check=True, timeout=600)


def make_art():
    """icon-512.png and feature-1024x500.png from the source art and the clean frame."""
    svg = (ROOT / "assets/icon.svg").read_text()
    square = svg.replace('<rect width="128" height="128" rx="28" fill="#10172b"/>',
                         '<rect width="128" height="128" fill="#10172b"/>', 1)
    (STORE / "icon-square.svg").write_text(square)
    subprocess.run(["inkscape", str(STORE / "icon-square.svg"), "--export-type=png",
                    f"--export-filename={STORE / 'icon-512.png'}", "-w", "512", "-h", "512"],
                   check=True, capture_output=True)
    step = STORE / "feature-step.png"
    subprocess.run(["convert", str(SHOTS / "2-spin-cycle-clean.png"), "-crop", "1320x645+300+140", "+repage",
                    "-resize", "1024x500!", "(", "-size", "1024x250", "xc:rgba(8,12,26,0)", "-size", "1024x250",
                    "gradient:rgba(8,12,26,0)-rgba(8,12,26,0.92)", "-append", ")", "-compose", "over", "-composite",
                    "-font", str(FONT), "-pointsize", "92", "-stroke", "#0b1020", "-strokewidth", "10",
                    "-fill", "#0b1020", "-annotate", "+36+468", "GIZMO", "-stroke", "none", "-fill", "white",
                    "-annotate", "+36+468", "GIZMO", str(step)], check=True)
    width = int(subprocess.run(["convert", "-font", str(FONT), "-pointsize", "92", "label:GIZMO ", "-format", "%w", "info:"],
                               check=True, capture_output=True, text=True).stdout)
    subprocess.run(["convert", str(step), "-font", str(FONT), "-pointsize", "92", "-stroke", "#0b1020",
                    "-strokewidth", "10", "-fill", "#0b1020", "-annotate", f"+{36 + width}+468", "JAM",
                    "-stroke", "none", "-fill", "#b4f53c", "-annotate", f"+{36 + width}+468", "JAM",
                    "-alpha", "off", "-type", "TrueColor", str(STORE / "feature-1024x500.png")], check=True)
    step.unlink()


def upload_image(edit, image_type, path):
    url = f"{UPLOAD}/edits/{edit.id}/listings/{LANGUAGE}/{image_type}?uploadType=media"
    headers = {"Authorization": "Bearer " + edit.token, "Content-Type": "image/png"}
    status, body = _request("POST", url, path.read_bytes(), headers, timeout=300)
    if status >= 300:
        raise PlayError(f"{image_type} upload: HTTP {status} {body.get('error', {}).get('message', '')}")


def publish(dry_run=False, *, review_clear=False):
    if not dry_run:
        play_publish.require_review_clear(review_clear)
    images = {"icon": [STORE / "icon-512.png"], "featureGraphic": [STORE / "feature-1024x500.png"],
              "phoneScreenshots": [SHOTS / name for name in SCREENSHOTS]}
    # Tablets show the same landscape game.
    images["sevenInchScreenshots"] = images["phoneScreenshots"]
    images["tenInchScreenshots"] = images["phoneScreenshots"]
    for files in images.values():
        for path in files:
            if not path.exists():
                raise PlayError(f"missing {path}; run with --capture")
    print(f"Title: {TITLE}\nShort ({len(SHORT)}/80): {SHORT}\nFull ({len(FULL)}/4000):\n{FULL}\n")
    for kind, files in images.items():
        print(f"{kind}: {', '.join(p.name for p in files)}")
    if dry_run:
        print("Dry run: nothing uploaded.")
        return
    with Edit(play_publish.access_token(), review_clear=review_clear) as edit:
        details = edit.call("GET", f"/edits/{edit.id}/details")
        wanted = {"defaultLanguage": LANGUAGE, "contactWebsite": WEBSITE,
                  "contactEmail": details.get("contactEmail") or EMAIL}
        edit.call("PATCH", f"/edits/{edit.id}/details", wanted)
        edit.call("PUT", f"/edits/{edit.id}/listings/{LANGUAGE}",
                  {"language": LANGUAGE, "title": TITLE, "shortDescription": SHORT, "fullDescription": FULL})
        for kind, files in images.items():
            edit.call("DELETE", f"/edits/{edit.id}/listings/{LANGUAGE}/{kind}")
            for path in files:
                upload_image(edit, kind, path)
            print(f"uploaded {kind} ({len(files)})")
        edit.commit()
    print("Store listing updated on Google Play.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--capture", action="store_true", help="re-take the screenshots and redraw the art first")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--review-clear", action="store_true",
                        help="attest that Play Console shows no changes in review for Gizmo Jam")
    args = parser.parse_args(argv)
    try:
        if not args.dry_run:
            play_publish.require_review_clear(args.review_clear)
        STORE.mkdir(parents=True, exist_ok=True)
        if args.capture:
            capture()
        if args.capture or not (STORE / "feature-1024x500.png").exists():
            make_art()
        publish(args.dry_run, review_clear=args.review_clear)
    except PlayError as error:
        raise SystemExit(f"Google Play: {error}")


if __name__ == "__main__":
    main()
