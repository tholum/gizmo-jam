"""Safety tests for flash.py. Read-only against the host: lsblk/findmnt only, and the
end-to-end tests write to temp files via --device-file. No block device is ever written.

    python3 -m unittest discover -s tools/pi-image/tests -v
"""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True  # keep __pycache__ out of tools/pi-image/
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("flash", HERE.parent / "flash.py")
flash = importlib.util.module_from_spec(spec)
sys.modules["flash"] = flash
spec.loader.exec_module(flash)

GiB = 1024**3


def disk(name, size, tran, rm=False, hotplug=False, children=(), mounts=(None,), model="X"):
    return {"name": name, "path": f"/dev/{name}", "size": size, "type": "disk", "tran": tran,
            "rm": rm, "model": model, "mountpoints": list(mounts), "hotplug": hotplug,
            "children": list(children)}


def part(name, size, mounts=(None,), typ="part"):
    return {"name": name, "path": f"/dev/{name}", "size": size, "type": typ, "tran": None,
            "rm": False, "model": None, "mountpoints": list(mounts), "hotplug": False}


class Evaluate(unittest.TestCase):
    def ok(self, dev, **kw):
        self.assertEqual(flash.evaluate(dev, set(), **kw), [])

    def bad(self, dev, needle, system=frozenset(), **kw):
        reasons = flash.evaluate(dev, set(system), **kw)
        self.assertTrue(any(needle in r for r in reasons), reasons)

    def test_usb_card_reader_accepted(self):
        self.ok(disk("sdc", 32 * GiB, "usb", rm=True, hotplug=True,
                     children=[part("sdc1", 512 * 1024**2, ["/media/u/bootfs"]),
                               part("sdc2", 6 * GiB, ["/media/u/rootfs"])]))

    def test_builtin_mmc_slot_accepted(self):
        self.ok(disk("mmcblk0", 64 * GiB, "mmc"))

    def test_old_lsblk_string_flags(self):
        self.ok(disk("sdd", 16 * GiB, None, rm="1", hotplug="0"))
        self.bad(disk("sdd", 16 * GiB, None, rm="0", hotplug="0"), "not removable")

    def test_nvme_rejected_even_if_small_and_hotplug(self):
        self.bad(disk("nvme0n1", 32 * GiB, "nvme", rm=True, hotplug=True), "NVMe")

    def test_fixed_sata_rejected(self):
        self.bad(disk("sda", 120 * GiB, "sata"), "not removable")

    def test_system_disk_rejected(self):
        d = disk("sdc", 32 * GiB, "usb", hotplug=True, children=[part("sdc1", GiB, ["/"])])
        self.bad(d, "mounted at /")
        self.bad(disk("sdc", 32 * GiB, "usb", hotplug=True), "system mount", system={"sdc"})

    def test_boot_and_odd_mounts_rejected(self):
        for mp in ("/boot", "/boot/efi", "/home", "/data", "/var/lib/x"):
            d = disk("sdc", 32 * GiB, "usb", hotplug=True, children=[part("sdc1", GiB, [mp])])
            self.bad(d, f"mounted at {mp}")

    def test_swap_rejected(self):
        d = disk("sdc", 32 * GiB, "usb", hotplug=True, children=[part("sdc1", GiB, ["[SWAP]"])])
        self.bad(d, "swap")

    def test_lvm_holder_rejected(self):
        d = disk("sdc", 32 * GiB, "usb", hotplug=True,
                 children=[part("sdc1", GiB, typ="part") | {"children": [part("vg-x", GiB, typ="lvm")]}])
        self.bad(d, "LVM")

    def test_size_limits(self):
        big = disk("sdc", 500 * 10**9, "usb", hotplug=True)
        self.bad(big, "256 GiB")
        self.ok(big, i_know=True)
        huge = disk("sdc", 5 * 10**12, "usb", hotplug=True)
        self.bad(huge, "2 TiB hard limit", i_know=True)
        self.bad(disk("sdc", 0, "usb", rm=True), "size 0")
        self.bad(disk("sdc", 4 * GiB, "usb", rm=True), "too small", image_size=6 * GiB)

    def test_partition_rejected(self):
        p = part("sdc1", GiB)
        self.bad(p, "not a whole disk")


class LiveHost(unittest.TestCase):
    """Read-only checks against this machine's real disks."""

    def test_every_nvme_and_root_disk_is_refused(self):
        tree = flash.lsblk()
        system = flash.system_disk_names(tree)
        root_src = subprocess.run(["findmnt", "-n", "-o", "SOURCE", "/"], capture_output=True,
                                  text=True).stdout.strip()
        root_disks = {line.split()[0] for line in subprocess.run(
            ["lsblk", "-n", "-s", "-r", "-o", "NAME,TYPE", root_src], capture_output=True,
            text=True).stdout.splitlines() if line.endswith(" disk")}
        self.assertTrue(root_disks, "could not find the disk behind /")
        self.assertTrue(root_disks <= system)
        seen = 0
        for dev in tree:
            reasons = flash.evaluate(dev, system, i_know=True)
            if dev["name"].startswith("nvme") or dev["name"] in root_disks:
                seen += 1
                self.assertTrue(reasons, f"{dev['name']} was not refused")
        self.assertGreater(seen, 0)

    def test_cli_refuses_root_disk(self):
        root_src = subprocess.run(["findmnt", "-n", "-o", "SOURCE", "/"], capture_output=True,
                                  text=True).stdout.strip()
        pk = subprocess.run(["lsblk", "-n", "-s", "-r", "-o", "PATH,TYPE", root_src],
                            capture_output=True, text=True).stdout.splitlines()
        root_disk = next(line.split()[0] for line in pk if line.endswith(" disk"))
        with tempfile.TemporaryDirectory() as td:
            img = Path(td) / "x.img"
            img.write_bytes(b"\0" * 4096)
            # Every step past the safety check is booby-trapped, so even a filter bug
            # could not unmount or write anything.
            trap = AssertionError("reached the write path")
            with mock.patch.object(flash, "write_image", side_effect=trap) as w, \
                    mock.patch.object(flash, "unmount_all", side_effect=trap) as u, \
                    mock.patch.object(flash, "run", side_effect=trap) as r, \
                    mock.patch("builtins.input", return_value="no"):
                rc = flash.main([str(img), "--device", root_disk, "--i-know"])
            self.assertEqual(rc, 1)
            for m in (w, u, r):
                m.assert_not_called()


class DeviceFile(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.dir = Path(self.td.name)
        self.img = self.dir / "a.img"
        self.img.write_bytes(bytes(range(256)) * 4096 * 4)  # 4 MiB

    def tearDown(self):
        self.td.cleanup()

    def test_roundtrip(self):
        target = self.dir / "card.bin"
        self.assertEqual(flash.main([str(self.img), "--device-file", str(target), "--yes"]), 0)
        self.assertEqual(target.read_bytes(), self.img.read_bytes())

    def test_verify_detects_corruption(self):
        target = self.dir / "card.bin"

        def bad_write(img, tgt, block):
            data = bytearray(Path(img).read_bytes())
            data[12345] ^= 0xFF
            Path(tgt).write_bytes(data)

        with mock.patch.object(flash, "write_image", side_effect=bad_write):
            self.assertEqual(flash.main([str(self.img), "--device-file", str(target), "--yes"]), 1)

    def test_wrong_confirmation_writes_nothing(self):
        target = self.dir / "card.bin"
        with mock.patch("builtins.input", return_value="/dev/sdb"):
            self.assertEqual(flash.main([str(self.img), "--device-file", str(target)]), 1)
        self.assertFalse(target.exists())

    def test_dev_paths_refused(self):
        self.assertEqual(flash.main([str(self.img), "--device-file", "/dev/null", "--yes"]), 1)

    def test_not_an_image(self):
        odd = self.dir / "odd.img"
        odd.write_bytes(b"abc")
        self.assertEqual(flash.main([str(odd), "--device-file", str(self.dir / "c"), "--yes"]), 1)


if __name__ == "__main__":
    unittest.main()
