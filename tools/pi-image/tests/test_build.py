"""Unit tests for build.py's generators and config validation (no image needed).

    python3 -m unittest discover -s tools/pi-image/tests -v
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep __pycache__ out of tools/pi-image/
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("build", HERE.parent / "build.py")
build = importlib.util.module_from_spec(spec)
sys.modules["build"] = build
spec.loader.exec_module(build)

try:
    import yaml  # only for round-trip checks; build.py itself never needs it
except ImportError:  # pragma: no cover
    yaml = None

PINS = json.loads((HERE.parent / "pins.json").read_text())
FAKE_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFak test@example"
BASE_CMDLINE = ("console=serial0,115200 console=tty1 root=PARTUUID=9586d7bf-02 rootfstype=ext4 "
                "fsck.repair=yes rootwait resize quiet splash plymouth.ignore-serial-consoles\n")


class Base(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.dir = Path(self.td.name)
        self.key = self.dir / "k.pub"
        self.key.write_text(FAKE_KEY + "\n")

    def tearDown(self):
        self.td.cleanup()

    def cfg(self, body: str, env=None):
        p = self.dir / "c.toml"
        p.write_text(f'ssh_public_keys = ["{self.key}"]\n' + body)
        return build.load_config(p, env or {})


class Config(Base):
    def test_defaults(self):
        c = self.cfg("")
        self.assertEqual((c.hostname, c.username, c.wifi_ssid, c.tailscale_key), ("gizmojam", "gizmo", "", ""))
        self.assertEqual(c.ssh_keys, [FAKE_KEY])

    def test_env_overrides_secrets(self):
        c = self.cfg('[wifi]\nssid = "Net"\npassword = "fromfile1"\ncountry = "US"\n[tailscale]\nauth_key = "tskey-a"\n',
                     env={"GIZMO_WIFI_PASSWORD": "fromenv12", "GIZMO_TAILSCALE_AUTH_KEY": "tskey-env"})
        self.assertEqual((c.wifi_password, c.tailscale_key), ("fromenv12", "tskey-env"))

    def test_rejections(self):
        bad = [
            'hostname = "Bad_Host"\n',
            'username = "root"\n',
            '[wifi]\nssid = "Net"\npassword = "short"\n',
            '[wifi]\nssid = "Net"\ncountry = ""\n',
            '[display]\nforce_hdmi_mode = "big"\n',
            '[extras]\npackages = ["ok", "rm -rf /"]\n',
            '[tailscale]\nauth_key = "tskey a b"\n',
        ]
        for body in bad:
            with self.subTest(body=body), self.assertRaises(build.BuildError):
                self.cfg(body)

    def test_private_key_rejected(self):
        self.key.write_text("-----BEGIN OPENSSH PRIVATE KEY-----\nxx\n")
        with self.assertRaises(build.BuildError):
            self.cfg("")

    def test_no_keys_rejected(self):
        p = self.dir / "c.toml"
        p.write_text("ssh_public_keys = []\n")
        with self.assertRaises(build.BuildError):
            build.load_config(p, {})


class Generators(Base):
    def test_cmdline(self):
        c = self.cfg('[wifi]\ncountry = "gb"\n[display]\nforce_hdmi_mode = "1280x720@60"\n')
        out = build.gen_cmdline(BASE_CMDLINE, c, "gizmojam-X")
        self.assertEqual(out.count("\n"), 1)
        self.assertTrue(out.startswith(BASE_CMDLINE.strip() + " ds=nocloud;i=gizmojam-X"))
        for tok in ("cfg80211.ieee80211_regdom=GB", "video=HDMI-A-1:1280x720@60D", "vc4.force_hotplug=1"):
            self.assertIn(tok, out.split())
        # Re-applying replaces our tokens instead of piling them up.
        again = build.gen_cmdline(out, c, "gizmojam-Y")
        self.assertEqual(again.count("ds=nocloud"), 1)
        self.assertIn("ds=nocloud;i=gizmojam-Y", again)
        plain = build.gen_cmdline(BASE_CMDLINE, self.cfg('[wifi]\ncountry = ""\n'), "id")
        self.assertEqual(plain, BASE_CMDLINE.strip() + " ds=nocloud;i=id\n")

    def test_firstboot_env_sources_in_bash(self):
        c = self.cfg('username = "gizmo"\n[extras]\npackages = ["aa", "bb"]\nkiosk = true\n')
        env = build.gen_firstboot_env(c, "gizmojam-X", PINS)
        f = self.dir / "fb.env"
        f.write_text(env)
        out = subprocess.run(["bash", "-c", 'set -eu; source "$1"; printf "%s|" "$GIZMO_USER" '
                              '"$GIZMO_EXTRA_PACKAGES" "$GIZMO_KIOSK" "$GIZMO_TAILSCALE" "$GIZMO_BUILD_ID"',
                              "x", str(f)], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, "gizmo|aa bb|1||gizmojam-X|")
        for key in ("GIZMO_USER", "GIZMO_HOSTNAME", "GIZMO_GODOT_ZIP", "GIZMO_GODOT_SHA512",
                    "GIZMO_TAILSCALE", "GIZMO_TAILSCALE_HOSTNAME", "GIZMO_TAILSCALE_SSH",
                    "GIZMO_EXTRA_PACKAGES", "GIZMO_KIOSK", "GIZMO_BUILD_ID"):
            self.assertIn(f"\n{key}=", "\n" + env)

    def test_sh_quote_is_inert(self):
        nasty = 'a"b$(touch /tmp/pwned)`id`\\c$HOME'
        out = subprocess.run(["bash", "-c", f"X={build.sh_quote(nasty)}; printf %s \"$X\""],
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, nasty)

    @unittest.skipIf(yaml is None, "PyYAML not available")
    def test_yaml_roundtrip_with_odd_strings(self):
        ssid = 'Café "Net" #1: \\ ✓'
        pw = "p@ss:w0rd #x'\""
        c = self.cfg(f'[wifi]\nssid = {json.dumps(ssid)}\npassword = {json.dumps(pw)}\ncountry = "US"\n')
        net = yaml.safe_load(build.gen_network_config(c))
        aps = net["network"]["wifis"]["wlan0"]["access-points"]
        self.assertEqual(aps, {ssid: {"password": pw}})
        ud = yaml.safe_load(build.gen_user_data(c, "id", "$6$salt$hash"))
        self.assertEqual(ud["user"]["passwd"], "$6$salt$hash")
        self.assertEqual(ud["user"]["ssh_authorized_keys"], [FAKE_KEY])
        self.assertEqual(ud["runcmd"], [["systemctl", "enable", "--now", "ssh"],
                                        ["bash", "/boot/firmware/gizmo/firstboot.sh"]])
        self.assertTrue(ud["user"]["sudo"].endswith("NOPASSWD:ALL"))
        self.assertIs(ud["ssh_pwauth"], False)

    @unittest.skipIf(yaml is None, "PyYAML not available")
    def test_open_network_and_minimal(self):
        c = self.cfg('[wifi]\nssid = "Open"\ncountry = "US"\n')
        net = yaml.safe_load(build.gen_network_config(c))
        self.assertEqual(net["network"]["wifis"]["wlan0"]["access-points"]["Open"],
                         {"auth": {"key-management": "none"}})
        self.assertIsNone(build.gen_network_config(self.cfg("")))
        ud = yaml.safe_load(build.gen_user_data(self.cfg(""), "id", None))
        self.assertIs(ud["user"]["lock_passwd"], True)
        self.assertNotIn("passwd", ud["user"])

    @unittest.skipUnless(shutil.which("cloud-init"), "cloud-init not installed")
    def test_cloud_init_schema(self):
        c = self.cfg('password = "x"\n[wifi]\nssid = "N"\npassword = "12345678"\ncountry = "US"\n')
        files = {"user-data": build.gen_user_data(c, "id", build.hash_password("x")),
                 "network-config": build.gen_network_config(c)}
        self.assertTrue(build.validate_cloud_config(files, self.dir))
        files["user-data"] += "bogus_key: 1\n"
        with self.assertRaises(build.BuildError):
            build.validate_cloud_config(files, self.dir)

    @unittest.skipUnless(shutil.which("openssl"), "openssl not installed")
    def test_password_hash(self):
        h = build.hash_password("test")
        self.assertTrue(h.startswith("$6$"))
        self.assertEqual(len(h.split("$")), 4)

    def test_stage_payload_skips_tests(self):
        src = self.dir / "payload"
        (src / "bin").mkdir(parents=True)
        (src / "tests").mkdir()
        (src / "bin" / "__pycache__").mkdir()
        (src / "firstboot.sh").write_text("#!/bin/bash\n")
        (src / "bin" / "gizmo-run").write_text("#!/bin/bash\n")
        (src / "tests" / "t.sh").write_text("x")
        (src / "bin" / "__pycache__" / "a.pyc").write_text("x")
        files = build.stage_payload(src, self.dir / "out")
        self.assertEqual(files, ["bin/gizmo-run", "firstboot.sh"])


if __name__ == "__main__":
    unittest.main()
