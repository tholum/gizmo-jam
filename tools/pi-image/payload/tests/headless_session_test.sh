#!/bin/bash
# Called by chroot_test.sh after firstboot.sh has run. Starts the image's real
# desktop session command (labwc-pi -> labwc -m, with /etc/xdg/labwc/autostart
# and its XDG autostart pass) on wlroots' headless backend inside the arm64
# chroot, then drives the helpers against it: gizmo-env, the kiosk autostart
# entry, gizmo-shot (real grim), gizmo-run with the real Godot (software GL,
# llvmpipe), --stop and --wait. Everything runs under qemu-user, so it is slow.
#
# Env from chroot_test.sh: ROOT (mounted image), TUSER (uid 1000), S (sudo or "").
# $S is "sudo" or empty (when already root) and is expanded unquoted on purpose.
# shellcheck disable=SC2086
set -u
: "${ROOT:?}" "${TUSER:?}"
S=${S-sudo}
UHOME=/home/$TUSER
OUTDIR=${GIZMO_TEST_OUTDIR:-$(cd "$(dirname "$0")/../../../.." && pwd)/.pi-image/scratch}
OWNER=${GIZMO_TEST_OWNER:-$(id -u):$(id -g)}
PASS=0
FAIL=0
LABWC_PID=""

ok() { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
checkc() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
inroot() { $S chroot "$ROOT" "$@"; }
asuser() { inroot runuser -u "$TUSER" -- "$@"; }
indent() { sed 's/^/    /'; }

# wait_for SECONDS DESCRIPTION COMMAND...: poll until COMMAND succeeds
wait_for() {
    local limit=$1 what=$2 i=0
    shift 2
    until "$@" >/dev/null 2>&1; do
        [ $i -ge "$limit" ] && { echo "    (gave up waiting for $what after ${limit}s)"; return 1; }
        sleep 1
        i=$((i + 1))
    done
    echo "    ($what after ${i}s)"
}

stop_labwc() {
    [ -n "$LABWC_PID" ] || return 0
    # exact PID, and only if it really is the process inside our chroot
    if [ "$($S readlink "/proc/$LABWC_PID/root" 2>/dev/null)" = "$ROOT" ]; then
        $S kill -TERM "$LABWC_PID" 2>/dev/null
        echo "    sent TERM to labwc pid $LABWC_PID"
    fi
    LABWC_PID=""
}
trap stop_labwc EXIT

# --- a tiny Godot project (main scene, no imported assets) -------------------
asuser mkdir -p "$UHOME/gizmo/project"
asuser tee "$UHOME/gizmo/project/project.godot" >/dev/null <<'EOF'
config_version=5

[application]
config/name="gizmo-headless-test"
run/main_scene="res://main.tscn"

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"
EOF
asuser tee "$UHOME/gizmo/project/main.tscn" >/dev/null <<'EOF'
[gd_scene format=3]

[node name="Main" type="Node2D"]

[node name="Bg" type="ColorRect" parent="."]
offset_right = 1920.0
offset_bottom = 1080.0
color = Color(0.1, 0.3, 0.6, 1)

[node name="Label" type="Label" parent="."]
offset_left = 100.0
offset_top = 100.0
text = "gizmo-run headless test"
EOF

# --- what logind + LightDM autologin provide ------------------------------------
inroot install -d -o 1000 -g 1000 -m 700 /run/user/1000
inroot install -d -m 1777 /tmp/.X11-unix
inroot rm -f /run/user/1000/labwc-test.pid
$S chroot "$ROOT" runuser -u "$TUSER" -- env -i \
    HOME="$UHOME" USER="$TUSER" LOGNAME="$TUSER" SHELL=/bin/bash \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    XDG_RUNTIME_DIR=/run/user/1000 XDG_SESSION_TYPE=wayland XDG_SEAT=seat0 \
    DESKTOP_SESSION=rpd-labwc XDG_SESSION_DESKTOP=rpd-labwc \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 WLR_LIBINPUT_NO_DEVICES=1 \
    sh -c 'echo $$ >/run/user/1000/labwc-test.pid; exec /usr/bin/labwc-pi >/tmp/labwc-test.log 2>&1' \
    </dev/null >/dev/null 2>&1 &
wait_for 60 "labwc pid file" $S test -s "$ROOT/run/user/1000/labwc-test.pid"
LABWC_PID=$($S cat "$ROOT/run/user/1000/labwc-test.pid" 2>/dev/null)
echo "    labwc pid: $LABWC_PID"

wait_for 180 "wayland-0 socket" $S test -S "$ROOT/run/user/1000/wayland-0"
checkc "labwc-pi (headless) came up" $?
$S ls -la "$ROOT/run/user/1000" "$ROOT/tmp/.X11-unix" 2>&1 | indent

# --- gizmo-env ----------------------------------------------------------------
wait_for 120 ".Xauthority from the XDG autostart create_xauth entry" $S test -s "$ROOT$UHOME/.Xauthority"
out=$(inroot /usr/local/bin/gizmo-env); rc=$?
printf '%s\n' "$out" | indent
checkc "gizmo-env (root) finds the session" "$rc"
check "WAYLAND_DISPLAY=wayland-0" grep -qx 'export WAYLAND_DISPLAY=wayland-0' <<<"$out"
# On the Pi this is :0. In the chroot the host's own X server may hold the
# abstract socket @/tmp/.X11-unix/X0 (shared network namespace), so labwc can
# end up on :1; gizmo-env must report whichever socket labwc created.
xd=$(sed -n 's/^export DISPLAY=://p' <<<"$out")
check "DISPLAY=:$xd matches the Xwayland socket labwc created" $S test -S "$ROOT/tmp/.X11-unix/X$xd"
check "XAUTHORITY=~/.Xauthority" grep -qx "export XAUTHORITY=$UHOME/.Xauthority" <<<"$out"
out2=$(asuser /usr/local/bin/gizmo-env)
check "gizmo-env as the user gives the same" [ "$out" = "$out2" ]

# --- kiosk: started by lxsession-xdg-autostart from ~/.config/autostart -----------
kiosk_running() { inroot /usr/local/bin/gizmo-kiosk status | grep -q '^running=[0-9]'; }
game_running() { inroot /usr/local/bin/gizmo-run --list | grep -q 'state=running'; }
wait_for 240 "kiosk loop from XDG autostart" kiosk_running
checkc "XDG autostart launched the kiosk loop" $?
wait_for 240 "kiosk game running" game_running
checkc "kiosk loop started the game via gizmo-run" $?
inroot /usr/local/bin/gizmo-kiosk status | indent
inroot /usr/local/bin/gizmo-run --list | indent
$S cat "$ROOT$UHOME/gizmo/logs/kiosk.log" 2>/dev/null | indent

sleep 45   # let the game map its window (software GL under qemu is slow)
out=$(inroot /usr/local/bin/gizmo-shot 2>&1); rc=$?
printf '%s\n' "$out" | indent
checkc "gizmo-shot (root) exits 0" "$rc"
shot=$(tail -n 1 <<<"$out")
check "screenshot is a PNG" bash -c "$S head -c 8 '$ROOT$shot' | od -An -tx1 | grep -q '89 50 4e 47 0d 0a 1a 0a'"
check "default screenshot is owned by uid 1000" [ "$($S stat -c %u "$ROOT$shot" 2>/dev/null)" = 1000 ]
$S cp "$ROOT$shot" "$OUTDIR/headless-kiosk-shot.png" 2>/dev/null && $S chown "$OWNER" "$OUTDIR/headless-kiosk-shot.png"
out=$(inroot /usr/local/bin/gizmo-shot --json --output HEADLESS-1 /tmp/shot2.png); rc=$?
echo "    $out"
checkc "gizmo-shot --output HEADLESS-1 --json" "$rc"

# crash -> restart (chroot_test.sh turned on --restart): kill the game
# behind the kiosk loop's back and expect a new one.
first=$(inroot /usr/local/bin/gizmo-run --list | sed -n 's/^pid=\([0-9]*\) state=running.*/\1/p' | head -n 1)
inroot /usr/local/bin/gizmo-run --stop "$first" >/dev/null
new_game() { inroot /usr/local/bin/gizmo-run --list | grep 'state=running' | grep -vq "^pid=$first "; }
wait_for 120 "kiosk restarted the game" new_game
checkc "kiosk --restart relaunches a game that died" $?

out=$(inroot /usr/local/bin/gizmo-kiosk stop); rc=$?
echo "    $out"
checkc "gizmo-kiosk stop" "$rc"
check "kiosk loop gone" bash -c "! $S chroot '$ROOT' /usr/local/bin/gizmo-kiosk status | grep -q '^running=[0-9]'"
check "kiosk game stopped" bash -c "! $S chroot '$ROOT' /usr/local/bin/gizmo-run --list | grep -q state=running"
$S tail -n 5 "$ROOT$UHOME/gizmo/logs/kiosk.log" | indent

# --- gizmo-run with the real Godot ------------------------------------------------
out=$(asuser /usr/local/bin/gizmo-run -- --path "$UHOME/gizmo/project"); rc=$?
printf '%s\n' "$out" | indent
checkc "gizmo-run (as user) starts Godot" "$rc"
pid=$(sed -n 's/^pid=//p' <<<"$out")
log=$(sed -n 's/^log=//p' <<<"$out")
sleep 40
check "Godot still running after 40s" bash -c "$S chroot '$ROOT' /usr/local/bin/gizmo-run --list | grep -q 'pid=$pid state=running'"
out=$(inroot /usr/local/bin/gizmo-health --pid "$pid"); echo "    $out" | cut -c1-400
check "gizmo-health --pid sees the game" python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["pid_alive"] and d["pid_rss_mb"]>0' "$out"
out=$(inroot /usr/local/bin/gizmo-shot "/tmp/godot-shot.png"); rc=$?
checkc "gizmo-shot while Godot runs" "$rc"
$S cp "$ROOT/tmp/godot-shot.png" "$OUTDIR/headless-godot-shot.png" 2>/dev/null && $S chown "$OWNER" "$OUTDIR/headless-godot-shot.png"
out=$(inroot /usr/local/bin/gizmo-run --stop "$pid"); rc=$?
printf '%s\n' "$out" | indent
checkc "gizmo-run --stop (root) on the user's game" "$rc"
check "status=stopped" grep -qx 'status=stopped' <<<"$out"
echo "    Godot log ($log):"
$S grep -vE '^\s*$' "$ROOT$log" | head -n 25 | indent
check "Godot log shows a GL context" $S grep -qE 'OpenGL API|OpenGL ES' "$ROOT$log"

out=$(asuser /usr/local/bin/gizmo-run --wait --timeout 300 -- --path "$UHOME/gizmo/project" --quit-after 3); rc=$?
printf '%s\n' "$out" | indent
checkc "gizmo-run --wait with --quit-after 3 exits 0" "$rc"

$S tail -n 15 "$ROOT/tmp/labwc-test.log" 2>/dev/null | indent
stop_labwc
echo "headless: passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
