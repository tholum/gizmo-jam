"""Tests for payload/bin/gizmo-pair against fake bluetoothctl/busctl (no Bluetooth needed).

    python3 -m unittest discover -s tools/pi-image/tests -v
"""

import http.client
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "payload" / "bin" / "gizmo-pair"

PAD = "AA:BB:CC:DD:EE:01"      # a gamepad that pairs
STUBBORN = "AA:BB:CC:DD:EE:02"  # a gamepad that refuses
SPEAKER = "AA:BB:CC:DD:EE:03"   # not a controller
OLD = "AA:BB:CC:DD:EE:04"       # already paired, asleep

FAKE_STATE = {
    "powered": False,
    "discovering": False,
    "devices": {
        PAD: {"Name": "Xbox Wireless Controller", "Icon": "input-gaming", "RSSI": -50},
        STUBBORN: {"Name": "Pro Controller", "Class": 0x002508, "RSSI": -70, "fail": "AuthenticationFailed"},
        SPEAKER: {"Name": 'Den 55" TV \\ \u00e9', "Icon": "audio-card", "RSSI": -40, "Maker": True},
        OLD: {"Name": "Wireless Controller", "Icon": "input-gaming", "Paired": True, "Trusted": True},
    },
}

# One script answers as both tools; argv[0]'s name says which.
FAKE = r'''#!PYTHON
import json, os, sys, time, signal
state_path = os.environ["FAKE_BT_STATE"]
with open(os.environ["FAKE_BT_LOG"], "a") as f:
    f.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\n")
def load():
    with open(state_path) as f: return json.load(f)
def save(s):
    tmp = state_path + ".tmp"
    with open(tmp, "w") as f: json.dump(s, f)
    os.replace(tmp, state_path)
def v(t, d): return {"type": t, "data": d}
args = sys.argv[1:]
if os.path.basename(sys.argv[0]) == "busctl":
    # busctl's plain output: signature, then values; arrays/dicts with counts,
    # variants with their signature, strings C-escaped (non-ASCII as \xNN).
    def q(text):
        out = '"'
        for b in text.encode():
            ch = chr(b)
            if ch in '"\\': out += "\\" + ch
            elif b < 32 or b >= 127: out += "\\x%02x" % b
            else: out += ch
        return out + '"'
    def props(d):
        parts = [str(len(d))]
        for k, (t, val) in d.items():
            if t == "b": val = "true" if val else "false"
            elif t in "so": val = q(val)
            parts += [q(k), t, str(val)]
        return " ".join(parts)
    s = load()
    objs = [
        ('/org/bluez', '1 "org.bluez.AgentManager1" 0'),
        ('/org/bluez/hci0', '2 "org.freedesktop.DBus.Introspectable" 0 "org.bluez.Adapter1" ' + props({
            "Address": ("s", "D8:3A:DD:00:00:01"), "Alias": ("s", "gizmojam"),
            "Powered": ("b", s["powered"]), "PowerState": ("s", "on" if s["powered"] else "off"),
            "Discovering": ("b", s["discovering"])})),
    ]
    for mac, d in s["devices"].items():
        p = {"Address": ("s", mac), "Adapter": ("o", "/org/bluez/hci0"),
             "Paired": ("b", d.get("Paired", False)), "Trusted": ("b", d.get("Trusted", False)),
             "Connected": ("b", d.get("Connected", False))}
        for k in ("Name", "Icon"):
            if k in d: p[k] = ("s", d[k])
        if "Class" in d: p["Class"] = ("u", d["Class"])
        if "RSSI" in d: p["RSSI"] = ("n", d["RSSI"])
        body = props(p)
        if d.get("Maker"):  # what broke busctl --json: a{qv} with an ay inside
            n, rest = body.split(" ", 1)
            body = f'{int(n) + 2} {rest} "ManufacturerData" a{{qv}} 2 117 ay 3 66 4 1 65305 ay 0 "UUIDs" as 1 "0000110a-0000-1000-8000-00805f9b34fb"'
        objs.append(("/org/bluez/hci0/dev_" + mac.replace(":", "_"), '1 "org.bluez.Device1" ' + body))
    print("a{oa{sa{sv}}} %d " % len(objs) + " ".join(q(path) + " " + body for path, body in objs))
    sys.exit(0)
timeout = None
while args and args[0].startswith("--"):
    if args[0] == "--timeout": timeout = float(args[1]); args = args[2:]
    elif args[0] == "--agent": args = args[2:]
    else: args = args[1:]
cmd, rest = args[0], args[1:]
s = load()
if cmd == "power":
    s["powered"] = rest[0] == "on"; save(s); print("Changing power on succeeded"); sys.exit(0)
if cmd == "scan":
    s["discovering"] = True; save(s)
    def stop(*_):
        s2 = load(); s2["discovering"] = False; save(s2); sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    time.sleep(timeout or 5); stop()
mac = rest[0]
d = s["devices"].get(mac)
if d is None:
    print(f"Device {mac} not available"); sys.exit(1)
if cmd == "pair":
    time.sleep(float(os.environ.get("FAKE_PAIR_DELAY", "0")))
    if d.get("fail"):
        print(f"Attempting to pair with {mac}\nFailed to pair: org.bluez.Error.{d['fail']}"); sys.exit(1)
    d["Paired"] = True; save(s); print("Pairing successful"); sys.exit(0)
if cmd == "trust":
    d["Trusted"] = True; save(s); print(f"Changing {mac} trust succeeded"); sys.exit(0)
if cmd == "connect":
    d["Connected"] = True; save(s); print("Connection successful"); sys.exit(0)
if cmd == "disconnect":
    d["Connected"] = False; save(s); print("Successful disconnected"); sys.exit(0)
if cmd == "remove":
    del s["devices"][mac]; save(s); print("Device has been removed"); sys.exit(0)
sys.exit(2)
'''

INPUT_DEVICES = textwrap.dedent("""\
    I: Bus=0003 Vendor=045e Product=028e Version=0110
    N: Name="Microsoft X-Box 360 pad"
    P: Phys=usb-0000:01:00.0-1.3/input0
    U: Uniq=
    H: Handlers=event5 js0

    I: Bus=0005 Vendor=054c Product=0ce6 Version=8100
    N: Name="DualSense Wireless Controller"
    U: Uniq=aa:bb:cc:dd:ee:09
    H: Handlers=event7 js1

    I: Bus=0005 Vendor=054c Product=0ce6 Version=8100
    N: Name="DualSense Wireless Controller Motion Sensors"
    H: Handlers=event8

    I: Bus=0011 Vendor=0001 Product=0001 Version=ab41
    N: Name="AT Translated Set 2 keyboard"
    H: Handlers=sysrq kbd event0 leds
    """)


def load_module(env: dict):
    os.environ.update(env)
    loader = importlib.machinery.SourceFileLoader("gizmo_pair", str(SCRIPT))
    spec = importlib.util.spec_from_loader("gizmo_pair", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    mod.log = lambda msg: None
    return mod


class PairServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.td = tempfile.TemporaryDirectory()
        d = Path(cls.td.name)
        fake = FAKE.replace("#!PYTHON", "#!" + sys.executable)
        for name in ("bluetoothctl", "busctl"):
            (d / name).write_text(fake)
            (d / name).chmod(0o755)
        (d / "input").write_text(INPUT_DEVICES)
        cls.state = d / "state.json"
        cls.log = d / "calls.log"
        cls.mod = load_module({
            "GIZMO_BLUETOOTHCTL": str(d / "bluetoothctl"), "GIZMO_BUSCTL": str(d / "busctl"),
            "GIZMO_INPUT_DEVICES": str(d / "input"), "FAKE_BT_STATE": str(cls.state),
            "FAKE_BT_LOG": str(cls.log),
        })
        cls.mod.ACTIONS = cls.mod.Actions()
        cls.srv = cls.mod.make_server("127.0.0.1", 0)
        cls.port = cls.srv.server_address[1]
        cls.thread = threading.Thread(target=cls.srv.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.mod.ACTIONS.scanner.stop()
        cls.srv.shutdown()
        cls.srv.server_close()
        cls.td.cleanup()

    def setUp(self):
        self.state.write_text(json.dumps(FAKE_STATE))
        self.log.write_text("")
        os.environ["FAKE_PAIR_DELAY"] = "0"
        with self.mod.ACTIONS.jobs_lock:
            self.mod.ACTIONS.jobs.clear()

    # -- helpers
    def request(self, method, path, body=None, headers=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        h = {"Content-Type": "application/json"} if body is not None else {}
        h.update(headers or {})
        c.request(method, path, body=json.dumps(body) if isinstance(body, dict) else body, headers=h)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r, data

    def post(self, path, body=None, headers=None):
        r, data = self.request("POST", path, body if body is not None else {}, headers)
        return r.status, json.loads(data)

    def get_state(self):
        r, data = self.request("GET", "/api/state")
        self.assertEqual(r.status, 200)
        return json.loads(data)

    def wait_job(self, mac, seconds=15):
        end = time.time() + seconds
        while time.time() < end:
            j = self.get_state()["jobs"].get(mac)
            if j and j["state"] in ("done", "failed"):
                return j
            time.sleep(0.1)
        self.fail(f"job for {mac} did not finish")

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines() if line.strip()]

    # -- tests
    def test_page_and_script(self):
        r, html = self.request("GET", "/")
        self.assertEqual(r.status, 200)
        self.assertIn("frame-ancestors 'none'", r.getheader("Content-Security-Policy"))
        self.assertIn(b'<script src="/app.js">', html)
        r, js = self.request("GET", "/app.js")
        self.assertEqual(r.status, 200)
        for page in (html, js):
            for banned in (b"prompt(", b"alert(", b"confirm(", b"innerHTML", b"document.write"):
                self.assertNotIn(banned, page)

    def test_state(self):
        s = self.get_state()
        self.assertTrue(s["available"])
        self.assertFalse(s["adapter"]["powered"])
        order = [d["address"] for d in s["devices"]]
        self.assertEqual(order[-1], SPEAKER, "controllers sort before other devices")
        by = {d["address"]: d for d in s["devices"]}
        self.assertTrue(by[STUBBORN]["gamepad"], "Class 0x2508 = peripheral/gamepad")
        self.assertFalse(by[SPEAKER]["gamepad"])
        self.assertEqual(by[SPEAKER]["name"], 'Den 55" TV \\ \u00e9', "escapes and UTF-8 decoded")
        self.assertTrue(by[OLD]["paired"])
        self.assertEqual([(p["name"], p["bus"], p["js"]) for p in s["pads"]],
                         [("Microsoft X-Box 360 pad", "USB", "js0"),
                          ("DualSense Wireless Controller", "Bluetooth", "js1")])
        self.assertEqual(s["pads"][1]["address"], "AA:BB:CC:DD:EE:09")
        self.assertEqual(s["pads"][0]["id"], "045e:028e")

    def test_pair_trust_connect(self):
        status, j = self.post("/api/pair", {"address": PAD})
        self.assertEqual(status, 200, j)
        job = self.wait_job(PAD)
        self.assertEqual(job["state"], "done")
        self.assertIn("Connected", job["message"])
        cmds = [c for c in self.calls() if c[0] == "bluetoothctl"]
        self.assertIn(["bluetoothctl", "--agent", "NoInputNoOutput", "pair", PAD], cmds)
        self.assertIn(["bluetoothctl", "trust", PAD], cmds)
        self.assertIn(["bluetoothctl", "connect", PAD], cmds)
        dev = {d["address"]: d for d in self.get_state()["devices"]}[PAD]
        self.assertTrue(dev["paired"] and dev["trusted"] and dev["connected"])

    def test_pair_refused_is_explained(self):
        self.post("/api/pair", {"address": STUBBORN})
        job = self.wait_job(STUBBORN)
        self.assertEqual(job["state"], "failed")
        self.assertIn("refused", job["message"])
        self.assertNotIn(["bluetoothctl", "trust", STUBBORN], self.calls())

    def test_pair_gone_device(self):
        self.post("/api/pair", {"address": "AA:BB:CC:DD:EE:77"})
        job = self.wait_job("AA:BB:CC:DD:EE:77")
        self.assertEqual(job["state"], "failed")
        self.assertIn("pairing mode", job["message"])

    def test_one_action_at_a_time(self):
        os.environ["FAKE_PAIR_DELAY"] = "1.5"
        self.assertEqual(self.post("/api/pair", {"address": PAD})[0], 200)
        status, j = self.post("/api/pair", {"address": STUBBORN})
        self.assertEqual(status, 409)
        self.assertIn("Busy", j["error"])
        self.wait_job(PAD)

    def test_disconnect_and_forget(self):
        self.post("/api/connect", {"address": OLD})
        self.assertEqual(self.wait_job(OLD)["state"], "done")
        self.post("/api/disconnect", {"address": OLD})
        self.assertEqual(self.wait_job(OLD)["message"], "Disconnected.")
        self.post("/api/forget", {"address": OLD})
        self.assertEqual(self.wait_job(OLD)["message"], "Forgotten.")
        self.assertNotIn(OLD, [d["address"] for d in self.get_state()["devices"]])

    def test_scan_powers_on_and_stops(self):
        status, j = self.post("/api/scan")
        self.assertEqual(status, 200, j)
        s = self.get_state()
        self.assertTrue(s["adapter"]["powered"], "scan turns Bluetooth on first")
        self.assertGreater(s["scanning"], 0)
        self.assertIn(["bluetoothctl", "--timeout", "20", "scan", "on"], self.calls())
        self.assertEqual(self.post("/api/scan/stop")[0], 200)
        self.assertEqual(self.get_state()["scanning"], 0)
        self.assertFalse(self.mod.ACTIONS.scanner.active())

    def test_bad_addresses_rejected(self):
        for bad in ["aa:bb:cc:dd:ee:01", "AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:01; rm -rf /",
                    "--help", 12, None, ["AA:BB:CC:DD:EE:01"]]:
            with self.subTest(bad=bad):
                status, j = self.post("/api/pair", {"address": bad})
                self.assertEqual(status, 400)
        self.assertEqual(self.calls(), [])

    def test_cross_site_and_bad_requests(self):
        host = f"127.0.0.1:{self.port}"
        cases = [
            ({"Origin": "http://evil.example"}, 403),
            ({"Origin": f"http://{host}", "Sec-Fetch-Site": "cross-site"}, 403),
            ({"Content-Type": "text/plain"}, 415),
            ({"Host": f"evil.example:{self.port}"}, 421),
            ({"Host": "127.0.0.1:1"}, 421),
        ]
        for headers, code in cases:
            with self.subTest(headers=headers):
                r, data = self.request("POST", "/api/pair", json.dumps({"address": PAD}),
                                       {"Content-Type": "application/json", **headers})
                self.assertEqual(r.status, code, data)
        r, _ = self.request("GET", "/api/state", headers={"Host": "attacker.example"})
        self.assertEqual(r.status, 421, "DNS rebinding: foreign Host refused on reads too")
        status, _ = self.post("/api/pair", {"address": PAD}, {"Origin": f"http://{host}"})
        self.assertEqual(status, 200, "same-origin request accepted")
        self.wait_job(PAD)
        r, _ = self.request("POST", "/api/nope", "{}", {"Content-Type": "application/json"})
        self.assertEqual(r.status, 404)
        r, _ = self.request("POST", "/api/scan", "[1]", {"Content-Type": "application/json"})
        self.assertEqual(r.status, 400)


class Helpers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module({})

    def test_client_ok(self):
        ok = ["192.168.1.5", "10.0.0.2", "172.18.16.20", "127.0.0.1", "::1", "fe80::1",
              "::ffff:192.168.1.5", "fd00::5", "fe80::1%wlan0"]
        bad = ["8.8.8.8", "100.64.0.1", "2001:4860::8888", "::ffff:8.8.8.8", "nonsense"]
        for a in ok:
            self.assertTrue(self.mod.client_ok(a), a)
        for a in bad:
            self.assertFalse(self.mod.client_ok(a), a)

    def test_host_ok(self):
        import socket
        name = socket.gethostname().lower()
        good = [f"{name}:8080", f"{name.upper()}.local:8080", "127.0.0.1:8080", "[::1]:8080",
                "192.168.1.9:8080"]
        for h in good:
            self.assertTrue(self.mod.host_ok(h, "::ffff:192.168.1.9", 8080), h)
        for h in ["evil.example:8080", f"{name}:9999", f"{name}", "192.168.1.10:8080", ""]:
            self.assertFalse(self.mod.host_ok(h, "192.168.1.9", 8080), h)

    def test_busctl_parse(self):
        text = ('a{oa{sa{sv}}} 1 "/org/bluez/hci0/dev_X" 1 "org.bluez.Device1" 5 '
                '"Name" s "A \\"q\\" \\xc3\\xa9 \\303\\251" "RSSI" n -61 "Paired" b true '
                '"ManufacturerData" a{qv} 1 76 ay 2 1 2 "Pair" (ii) 3 4')
        o = self.mod.busctl_parse(text)
        d = o["/org/bluez/hci0/dev_X"]["org.bluez.Device1"]
        self.assertEqual(d["Name"], 'A "q" \u00e9 \u00e9')
        self.assertEqual((d["RSSI"], d["Paired"], d["ManufacturerData"], d["Pair"]), (-61, True, {76: [1, 2]}, [3, 4]))
        with self.assertRaises(ValueError):
            self.mod.busctl_parse('a{sv} 2 "Name" s "x"')

    def test_ini_set(self):
        conf = textwrap.dedent("""\
            [General]
            # comment
            #FastConnectable = false
            Name = box

            [Policy]
            #AutoEnable=true
            ReconnectAttempts=3
            ReconnectAttempts=5
            """)
        out = conf
        for s, k, v in self.mod.BLUEZ_SETTINGS:
            out = self.mod.ini_set(out, s, k, v)
        self.assertIn("#FastConnectable = false\nFastConnectable = true\n", out)
        self.assertIn("Name = box\nTemporaryTimeout = 120\n\n[Policy]", out)
        self.assertIn("#AutoEnable=true\nAutoEnable = true\n", out)
        self.assertEqual(out.count("ReconnectAttempts"), 1)
        again = out
        for s, k, v in self.mod.BLUEZ_SETTINGS:
            again = self.mod.ini_set(again, s, k, v)
        self.assertEqual(again, out, "idempotent")
        self.assertEqual(self.mod.ini_set("", "Policy", "AutoEnable", "true"), "[Policy]\nAutoEnable = true\n")

    def test_setup_and_unblock(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            for n, kind, soft in (("rfkill0", "bluetooth", "1"), ("rfkill1", "wlan", "1")):
                (d / n).mkdir()
                (d / n / "type").write_text(kind + "\n")
                (d / n / "soft").write_text(soft + "\n")
            conf = d / "main.conf"
            conf.write_text("[General]\n#FastConnectable = false\n\n[Policy]\n#AutoEnable=true\n")
            conf.chmod(0o644)
            self.mod.RFKILL_DIR = str(d)
            from contextlib import redirect_stdout, redirect_stderr
            import io
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                self.assertEqual(self.mod.setup(str(conf)), 0)
                self.assertEqual(self.mod.setup(str(conf)), 0)
            self.assertEqual(out.getvalue().split(), ["changed", "unchanged"])
            self.assertEqual((d / "rfkill0" / "soft").read_text(), "0")
            self.assertEqual((d / "rfkill1" / "soft").read_text().strip(), "1", "Wi-Fi switch untouched")
            self.assertEqual(conf.stat().st_mode & 0o777, 0o644)
            self.assertIn("AutoEnable = true", conf.read_text())


if __name__ == "__main__":
    unittest.main()
