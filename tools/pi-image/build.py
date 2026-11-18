#!/usr/bin/env python3
"""Build a ready-to-flash Raspberry Pi 4 SD-card image for a Gizmo Jam box.

Takes the pinned Raspberry Pi OS (64-bit, desktop) image, and writes a cloud-init
NoCloud seed plus the tools/pi-image/payload/ tree and the Godot arm64 editor into
its FAT boot partition. Everything happens on an image file, without root: the
boot partition is edited in place with mtools.

    python3 tools/pi-image/build.py              # build with .pi-image/config.toml
    python3 tools/pi-image/build.py --dry-run    # show what would be written
    python3 tools/pi-image/build.py --help

Work directories (all under <repo>/.pi-image/, gitignored):
    cache/   downloads and the decompressed pristine base image (reused)
    out/     built images, latest.img symlink
    tools/   vendored mtools when mcopy is not installed

Python 3.12+, standard library only.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WORK = REPO / ".pi-image"
CACHE = WORK / "cache"
OUT = WORK / "out"
TOOLS = WORK / "tools"
PINS_FILE = HERE / "pins.json"
EXAMPLE_CONFIG = HERE / "config.example.toml"
DEFAULT_CONFIG = WORK / "config.toml"
DEFAULT_PAYLOAD = HERE / "payload"

BOOT_GIZMO = "/boot/firmware/gizmo"
USER_AGENT = "gizmo-jam-pi-image-builder"
CHUNK = 4 * 1024 * 1024

# Names in payload/ that are never copied to the card.
PAYLOAD_EXCLUDE_TOP = {"tests"}
PAYLOAD_EXCLUDE_ANY = {"__pycache__", ".DS_Store", ".pytest_cache"}
# Paths under gizmo/ that build.py generates itself.
GENERATED_GIZMO_PATHS = ("firstboot.env", "secrets", "godot")


class BuildError(Exception):
    pass


def die(msg: str) -> None:
    raise BuildError(msg)


def info(msg: str) -> None:
    print(f"==> {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"WARNING: {msg}", file=sys.stderr, flush=True)


def human(n: int) -> str:
    size = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{n} B"


# --------------------------------------------------------------------------- config


@dataclass
class Config:
    hostname: str
    username: str
    ssh_keys: list[str]
    ssh_key_files: list[str]
    password: str
    timezone: str
    locale: str
    keyboard_layout: str
    wifi_ssid: str
    wifi_password: str
    wifi_country: str
    tailscale_key: str
    tailscale_hostname: str
    tailscale_ssh: bool
    force_hdmi_mode: str
    packages: list[str]
    kiosk: bool
    secret_sources: dict[str, str] = field(default_factory=dict)


HOSTNAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
RESERVED_USERS = {
    "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp",
    "proxy", "www-data", "backup", "list", "irc", "nobody", "systemd-network", "messagebus",
    "sshd", "lightdm", "rpi-first-boot-wizard", "avahi", "polkitd",
}
TIMEZONE_RE = re.compile(r"^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$")
LOCALE_RE = re.compile(r"^[A-Za-z]{2,3}(_[A-Za-z]{2})?(\.[A-Za-z0-9-]+)?(@[A-Za-z]+)?$")
KEYMAP_RE = re.compile(r"^[a-z]{2,8}([-_][a-z0-9]{1,16})?$")
COUNTRY_RE = re.compile(r"^[A-Z]{2}$")
HDMI_MODE_RE = re.compile(r"^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}(@[1-9][0-9]{1,2})?$")
PACKAGE_RE = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")
KEY_LINE_RE = re.compile(
    r"(^|\s)(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-nistp(256|384|521)|"
    r"sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\s+AAAA[0-9A-Za-z+/=]+"
)

KNOWN_KEYS = {
    "": {"hostname", "username", "ssh_public_keys", "password", "timezone", "locale",
         "keyboard_layout", "wifi", "tailscale", "display", "extras"},
    "wifi": {"ssid", "password", "country"},
    "tailscale": {"auth_key", "auth_key_file", "hostname", "ssh"},
    "display": {"force_hdmi_mode"},
    "extras": {"packages", "kiosk"},
}


def _get(table: dict, key: str, typ: type, default, where: str):
    val = table.get(key, default)
    if not isinstance(val, typ) or (typ is int and isinstance(val, bool)):
        die(f"config: {where}{key} must be a {typ.__name__}, got {type(val).__name__}")
    return val


def _no_ctrl(value: str, what: str) -> str:
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        die(f"config: {what} contains a control character or newline")
    return value


def read_ssh_keys(paths: list[str]) -> list[str]:
    keys: list[str] = []
    for raw in paths:
        p = Path(os.path.expanduser(raw))
        if not p.is_file():
            die(f"config: ssh_public_keys: {raw} not found (expanded to {p})")
        text = p.read_text(encoding="utf-8", errors="replace")
        if "PRIVATE KEY" in text:
            die(f"config: ssh_public_keys: {raw} is a PRIVATE key. List the .pub file instead.")
        found = 0
        for line in text.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if not KEY_LINE_RE.search(line):
                die(f"config: ssh_public_keys: {raw} has a line that is not an OpenSSH public key")
            keys.append(line)
            found += 1
        if not found:
            die(f"config: ssh_public_keys: {raw} contains no keys")
    # Keep order, drop duplicates.
    return list(dict.fromkeys(keys))


def load_config(path: Path, env: dict[str, str] | None = None) -> Config:
    env = os.environ if env is None else env
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except tomllib.TOMLDecodeError as e:
        die(f"config: {path}: {e}")

    for section, known in KNOWN_KEYS.items():
        table = data if section == "" else data.get(section, {})
        if not isinstance(table, dict):
            die(f"config: [{section}] must be a table")
        for k in table:
            if k not in known:
                warn(f"config: unknown key {section + '.' if section else ''}{k} (typo?) is ignored")

    wifi = data.get("wifi", {})
    ts = data.get("tailscale", {})
    disp = data.get("display", {})
    extras = data.get("extras", {})
    sources: dict[str, str] = {}

    hostname = _get(data, "hostname", str, "gizmojam", "").strip().lower()
    if not HOSTNAME_RE.match(hostname):
        die(f"config: hostname {hostname!r} is not a valid hostname (a-z, 0-9, '-', max 63)")
    username = _get(data, "username", str, "gizmo", "").strip()
    if not USERNAME_RE.match(username) or username in RESERVED_USERS:
        die(f"config: username {username!r} is not allowed (lowercase, starts with a letter, "
            "not a system account)")

    key_files = _get(data, "ssh_public_keys", list, [], "")
    if not all(isinstance(k, str) for k in key_files):
        die("config: ssh_public_keys must be a list of file paths")
    if not key_files:
        die("config: ssh_public_keys is empty. SSH on the box accepts keys only, so at least "
            "one public key file is required.")
    ssh_keys = read_ssh_keys(key_files)

    password = _no_ctrl(_get(data, "password", str, "", ""), "password")
    timezone = _get(data, "timezone", str, "Etc/UTC", "").strip()
    if not TIMEZONE_RE.match(timezone):
        die(f"config: timezone {timezone!r} looks invalid (expected e.g. America/Chicago)")
    if Path("/usr/share/zoneinfo").is_dir() and not (Path("/usr/share/zoneinfo") / timezone).is_file():
        warn(f"config: timezone {timezone!r} is not in this host's /usr/share/zoneinfo")
    locale = _get(data, "locale", str, "en_US.UTF-8", "").strip()
    if not LOCALE_RE.match(locale):
        die(f"config: locale {locale!r} looks invalid (expected e.g. en_US.UTF-8)")
    keyboard = _get(data, "keyboard_layout", str, "us", "").strip()
    if not KEYMAP_RE.match(keyboard):
        die(f"config: keyboard_layout {keyboard!r} looks invalid (expected e.g. us, gb, de)")

    ssid = _no_ctrl(_get(wifi, "ssid", str, "", "wifi."), "wifi.ssid")
    wifi_password = _get(wifi, "password", str, "", "wifi.")
    if env.get("GIZMO_WIFI_PASSWORD"):
        wifi_password = env["GIZMO_WIFI_PASSWORD"]
        sources["wifi_password"] = "env GIZMO_WIFI_PASSWORD"
    _no_ctrl(wifi_password, "wifi.password")
    country = _get(wifi, "country", str, "", "wifi.").strip().upper()
    if ssid:
        if len(ssid.encode()) > 32:
            die("config: wifi.ssid is longer than 32 bytes")
        if wifi_password and not (
            8 <= len(wifi_password) <= 63 or re.fullmatch(r"[0-9a-fA-F]{64}", wifi_password)
        ):
            die("config: wifi.password must be 8-63 characters (or a 64-hex PSK); empty = open network")
        if not country:
            die("config: wifi.country is required when wifi.ssid is set (e.g. \"US\")")
    if country and not COUNTRY_RE.match(country):
        die(f"config: wifi.country {country!r} must be a 2-letter code like US, GB, DE")

    ts_key = _get(ts, "auth_key", str, "", "tailscale.").strip()
    ts_key_file = _get(ts, "auth_key_file", str, "", "tailscale.").strip()
    if ts_key and ts_key_file:
        die("config: set only one of tailscale.auth_key and tailscale.auth_key_file")
    if ts_key_file:
        kp = Path(os.path.expanduser(ts_key_file))
        if not kp.is_file():
            die(f"config: tailscale.auth_key_file {ts_key_file} not found")
        ts_key = kp.read_text(encoding="utf-8").strip()
        sources["tailscale_key"] = f"file {ts_key_file}"
    if env.get("GIZMO_TAILSCALE_AUTH_KEY"):
        ts_key = env["GIZMO_TAILSCALE_AUTH_KEY"].strip()
        sources["tailscale_key"] = "env GIZMO_TAILSCALE_AUTH_KEY"
    if ts_key:
        if any(c.isspace() for c in ts_key) or any(ord(c) < 32 for c in ts_key):
            die("config: the Tailscale auth key contains whitespace")
        if not ts_key.startswith("tskey-"):
            warn("Tailscale auth key does not start with 'tskey-'; using it anyway")
    ts_host = _get(ts, "hostname", str, "", "tailscale.").strip().lower() or hostname
    if not HOSTNAME_RE.match(ts_host):
        die(f"config: tailscale.hostname {ts_host!r} is not a valid hostname")
    ts_ssh = _get(ts, "ssh", bool, False, "tailscale.")

    mode = _get(disp, "force_hdmi_mode", str, "", "display.").strip()
    if mode and not HDMI_MODE_RE.match(mode):
        die(f"config: display.force_hdmi_mode {mode!r} must look like 1920x1080@60 or 1280x720")

    packages = _get(extras, "packages", list, [], "extras.")
    for p in packages:
        if not isinstance(p, str) or not PACKAGE_RE.match(p):
            die(f"config: extras.packages entry {p!r} is not a valid apt package name")
    kiosk = _get(extras, "kiosk", bool, False, "extras.")

    return Config(
        hostname=hostname, username=username, ssh_keys=ssh_keys, ssh_key_files=key_files,
        password=password, timezone=timezone, locale=locale, keyboard_layout=keyboard,
        wifi_ssid=ssid, wifi_password=wifi_password, wifi_country=country,
        tailscale_key=ts_key, tailscale_hostname=ts_host, tailscale_ssh=ts_ssh,
        force_hdmi_mode=mode, packages=list(dict.fromkeys(packages)), kiosk=kiosk,
        secret_sources=sources,
    )


# ------------------------------------------------------------------- file generation


def yq(value: str) -> str:
    """Quote a string for YAML. JSON double-quoted strings are valid YAML; additionally
    escape the few non-ASCII code points YAML does not allow raw."""
    s = json.dumps(value, ensure_ascii=False)
    out = []
    for ch in s:
        o = ord(ch)
        if 0x7F <= o <= 0x9F or o in (0x2028, 0x2029, 0xFEFF) or 0xD800 <= o <= 0xDFFF:
            out.append(f"\\u{o:04x}")
        else:
            out.append(ch)
    return "".join(out)


def sh_quote(value: str) -> str:
    """Double-quote a value for a shell-sourceable KEY="value" file."""
    for ch in value:
        if ord(ch) < 32 and ch != "\t":
            raise ValueError("control character in firstboot.env value")
    return '"' + re.sub(r'([\\"$`])', r"\\\1", value) + '"'


def gen_user_data(cfg: Config, build_id: str, passwd_hash: str | None) -> str:
    lines = [
        "#cloud-config",
        f"# Generated by tools/pi-image/build.py, build {build_id}.",
        "# This file stays readable on the card's boot partition: public keys and a password",
        "# hash only, never plaintext secrets.",
        "manage_resolv_conf: false",
        "",
        f"hostname: {yq(cfg.hostname)}",
        "manage_etc_hosts: true",
        f"timezone: {yq(cfg.timezone)}",
        f"locale: {yq(cfg.locale)}",
        "keyboard:",
        "  model: \"pc105\"",
        f"  layout: {yq(cfg.keyboard_layout)}",
        "# The Pi has no RTC: until NTP syncs, the clock may lag the apt repo's Release date.",
        "apt:",
        "  preserve_sources_list: true",
        "  conf: |",
        "    Acquire {",
        "      Check-Date \"false\";",
        "    };",
        "user:",
        f"  name: {yq(cfg.username)}",
        "  shell: \"/bin/bash\"",
    ]
    if passwd_hash:
        lines += ["  lock_passwd: false", f"  passwd: {yq(passwd_hash)}"]
    else:
        lines += ["  lock_passwd: true"]
    lines.append("  ssh_authorized_keys:")
    lines += [f"    - {yq(k)}" for k in cfg.ssh_keys]
    lines += [
        "  sudo: \"ALL=(ALL) NOPASSWD:ALL\"",
        "ssh_pwauth: false",
        "runcmd:",
        "  - [ systemctl, enable, --now, ssh ]",
        f"  - [ bash, {BOOT_GIZMO}/firstboot.sh ]",
        "",
    ]
    return "\n".join(lines)


def gen_meta_data(build_id: str) -> str:
    return f"instance-id: {build_id}\n"


def gen_network_config(cfg: Config, wifi_password: str | None = None) -> str | None:
    if not cfg.wifi_ssid:
        return None
    pw = cfg.wifi_password if wifi_password is None else wifi_password
    lines = [
        "# Generated by tools/pi-image/build.py (netplan v2, rendered by NetworkManager).",
        "network:",
        "  version: 2",
        "  ethernets:",
        "    eth0:",
        "      dhcp4: true",
        "      dhcp6: true",
        "      optional: true",
        "  wifis:",
        "    wlan0:",
        "      dhcp4: true",
        f"      regulatory-domain: {yq(cfg.wifi_country)}",
        "      access-points:",
        f"        {yq(cfg.wifi_ssid)}:",
    ]
    if pw:
        lines.append(f"          password: {yq(pw)}")
    else:
        lines += ["          auth:", "            key-management: \"none\""]
    lines += ["      optional: true", ""]
    return "\n".join(lines)


CMDLINE_OWNED_PREFIXES = ("ds=", "video=HDMI-A-1:", "cfg80211.ieee80211_regdom=", "vc4.force_hotplug=")


def gen_cmdline(original: str, cfg: Config, build_id: str) -> str:
    text = original.strip()
    if "\n" in text:
        die("cmdline.txt in the base image has more than one line; refusing to edit it")
    tokens = [t for t in text.split() if not t.startswith(CMDLINE_OWNED_PREFIXES)]
    tokens.append(f"ds=nocloud;i={build_id}")
    if cfg.wifi_country:
        tokens.append(f"cfg80211.ieee80211_regdom={cfg.wifi_country}")
    if cfg.force_hdmi_mode:
        tokens.append(f"video=HDMI-A-1:{cfg.force_hdmi_mode}D")
        tokens.append("vc4.force_hotplug=1")
    return " ".join(tokens) + "\n"


def gen_firstboot_env(cfg: Config, build_id: str, pins: dict) -> str:
    g = pins["godot"]
    values = [
        ("GIZMO_USER", cfg.username),
        ("GIZMO_HOSTNAME", cfg.hostname),
        ("GIZMO_GODOT_ZIP", f"godot/{g['filename']}"),
        ("GIZMO_GODOT_SHA512", g["sha512"]),
        ("GIZMO_TAILSCALE", "1" if cfg.tailscale_key else ""),
        ("GIZMO_TAILSCALE_HOSTNAME", cfg.tailscale_hostname),
        ("GIZMO_TAILSCALE_SSH", "1" if cfg.tailscale_ssh else ""),
        ("GIZMO_EXTRA_PACKAGES", " ".join(cfg.packages)),
        ("GIZMO_KIOSK", "1" if cfg.kiosk else ""),
        ("GIZMO_BUILD_ID", build_id),
    ]
    body = "\n".join(f"{k}={sh_quote(v)}" for k, v in values)
    return ("# Generated by tools/pi-image/build.py. Sourced by firstboot.sh. "
            "Empty value = off.\n" + body + "\n")


def hash_password(password: str) -> str:
    """sha512-crypt via openssl; the password goes over stdin, never argv."""
    if not shutil.which("openssl"):
        die("openssl is needed to hash the configured password (sudo apt install openssl)")
    r = subprocess.run(["openssl", "passwd", "-6", "-stdin"], input=password + "\n",
                       capture_output=True, text=True)
    out = r.stdout.strip()
    if r.returncode != 0 or not out.startswith("$6$"):
        die(f"openssl passwd failed: {r.stderr.strip()}")
    return out


def validate_cloud_config(files: dict[str, str], tmpdir: Path) -> bool:
    """Run `cloud-init schema` on user-data (and network-config). Returns False if
    cloud-init is not installed. Raises BuildError on schema errors."""
    exe = shutil.which("cloud-init")
    if not exe:
        warn("cloud-init is not installed on this host: skipping user-data schema validation "
             "(sudo apt install cloud-init to enable it)")
        return False
    checks = [("user-data", "cloud-config")]
    if "network-config" in files:
        checks.append(("network-config", "network-config"))
    for name, schema in checks:
        p = tmpdir / f"validate-{name}"
        p.write_text(files[name], encoding="utf-8")
        try:
            r = subprocess.run([exe, "schema", "-c", str(p), "-t", schema],
                               capture_output=True, text=True)
        finally:
            p.unlink()
        # Drop cloud-init's own log noise (it cannot read the host's /etc/cloud as non-root).
        out = "\n".join(line for line in (r.stdout + r.stderr).splitlines()
                        if line.strip() and " - " not in line[:40]).strip()
        if r.returncode != 0 or "Error" in r.stdout:
            die(f"cloud-init schema rejected {name}:\n{out}")
        if "deprecat" in out.lower():
            warn(f"cloud-init schema: {name} uses deprecated keys:\n{out}")
        info(f"cloud-init schema: {name} valid")
    return True


# ------------------------------------------------------------------ hashing / downloads


def file_hash(path: Path, algo: str, label: str | None = None) -> str:
    h = hashlib.new(algo)
    size = path.stat().st_size
    done = 0
    last = -1
    with open(path, "rb") as f:
        while chunk := f.read(CHUNK):
            h.update(chunk)
            done += len(chunk)
            if label and size > 256 * 1024 * 1024:
                pct = done * 100 // size
                if pct // 10 != last:
                    last = pct // 10
                    print(f"\r    {label}: {algo} {pct:3d}%", end="", flush=True)
    if label and size > 256 * 1024 * 1024:
        print()
    return h.hexdigest()


def stamp_ok(path: Path, algo: str, expected: str, label: str) -> bool:
    """Verify a large file once; remember the result in <file>.verified keyed on size+mtime."""
    stamp = path.with_name(path.name + ".verified")
    st = path.stat()
    key = {"size": st.st_size, "mtime_ns": st.st_mtime_ns, algo: expected}
    try:
        if json.loads(stamp.read_text()) == key:
            return True
    except (OSError, ValueError):
        pass
    if file_hash(path, algo, label) != expected:
        return False
    stamp.write_text(json.dumps(key))
    return True


def download(url: str, dest: Path, size: int | None, algo: str, expected: str) -> None:
    """Download to <dest>.part (resuming with Range if possible), verify, rename."""
    part = dest.with_name(dest.name + ".part")
    start = part.stat().st_size if part.exists() else 0
    if size and start > size:
        part.unlink()
        start = 0
    if not (size and start == size):
        headers = {"User-Agent": USER_AGENT}
        if start:
            headers["Range"] = f"bytes={start}-"
        info(f"downloading {url}" + (f" (resuming at {human(start)})" if start else ""))
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                mode = "ab"
                if start and r.status != 206:
                    start, mode = 0, "wb"
                total = size or (start + int(r.headers.get("Content-Length") or 0))
                done = start
                last = -1
                with open(part, mode) as f:
                    while chunk := r.read(1024 * 1024):
                        f.write(chunk)
                        done += len(chunk)
                        if total:
                            pct = done * 100 // total
                            if pct // 5 != last:
                                last = pct // 5
                                print(f"\r    {human(done)} / {human(total)} ({pct}%)", end="",
                                      flush=True)
                print()
        except OSError as e:
            die(f"download failed ({e}); run again to resume. Partial file: {part}")
    got = file_hash(part, algo, dest.name)
    if got != expected:
        part.unlink()
        die(f"{dest.name}: {algo} mismatch (got {got}, pinned {expected}). Deleted the download.")
    os.replace(part, dest)
    info(f"{dest.name}: {algo} verified")


# --------------------------------------------------------------------- base image / godot


def ensure_base_xz(pins: dict, base_xz: Path | None) -> Path:
    b = pins["base_image"]
    dest = CACHE / f"{b['name']}.img.xz"
    if dest.exists() and stamp_ok(dest, "sha256", b["sha256"], dest.name):
        return dest
    if dest.exists():
        warn(f"{dest} does not match the pinned sha256; replacing it")
        dest.unlink()
    if base_xz:
        src = base_xz.expanduser().resolve()
        if not src.is_file():
            die(f"--base-xz {src} not found")
        info(f"checking {src} against pinned sha256")
        if file_hash(src, "sha256", src.name) != b["sha256"]:
            die(f"--base-xz {src} does not match the pinned sha256 {b['sha256']}")
        try:
            os.link(src, dest)
            info(f"hardlinked {src} into the cache")
        except OSError:
            info(f"copying {src} into the cache")
            shutil.copyfile(src, dest)
        stamp_ok(dest, "sha256", b["sha256"], dest.name)
        return dest
    download(b["url"], dest, b.get("size"), "sha256", b["sha256"])
    stamp_ok(dest, "sha256", b["sha256"], dest.name)
    return dest


def ensure_pristine(pins: dict, base_xz: Path | None) -> Path:
    """Decompressed, verified, read-only base image in the cache."""
    b = pins["base_image"]
    img = CACHE / f"{b['name']}.img"
    if img.exists():
        if img.stat().st_size == b["extract_size"] and stamp_ok(img, "sha256", b["extract_sha256"],
                                                                img.name):
            return img
        warn(f"cached {img.name} is damaged or modified; extracting it again")
        img.chmod(0o644)
        img.unlink()
    xz = ensure_base_xz(pins, base_xz)
    if not shutil.which("xz"):
        die("xz is needed to decompress the base image (sudo apt install xz-utils)")
    need = b["extract_size"] + 64 * 1024 * 1024
    if shutil.disk_usage(CACHE).free < need:
        die(f"not enough disk space in {CACHE} to decompress the base image ({human(need)} needed)")
    info(f"decompressing {xz.name} -> {img.name} ({human(b['extract_size'])})")
    part = img.with_name(img.name + ".part")
    h = hashlib.sha256()
    zero = bytes(CHUNK)
    total = 0
    last = -1
    proc = subprocess.Popen(["xz", "-dc", "-T0", str(xz)], stdout=subprocess.PIPE)
    assert proc.stdout is not None
    try:
        with open(part, "wb") as f:
            while chunk := proc.stdout.read(CHUNK):
                h.update(chunk)
                if chunk == zero[: len(chunk)]:
                    f.seek(len(chunk), os.SEEK_CUR)  # keep the cache file sparse
                else:
                    f.write(chunk)
                total += len(chunk)
                pct = total * 100 // b["extract_size"]
                if pct // 10 != last:
                    last = pct // 10
                    print(f"\r    {pct:3d}%", end="", flush=True)
            f.truncate(total)
        print()
    finally:
        rc = proc.wait()
    if rc != 0:
        part.unlink(missing_ok=True)
        die(f"xz failed with exit code {rc}")
    if total != b["extract_size"] or h.hexdigest() != b["extract_sha256"]:
        part.unlink(missing_ok=True)
        die(f"decompressed image does not match the pin (size {total}, sha256 {h.hexdigest()})")
    os.replace(part, img)
    img.chmod(0o444)
    st = img.stat()
    img.with_name(img.name + ".verified").write_text(json.dumps(
        {"size": st.st_size, "mtime_ns": st.st_mtime_ns, "sha256": b["extract_sha256"]}))
    info(f"{img.name}: extract sha256 verified")
    return img


def ensure_godot(pins: dict) -> Path:
    g = pins["godot"]
    dest = CACHE / "godot" / g["filename"]
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        if stamp_ok(dest, "sha512", g["sha512"], dest.name):
            return dest
        warn(f"cached {dest.name} does not match the pinned sha512; downloading it again")
        dest.unlink()
    download(g["url"], dest, g.get("size"), "sha512", g["sha512"])
    stamp_ok(dest, "sha512", g["sha512"], dest.name)
    return dest


# ----------------------------------------------------------------------------- mtools


class MTools:
    def __init__(self, bindir: Path | None):
        self.bindir = bindir
        self.env = dict(os.environ, MTOOLS_SKIP_CHECK="1", LC_ALL="C.UTF-8")

    def exe(self, name: str) -> str:
        return str(self.bindir / name) if self.bindir else name

    def run(self, name: str, *args: str) -> subprocess.CompletedProcess:
        r = subprocess.run([self.exe(name), *args], capture_output=True, env=self.env)
        if r.returncode != 0:
            die(f"{name} {' '.join(args)} failed: {r.stderr.decode(errors='replace').strip()}")
        return r


def ensure_mtools() -> MTools:
    if all(shutil.which(c) for c in ("mcopy", "mmd", "mtype", "mdir")):
        return MTools(None)
    vend = TOOLS / "mtools"
    bindir = vend / "usr" / "bin"
    if not (bindir / "mcopy").exists():
        info("mcopy not found: vendoring mtools into .pi-image/tools (no root needed)")
        if not (shutil.which("apt-get") and shutil.which("dpkg")):
            die("mtools is not installed and apt-get/dpkg are not available to vendor it. "
                "Install mtools with your package manager.")
        with tempfile.TemporaryDirectory(dir=TOOLS) as td:
            r = subprocess.run(["apt-get", "download", "mtools"], cwd=td, capture_output=True,
                               text=True)
            debs = list(Path(td).glob("mtools_*.deb"))
            if r.returncode != 0 or not debs:
                die("apt-get download mtools failed:\n" + r.stderr.strip() +
                    "\nInstall it instead: sudo apt install mtools")
            if vend.exists():
                shutil.rmtree(vend)
            subprocess.run(["dpkg", "-x", str(debs[0]), str(vend)], check=True)
    mt = MTools(bindir)
    r = subprocess.run([mt.exe("mcopy"), "-V"], capture_output=True, text=True, env=mt.env)
    if r.returncode != 0:
        die(f"vendored mcopy does not run: {r.stderr.strip()}. Install mtools: sudo apt install mtools")
    info(f"using vendored {r.stdout.splitlines()[0].strip()} from {bindir}")
    return mt


# ------------------------------------------------------------------------ image editing


def bootfs_offset(img: Path) -> int:
    r = subprocess.run(["sfdisk", "-J", str(img)], capture_output=True, text=True)
    if r.returncode != 0:
        die(f"sfdisk -J {img} failed: {r.stderr.strip()}")
    pt = json.loads(r.stdout)["partitiontable"]
    parts = pt.get("partitions") or []
    if not parts:
        die("base image has no partitions")
    p1 = parts[0]
    if p1.get("type", "").lower() not in ("c", "b", "e", "ef"):
        die(f"partition 1 has type {p1.get('type')}, expected FAT (c)")
    return int(p1["start"]) * int(pt.get("sectorsize", 512))


def image_spec(img: Path, offset: int) -> str:
    return f"{img}@@{offset}"


def stage_payload(payload: Path, dest: Path) -> list[str]:
    """Copy payload/ to dest, skipping tests/ and caches. Returns relative file list."""
    files: list[str] = []
    if not payload.is_dir():
        warn(f"payload directory {payload} does not exist; copying nothing from it")
        dest.mkdir(parents=True, exist_ok=True)
        return files

    def ignore(dirpath: str, names: list[str]) -> set[str]:
        skip = {n for n in names if n in PAYLOAD_EXCLUDE_ANY or n.endswith(".pyc")}
        if Path(dirpath).resolve() == payload.resolve():
            skip |= {n for n in names if n in PAYLOAD_EXCLUDE_TOP}
            for n in names:
                if n in GENERATED_GIZMO_PATHS:
                    warn(f"payload/{n} is overwritten/merged with what build.py generates")
        return skip

    shutil.copytree(payload, dest, ignore=ignore, symlinks=False, dirs_exist_ok=True)
    for p in sorted(dest.rglob("*")):
        if p.is_file():
            files.append(p.relative_to(dest).as_posix())
    return files


def write_bootfs(mt: MTools, spec: str, top_files: dict[str, bytes], gizmo_dir: Path) -> None:
    with tempfile.TemporaryDirectory(dir=WORK) as td:
        for name, content in top_files.items():
            p = Path(td) / name
            p.write_bytes(content)
            mt.run("mcopy", "-o", "-i", spec, str(p), f"::/{name}")
    mt.run("mcopy", "-s", "-o", "-m", "-i", spec, str(gizmo_dir), "::/")


def verify_bootfs(mt: MTools, spec: str, top_files: dict[str, bytes], gizmo_dir: Path) -> int:
    count = 0
    for name, content in top_files.items():
        if mt.run("mtype", "-i", spec, f"::/{name}").stdout != content:
            die(f"read-back of ::/{name} does not match what was written")
        count += 1
    for p in sorted(gizmo_dir.rglob("*")):
        if p.is_file():
            rel = p.relative_to(gizmo_dir).as_posix()
            got = mt.run("mtype", "-i", spec, f"::/gizmo/{rel}").stdout
            if hashlib.sha256(got).digest() != hashlib.sha256(p.read_bytes()).digest():
                die(f"read-back of ::/gizmo/{rel} does not match what was written")
            count += 1
    return count


# ------------------------------------------------------------------------------- main


def prepare_dirs() -> None:
    for d in (WORK, CACHE, OUT, TOOLS):
        d.mkdir(parents=True, exist_ok=True)
        d.chmod(0o700)  # images and config hold secrets


def ensure_config(path: Path) -> None:
    if path.exists():
        mode = path.stat().st_mode & 0o077
        if mode:
            warn(f"{path} is readable by other users; it may hold secrets. Run: chmod 600 {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(EXAMPLE_CONFIG, path)
    path.chmod(0o600)
    print(f"No config found. Copied the example to:\n    {path}\n"
          "Edit it (hostname, user, ssh_public_keys, optional Wi-Fi / Tailscale / password), "
          "then run build.py again.", file=sys.stderr)
    raise SystemExit(2)


def redact_preview(name: str, text: str) -> str:
    border = "-" * 72
    return f"{border}\n{name}\n{border}\n{text.rstrip()}\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Build a Raspberry Pi 4 SD-card image for a Gizmo Jam box.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Secrets may come from env vars GIZMO_WIFI_PASSWORD and GIZMO_TAILSCALE_AUTH_KEY.",
    )
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                    help=f"config file (default: {DEFAULT_CONFIG.relative_to(REPO)})")
    ap.add_argument("--payload", type=Path, default=DEFAULT_PAYLOAD,
                    help="payload directory copied to the card's gizmo/ (default: tools/pi-image/payload)")
    ap.add_argument("--base-xz", type=Path,
                    help="use a local copy of the pinned base .img.xz instead of downloading it")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be written (secrets redacted); touch no image")
    ap.add_argument("--compress", action="store_true", help="also write <image>.img.xz")
    ap.add_argument("--name", help="output image base name (default: gizmojam-<YYYYMMDD-HHMM>)")
    args = ap.parse_args(argv)

    try:
        return build(args)
    except BuildError as e:
        print(f"\nERROR: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130


def build(args: argparse.Namespace) -> int:
    pins = json.loads(PINS_FILE.read_text())
    config_path = args.config.expanduser().resolve()
    if not args.dry_run:
        prepare_dirs()
    ensure_config(config_path)
    cfg = load_config(config_path)
    payload = args.payload.expanduser().resolve()

    now = dt.datetime.now(dt.UTC)
    build_id = f"gizmojam-{now:%Y%m%dT%H%M%SZ}"
    name = args.name or f"gizmojam-{now:%Y%m%d-%H%M}"
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name) or name.endswith(".img"):
        die("--name may contain only letters, digits, '.', '_', '-' (no .img suffix)")

    passwd_hash = hash_password(cfg.password) if cfg.password else None

    files: dict[str, str] = {
        "user-data": gen_user_data(cfg, build_id, passwd_hash),
        "meta-data": gen_meta_data(build_id),
    }
    netcfg = gen_network_config(cfg)
    if netcfg:
        files["network-config"] = netcfg
    firstboot_env = gen_firstboot_env(cfg, build_id, pins)

    if not (payload / "firstboot.sh").is_file():
        warn(f"{payload}/firstboot.sh is missing: the card will create the user and enable SSH, "
             "but the Gizmo setup (Godot, helpers, Tailscale, autologin) will not run")

    WORK.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=WORK, prefix="validate-") as td:
        schema_checked = validate_cloud_config(files, Path(td))

    if args.dry_run:
        return dry_run(args, cfg, pins, payload, build_id, name, files, firstboot_env)

    mt = ensure_mtools()
    godot = ensure_godot(pins)
    pristine = ensure_pristine(pins, args.base_xz)

    out_img = OUT / f"{name}.img"
    if out_img.exists():
        die(f"{out_img} already exists; pass --name or delete it")
    need = pristine.stat().st_size + 256 * 1024 * 1024
    free = shutil.disk_usage(OUT).free
    if free < need:
        die(f"not enough free space in {OUT}: {human(free)} free, {human(need)} needed. "
            "Delete old images in .pi-image/out/.")

    part = out_img.with_name(out_img.name + ".part")
    part.unlink(missing_ok=True)
    info(f"copying pristine image -> {part.name}")
    subprocess.run(["cp", "--reflink=auto", "--sparse=always", str(pristine), str(part)], check=True)
    part.chmod(0o600)
    try:
        offset = bootfs_offset(part)
        spec = image_spec(part, offset)
        info(f"bootfs at byte offset {offset}")
        mt.run("mdir", "-i", spec, "::/cmdline.txt")
        original_cmdline = mt.run("mtype", "-i", spec, "::/cmdline.txt").stdout.decode()
        cmdline = gen_cmdline(original_cmdline, cfg, build_id)

        top = {k: v.encode() for k, v in files.items()}
        top["cmdline.txt"] = cmdline.encode()

        with tempfile.TemporaryDirectory(dir=WORK, prefix="stage-") as td:
            gizmo = Path(td) / "gizmo"
            payload_files = stage_payload(payload, gizmo)
            (gizmo / "godot").mkdir(exist_ok=True)
            shutil.copyfile(godot, gizmo / "godot" / godot.name)
            (gizmo / "firstboot.env").write_text(firstboot_env, encoding="utf-8")
            if cfg.tailscale_key:
                (gizmo / "secrets").mkdir(mode=0o700, exist_ok=True)
                (gizmo / "secrets" / "tailscale.key").write_text(cfg.tailscale_key)
            info(f"writing user-data, meta-data, {'network-config, ' if netcfg else ''}cmdline.txt "
                 f"and gizmo/ ({len(payload_files)} payload files + Godot zip) to bootfs")
            write_bootfs(mt, spec, top, gizmo)
            n = verify_bootfs(mt, spec, top, gizmo)
            info(f"read back {n} files from bootfs: all match")

        info("computing sha256 of the finished image")
        digest = file_hash(part, "sha256", part.name)
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    os.replace(part, out_img)
    (OUT / f"{name}.img.sha256").write_text(f"{digest}  {out_img.name}\n")
    latest = OUT / "latest.img"
    tmp_link = OUT / ".latest.img.tmp"
    tmp_link.unlink(missing_ok=True)
    tmp_link.symlink_to(out_img.name)
    os.replace(tmp_link, latest)

    xz_path = None
    if args.compress:
        xz_path = out_img.with_name(out_img.name + ".xz")
        info(f"compressing -> {xz_path.name} (takes a few minutes)")
        xz_part = xz_path.with_name(xz_path.name + ".part")
        with open(xz_part, "wb") as f:
            os.chmod(xz_part, 0o600)
            r = subprocess.run(["xz", "-T0", "-6", "-c", str(out_img)], stdout=f)
        if r.returncode != 0:
            xz_part.unlink(missing_ok=True)
            die("xz compression failed")
        os.replace(xz_part, xz_path)

    others = sorted(p for p in OUT.glob("*.img") if p.is_file() and not p.is_symlink()
                    and p != out_img)
    summary(cfg, out_img, digest, build_id, cmdline, xz_path, schema_checked, others)
    return 0


def dry_run(args, cfg: Config, pins: dict, payload: Path, build_id: str, name: str,
            files: dict[str, str], firstboot_env: str) -> int:
    print("DRY RUN: nothing is downloaded or written.\n")
    red_files = {
        "user-data": gen_user_data(cfg, build_id, "<redacted sha512-crypt hash>" if cfg.password else None),
        "meta-data": files["meta-data"],
    }
    if "network-config" in files:
        red_files["network-config"] = gen_network_config(
            cfg, "<redacted>" if cfg.wifi_password else "")
    fake_cmdline = "<base cmdline.txt>"
    print(redact_preview("bootfs: cmdline.txt (appended to the base image's line)",
                         gen_cmdline(fake_cmdline, cfg, build_id)))
    for k, v in red_files.items():
        print(redact_preview(f"bootfs: {k}", v))
    print(redact_preview("bootfs: gizmo/firstboot.env", firstboot_env))
    if cfg.tailscale_key:
        print(redact_preview("bootfs: gizmo/secrets/tailscale.key",
                             f"<redacted, {len(cfg.tailscale_key)} characters, from "
                             f"{cfg.secret_sources.get('tailscale_key', 'config')}>"))
    with tempfile.TemporaryDirectory() as td:
        listed = stage_payload(payload, Path(td) / "gizmo") if payload.is_dir() else []
    g = pins["godot"]
    print(redact_preview("bootfs: gizmo/ (payload)",
                         "\n".join(listed) or f"(empty: {payload} has no files)"))
    print(f"bootfs: gizmo/godot/{g['filename']} (sha512 {g['sha512'][:16]}...)")
    b = pins["base_image"]
    cached = {
        "base image (.img, pristine)": (CACHE / f"{b['name']}.img").exists(),
        "base image (.img.xz)": (CACHE / f"{b['name']}.img.xz").exists(),
        "Godot zip": (CACHE / "godot" / g["filename"]).exists(),
    }
    print("\ncache: " + ", ".join(f"{k}: {'present' if v else 'missing'}" for k, v in cached.items()))
    print(f"would write: {OUT / (name + '.img')}")
    return 0


def summary(cfg: Config, img: Path, digest: str, build_id: str, cmdline: str,
            xz_path: Path | None, schema_checked: bool, others: list[Path]) -> None:
    rel = os.path.relpath(img, Path.cwd())
    flash = os.path.relpath(HERE / "flash.py", Path.cwd())
    rows = [
        ("Image", f"{img}"),
        ("Size", f"{human(img.stat().st_size)} ({img.stat().st_size} bytes)"),
        ("sha256", digest),
        ("Instance id", build_id),
        ("User", f"{cfg.username} (uid 1000, passwordless sudo, "
                 f"{'console password set' if cfg.password else 'password locked'}, "
                 f"{len(cfg.ssh_keys)} SSH key(s))"),
        ("Hostname", f"{cfg.hostname} (ssh {cfg.username}@{cfg.hostname}.local)"),
        ("Wi-Fi", f"yes ({cfg.wifi_ssid}, {cfg.wifi_country})" if cfg.wifi_ssid else "no (Ethernet only)"),
        ("Tailscale", (f"yes (as {cfg.tailscale_hostname}"
                       f"{', Tailscale SSH' if cfg.tailscale_ssh else ''})") if cfg.tailscale_key else "no"),
        ("Forced HDMI", f"HDMI-A-1 {cfg.force_hdmi_mode}" if cfg.force_hdmi_mode else "no (EDID decides)"),
        ("Kiosk", "yes" if cfg.kiosk else "no"),
        ("Extra packages", " ".join(cfg.packages) or "-"),
        ("Schema check", "cloud-init schema passed" if schema_checked else "skipped (no cloud-init)"),
    ]
    if xz_path:
        rows.append(("Compressed", str(xz_path)))
    width = max(len(k) for k, _ in rows)
    print("\n" + "=" * 72)
    print("Gizmo Jam Pi image built")
    print("=" * 72)
    for k, v in rows:
        print(f"{k:<{width}}  {v}")
    print(f"{'cmdline.txt':<{width}}  {cmdline.strip()}")
    secrets = [what for what, on in (("Wi-Fi password", cfg.wifi_ssid and cfg.wifi_password),
                                     ("Tailscale auth key", cfg.tailscale_key),
                                     ("password hash", cfg.password)) if on]
    if secrets:
        print(f"\nThe image contains secrets ({', '.join(secrets)}): keep it private.")
    print("\nFlash it (lists candidate SD cards first, then asks you to type the device name):")
    print(f"    python3 {flash}")
    print(f"    python3 {flash} {rel} --device /dev/sdX")
    if others:
        total = sum(p.stat().st_blocks * 512 for p in others)
        print(f"\nNote: {len(others)} older image(s) in {OUT} use {human(total)}:")
        for p in others:
            print(f"    {p.name}")
        print("    delete them when you no longer need them.")


if __name__ == "__main__":
    sys.exit(main())
