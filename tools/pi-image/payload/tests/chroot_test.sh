#!/bin/bash
# Real-userland test of payload/firstboot.sh and the helpers: loop-mounts the
# real Raspberry Pi OS image, simulates what cloud-init does before runcmd
# (rename uid 1000 to the test user, render netplan), copies the payload +
# a test firstboot.env + the real Godot zip into /boot/firmware/gizmo, and
# runs everything in an arm64 chroot through qemu-user binfmt.
#
#   bash tools/pi-image/payload/tests/chroot_test.sh [--keep] [--skip-net] [--image IMG.xz]
#
# Needs: passwordless sudo, qemu-aarch64 binfmt (with the F flag), xz, unzip,
# curl, unshare. Uses .pi-image/scratch/chroot-test/ (gitignored). All mounts
# live in a private mount namespace; detaches exactly the loop device it
# created; deletes the 6.7 GB image unless --keep.
#   --keep       leave the decompressed image (not mounted) for a faster re-run
#   --skip-net   skip the apt/Tailscale part (slow under qemu)
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PAYLOAD=$(cd "$HERE/.." && pwd)
REPO=$(cd "$PAYLOAD/../../.." && pwd)
WORK="$REPO/.pi-image/scratch/chroot-test"
IMG="$WORK/test.img"
ROOT="$WORK/root"
IMG_XZ=/tmp/piimg-dl/full.img.xz
IMG_XZ_SHA256=976766570bee2aaf3047dd78649cfe82abb8fe9687b7f15030cd533ba4e9f7a9
GODOT_URL=https://github.com/godotengine/godot/releases/download/4.5.1-stable/Godot_v4.5.1-stable_linux.arm64.zip
GODOT_ZIP="$REPO/.pi-image/scratch/godot-dl/Godot_v4.5.1-stable_linux.arm64.zip"
GODOT_SHA512=9d55e9cdccaa4b6528d0b39824d51c47987667babffbab7f83b05fba2ece842a59752b84128332421c9d261fe06846b88480f3b0171af255ea99383d3bc96b2c
TUSER=gizmotest
KEEP=0
SKIP_NET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1; shift ;;
        --skip-net) SKIP_NET=1; shift ;;
        --image) IMG_XZ=$2; IMG_XZ_SHA256=""; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

S=sudo
[ "$(id -u)" = 0 ] && S=""
PASS=0
FAIL=0

say() { printf '\n### %s\n' "$*"; }
ok() { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
checkc() { if [ "$2" = 0 ]; then ok "$1"; else bad "$1"; fi; }
inroot() { $S chroot "$ROOT" "$@"; }

# ===========================================================================
# Outer phase (host mount namespace): image, Godot zip, loop device. All
# mounting happens in the inner phase, inside a private mount namespace
# (unshare --propagation private), so no mount can propagate into the host's
# or any service's namespace, and everything is unmounted by the kernel when
# the namespace goes away, even if the test is killed.
if [ -z "${GIZMO_CHROOT_INNER:-}" ]; then
    LOOP=""
    # shellcheck disable=SC2317  # called from the EXIT trap
    outer_cleanup() {
        say "cleanup"
        if [ -n "$LOOP" ]; then
            $S losetup -d "$LOOP" && echo "detached $LOOP"
            rm -f "$WORK/loopdev"
        fi
        if [ "$KEEP" = 0 ]; then
            rm -f "$IMG" "$IMG.pristine" && echo "deleted $IMG"
        else
            echo "kept $IMG (modified; delete it or re-run without --keep)"
        fi
        rmdir "$ROOT" 2>/dev/null
    }

    mkdir -p "$WORK"
    if [ -f "$WORK/loopdev" ]; then
        echo "a previous run left $(cat "$WORK/loopdev") attached (see $WORK/loopdev); clean it up first" >&2
        exit 1
    fi
    if [ -f "$IMG" ] && [ -f "$IMG.pristine" ]; then
        say "reusing pristine $IMG"
    else
        say "decompressing $IMG_XZ"
        [ -f "$IMG_XZ" ] || { echo "missing $IMG_XZ" >&2; exit 1; }
        if [ -n "$IMG_XZ_SHA256" ]; then
            echo "$IMG_XZ_SHA256  $IMG_XZ" | sha256sum -c - || exit 1
        fi
        rm -f "$IMG" "$IMG.pristine"
        xz -dc -T0 "$IMG_XZ" >"$IMG.part" && mv "$IMG.part" "$IMG" || exit 1
        touch "$IMG.pristine"
    fi
    if [ ! -f "$GODOT_ZIP" ]; then
        say "downloading Godot arm64 zip"
        mkdir -p "${GODOT_ZIP%/*}"
        curl -fL -o "$GODOT_ZIP.part" "$GODOT_URL" && mv "$GODOT_ZIP.part" "$GODOT_ZIP" || exit 1
    fi
    echo "$GODOT_SHA512  $GODOT_ZIP" | sha512sum -c - || exit 1

    trap outer_cleanup EXIT
    trap 'exit 130' INT TERM
    rm -f "$IMG.pristine"
    LOOP=$($S losetup -P --find --show "$IMG") || exit 1
    echo "$LOOP" >"$WORK/loopdev"
    echo "loop device: $LOOP"
    mkdir -p "$ROOT"
    inner_args=()
    [ "$SKIP_NET" = 1 ] && inner_args+=(--skip-net)
    $S unshare --mount --propagation private -- env GIZMO_CHROOT_INNER=1 GIZMO_LOOP="$LOOP" \
        GIZMO_TEST_OWNER="$(id -u):$(id -g)" GIZMO_SKIP_HEADLESS="${GIZMO_SKIP_HEADLESS:-}" \
        bash "$0" "${inner_args[@]}"
    exit $?
fi

# ===========================================================================
# Inner phase: root, private mount namespace.
LOOP=$GIZMO_LOOP
MOUNTS=()

# PIDs of processes whose root directory is our chroot (started by this test;
# selected by /proc/PID/root, never by name).
chroot_pids() {
    local p
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/root" 2>/dev/null)" = "$ROOT" ] && echo "${p#/proc/}"
    done
}

stop_chroot_procs() {
    local pids p
    pids=$(chroot_pids)
    [ -n "$pids" ] || return 0
    echo "stopping processes left in the chroot: $(echo "$pids" | tr '\n' ' ')"
    for p in $pids; do kill -TERM "$p" 2>/dev/null; done
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -z "$(chroot_pids)" ] && return 0
        sleep 1
    done
    for p in $(chroot_pids); do kill -KILL "$p" 2>/dev/null; done
    sleep 1
}

inner_cleanup() {
    local i
    say "unmounting"
    stop_chroot_procs
    rm -f "$ROOT/usr/sbin/policy-rc.d" 2>/dev/null
    for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
        umount -R "${MOUNTS[$i]}" 2>/dev/null || umount -R -l "${MOUNTS[$i]}" ||
            echo "WARNING: could not unmount ${MOUNTS[$i]}"
    done
    sync
}

mnt() {   # mnt [opts...] SRC DST
    local dst=${*: -1}
    mount "$@" || { echo "mount $* failed" >&2; exit 1; }
    MOUNTS+=("$dst")
}

trap inner_cleanup EXIT
trap 'exit 130' INT TERM

say "mounting (private mount namespace)"
mnt "${LOOP}p2" "$ROOT"
mnt "${LOOP}p1" "$ROOT/boot/firmware"
mnt -t proc proc "$ROOT/proc"
mnt --rbind /sys "$ROOT/sys"
mnt --rbind /dev "$ROOT/dev"   # includes /dev/pts and /dev/shm (wlroots needs shm)
rm -f "$ROOT/etc/resolv.conf"
grep '^nameserver' /etc/resolv.conf >"$ROOT/etc/resolv.conf"
# Keep package postinst scripts from starting daemons inside the chroot.
printf '#!/bin/sh\nexit 101\n' >"$ROOT/usr/sbin/policy-rc.d"
chmod 755 "$ROOT/usr/sbin/policy-rc.d"
inroot /bin/true || { echo "cannot run arm64 binaries (qemu-aarch64 binfmt?)" >&2; exit 1; }
inroot uname -m

# --- what cloud-init does before runcmd -------------------------------------
say "simulating cloud-init (user rename, sudo, netplan)"
echo "lightdm before: $(grep '^autologin-user' "$ROOT/etc/lightdm/lightdm.conf")"
inroot /usr/lib/userconf-pi/userconf "$TUSER" 2>&1 | tail -n 5
check "uid 1000 is now $TUSER" [ "$(inroot getent passwd 1000 | cut -d: -f1)" = "$TUSER" ]
echo "lightdm after userconf/cancel-rename: $(grep '^autologin-user' "$ROOT/etc/lightdm/lightdm.conf")"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TUSER" | $S tee "$ROOT/etc/sudoers.d/90-cloud-init-users" >/dev/null
$S tee "$ROOT/boot/firmware/network-config" >/dev/null <<'EOF'
network:
  version: 2
  wifis:
    wlan0:
      dhcp4: true
      regulatory-domain: "US"
      access-points:
        "gizmo-test-ssid":
          password: "not-a-real-password"
      optional: true
EOF

# --- payload on bootfs --------------------------------------------------------
say "populating /boot/firmware/gizmo"
B="$ROOT/boot/firmware/gizmo"
$S rm -rf "$B"
$S mkdir -p "$B/godot" "$B/secrets"
$S cp -r "$PAYLOAD/firstboot.sh" "$PAYLOAD/bin" "$PAYLOAD/systemd" "$B/"
$S cp "$GODOT_ZIP" "$B/godot/"
BUILD_ID="gizmojam-test-$(date -u +%Y%m%dT%H%M%SZ)"
$S tee "$B/firstboot.env" >/dev/null <<EOF
GIZMO_USER="$TUSER"
GIZMO_HOSTNAME="gizmojam"
GIZMO_GODOT_ZIP="godot/Godot_v4.5.1-stable_linux.arm64.zip"
GIZMO_GODOT_SHA512="$GODOT_SHA512"
GIZMO_TAILSCALE="1"
GIZMO_TAILSCALE_HOSTNAME="gizmojam-test"
GIZMO_TAILSCALE_SSH="1"
GIZMO_EXTRA_PACKAGES="mesa-utils gizmo-no-such-package"
GIZMO_KIOSK="1"
GIZMO_BUILD_ID="$BUILD_ID"
EOF
echo "tskey-auth-FAKE-test-only-0000" | $S tee "$B/secrets/tailscale.key" >/dev/null
$S ls -lR "$B" | sed 's/^/    /'

# --- run 1: offline first boot -------------------------------------------------
say "run 1: firstboot.sh with the network down (GIZMO_TEST_NO_NET=1)"
start=$(date +%s)
inroot env GIZMO_TEST_CHROOT=1 GIZMO_TEST_NO_NET=1 bash /boot/firmware/gizmo/firstboot.sh
rc=$?
echo "(run 1 took $(( $(date +%s) - start ))s, exit $rc)"
checkc "run 1 exits 0" "$rc"
check "log written" $S test -s "$ROOT/var/log/gizmo-firstboot.log"
check "firstboot.done written" $S grep -q "^build_id=$BUILD_ID" "$ROOT/var/lib/gizmo/firstboot.done"
check "bootfs Tailscale key shredded" bash -c "! $S test -e '$B/secrets/tailscale.key'"
check "rootfs key copy is root-only 0600 (kept for the deferred retry)" \
    [ "$($S stat -c '%a %U' "$ROOT/var/lib/gizmo/secrets/tailscale.key" 2>/dev/null)" = "600 root" ]
check "network step deferred" $S grep -qx 'step.network=deferred' "$ROOT/var/lib/gizmo/firstboot.done"
check "gizmo-firstboot-net.service enabled" \
    $S test -L "$ROOT/etc/systemd/system/multi-user.target.wants/gizmo-firstboot-net.service"
for b in gizmo-env gizmo-run gizmo-shot gizmo-health gizmo-kiosk; do
    check "/usr/local/bin/$b installed 0755" [ "$($S stat -c %a "$ROOT/usr/local/bin/$b" 2>/dev/null)" = 755 ]
done
check "/usr/local/lib/gizmo/firstboot.sh installed" $S test -x "$ROOT/usr/local/lib/gizmo/firstboot.sh"
check "unit installed" $S test -f "$ROOT/etc/systemd/system/gizmo-firstboot-net.service"
out=$(inroot /opt/godot/godot --version 2>&1 | tail -n 1)
echo "    /opt/godot/godot --version -> $out"
check "Godot runs under qemu and reports 4.5.1" grep -q '^4\.5\.1\.stable' <<<"$out"
check "/usr/local/bin/godot -> /opt/godot/godot" [ "$(readlink "$ROOT/usr/local/bin/godot")" = /opt/godot/godot ]
check "sudoers drop-in valid" inroot visudo -cqf /etc/sudoers.d/010_gizmo-nopasswd
check "lightdm autologin-user=$TUSER" $S grep -qx "autologin-user=$TUSER" "$ROOT/etc/lightdm/lightdm.conf"
check "graphical.target is default" [ "$(basename "$(readlink "$ROOT/etc/systemd/system/default.target")")" = graphical.target ]
check "home/gizmo/logs owned by uid 1000 ($TUSER)" [ "$($S stat -c %u "$ROOT/home/$TUSER/gizmo/logs")" = 1000 ]
check "kiosk autostart entry owned by uid 1000" \
    [ "$($S stat -c %u "$ROOT/home/$TUSER/.config/autostart/gizmo-kiosk.desktop" 2>/dev/null)" = 1000 ]
check "Wi-Fi left alone while netplan has no Wi-Fi (not rendered)" $S grep -q 'not-a-real-password' "$ROOT/boot/firmware/network-config"
check "/etc/gizmo/gizmo.conf" $S grep -qx "GIZMO_USER=\"$TUSER\"" "$ROOT/etc/gizmo/gizmo.conf"
$S cat "$ROOT/var/lib/gizmo/firstboot.done" | sed 's/^/    /'

# --- cloud-init would have rendered netplan; scrub on re-run ---------------------
say "run 2: re-run (idempotency) with netplan rendered"
$S mkdir -p "$ROOT/etc/netplan"
$S cp "$ROOT/boot/firmware/network-config" "$ROOT/etc/netplan/50-cloud-init.yaml"
$S chmod 600 "$ROOT/etc/netplan/50-cloud-init.yaml"
snap() { $S sha256sum "$ROOT/etc/sudoers.d/010_gizmo-nopasswd" "$ROOT/etc/lightdm/lightdm.conf" \
    "$ROOT/home/$TUSER/.config/autostart/gizmo-kiosk.desktop" "$ROOT/opt/godot/godot" \
    "$ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" 2>&1; }
before=$(snap)
inroot env GIZMO_TEST_CHROOT=1 GIZMO_TEST_NO_NET=1 bash /boot/firmware/gizmo/firstboot.sh >/dev/null 2>&1
rc=$?
checkc "run 2 exits 0" "$rc"
check "config files unchanged by the re-run" [ "$before" = "$(snap)" ]
check "godot step skipped (already installed)" $S grep -qx 'step.godot=skipped' "$ROOT/var/lib/gizmo/firstboot.done"
check "sudo step skipped (unchanged)" $S grep -qx 'step.sudo=skipped' "$ROOT/var/lib/gizmo/firstboot.done"
check "Wi-Fi password scrubbed from bootfs" bash -c "! $S grep -q 'not-a-real-password' '$ROOT/boot/firmware/network-config'"
check "rendered netplan untouched" $S grep -q 'not-a-real-password' "$ROOT/etc/netplan/50-cloud-init.yaml"
check "one sudoers line for the user" [ "$($S grep -c "^$TUSER " "$ROOT/etc/sudoers.d/010_gizmo-nopasswd")" = 1 ]
check "one autologin-user line" [ "$($S grep -c '^autologin-user=' "$ROOT/etc/lightdm/lightdm.conf")" = 1 ]
$S cat "$ROOT/var/lib/gizmo/firstboot.done" | sed 's/^/    /'

# --- run 3: the deferred network service ------------------------------------------
if [ "$SKIP_NET" = 0 ]; then
    say "run 3: firstboot.sh --net (what gizmo-firstboot-net.service runs), network up"
    start=$(date +%s)
    inroot env GIZMO_TEST_CHROOT=1 /usr/local/lib/gizmo/firstboot.sh --net 2>&1 |
        grep -E 'gizmo-firstboot|^E:|Setting up (mesa-utils|tailscale) ' | tail -n 40
    rc=${PIPESTATUS[0]}
    echo "(run 3 took $(( $(date +%s) - start ))s, exit $rc)"
    checkc "--net exits 0 (finished)" "$rc"
    inroot dpkg -s mesa-utils >/dev/null 2>&1; checkc "mesa-utils installed" $?
    check "bogus package recorded as failed, not fatal" $S grep -q '^failed gizmo-no-such-package' "$ROOT/var/lib/gizmo/packages.done"
    inroot dpkg -s tailscale >/dev/null 2>&1; checkc "tailscale installed from pkgs.tailscale.com" $?
    check "rootfs Tailscale key shredded after use" bash -c "! $S test -e '$ROOT/var/lib/gizmo/secrets/tailscale.key'"
    check "net.done written" $S test -f "$ROOT/var/lib/gizmo/net.done"
    check "gizmo-firstboot-net.service disabled itself" \
        bash -c "! $S test -e '$ROOT/etc/systemd/system/multi-user.target.wants/gizmo-firstboot-net.service'"
    check "firstboot.done says network=done" $S grep -qx 'network=done' "$ROOT/var/lib/gizmo/firstboot.done"
    inroot env GIZMO_TEST_CHROOT=1 /usr/local/lib/gizmo/firstboot.sh --net >/dev/null 2>&1
    checkc "--net again: no-op, exits 0" $?
fi

# --- helpers inside the image ----------------------------------------------------
say "helpers in the chroot"
# Games started over SSH live on after logout only if logind does not kill
# user processes (Debian default: KillUserProcesses=no).
kup=$(grep -hs '^[[:space:]]*KillUserProcesses' "$ROOT"/etc/systemd/logind.conf "$ROOT"/etc/systemd/logind.conf.d/*.conf "$ROOT"/usr/lib/systemd/logind.conf.d/*.conf | tail -n 1)
echo "    logind KillUserProcesses: ${kup:-not set (compiled-in default)}"
check "logind does not kill processes at SSH logout" bash -c "! grep -qi 'KillUserProcesses=yes' <<<'$kup'"
out=$(inroot /usr/local/bin/gizmo-health); rc=$?
echo "    $out"
checkc "gizmo-health exits 0 without a working vcgencmd" "$rc"
check "vcgencmd values are null, load/mem present" python3 -I -c '
import json,sys
d=json.loads(sys.argv[1])
assert d["arm_hz"] is None and d["v3d_hz"] is None and d["throttled_hex"] is None, d
assert d["under_voltage_now"] is None and d["load1"] is not None and d["mem_available_mb"] > 0
' "$out"
out=$(inroot /usr/local/bin/gizmo-health --watch 0.5 --count 2 --csv /tmp/h.csv | tail -n 1)
check "gizmo-health --watch summary" python3 -I -c 'import json,sys; assert json.loads(sys.argv[1])["samples"]==2' "$out"
check "gizmo-env as root targets $TUSER" [ "$(inroot /usr/local/bin/gizmo-env --user)" = "$TUSER" ]
inroot /usr/local/bin/gizmo-env >/dev/null 2>&1
checkc "gizmo-env with no desktop session -> exit 3" "$(( $? == 3 ? 0 : 1 ))"
inroot /usr/local/bin/gizmo-run -- --version >/dev/null 2>&1
checkc "gizmo-run with no desktop session -> exit 3" "$(( $? == 3 ? 0 : 1 ))"
inroot /usr/local/bin/gizmo-shot >/dev/null 2>&1
checkc "gizmo-shot with no desktop session -> exit 3" "$(( $? == 3 ? 0 : 1 ))"
out=$(inroot runuser -u "$TUSER" -- /usr/local/bin/gizmo-kiosk status)
printf "%s\n" "$out" | sed "s/^/    /"
check "kiosk status (as user): on, target none" bash -c "grep -qx kiosk=on <<<'$out' && grep -qx target=none <<<'$out'"
inroot runuser -u "$TUSER" -- mkdir -p "/home/$TUSER/gizmo/project"
inroot runuser -u "$TUSER" -- touch "/home/$TUSER/gizmo/project/project.godot"
check "kiosk target follows ~/gizmo/project" bash -c "$S chroot '$ROOT' /usr/local/bin/gizmo-kiosk status --json | grep -q '\"target\":\"project\"'"
inroot /usr/local/bin/gizmo-kiosk off >/dev/null
check "kiosk off (as root) removes the autostart entry" bash -c "! $S test -e '$ROOT/home/$TUSER/.config/autostart/gizmo-kiosk.desktop'"
inroot /usr/local/bin/gizmo-kiosk on --restart >/dev/null
check "kiosk on --restart (as root) writes files owned by the user" \
    [ "$($S stat -c %u "$ROOT/home/$TUSER/.config/gizmo/kiosk.conf")" = 1000 ]
inroot /usr/local/bin/gizmo-kiosk start >/dev/null 2>&1
checkc "kiosk start with no session -> exit 3" "$(( $? == 3 ? 0 : 1 ))"
inroot runuser -u "$TUSER" -- /usr/local/bin/gizmo-run --stop 1 >/dev/null 2>&1
checkc "gizmo-run --stop 1 refused (not ours)" "$(( $? == 1 ? 0 : 1 ))"

if [ -x "$HERE/headless_session_test.sh" ] && [ "${GIZMO_SKIP_HEADLESS:-}" != 1 ]; then
    say "headless labwc session test"
    ROOT="$ROOT" TUSER="$TUSER" S="$S" GIZMO_TEST_OWNER="${GIZMO_TEST_OWNER:-}" \
        bash "$HERE/headless_session_test.sh"
    checkc "headless labwc session test" $?
fi

say "result: passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
