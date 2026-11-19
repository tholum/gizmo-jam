#!/bin/bash
# Host-side tests for the Pi helpers that do not need a Pi: gizmo-env (socket
# detection), gizmo-run (detach, registry, --stop/--wait/--timeout, refusing
# unknown PIDs) and gizmo-health (vcgencmd parsing, throttle bits, CSV, nulls).
# Uses fake runtime/X11 dirs, a fake "godot" and a fake vcgencmd under a temp
# dir; every process it starts is stopped by its exact PID.
#
#   bash tools/pi-image/payload/tests/test_helpers.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BIN=$(cd "$HERE/../bin" && pwd)
T=$(mktemp -d /tmp/gizmo-helpers-test.XXXXXX)
ME=$(id -un)
MYUID=$(id -u)
PASS=0
FAIL=0
STARTED_PIDS=()

cleanup() {
    local p
    for p in "${STARTED_PIDS[@]}"; do
        kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
    done
    rm -rf "$T"
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
indent() { printf "%s\n" "$1" | sed "s/^/    /"; }
checkc() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }

mksock() { python3 -I -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"; }

export GIZMO_RUNTIME_BASE="$T/run"
export GIZMO_X11_DIR="$T/x11"
export GIZMO_LIGHTDM_CONF="$T/lightdm.conf"
export GIZMO_CONF="$T/gizmo.conf"
mkdir -p "$T/x11" "$T/logs"

echo "# gizmo-env"
out=$("$BIN/gizmo-env" 2>&1); rc=$?
check "no runtime dir -> exit 3" [ "$rc" = 3 ]
echo "    $out"
mkdir -p "$T/run/$MYUID"
"$BIN/gizmo-env" >/dev/null 2>&1; rc=$?
check "runtime dir but no wayland socket -> exit 3" [ "$rc" = 3 ]
mksock "$T/run/$MYUID/wayland-1"
touch "$T/run/$MYUID/wayland-1.lock" "$T/run/$MYUID/wayland-0.lock"
mksock "$T/run/$MYUID/bus"
out=$("$BIN/gizmo-env"); rc=$?
check "session found -> exit 0" [ "$rc" = 0 ]
indent "$out"
check "WAYLAND_DISPLAY=wayland-1 (lock files ignored)" grep -qx 'export WAYLAND_DISPLAY=wayland-1' <<<"$out"
check "no X socket -> unset DISPLAY" grep -qx 'unset DISPLAY' <<<"$out"
mksock "$T/x11/X3"
mksock "$T/x11/X1"
mksock "$T/run/$MYUID/wayland-0"
out=$("$BIN/gizmo-env")
check "lowest wayland socket wins" grep -qx 'export WAYLAND_DISPLAY=wayland-0' <<<"$out"
check "lowest X socket owned by user -> DISPLAY=:1" grep -qx 'export DISPLAY=:1' <<<"$out"
check "DBUS address" grep -q "^export DBUS_SESSION_BUS_ADDRESS=unix:path=" <<<"$out"
check "eval works" bash -c "eval \"\$('$BIN/gizmo-env')\" && [ \"\$XDG_RUNTIME_DIR\" = '$T/run/$MYUID' ] && [ \"\$GIZMO_DESKTOP_USER\" = '$ME' ]"
out=$("$BIN/gizmo-env" --json)
check "--json is valid JSON" python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["WAYLAND_DISPLAY"]=="wayland-0"' "$out"
check "--user prints the user" [ "$("$BIN/gizmo-env" --user)" = "$ME" ]
"$BIN/gizmo-env" --for no-such-user-xyz >/dev/null 2>&1; rc=$?
check "unknown user -> exit 4" [ "$rc" = 4 ]
"$BIN/gizmo-env" --bogus >/dev/null 2>&1; rc=$?
check "bad option -> exit 2" [ "$rc" = 2 ]

echo "# gizmo-run"
cat >"$T/fake-godot" <<'EOF'
#!/bin/bash
echo "fake-godot args: $*"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} DISPLAY=${DISPLAY:-} SSH_CONNECTION=${SSH_CONNECTION:-none}"
for a in "$@"; do case "$a" in --exit=*) exit "${a#--exit=}" ;; esac; done
exec sleep 300
EOF
chmod +x "$T/fake-godot"
export GIZMO_GODOT="$T/fake-godot"
export SSH_CONNECTION="1.2.3.4 1 5.6.7.8 22"

out=$("$BIN/gizmo-run" --log "$T/logs/a.log" -- --path /some/project); rc=$?
indent "$out"
pid=$(sed -n 's/^pid=//p' <<<"$out")
[ -n "$pid" ] && STARTED_PIDS+=("$pid")
[ "$rc" = 0 ] && [ -n "$pid" ]; checkc "run -> exit 0 and a pid" $?
check "game is running" kill -0 "$pid"
sleep 0.3
check "log has default driver + args" grep -q 'fake-godot args: --rendering-driver opengl3_es --path /some/project' "$T/logs/a.log"
check "game sees session env" grep -q "WAYLAND_DISPLAY=wayland-0 DISPLAY=:1" "$T/logs/a.log"
check "SSH env not leaked" grep -q 'SSH_CONNECTION=none' "$T/logs/a.log"
check "game is in its own session (setsid)" [ "$(ps -o sid= -p "$pid" | tr -d ' ')" != "$(ps -o sid= -p $$ | tr -d ' ')" ]
check "--list shows it running" bash -c "'$BIN/gizmo-run' --list | grep -q 'pid=$pid state=running'"
check "--list --json valid" python3 -I -c 'import json,sys; assert any(e["pid"]==int(sys.argv[2]) for e in json.loads(sys.argv[1]))' "$("$BIN/gizmo-run" --list --json)" "$pid"

sleep 300 &
other=$!
STARTED_PIDS+=("$other")
"$BIN/gizmo-run" --stop "$other" >/dev/null 2>&1; rc=$?
check "--stop on a PID gizmo-run did not start -> refused (exit 1)" [ "$rc" = 1 ]
check "  ... and that process is untouched" kill -0 "$other"
kill "$other"; wait "$other" 2>/dev/null

out=$("$BIN/gizmo-run" --stop "$pid"); rc=$?
indent "$out"
[ "$rc" = 0 ] && grep -qx 'status=stopped' <<<"$out" && grep -qx 'exit=143' <<<"$out"; checkc "--stop -> exit 0, status=stopped, exit=143" $?
check "game is gone" bash -c "! kill -0 $pid 2>/dev/null"
check "--stop again -> already_exited" bash -c "'$BIN/gizmo-run' --stop $pid | grep -qx status=already_exited"
check "log records the exit" grep -q 'gizmo-run: exited rc=143' "$T/logs/a.log"

out=$("$BIN/gizmo-run" --wait --driver default --log "$T/logs/b.log" -- --exit=7); rc=$?
indent "$out"
[ "$rc" = 7 ] && grep -qx 'exit=7' <<<"$out"; checkc "--wait returns the game's exit code (7)" $?
check "--driver default passes no driver" grep -q 'fake-godot args: --exit=7$' "$T/logs/b.log"

out=$("$BIN/gizmo-run" --wait --timeout 1 --grace 2 --fullscreen --display wayland --log "$T/logs/c.log"); rc=$?
[ "$rc" = 124 ] && grep -qx 'timed_out=1' <<<"$out"; checkc "--wait --timeout -> exit 124, timed_out=1" $?
check "--fullscreen/--display passed" grep -q -- '--display-driver wayland --fullscreen' "$T/logs/c.log"

out=$("$BIN/gizmo-run" --json --wait --driver opengl3 --log "$T/logs/d.log" -- --exit=0); rc=$?
check "--json --wait is one valid object with exit 0" python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["exit"]==0 and d["timed_out"] is False and d["pid"]>0' "$out"

out=$("$BIN/gizmo-run" --log "$T/logs/e.log"); pid=$(sed -n 's/^pid=//p' <<<"$out"); STARTED_PIDS+=("$pid")
( sleep 1; "$BIN/gizmo-run" --stop "$pid" >/dev/null ) &
out=$("$BIN/gizmo-run" --wait-for "$pid"); rc=$?
wait
[ "$rc" = 143 ] && grep -qx 'exit=143' <<<"$out"; checkc "--wait-for sees the stop (exit=143)" $?

"$BIN/gizmo-run" --binary "$T/nope" >/dev/null 2>&1; rc=$?
check "missing binary -> exit 1" [ "$rc" = 1 ]
"$BIN/gizmo-run" --driver bogus >/dev/null 2>&1; rc=$?
check "bad driver -> exit 2" [ "$rc" = 2 ]
"$BIN/gizmo-run" /some/path >/dev/null 2>&1; rc=$?
check "args without -- -> exit 2" [ "$rc" = 2 ]
"$BIN/gizmo-run" --log /proc/nope/x.log >/dev/null 2>&1; rc=$?
check "unwritable log -> exit 1" [ "$rc" = 1 ]

echo "# gizmo-health"
cat >"$T/fake-vcgencmd" <<'EOF'
#!/bin/sh
case "$1 ${2:-}" in
  "measure_temp ") echo "temp=61.3'C" ;;
  "measure_clock arm") echo "frequency(48)=1800404352" ;;
  "measure_clock core") echo "frequency(1)=500000992" ;;
  "measure_clock v3d") echo "frequency(46)=500000992" ;;
  "measure_volts core") echo "volt=0.8500V" ;;
  "get_throttled ") echo "throttled=0x50005" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/fake-vcgencmd"
out=$(GIZMO_VCGENCMD="$T/fake-vcgencmd" "$BIN/gizmo-health" --pid $$); rc=$?
echo "    $out"
python3 -I -c '
import json,sys
d=json.loads(sys.argv[1])
assert d["temp_c"]==61.3 and d["temp_source"]=="vcgencmd", d
assert d["arm_hz"]==1800404352 and d["core_hz"]==500000992 and d["v3d_hz"]==500000992
assert d["core_volts"]==0.85 and d["throttled_hex"]=="0x50005"
assert d["under_voltage_now"] and d["throttled_now"] and not d["freq_capped_now"] and not d["soft_temp_limit_now"]
assert d["under_voltage_occurred"] and d["throttled_occurred"] and not d["freq_capped_occurred"]
assert d["mem_available_mb"]>0 and d["load1"] is not None and d["pid_alive"] is True
' "$out" && [ "$rc" = 0 ]; checkc "one-shot JSON decodes throttled=0x50005" $?
out=$(GIZMO_VCGENCMD="$T/no-such-vcgencmd" "$BIN/gizmo-health"); rc=$?
python3 -I -c '
import json,sys
d=json.loads(sys.argv[1])
assert d["arm_hz"] is None and d["throttled_hex"] is None and d["under_voltage_now"] is None
' "$out" && [ "$rc" = 0 ]; checkc "missing vcgencmd -> nulls, exit 0" $?
out=$(GIZMO_VCGENCMD="$T/fake-vcgencmd" "$BIN/gizmo-health" --watch 0.2 --count 3 --csv "$T/h.csv"); rc=$?
python3 -I -c '
import json,sys
lines=[json.loads(l) for l in sys.argv[1].splitlines()]
assert [l["type"] for l in lines]==["sample"]*3+["summary"], lines
s=lines[-1]; assert s["samples"]==3 and s["temp_c"]["max"]==61.3 and s["under_voltage_seen"] is True
' "$out" && [ "$rc" = 0 ]; checkc "--watch --count 3: 3 samples + summary" $?
check "CSV has header + 3 rows" [ "$(wc -l <"$T/h.csv")" = 4 ]
head -2 "$T/h.csv" | cut -c1-150 | sed 's/^/    /'
out=$(timeout -s TERM 1 env GIZMO_VCGENCMD="$T/fake-vcgencmd" "$BIN/gizmo-health" --watch 0.3 --quiet); rc=$?
check "SIGTERM ends --watch with a summary (interrupted=true)" python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["interrupted"] is True and d["samples"]>=1' "$out"
"$BIN/gizmo-health" --csv x >/dev/null 2>&1; rc=$?
check "--csv without --watch -> exit 2" [ "$rc" = 2 ]

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
