// A browser guest for tests/run_browser.py: headless Chrome over the DevTools
// protocol. Loads the page, clicks the canvas for keyboard focus, then taps
// Space every half second, and saves the console and a few screenshots.
//   node tests/browser_guest.mjs <url> <seconds> <outdir> <debug-port>
// Starts its own Chrome and stops exactly that PID at the end.
import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync, appendFileSync } from "node:fs";

const [url, seconds, outdir, port] = process.argv.slice(2);
mkdirSync(outdir, { recursive: true });
const log = `${outdir}/console.log`;
writeFileSync(log, "");
const note = (s) => appendFileSync(log, s + "\n");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const chrome = spawn(process.env.CHROME || "/usr/bin/google-chrome", [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${outdir}/profile`,
  "--no-first-run", "--no-default-browser-check", "--disable-extensions",
  "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
  "--window-size=1280,800", "about:blank"], { stdio: ["ignore", "ignore", "ignore"] });
console.log(`CHROME_PID ${chrome.pid}`);

let target;
for (let i = 0; i < 75 && !target; i++) {
  await sleep(200);
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    target = list.find((t) => t.type === "page");
  } catch {}
}
if (!target) { console.log("NO_CHROME_TARGET"); chrome.kill("SIGTERM"); process.exit(1); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let id = 0;
const pending = new Map();
const send = (method, params = {}) => new Promise((res) => {
  const n = ++id; pending.set(n, res); ws.send(JSON.stringify({ id: n, method, params }));
});
const t0 = Date.now();
const stamp = () => ((Date.now() - t0) / 1000).toFixed(1).padStart(6);
ws.addEventListener("message", (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m); pending.delete(m.id); return; }
  if (m.method === "Runtime.consoleAPICalled") {
    note(`${stamp()} [console.${m.params.type}] ${m.params.args.map((a) => a.value ?? a.description ?? "").join(" ")}`);
  } else if (m.method === "Runtime.exceptionThrown") {
    const d = m.params.exceptionDetails;
    note(`${stamp()} [exception] ${d.text} ${d.exception?.description ?? ""}`);
  }
});
await send("Runtime.enable");
await send("Page.enable");
note(`${stamp()} navigate ${url}`);
await send("Page.navigate", { url });
const shot = async (name) => {
  const r = await send("Page.captureScreenshot", { format: "png" });
  if (r.data) writeFileSync(`${outdir}/${name}.png`, Buffer.from(r.data, "base64"));
};
const end = Date.now() + Number(seconds) * 1000;
let n = 0;
while (Date.now() < end) {
  await sleep(500);
  n++;
  if (n === 20) {
    for (const type of ["mousePressed", "mouseReleased"]) {
      await send("Input.dispatchMouseEvent", { type, x: 1200, y: 60, button: "left", clickCount: 1 });
    }
  }
  if (n > 20) {
    await send("Input.dispatchKeyEvent", { type: "keyDown", key: " ", code: "Space", windowsVirtualKeyCode: 32, text: " " });
    await sleep(80);
    await send("Input.dispatchKeyEvent", { type: "keyUp", key: " ", code: "Space", windowsVirtualKeyCode: 32 });
  }
  if (n % 20 === 0) await shot(`shot-${String(n / 20).padStart(2, "0")}`);
}
ws.close();
chrome.kill("SIGTERM");
await sleep(1500);
let alive = true;
try { process.kill(chrome.pid, 0); } catch { alive = false; }
if (alive) chrome.kill("SIGKILL");
console.log(`CHROME_EXITED pid=${chrome.pid}`);
