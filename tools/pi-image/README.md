# Raspberry Pi 4 SD-card image for Gizmo Jam

These tools turn a stock Raspberry Pi OS image into an SD card for a Gizmo Jam test and play
box. You flash the card, plug the Pi into a TV, and power it on. A few minutes later you can
SSH in and run the game on the Pi's real GPU.

- `build.py` builds the image on your PC. It needs no root.
- `flash.py` writes the image to an SD card and checks the result.

## What the box ends up as

- **OS:** Raspberry Pi OS (64-bit) with desktop, Debian 13 "trixie", release 2026-10-06. The
  exact image is pinned by sha256 in `pins.json`.
- **User:** one user (default `gizmo`, uid 1000) with passwordless `sudo`. The desktop (labwc,
  Wayland) logs in as this user automatically.
- **SSH:** keys only. Password login over SSH is off. If you set a password, it works only on
  the local console and desktop.
- **Network:** Ethernet (DHCP) always works. Wi-Fi is optional.
- **Tailscale:** optional. It joins your tailnet with an auth key, and can enable Tailscale SSH.
- **Godot:** 4.5.1 arm64 at `/opt/godot`, with the `godot` command on the PATH. The zip is
  carried on the card, so this step needs no network on first boot.
- **Display:** HDMI output is forced (default 1280x720@60 on the HDMI port next to USB-C; the TV scales it up, and a Pi 4 only holds ~30 fps at 720p), so
  the desktop renders to HDMI even when the TV is off or switched to another input.
- **Helper commands** for an agent working over SSH: `gizmo-env`, `gizmo-run`, `gizmo-shot`,
  `gizmo-health`, and `gizmo-kiosk`. See [On the Pi](#on-the-pi).

## Prerequisites (build host)

- Linux with Python 3.12 or newer (standard library only), plus `xz`, `sfdisk`, `cp` and
  `openssl`. Most distros have all of these already.
- `mtools`. If `mcopy` is not installed, `build.py` fetches it without root
  (`apt-get download mtools` and `dpkg -x` into `.pi-image/tools/`). On a system without apt,
  install mtools with your package manager.
- `cloud-init` (optional, recommended). When it is installed, `build.py` validates the
  generated `user-data` and `network-config` with `cloud-init schema`. A schema error fails
  the build.
- Disk space: about 1.4 GB for the download, 6.8 GB for the cached base image, and 6.8 GB for
  each built image.
- An SD card of 8 GB or more, and a card reader.

## 1. Configure

```sh
python3 tools/pi-image/build.py
```

The first run copies `config.example.toml` to `.pi-image/config.toml` (at the repo root, mode
600) and stops. Edit that copy:

| Setting | Meaning |
|---|---|
| `hostname` | Pi hostname. Reachable as `<hostname>.local` on the LAN. |
| `username` | Login user. |
| `ssh_public_keys` | List of **public** key files on this machine, such as `~/.ssh/id_ed25519.pub`. At least one is required. |
| `password` | Optional console/desktop password. It is hashed (sha512-crypt) at build time. Leave it empty to lock the password. |
| `timezone`, `locale`, `keyboard_layout` | Regional settings. |
| `[wifi] ssid / password / country` | Leave `ssid` empty for Ethernet only. An empty password means an open network. |
| `[tailscale] auth_key` or `auth_key_file`, `hostname`, `ssh` | Leave the key empty to skip Tailscale. Use a reusable or pre-authorized key if you plan to reflash. |
| `[display] force_hdmi_mode` | For example `1920x1080@60` or `1280x720@60`. Empty means no forcing, so the TV's EDID decides. |
| `[extras] packages` | apt packages installed on first boot when the network is up. Failures there do not stop the boot. |
| `[extras] kiosk` | `true` starts the game fullscreen at login. |

You can keep secrets out of the file with environment variables. These override the file:

```sh
export GIZMO_WIFI_PASSWORD='...'
export GIZMO_TAILSCALE_AUTH_KEY='tskey-auth-...'
```

## 2. Build

```sh
python3 tools/pi-image/build.py --dry-run   # show what would be written; secrets are redacted
python3 tools/pi-image/build.py             # build
```

On the first build, `build.py`:

1. Downloads the pinned Raspberry Pi OS `.img.xz` (1.3 GB) and the Godot arm64 zip (68 MB) into
   `.pi-image/cache/`. Downloads resume from a `.part` file, and each one is checked against
   `pins.json` (sha256 for the image, sha512 for Godot). If you already have the image, pass it
   with `--base-xz PATH`. It is verified and then hard-linked or copied into the cache.
2. Decompresses the image once to a read-only pristine `.img` in the cache, and checks it
   against the pinned extract sha256.

On every build, `build.py`:

1. Copies the pristine image to `.pi-image/out/gizmojam-<YYYYMMDD-HHMM>.img` and points
   `.pi-image/out/latest.img` at it.
2. Writes these files into the boot partition with mtools: `user-data`, `meta-data`,
   `network-config` (only with Wi-Fi), the edited `cmdline.txt`, and a `gizmo/` folder. That
   folder holds the payload, the Godot zip, `firstboot.env`, and the Tailscale key if you set
   one. Each file is read back and compared.
3. Prints a summary with the image path, the instance ID, your settings, and the command to
   flash the image.

Each build gets a new cloud-init instance ID, so cloud-init always runs on the first boot.

Options:

- `--config PATH` uses a different config file.
- `--payload DIR` uses a different payload directory. The default is
  `tools/pi-image/payload/`; its `tests/` folder is never copied.
- `--compress` also writes `<image>.img.xz`.
- `--name NAME` sets the output file name.

Each image is 6.3 GiB, and old images are not deleted for you. Remove the ones you no longer
need from `.pi-image/out/`.

## 3. Flash

```sh
python3 tools/pi-image/flash.py                                     # list candidate cards
python3 tools/pi-image/flash.py .pi-image/out/latest.img --device /dev/sdX
```

`flash.py` accepts only whole disks that are removable, hotplug, or attached over USB/MMC. It
refuses:

- NVMe disks
- the disk behind `/`, `/boot`, swap, or any other system mount
- disks with a partition mounted outside `/media`, `/run/media`, or `/mnt`
- disks that hold LVM, RAID, or crypt volumes
- partitions (pass `/dev/sdb`, not `/dev/sdb1`)
- disks larger than 256 GiB, unless you pass `--i-know`
- anything larger than 2 TiB, whatever you pass

Run it with no `--device` first to see which disks it accepts and why it refuses the others.
Then:

1. It shows the card's model, size, and partitions, and asks you to **type the device path**
   to confirm. `--yes` skips this question; only use it in scripts where you are sure of the
   device.
2. It checks the device again, so a card swapped in the meantime is caught. It unmounts the
   card's partitions (`udisksctl`, falling back to `sudo umount`).
3. It writes with `sudo dd bs=4M conv=fsync oflag=direct status=progress`, then runs `sync`.
4. It reads the image's length back from the card and compares sha256. `--no-verify` skips
   this check.

When the card is in a USB reader it usually shows up as `/dev/sdX`. In a built-in slot it shows
up as `/dev/mmcblk0`. If you are unsure, run `lsblk` before and after inserting the card.

Any other flasher works too, for example `dd` or Raspberry Pi Imager's "Use custom" option.
Do not let Imager apply its own OS customisation, because it would replace this image's
cloud-init files.

## 4. First boot

Put the card in the Pi 4, connect HDMI (the port next to USB-C) and Ethernet or rely on the
configured Wi-Fi, then power it on. The first boot takes a few minutes (count on about 5) and
reboots only in the rare case that auto-login had to be fixed after the desktop started:

1. The root partition grows to fill the card, and SSH host keys are generated.
2. cloud-init creates your user, sets the hostname, Wi-Fi, locale and so on, and enables SSH.
3. `gizmo/firstboot.sh` installs Godot, the helper commands, extra packages and Tailscale. It
   also sets up desktop auto-login. If the Pi is offline at this point, the network steps retry
   on later boots.

Then connect:

```sh
ssh gizmo@gizmojam.local             # use your username and hostname; mDNS on the LAN
ssh gizmo@gizmojam                   # over Tailscale (or tailscale ssh, if enabled)
```

If `.local` does not resolve, find the Pi's IP address in your router's DHCP list, or use
`tailscale status`.

To debug the first boot on the Pi, use `cloud-init status --long`,
`/var/log/cloud-init-output.log`, and `/var/log/gizmo-firstboot.log`.

## Secrets and what stays on the card

- **`.pi-image/`** (gitignored) holds `config.toml` with any Wi-Fi password and Tailscale key in
  **plain text**, plus built images that contain them. `build.py` keeps these directories at
  mode 700 and the images at mode 600. Never commit them or share them.
- **The card's boot partition is FAT.** Anyone who holds the card can read it, with no
  permissions to stop them. After the first boot it still contains:
  - `user-data`: your user name, your **public** SSH keys, and the password **hash** if you set a
    password. A hash can be brute-forced offline, so use a strong password or none.
  - `network-config`: the **Wi-Fi password in plain text** until the first boot has applied
    it. `firstboot.sh` then replaces the file with a pointer to the live copy in
    `/etc/netplan/` (NetworkManager keeps it as `90-NM-<uuid>.yaml`). The built `.img` in `.pi-image/out/` still has it.
  - `gizmo/secrets/tailscale.key` is shredded from the boot partition at the start of
    `firstboot.sh`. If the Pi is offline, a root-only copy waits in `/var/lib/gizmo/secrets/`
    and is shredded once Tailscale is up, or after 5 failed attempts. To be safe, use a short-lived or one-off auth key anyway.
- Treat a configured card like a key to your network: wipe it before you give it away.

## Files

```
tools/pi-image/
  build.py              builds the image (host)
  flash.py              writes it to an SD card (host)
  pins.json             pinned base image + Godot URLs and checksums
  config.example.toml   template for .pi-image/config.toml
  payload/              copied to the card as /boot/firmware/gizmo/ (runs on the Pi)
  tests/                host-side tests:
                        PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/pi-image/tests
```

To move to a newer Raspberry Pi OS or Godot release, update `pins.json`: the URL, size, sha256
and `extract_size`/`extract_sha256`. Imager's OS list,
`https://downloads.raspberrypi.com/os_list_imagingutility_v4.json`, publishes the last two.
Then rebuild.

## On the Pi

### What first boot sets up
`cloud-init` runs `/boot/firmware/gizmo/firstboot.sh` once, as root. It:

- adds a passwordless sudo drop-in for the user
- turns on desktop autologin (labwc on Wayland) and turns screen blanking off
- installs Godot 4.5.1 (arm64, sha512 checked) to `/opt/godot`, linked as `/opt/godot/godot` and `/usr/local/bin/godot`
- installs the helpers below to `/usr/local/bin`
- creates `~/gizmo/{logs,shots}`
- installs the extra apt packages and Tailscale, if configured
- removes the Wi-Fi password from `/boot/firmware/network-config` once it has been applied (the live copy is in `/etc/netplan/`, kept by NetworkManager as `90-NM-<uuid>.yaml`)
- shreds the Tailscale key

If the network is down at first boot, `gizmo-firstboot-net.service` retries the package and Tailscale steps every 2 minutes, including on later boots, and then disables itself.

Check first-boot status:

```sh
cat /var/lib/gizmo/firstboot.done        # build_id, step.<name>=ok|skipped|deferred|failed, network=done|pending
less /var/log/gizmo-firstboot.log        # full log (readable by the adm group)
systemctl status gizmo-firstboot-net     # only matters while network=pending
cloud-init status --long                 # "error" means a critical first-boot step failed
```

Layout:

| Path | What |
|---|---|
| `/opt/godot/godot` | Godot 4.5.1 editor/runtime (arm64) |
| `/usr/local/bin/gizmo-*` | helper commands below |
| `~/gizmo/project/` | rsync a project here |
| `~/gizmo/game/GizmoJam.arm64` | or an exported arm64 build here |
| `~/gizmo/logs/` | one log per `gizmo-run`, plus `kiosk.log` |
| `~/gizmo/shots/` | default screenshot location |

Every helper has `--help`. They never prompt. They print plain `key=value` lines or JSON, and work over SSH either as the desktop user or as root. As root, they act on the autologin user. Exit code 3 always means "no desktop session is running".

### Helpers

`gizmo-env` prints the desktop session environment (`XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `DISPLAY`, `XAUTHORITY`, ...), so any GUI command run over SSH appears on the Pi's screen:

```sh
eval "$(gizmo-env)" && wlr-randr      # also: --json, --plain, --user
```

`gizmo-run` starts Godot in the desktop session, detached from your SSH connection, and logs to `~/gizmo/logs/<timestamp>.log`. The default is `--rendering-driver opengl3_es`, because the Pi 4 GPU has no desktop GL 3.3.

```sh
gizmo-run -- --path ~/gizmo/project                      # prints pid=..., log=..., user=...
gizmo-run --fullscreen --binary ~/gizmo/game/GizmoJam.arm64
gizmo-run --wait --timeout 120 -- --path ~/gizmo/project --print-fps   # foreground; exits with the game's code (124 on timeout)
gizmo-run --list                 # games started this session (--json)
gizmo-run --wait-for 1234        # wait for an earlier start; prints exit=N
gizmo-run --stop 1234            # TERM, then KILL after --grace 10s
```

Options:
- `--driver opengl3_es|opengl3|vulkan|default` picks the renderer.
- `--display x11|wayland` picks the display driver. Godot's default is Xwayland, falling back to native Wayland.

`--stop` only signals a PID that `gizmo-run` started, checked against a recorded start time. It never matches processes by name.

`gizmo-shot` takes a PNG of the HDMI output with grim and prints its path. It powers the output back on first if it was blanked.

```sh
gizmo-shot                       # -> ~/gizmo/shots/<timestamp>.png
gizmo-shot /tmp/now.png          # or --output HDMI-A-1, --json
```

`gizmo-health` reports temperature, clocks and throttling as JSON. Values it cannot read are `null`.

```sh
gizmo-health
# {"temp_c": 52.1, "arm_hz": 1800000000, "core_hz": 500000000, "v3d_hz": 500000000,
#  "throttled_hex": "0x0", "under_voltage_now": false, "freq_capped_now": false,
#  "throttled_now": false, "soft_temp_limit_now": false, "..._occurred": false,
#  "load1": 0.4, "cpu_pct": 7.5, "mem_available_mb": 3120.5, ...}
gizmo-health --watch 1 --duration 120 --csv ~/gizmo/logs/run.csv --pid 1234
```

`--watch` prints one JSON line per sample (`"type":"sample"`), then a summary line (`"type":"summary"`) with min/max/avg values and `*_seen` throttle flags. `--pid` adds the game's CPU% and RSS.

`gizmo-kiosk` launches the game fullscreen at every desktop login. It picks the first of these that exists:
1. `~/gizmo/kiosk.sh`, run with bash in the foreground
2. `~/gizmo/game/GizmoJam.arm64`
3. `~/gizmo/project`

```sh
gizmo-kiosk on [--restart]       # --restart: relaunch after a crash (backoff 2s..60s); off by default
gizmo-kiosk start | stop         # start or stop it in the current session now
gizmo-kiosk status               # kiosk=on|off restart= running=PID|no target=...
gizmo-kiosk off                  # disable autostart and stop a running kiosk game
```

Run `gizmo-kiosk stop` before your own perf runs. With `--restart` on, a game you stop with `gizmo-run --stop` is relaunched.

### Agent workflow (performance test over SSH)

```sh
rsync -a --delete --exclude .godot/ ./ gizmo@PI:gizmo/project/
ssh gizmo@PI 'godot --headless --path ~/gizmo/project --import'   # once per asset change; slow on the Pi
ssh gizmo@PI 'gizmo-kiosk stop; gizmo-run --fullscreen -- --path ~/gizmo/project --print-fps'
#   -> pid=1234  log=/home/gizmo/gizmo/logs/20261118-101500.log
ssh gizmo@PI 'gizmo-health --watch 1 --duration 60 --pid 1234 --csv ~/gizmo/logs/perf.csv | tail -n 1'
ssh gizmo@PI 'gizmo-shot'                  # then scp the printed path back
ssh gizmo@PI 'gizmo-run --stop 1234; tail -n 50 ~/gizmo/logs/20261118-101500.log'
```

Alternatively, rsync an exported arm64 build to `~/gizmo/game/` and use `--binary`. That skips the import step.

### Tests (payload)

```sh
bash tools/pi-image/payload/tests/test_helpers.sh      # helpers against fakes, no root
bash tools/pi-image/payload/tests/chroot_test.sh       # firstboot.sh in the real image's rootfs (sudo, qemu-aarch64 binfmt)
```
