#!/usr/bin/env python3
"""Regenerate Gizmo Jam announcer lines and sound effects with ElevenLabs.

Usage:
    ELEVENLABS_API_KEY=... python3 tools/generate_audio.py [--force] [--only id,id] [--reprocess]

Pipeline per manifest entry:
    1. Fetch raw audio from ElevenLabs (text-to-speech for "voice", sound-generation
       for "sfx") into tools/audio-source/<kind>/<id>.mp3. This cache is not exported.
    2. Post-process with ffmpeg + numpy: mono 44.1 kHz, trim leading/trailing silence,
       cap length, RMS-normalise with a peak ceiling, short fade in/out (no clicks).
    3. Encode to assets/audio/<kind>/<id>.ogg (Vorbis), which Godot imports natively.

Idempotent: entries whose .ogg already exists are skipped unless --force is passed.
--reprocess rebuilds the .ogg files from the cached source without calling the API.
If the sound-generation endpoint is refused (401/403), SFX fall back to procedural
synthesis written directly as .wav into assets/audio/sfx/.

The API key is read only from ELEVENLABS_API_KEY and is never printed or written.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "audio"
SRC_DIR = ROOT / "tools" / "audio-source"
API = "https://api.elevenlabs.io/v1"
RATE = 44100

# Premade ElevenLabs voice: "Adam - Dominant, Firm" (bright, brash tenor that cuts
# through a mix). Used as a generic hype announcer; no real person is imitated.
VOICE_ID = "pNInz6obpgDQGcFmaJgB"
VOICE_MODEL = "eleven_multilingual_v2"
VOICE_SETTINGS = {
    "stability": 0.32,
    "similarity_boost": 0.8,
    "style": 0.65,
    "use_speaker_boost": True,
}

# id, kind, text (voice) or prompt (sfx). Optional keys:
#   duration  - seconds requested from sound-generation (0.5..22)
#   max_len   - hard cap after trimming (seconds)
#   gain_db   - offset from the kind's loudness target
#   fade_out  - fade-out length in seconds
MANIFEST: list[dict] = [
    # ---- announcer -------------------------------------------------------
    {"id": "welcome", "kind": "voice", "text": "Welcome to Gizmo Jam!"},
    {"id": "game_spin_cycle", "kind": "voice", "text": "Spin Cycle!"},
    {"id": "three", "kind": "voice", "text": "Three!"},
    {"id": "two", "kind": "voice", "text": "Two!"},
    {"id": "one", "kind": "voice", "text": "One!"},
    {"id": "go", "kind": "voice", "text": "Go!"},
    {"id": "accelerating", "kind": "voice", "text": "Speeding up!"},
    {"id": "overdrive", "kind": "voice", "text": "Overdrive!"},
    {"id": "youre_out", "kind": "voice", "text": "You're out!"},
    {"id": "last_two", "kind": "voice", "text": "Down to the final two!"},
    {"id": "winner", "kind": "voice", "text": "We have a champion!"},
    {"id": "you_win", "kind": "voice", "text": "You win!"},
    {"id": "draw", "kind": "voice", "text": "It's a draw!"},
    {"id": "streak", "kind": "voice", "text": "On fire!"},
    {"id": "lobby", "kind": "voice", "text": "Waiting for players."},
    {"id": "player_joined", "kind": "voice", "text": "New challenger!"},
    {"id": "rematch", "kind": "voice", "text": "Run it back!"},
    # Live Wire
    {"id": "game_livewire", "kind": "voice", "text": "Live Wire!"},
    {"id": "surge", "kind": "voice", "text": "Surge incoming!"},
    {"id": "zapped", "kind": "voice", "text": "Zapped!"},
    {"id": "locked", "kind": "voice", "text": "Locked in!"},
    {"id": "ten_seconds", "kind": "voice", "text": "Ten seconds!"},
    {"id": "time_up", "kind": "voice", "text": "Time's up!"},
    # ---- sound effects ---------------------------------------------------
    {"id": "ui_hover", "kind": "sfx", "duration": 0.5, "max_len": 0.09, "gain_db": -9.0, "fade_out": 0.03,
     "prompt": "Single very short soft UI tick, tiny muted plastic click for a menu hover, clean, no reverb"},
    {"id": "ui_click", "kind": "sfx", "duration": 0.5, "max_len": 0.3, "gain_db": -3.0, "fade_out": 0.06,
     "prompt": "Crisp futuristic menu button confirm sound, short bright two-note digital chirp, clean, no reverb"},
    {"id": "ui_back", "kind": "sfx", "duration": 0.5, "max_len": 0.3, "gain_db": -4.0, "fade_out": 0.06,
     "prompt": "Short soft descending digital blip for a menu back or cancel button, clean, no reverb"},
    {"id": "countdown_tick", "kind": "sfx", "duration": 0.5, "max_len": 0.35, "gain_db": -2.0, "fade_out": 0.08,
     "prompt": "Single punchy electronic countdown beep, game show timer tick, one short tone, clean"},
    {"id": "countdown_go", "kind": "sfx", "duration": 1.0, "max_len": 0.8, "gain_db": 0.0, "fade_out": 0.2,
     "prompt": "Bright energetic electronic start horn blast, arcade race start GO signal, short and punchy"},
    {"id": "jump", "kind": "sfx", "duration": 0.5, "max_len": 0.35, "gain_db": -4.0, "fade_out": 0.08,
     "prompt": "Quick upward airy whoosh for a character jump, short cartoon hop swoosh, no voice"},
    {"id": "duck", "kind": "sfx", "duration": 0.5, "max_len": 0.3, "gain_db": -5.0, "fade_out": 0.08,
     "prompt": "Quick low sliding swish, sneakers sliding on a metal floor, short slide, no voice"},
    {"id": "clear", "kind": "sfx", "duration": 0.5, "max_len": 0.3, "gain_db": -4.0, "fade_out": 0.08,
     "prompt": "Short bright positive arcade blip, rising sparkle chime for success, clean"},
    {"id": "hit", "kind": "sfx", "duration": 0.5, "max_len": 0.45, "gain_db": -1.0, "fade_out": 0.1,
     "prompt": "Short sharp electric zap impact, energy rod hitting a robot runner, punchy crackle"},
    {"id": "eliminated", "kind": "sfx", "duration": 1.2, "max_len": 1.1, "gain_db": -1.0, "fade_out": 0.25,
     "prompt": "Sci-fi power down sound, electronic machine shutting off with a descending pitch sweep"},
    {"id": "rod_warn", "kind": "sfx", "duration": 0.5, "max_len": 0.3, "gain_db": -8.0, "fade_out": 0.1,
     "prompt": "Subtle soft high warning ping, small sci-fi proximity alert, single short tone"},
    {"id": "victory", "kind": "sfx", "duration": 4.0, "max_len": 3.4, "gain_db": 0.0, "fade_out": 0.6,
     "prompt": "Three second triumphant orchestral brass fanfare with synth, game show champion victory jingle, rising melody into a sustained final chord held for over a second"},
    {"id": "round_start", "kind": "sfx", "duration": 0.8, "max_len": 0.75, "gain_db": -2.0, "fade_out": 0.15,
     "prompt": "Big fast cinematic whoosh rising into an impact, energetic round start transition"},
    # Live Wire. "claim" retriggers several times a second: keep it tiny and quiet.
    {"id": "dash", "kind": "sfx", "duration": 0.5, "max_len": 0.3, "gain_db": -4.0, "fade_out": 0.08,
     "prompt": "Quick sharp airy whoosh burst, a character dashing forward fast, short swoosh, no voice"},
    {"id": "shove", "kind": "sfx", "duration": 0.5, "max_len": 0.28, "gain_db": -2.0, "fade_out": 0.08,
     "prompt": "Short dull body-check thud, padded shoulder bump between two players, single low thump, no voice"},
    {"id": "zap", "kind": "sfx", "duration": 0.5, "max_len": 0.5, "gain_db": -1.0, "fade_out": 0.1,
     "prompt": "Electric shock hit, harsh buzzing high-voltage zap with crackle shocking a character, short, no voice"},
    {"id": "claim", "kind": "sfx", "duration": 0.5, "max_len": 0.06, "gain_db": -11.0, "fade_out": 0.025,
     "prompt": "Single tiny soft tile tick, very short muted digital tap, clean, no reverb"},
    {"id": "loop_lock", "kind": "sfx", "duration": 0.8, "max_len": 0.7, "gain_db": -2.0, "fade_out": 0.15,
     "prompt": "Bright rising lock-in chime, quick ascending sparkle arpeggio ending on a confirmed ding, arcade capture success, clean"},
    {"id": "surge_warn", "kind": "sfx", "duration": 1.6, "max_len": 1.45, "gain_db": -4.0, "fade_out": 0.08,
     "prompt": "Sci-fi power charge-up riser, deep electrical hum sweeping upward in pitch from low to high and getting louder, energy weapon charging, ends at its peak"},
    {"id": "surge_fire", "kind": "sfx", "duration": 0.6, "max_len": 0.5, "gain_db": 0.0, "fade_out": 0.12,
     "prompt": "Sharp powerful electric beam blast, high-voltage energy discharge burst with instant attack, short and punchy"},
]

# RMS loudness targets in dBFS (before gain_db), and a common peak ceiling.
TARGET_RMS_DB = {"voice": -16.0, "sfx": -18.0}
PEAK_CEIL_DB = -1.0


def log(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------------------
# HTTP (stdlib only; the key goes into a header and nowhere else)
# ---------------------------------------------------------------------------
class ApiRefused(Exception):
    pass


def api_post(path: str, payload: dict, key: str, query: str = "") -> bytes:
    url = f"{API}{path}{query}"
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"xi-api-key": key, "Content-Type": "application/json", "Accept": "audio/mpeg"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read()
    except urllib.error.HTTPError as exc:
        body = exc.read()[:300].decode("utf-8", "replace")
        if exc.code in (401, 403):
            raise ApiRefused(f"HTTP {exc.code} on {path}") from None
        raise RuntimeError(f"HTTP {exc.code} on {path}: {body}") from None


def fetch_voice(entry: dict, key: str) -> bytes:
    return api_post(
        f"/text-to-speech/{VOICE_ID}",
        {"text": entry["text"], "model_id": VOICE_MODEL, "voice_settings": VOICE_SETTINGS},
        key,
        "?output_format=mp3_44100_128",
    )


def fetch_sfx(entry: dict, key: str) -> bytes:
    return api_post(
        "/sound-generation",
        {
            "text": entry["prompt"],
            "duration_seconds": max(0.5, min(22.0, entry.get("duration", 1.0))),
            "prompt_influence": 0.6,
        },
        key,
    )


# ---------------------------------------------------------------------------
# Post-processing
# ---------------------------------------------------------------------------
def decode(path: Path):
    import numpy as np

    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(RATE), "-f", "f32le", "-"],
        check=True, capture_output=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def process(samples, entry: dict):
    import numpy as np

    kind = entry["kind"]
    x = samples - samples.mean() if samples.size else samples
    peak = float(np.max(np.abs(x))) if x.size else 0.0
    if peak <= 1e-6:
        raise RuntimeError(f"{entry['id']}: silent audio")
    # Trim using a short-window envelope relative to the peak.
    win = int(RATE * 0.005)
    env = np.sqrt(np.convolve(x * x, np.ones(win) / win, mode="same"))
    thresh = peak * (10 ** (-42 / 20))
    idx = np.nonzero(env > thresh)[0]
    pre = int(RATE * 0.004)
    post = int(RATE * (0.06 if kind == "voice" else 0.03))
    start = max(0, idx[0] - pre)
    end = min(x.size, idx[-1] + post)
    x = x[start:end]
    max_len = entry.get("max_len")
    if max_len:
        x = x[: int(RATE * max_len)]
    # Loudness: RMS over the non-silent part, then peak ceiling.
    active = x[np.abs(x) > thresh]
    rms = float(np.sqrt(np.mean(active * active))) if active.size else peak
    target = TARGET_RMS_DB[kind] + entry.get("gain_db", 0.0)
    gain = (10 ** (target / 20)) / max(rms, 1e-9)
    ceil = 10 ** (PEAK_CEIL_DB / 20)
    gain = min(gain, ceil / max(float(np.max(np.abs(x))), 1e-9))
    x = x * gain
    # Fades: start and end must reach exactly zero.
    fi = max(2, int(RATE * 0.003))
    fo = max(2, min(x.size // 2, int(RATE * entry.get("fade_out", 0.08 if kind == "voice" else 0.05))))
    x[:fi] *= np.linspace(0.0, 1.0, fi) ** 2
    x[-fo:] *= np.cos(np.linspace(0.0, math.pi / 2, fo)) ** 2
    return x


def encode_ogg(x, dest: Path) -> None:
    import numpy as np

    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(".tmp.ogg")
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(RATE), "-ac", "1", "-i", "-",
         "-c:a", "libvorbis", "-q:a", "6", str(tmp)],
        input=np.clip(x, -1, 1).astype(np.float32).tobytes(), check=True,
    )
    tmp.replace(dest)


# ---------------------------------------------------------------------------
# Procedural SFX fallback (only used if sound-generation is refused)
# ---------------------------------------------------------------------------
def synth_sfx(sid: str) -> list[float]:
    import random

    rnd = random.Random(sid)

    def tone(f0, f1, dur, wave_="sine", decay=6.0, noise=0.0):
        n = int(RATE * dur)
        out, ph = [], 0.0
        for i in range(n):
            t = i / n
            f = f0 + (f1 - f0) * t
            ph += 2 * math.pi * f / RATE
            s = math.sin(ph) if wave_ == "sine" else (1.0 if math.sin(ph) > 0 else -1.0) * 0.5
            s = s * (1 - noise) + (rnd.uniform(-1, 1) * noise)
            out.append(s * math.exp(-decay * t))
        return out

    def cat(*parts):
        return [s for p in parts for s in p]

    table = {
        "ui_hover": lambda: tone(2400, 2200, 0.04, decay=9),
        "ui_click": lambda: cat(tone(880, 880, 0.06, decay=3), tone(1320, 1320, 0.12)),
        "ui_back": lambda: cat(tone(990, 990, 0.06, decay=3), tone(660, 600, 0.12)),
        "countdown_tick": lambda: tone(880, 880, 0.2, "square", decay=5),
        "countdown_go": lambda: tone(1320, 1320, 0.6, "square", decay=3),
        "jump": lambda: tone(300, 900, 0.25, noise=0.5, decay=4),
        "duck": lambda: tone(500, 200, 0.22, noise=0.7, decay=4),
        "clear": lambda: cat(tone(1047, 1047, 0.07, decay=2), tone(1568, 1568, 0.18)),
        "hit": lambda: tone(160, 60, 0.35, "square", noise=0.5, decay=5),
        "eliminated": lambda: tone(700, 60, 1.0, "square", decay=2),
        "rod_warn": lambda: tone(1760, 1760, 0.2, decay=7),
        "victory": lambda: cat(*(tone(f, f, d, "square", decay=1.5) for f, d in
                                 [(523, 0.18), (659, 0.18), (784, 0.18), (1047, 0.5), (784, 0.16), (1047, 1.6)])),
        "round_start": lambda: tone(150, 1200, 0.6, noise=0.8, decay=1.5),
        "dash": lambda: tone(400, 1500, 0.18, noise=0.8, decay=3),
        "shove": lambda: tone(140, 50, 0.16, noise=0.3, decay=6),
        "zap": lambda: tone(240, 90, 0.4, "square", noise=0.6, decay=4),
        "claim": lambda: tone(1900, 1700, 0.035, decay=9),
        "loop_lock": lambda: cat(tone(784, 784, 0.07, decay=2), tone(1047, 1047, 0.07, decay=2), tone(1568, 1568, 0.3)),
        "surge_warn": lambda: tone(90, 520, 1.4, "square", noise=0.15, decay=-1.2),
        "surge_fire": lambda: tone(1800, 200, 0.5, "square", noise=0.6, decay=3),
    }
    return table[sid]()


def write_wav(x, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(dest), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(int(max(-1, min(1, s)) * 32767).to_bytes(2, "little", signed=True) for s in x))


def procedural(entry: dict) -> Path:
    samples = synth_sfx(entry["id"])
    try:
        import numpy as np

        x = process(np.asarray(samples, dtype=np.float64), entry)
    except ImportError:
        peak = max(abs(s) for s in samples) or 1.0
        x = [s / peak * 0.5 for s in samples]
        fade = int(RATE * 0.003)
        for i in range(fade):
            x[i] *= i / fade
            x[-1 - i] *= i / fade
    dest = OUT_DIR / "sfx" / f"{entry['id']}.wav"
    write_wav(x, dest)
    return dest


# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--force", action="store_true", help="regenerate even if the output exists")
    ap.add_argument("--reprocess", action="store_true", help="rebuild outputs from cached source, no API calls")
    ap.add_argument("--only", default="", help="comma-separated ids to limit the run")
    ap.add_argument("--list", action="store_true", help="print the manifest as JSON and exit")
    args = ap.parse_args()

    if args.list:
        print(json.dumps(MANIFEST, indent=2))
        return 0
    if not shutil.which("ffmpeg"):
        log("ffmpeg is required for post-processing.")
        return 2

    only = {s.strip() for s in args.only.split(",") if s.strip()}
    entries = [e for e in MANIFEST if not only or e["id"] in only]
    unknown = only - {e["id"] for e in MANIFEST}
    if unknown:
        log(f"unknown ids: {', '.join(sorted(unknown))}")
        return 2

    key = os.environ.get("ELEVENLABS_API_KEY", "").strip()
    sfx_refused = False
    failures = 0
    for entry in entries:
        sid, kind = entry["id"], entry["kind"]
        dest = OUT_DIR / kind / f"{sid}.ogg"
        src = SRC_DIR / kind / f"{sid}.mp3"
        if not (args.force or args.reprocess) and (dest.exists() or dest.with_suffix(".wav").exists()):
            log(f"skip   {kind}/{sid} (exists)")
            continue
        try:
            if args.force or not src.exists():
                if args.reprocess:
                    log(f"miss   {kind}/{sid} (no cached source)")
                    continue
                if kind == "sfx" and sfx_refused:
                    log(f"synth  sfx/{sid} -> {procedural(entry).relative_to(ROOT)}")
                    continue
                if not key:
                    log("ELEVENLABS_API_KEY is not set.")
                    return 2
                try:
                    data = fetch_voice(entry, key) if kind == "voice" else fetch_sfx(entry, key)
                except ApiRefused as exc:
                    if kind != "sfx":
                        raise RuntimeError(str(exc)) from None
                    log(f"sound-generation refused ({exc}); using procedural SFX")
                    sfx_refused = True
                    log(f"synth  sfx/{sid} -> {procedural(entry).relative_to(ROOT)}")
                    continue
                src.parent.mkdir(parents=True, exist_ok=True)
                src.write_bytes(data)
                log(f"fetch  {kind}/{sid} ({len(data)} bytes)")
            encode_ogg(process(decode(src), entry), dest)
            log(f"write  {dest.relative_to(ROOT)}")
        except Exception as exc:  # keep going; report at the end
            failures += 1
            log(f"FAIL   {kind}/{sid}: {exc}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
