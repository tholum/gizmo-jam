#!/usr/bin/env python3
"""Write a Gizmo Jam Pi image to an SD card, carefully.

    python3 tools/pi-image/flash.py                       # list candidate cards
    python3 tools/pi-image/flash.py IMAGE                 # same, for this image
    python3 tools/pi-image/flash.py IMAGE --device /dev/sdX

Only whole disks that are removable, hotplug, or attached over USB/MMC are accepted.
NVMe disks, the disk behind / and /boot (or any other system mount), disks holding
LVM/RAID/crypt volumes, and disks over 256 GiB (unless --i-know) are refused. You must
type the device path to confirm (or pass --yes). The card's partitions are unmounted,
the image is written with `sudo dd ... conv=fsync oflag=direct`, and then read back and
compared by sha256.

Python 3.12+, standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

LSBLK_COLUMNS = "NAME,PATH,SIZE,TYPE,TRAN,RM,MODEL,MOUNTPOINTS,HOTPLUG"
MAX_BYTES = 256 * 1024**3  # 256 GiB; --i-know lifts this
HARD_MAX_BYTES = 2 * 1024**4  # 2 TiB (SDXC maximum); nothing lifts this
CHUNK = 4 * 1024 * 1024
# A card's own partitions may be mounted here (desktop automount); they get unmounted.
USER_MOUNT_PREFIXES = ("/media/", "/run/media/", "/mnt/")
# Mounts whose backing disk is never a valid target, whatever lsblk says about it.
SYSTEM_MOUNTS = ("/", "/boot", "/boot/efi", "/boot/firmware", "/efi", "/home", "/usr", "/var",
                 "/opt", "/srv", "/tmp", "/nix", "/snap")
REMOVABLE_TRANSPORTS = {"usb", "mmc"}
NEVER_NAME_PREFIXES = ("nvme", "loop", "zram", "ram", "sr", "dm-", "md", "nbd", "rbd")


class FlashError(Exception):
    pass


def die(msg: str) -> None:
    raise FlashError(msg)


def human(n: int) -> str:
    size = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if size < 1024 or unit == "TiB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{n} B"


# ----------------------------------------------------------------- device discovery


def lsblk(*extra: str) -> list[dict]:
    r = subprocess.run(["lsblk", "-J", "-b", "-o", LSBLK_COLUMNS, *extra],
                       capture_output=True, text=True)
    if r.returncode != 0:
        die(f"lsblk failed: {r.stderr.strip()}")
    return json.loads(r.stdout).get("blockdevices", [])


def walk(dev: dict):
    """The device and all its descendants."""
    yield dev
    for child in dev.get("children") or []:
        yield from walk(child)


def flag(value) -> bool:
    """lsblk prints booleans as true/false (new) or "1"/"0" (old)."""
    return value in (True, 1, "1", "true")


def mountpoints(dev: dict) -> list[str]:
    return [m for m in (dev.get("mountpoints") or []) if m]


def system_disk_names(tree: list[dict] | None = None) -> set[str]:
    """Names of whole disks that back a system mount point or active swap."""
    tree = lsblk() if tree is None else tree
    names: set[str] = set()
    for disk in tree:
        for d in walk(disk):
            for mp in mountpoints(d):
                if mp in SYSTEM_MOUNTS or mp == "[SWAP]":
                    names.add(disk["name"])
    # Independent second source: ask findmnt + lsblk -s for each system mount.
    for mp in SYSTEM_MOUNTS:
        r = subprocess.run(["findmnt", "-n", "-o", "SOURCE", "--target", mp],
                           capture_output=True, text=True)
        src = r.stdout.strip().split("[")[0]
        if r.returncode != 0 or not src.startswith("/dev/"):
            continue
        r2 = subprocess.run(["lsblk", "-n", "-s", "-o", "NAME,TYPE", "-r", src],
                            capture_output=True, text=True)
        for line in r2.stdout.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[1] == "disk":
                names.add(parts[0])
    try:
        for line in Path("/proc/swaps").read_text().splitlines()[1:]:
            src = line.split()[0]
            if src.startswith("/dev/"):
                r = subprocess.run(["lsblk", "-n", "-s", "-o", "NAME,TYPE", "-r", src],
                                   capture_output=True, text=True)
                for l2 in r.stdout.splitlines():
                    p = l2.split()
                    if len(p) == 2 and p[1] == "disk":
                        names.add(p[0])
    except OSError:
        pass
    return names


def evaluate(dev: dict, system_disks: set[str], *, i_know: bool = False,
             image_size: int | None = None) -> list[str]:
    """Reasons this device must NOT be written. Empty list = acceptable target."""
    reasons: list[str] = []
    name = dev.get("name") or ""
    tran = (dev.get("tran") or "").lower()
    size = int(dev.get("size") or 0)
    if dev.get("type") != "disk":
        reasons.append(f"not a whole disk (type {dev.get('type')})")
    if name.startswith("nvme") or tran == "nvme":
        reasons.append("NVMe disk: never an SD card")
    elif name.startswith(NEVER_NAME_PREFIXES):
        reasons.append(f"{name} is a virtual/optical/mapper device")
    if name in system_disks:
        reasons.append("backs a system mount (/, /boot, swap, ...)")
    for d in walk(dev):
        for mp in mountpoints(d):
            if mp == "[SWAP]":
                reasons.append(f"{d.get('path')} is active swap")
            elif mp in SYSTEM_MOUNTS or not mp.startswith(USER_MOUNT_PREFIXES):
                reasons.append(f"{d.get('path')} is mounted at {mp} (not a removable-media mount)")
    holders = sorted({d.get("type") or "?" for d in list(walk(dev))[1:]
                      if d.get("type") != "part"})
    if holders:
        reasons.append(f"holds {'/'.join(holders)} volumes (LVM/RAID/crypt in use)")
    if not (flag(dev.get("rm")) or flag(dev.get("hotplug")) or tran in REMOVABLE_TRANSPORTS):
        reasons.append("not removable, not hotplug, not USB/MMC")
    if size <= 0:
        reasons.append("size 0 (no card inserted?)")
    elif size > HARD_MAX_BYTES:
        reasons.append(f"{human(size)} is bigger than any SD card (2 TiB hard limit)")
    elif size > MAX_BYTES and not i_know:
        reasons.append(f"larger than 256 GiB ({human(size)}); pass --i-know if this really is the card")
    if image_size is not None and 0 < size < image_size:
        reasons.append(f"too small for the image ({human(size)} < {human(image_size)})")
    # Dedupe, keep order.
    return list(dict.fromkeys(reasons))


def describe(dev: dict) -> str:
    model = (dev.get("model") or "").strip() or "?"
    flags = []
    if flag(dev.get("rm")):
        flags.append("removable")
    if flag(dev.get("hotplug")):
        flags.append("hotplug")
    return (f"{dev.get('path')}  {human(int(dev.get('size') or 0)):>10}  "
            f"{(dev.get('tran') or '-'):<5} {model}  [{', '.join(flags) or 'fixed'}]")


def print_partitions(dev: dict) -> None:
    kids = list(walk(dev))[1:]
    if not kids:
        print("    (no partitions)")
    for k in kids:
        mps = ", ".join(mountpoints(k)) or "not mounted"
        print(f"    {k.get('path')}  {human(int(k.get('size') or 0)):>10}  {k.get('type')}  {mps}")


def list_candidates(tree: list[dict], system: set[str], i_know: bool,
                    image_size: int | None) -> list[dict]:
    ok: list[dict] = []
    refused: list[tuple[dict, list[str]]] = []
    for dev in tree:
        if dev.get("type") != "disk":
            continue
        reasons = evaluate(dev, system, i_know=i_know, image_size=image_size)
        (refused.append((dev, reasons)) if reasons else ok.append(dev))
    print("Candidate SD cards:")
    if not ok:
        print("    none found. Insert the card (USB reader or built-in slot) and run again.")
    for dev in ok:
        print("    " + describe(dev))
        print_partitions(dev)
    if refused:
        print("\nRefused disks:")
        for dev, reasons in refused:
            print(f"    {dev.get('path')} ({human(int(dev.get('size') or 0))}, "
                  f"{(dev.get('model') or '?').strip()}): {'; '.join(reasons)}")
    return ok


# ---------------------------------------------------------------------- writing


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print("+ " + " ".join(cmd), flush=True)
    return subprocess.run(cmd, **kw)


def image_sha256(img: Path) -> str:
    side = img.with_name(img.name + ".sha256")
    try:
        if side.stat().st_mtime >= img.stat().st_mtime:
            digest, fname = side.read_text().split()[:2]
            if fname == img.name and len(digest) == 64:
                print(f"image sha256 (from {side.name}): {digest}")
                return digest
    except (OSError, ValueError):
        pass
    print("computing image sha256 ...", flush=True)
    h = hashlib.sha256()
    with open(img, "rb") as f:
        while chunk := f.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def read_back_sha256(target: str, length: int, use_sudo: bool, direct: bool) -> str:
    flags = "count_bytes" + (",direct" if direct else "")
    cmd = (["sudo"] if use_sudo else []) + [
        "dd", f"if={target}", "bs=4M", f"count={length}", f"iflag={flags}", "status=none"]
    print("+ " + " ".join(cmd) + " | sha256", flush=True)
    h = hashlib.sha256()
    done = 0
    last = -1
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    assert proc.stdout is not None
    while chunk := proc.stdout.read(CHUNK):
        h.update(chunk)
        done += len(chunk)
        pct = done * 100 // length
        if pct // 5 != last:
            last = pct // 5
            print(f"\r    verify {pct:3d}%", end="", flush=True)
    print()
    if proc.wait() != 0:
        die("reading the card back failed")
    if done != length:
        die(f"read back {done} bytes, expected {length}")
    return h.hexdigest()


def unmount_all(dev: dict) -> None:
    for d in list(walk(dev))[1:]:
        if not mountpoints(d):
            continue
        path = d["path"]
        if shutil.which("udisksctl"):
            r = run(["udisksctl", "unmount", "--no-user-interaction", "-b", path],
                    capture_output=True, text=True)
            if r.returncode == 0:
                continue
        r = run(["sudo", "umount", path])
        if r.returncode != 0:
            die(f"could not unmount {path}")


def write_image(img: Path, target: str, *, block: bool) -> None:
    sudo = ["sudo"] if block else []
    bmap = img.with_name(img.name + ".bmap")
    if block and shutil.which("bmaptool") and bmap.exists():
        cmd = sudo + ["bmaptool", "copy", "--bmap", str(bmap), str(img), target]
    else:
        cmd = sudo + ["dd", f"if={img}", f"of={target}", "bs=4M", "status=progress"] + (
            ["conv=fsync", "oflag=direct"] if block else ["conv=fsync,notrunc"])
    if run(cmd).returncode != 0:
        die("writing the image failed")
    run(["sync"])


def confirm(target: str, yes: bool) -> None:
    if yes:
        print(f"--yes given: writing to {target} without asking.")
        return
    print(f"\nEVERYTHING ON {target} WILL BE DESTROYED.")
    try:
        typed = input(f"Type the device path ({target}) to continue: ")
    except EOFError:
        typed = ""
    if typed.strip() != target:
        die("confirmation did not match; nothing was written")


def check_image(img_arg: Path) -> Path:
    img = img_arg.expanduser().resolve()
    if not img.is_file():
        die(f"image {img_arg} not found")
    if img.suffix in (".xz", ".gz", ".zst", ".zip"):
        die("pass the uncompressed .img (build.py writes it to .pi-image/out/)")
    size = img.stat().st_size
    if size == 0 or size % 512:
        die(f"{img} is {size} bytes, not a whole number of 512-byte sectors; not a disk image")
    return img


def flash_device(args, img: Path) -> int:
    device = os.path.realpath(args.device)
    if not device.startswith("/dev/"):
        die(f"{args.device} is not under /dev")
    try:
        st = os.stat(device)
    except OSError as e:
        die(f"{args.device}: {e.strerror}")
    if not stat.S_ISBLK(st.st_mode):
        die(f"{device} is not a block device")
    size = img.stat().st_size

    def find() -> dict:
        system = system_disk_names()
        for dev in lsblk():
            if dev.get("path") == device:
                reasons = evaluate(dev, system, i_know=args.i_know, image_size=size)
                if reasons:
                    die(f"refusing {device}: " + "; ".join(reasons))
                return dev
        die(f"{device} is not a whole disk listed by lsblk (partitions are not accepted; "
            "use the disk, e.g. /dev/sdb not /dev/sdb1)")
        raise AssertionError

    dev = find()
    print(f"\nImage:  {img} ({human(size)})")
    print(f"Target: {describe(dev)}")
    print_partitions(dev)
    confirm(device, args.yes)

    # Look again right before writing: the card might have been swapped meanwhile.
    again = find()
    if (again.get("size"), again.get("model")) != (dev.get("size"), dev.get("model")):
        die(f"{device} changed since it was confirmed; nothing was written")
    unmount_all(again)
    if any(mountpoints(d) for d in walk(find())):
        die(f"{device} still has mounted partitions; nothing was written")
    if run(["sudo", "-v"]).returncode != 0:
        die("sudo is needed to write the card")
    expected = None if args.no_verify else image_sha256(img)
    write_image(img, device, block=True)
    if expected:
        got = read_back_sha256(device, size, use_sudo=True, direct=True)
        if got != expected:
            die(f"VERIFY FAILED: card sha256 {got} != image {expected}. Do not use this card.")
        print(f"verified: the first {size} bytes of {device} match the image (sha256 {got})")
    print(f"\nDone. Remove the card safely:  udisksctl power-off -b {device}")
    return 0


def flash_file(args, img: Path) -> int:
    """Test hook: 'flash' into a regular file. Same flow, no sudo, no block devices."""
    target = Path(args.device_file).expanduser().absolute()
    real = os.path.realpath(target)
    if real.startswith(("/dev/", "/sys/", "/proc/")):
        die("--device-file must be a regular file, not something under /dev, /sys or /proc")
    if target.exists() and not target.is_file():
        die(f"--device-file {target} exists and is not a regular file")
    if target.exists() and os.path.samefile(target, img):
        die("--device-file is the image itself")
    size = img.stat().st_size
    print(f"\nImage:  {img} ({human(size)})")
    print(f"Target: {target} (regular file, test mode)")
    confirm(str(target), args.yes)
    expected = None if args.no_verify else image_sha256(img)
    write_image(img, str(target), block=False)
    if expected:
        got = read_back_sha256(str(target), size, use_sudo=False, direct=False)
        if got != expected:
            die(f"VERIFY FAILED: {got} != {expected}")
        print(f"verified: {target} matches the image (sha256 {got})")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Write a Gizmo Jam Pi image to an SD card (with safety checks).")
    ap.add_argument("image", nargs="?", type=Path,
                    help="image to write, e.g. .pi-image/out/latest.img")
    ap.add_argument("--device", help="whole-disk device of the SD card, e.g. /dev/sdb or /dev/mmcblk0")
    ap.add_argument("--yes", action="store_true", help="do not ask to type the device path")
    ap.add_argument("--no-verify", action="store_true", help="skip the read-back sha256 check")
    ap.add_argument("--i-know", action="store_true",
                    help="allow a target larger than 256 GiB, up to 2 TiB (other checks still apply)")
    ap.add_argument("--device-file", metavar="PATH",
                    help="testing: write to this regular file instead of a device")
    args = ap.parse_args(argv)

    try:
        if args.device and args.device_file:
            die("use either --device or --device-file")
        img = check_image(args.image) if args.image else None
        if args.device_file:
            if not img:
                die("an image is required")
            return flash_file(args, img)
        if not args.device:
            tree = lsblk()
            list_candidates(tree, system_disk_names(tree), args.i_know,
                            img.stat().st_size if img else None)
            print("\nTo write: python3 tools/pi-image/flash.py IMAGE --device /dev/sdX")
            return 0
        if not img:
            die("an image is required with --device")
        return flash_device(args, img)
    except FlashError as e:
        print(f"\nERROR: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
