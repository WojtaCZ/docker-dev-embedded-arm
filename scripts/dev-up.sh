#!/usr/bin/env bash
# Headless build + run for the ARM Cortex-M dev container on Linux.
#
# Targets: STM32 (all families incl. WBA65), RP2040, TI MSPM0, any Cortex-M.
#
# Usage:
#   ./scripts/dev-up.sh                   # workspace = $(pwd)
#   ./scripts/dev-up.sh /path/to/project
#
# Env vars:
#   DEV_IMAGE=<name>       image tag              (default: dev-template-embedded-arm)
#   DEV_CONTAINER=<name>   running container name (default: dev-emb-arm)
#   DEV_CHANNEL=stable     track the promoted base tag instead of :latest
#   DEV_NO_BUILD=1         skip docker build
#   DEV_NO_PULL=1          don't --pull the base image (offline / pin)
#   DEV_REBUILD=1          docker build --no-cache
#   DEV_NO_CACHE_VOLUMES=1 don't mount the persistent package caches
#   DEV_SKIP_UPDATE=1      skip `claude update` on container start
#   DEV_DOCTOR=1           run dev-doctor and exit
#   DEV_PROBE=/dev/ttyXX   additional single device to pass through (static —
#                          must exist at container start, unlike /dev/bus/usb
#                          below, which is hotplug-capable)
#
# Optional host-mounted ST tooling (neither is redistributable, so neither is
# baked into the image). Both are auto-detected at their default paths:
#   DEV_CUBECLT=<path>     STM32CubeCLT  -> /opt/st/clt      (default ~/st/STM32CubeCLT)
#                          STM32_Programmer_CLI + ST-LINK GDB server. Day-one
#                          support for new silicon; useful when neither openocd
#                          nor probe-rs knows a part yet.
#   DEV_CUBEWBA=<path>     STM32CubeWBA  -> /opt/st/cubewba  (default ~/st/cubewba)
#                          REQUIRED for BLE on STM32WBA — the link layer and host
#                          stack are ST binary libraries under SLA0044 and there
#                          is no open alternative. See the stm32wba-ble-bringup skill.

set -euo pipefail

IMAGE_NAME="${DEV_IMAGE:-dev-template-embedded-arm}"
CONTAINER_NAME="${DEV_CONTAINER:-dev-emb-arm}"
WORKSPACE="${1:-$(pwd)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${DEV_NO_BUILD:-0}" != "1" ]; then
    BUILD_FLAGS=(--build-arg "BASE_TAG=${DEV_CHANNEL:-latest}")
    [ "${DEV_NO_PULL:-0}" != "1" ] && BUILD_FLAGS+=("--pull")
    [ "${DEV_REBUILD:-0}" = "1" ]  && BUILD_FLAGS+=("--no-cache")
    docker build "${BUILD_FLAGS[@]}" -t "$IMAGE_NAME" "$REPO_ROOT"
fi

CLAUDE_JSON="$HOME/.claude.json"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_CREDS="$CLAUDE_DIR/.credentials.json"
if [ ! -f "$CLAUDE_JSON" ]; then
    echo "WARN: $CLAUDE_JSON not found. Run 'claude' on the host at least once." >&2
fi
mkdir -p "$CLAUDE_DIR"
touch "$CLAUDE_JSON"
[ -f "$CLAUDE_CREDS" ] || { touch "$CLAUDE_CREDS"; chmod 600 "$CLAUDE_CREDS"; }

# .claude.json and .credentials.json are bind-mounted straight onto their
# final in-container paths, NOT through the base image's entrypoint-time
# symlink-after-copy at /host-claude-auth.json / /host-claude-dir (which now
# harmlessly no-ops, since those paths are never populated here anymore).
# `claude login` persists credentials with a write-temp-then-rename(2), and
# rename(2) onto a plain symlink just replaces the symlink with a new inode —
# silently orphaning the host file — so a login done only inside a --rm
# container never survived a restart. A real bind mount IS a mount point:
# rename(2) onto it fails EBUSY, which Claude Code's credential writer
# specifically catches and falls back to copyFile(), which writes through to
# the real host file. Verified against the shipped `claude` binary's write
# path and reproduced end-to-end with both mount styles.
MOUNTS=(
    -v "$WORKSPACE:/workspace"
    -v "$CLAUDE_JSON:/home/dev/.claude.json"
    -v "$CLAUDE_CREDS:/home/dev/.claude/.credentials.json"
)
for shared in projects memory; do
    if [ -e "$CLAUDE_DIR/$shared" ]; then
        MOUNTS+=(-v "$CLAUDE_DIR/$shared:/home/dev/.claude/$shared")
    fi
done

if [ "${DEV_NO_CACHE_VOLUMES:-0}" != "1" ]; then
    MOUNTS+=(
        -v "dev-cache-npm:/home/dev/.npm"
        -v "dev-cache-uv:/home/dev/.cache/uv"
        -v "dev-cache-cargo:/home/dev/.cargo"
        -v "dev-cache-pyocd:/opt/pyocd"
        -v "dev-cache-ccache:/home/dev/.cache/ccache"
    )
fi

# Optional ST tooling, mounted read-only if present on the host.
CUBECLT="${DEV_CUBECLT:-$HOME/st/STM32CubeCLT}"
CUBEWBA="${DEV_CUBEWBA:-$HOME/st/cubewba}"
if [ -d "$CUBECLT" ]; then
    MOUNTS+=(-v "$CUBECLT:/opt/st/clt:ro")
    echo "info: mounting STM32CubeCLT from $CUBECLT"
fi
if [ -d "$CUBEWBA" ]; then
    MOUNTS+=(-v "$CUBEWBA:/opt/st/cubewba:ro")
    echo "info: mounting STM32CubeWBA from $CUBEWBA (BLE stack available)"
fi

# USB / probe passthrough — hotplug-capable, no container restart needed to
# pick up a probe attached after `dev-up.sh` has already started.
#
# `--device=/dev/bus/usb` (the old approach) makes Docker walk the directory
# ONCE at container creation, mknod only the device nodes it finds right then,
# and cgroup-allow only those specific major:minor pairs. Anything plugged in
# afterwards is invisible — not because the bind mount is stale, but because
# the container's device cgroup never allowed its major:minor in the first
# place.
#
# Fix: `-v` bind-mounts the directory itself, a live view — new device nodes
# the kernel creates under it later show up immediately, same as any other
# directory bind mount of a path that changes on the host. Pair that with
# `--device-cgroup-rule`, which grants a wildcard on USB's kernel-assigned
# major number (189, "USB devices" in Documentation/admin-guide/devices.txt)
# instead of an enumerated list, so every future minor under it is already
# permitted — no restart needed to re-grant it either.
USB_ARGS=()
if [ -d /dev/bus/usb ]; then
    USB_ARGS+=(-v /dev/bus/usb:/dev/bus/usb --device-cgroup-rule='c 189:* rmw')
else
    echo "WARN: /dev/bus/usb not present on this host — no probe passthrough." >&2
fi
[ -d /dev/serial/by-id ] && USB_ARGS+=(-v /dev/serial/by-id:/dev/serial/by-id:ro)
# /sys/bus/usb is deliberately NOT bind-mounted. Docker Desktop's WSL
# integration remembers every bind source and replays it when the distro proxy
# starts; after a WSL restart (usbipd detached) /sys/bus/usb no longer exists,
# sysfs rejects the mkdir, and the whole integration fails with
# "mkdir /sys/bus/usb: operation not permitted". The container's own /sys is
# the kernel's sysfs, so /sys/bus/usb appears there by itself once USB exists.
# DEV_PROBE stays a static, one-shot --device: unlike the bus-wide bind mount
# above, a single device node still has to exist at container start.
[ -n "${DEV_PROBE:-}" ] && [ -e "$DEV_PROBE" ] && USB_ARGS+=(--device="$DEV_PROBE")

# hidraw passthrough, for a USB *device under test* that enumerates as HID (not
# a probe — probes are reached through libusb and /dev/bus/usb above).
#
# This one cannot be made hotplug-capable the way /dev/bus/usb is. hidraw nodes
# are created flat in /dev, so there is no per-subsystem directory to bind-mount
# as a live view; bind-mounting /dev wholesale is not an acceptable price. So
# the nodes are enumerated once, like DEV_PROBE. Plug the board in BEFORE
# starting the container, or re-run dev-up.sh after plugging it in.
#
# The cgroup grant is still a wildcard, because hidraw's major is assigned
# dynamically at module load (240 on one boot, something else on the next) —
# read it from /proc/devices rather than hardcoding. With the major granted,
# a node that appears later only needs a mknod, not a new container.
HIDRAW_MAJOR="$(awk '$2 == "hidraw" { print $1 }' /proc/devices)"
if [ -n "$HIDRAW_MAJOR" ]; then
    USB_ARGS+=(--device-cgroup-rule="c $HIDRAW_MAJOR:* rmw")
    hidraw_found=0
    for node in /dev/hidraw*; do
        [ -c "$node" ] || continue
        USB_ARGS+=(-v "$node:$node")
        hidraw_found=1
    done
    if [ "$hidraw_found" = 0 ]; then
        echo "info: hidraw major $HIDRAW_MAJOR granted, but no /dev/hidraw* node exists yet — re-run dev-up.sh once the device is plugged in." >&2
    fi
fi

# ttyACM passthrough — the ST-Link (and most CDC-ACM debug probes) expose a
# virtual COM port here, used for VCP logging and RTT-over-serial fallback.
#
# Same shape as hidraw: ttyACM nodes are flat in /dev with no per-subsystem
# directory to bind-mount live, so they're enumerated once at container start.
# Plug the board in BEFORE starting the container, or re-run dev-up.sh after.
# The major is LANANA-assigned as 166 ("USB serial converters - ttyACM" in
# Documentation/admin-guide/devices.txt), but it's still read from
# /proc/devices rather than hardcoded, same reasoning as hidraw/input above.
TTYACM_MAJOR="$(awk '$2 == "ttyACM" { print $1 }' /proc/devices)"
if [ -n "$TTYACM_MAJOR" ]; then
    USB_ARGS+=(--device-cgroup-rule="c $TTYACM_MAJOR:* rmw")
    ttyacm_found=0
    for node in /dev/ttyACM*; do
        [ -c "$node" ] || continue
        USB_ARGS+=(-v "$node:$node")
        ttyacm_found=1
    done
    if [ "$ttyacm_found" = 0 ]; then
        echo "info: ttyACM major $TTYACM_MAJOR granted, but no /dev/ttyACM* node exists yet — re-run dev-up.sh once the device is plugged in." >&2
    fi
fi

# /dev/input passthrough — touch panels, styluses, and anything else the
# kernel binds a Linux input handler to (hid-multitouch included), as opposed
# to the raw HID reports above.
#
# Unlike hidraw, /dev/input IS a per-subsystem directory, same shape as
# /dev/bus/usb: bind-mounting it is a live view, so an eventN node the kernel
# creates after this container has already started (hid-multitouch binding on
# a panel attached to WSL later, a replug) shows up with no restart. by-id/
# and by-path/ ride along for free, giving stable paths for a specific panel.
#
# The input major is conventionally 13 (INPUT_MAJOR in the kernel headers),
# but it's still read from /proc/devices rather than hardcoded, on the same
# reasoning as hidraw above — cheap insurance against a kernel that assigns
# it differently.
INPUT_MAJOR="$(awk '$2 == "input" { print $1 }' /proc/devices)"
if [ -d /dev/input ]; then
    USB_ARGS+=(-v /dev/input:/dev/input)
    [ -n "$INPUT_MAJOR" ] && USB_ARGS+=(--device-cgroup-rule="c $INPUT_MAJOR:* rmw")
else
    echo "WARN: /dev/input not present on this host — no touch/HID input passthrough." >&2
fi

# The numeric dialout/plugdev/input GIDs differ between the Arch container and
# the host distro, so pass the host's through explicitly. A device-cgroup-rule
# only grants the container's cgroup permission to open the node; the node
# itself is still owned root:<group> mode 0660 (hidraw nodes land in plugdev
# via udev rule, input nodes in the kernel's own "input" group), so the `dev`
# user still needs to be a member of that GID to actually read() it.
GROUP_ARGS=()
DIALOUT_GID="$(getent group dialout 2>/dev/null | cut -d: -f3 || true)"
PLUGDEV_GID="$(getent group plugdev 2>/dev/null | cut -d: -f3 || true)"
INPUT_GID="$(getent group input 2>/dev/null | cut -d: -f3 || true)"
[ -n "$DIALOUT_GID" ] && GROUP_ARGS+=(--group-add "$DIALOUT_GID")
[ -n "$PLUGDEV_GID" ] && GROUP_ARGS+=(--group-add "$PLUGDEV_GID")
[ -n "$INPUT_GID" ] && GROUP_ARGS+=(--group-add "$INPUT_GID")

# UID alignment for the bind-mounted workspace.
USER_ARGS=()
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
if [ "$HOST_UID" != "1000" ] || [ "$HOST_GID" != "1000" ]; then
    USER_ARGS=(--user 0:0 -e "HOST_UID=$HOST_UID" -e "HOST_GID=$HOST_GID")
fi

ENV_ARGS=()
[ "${DEV_SKIP_UPDATE:-0}" = "1" ] && ENV_ARGS+=(-e DEV_SKIP_UPDATE=1)
[ -n "${GITHUB_TOKEN:-}" ] && ENV_ARGS+=(-e "GITHUB_TOKEN=$GITHUB_TOKEN")

SSH_ARGS=()
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    SSH_ARGS=(-v "$SSH_AUTH_SOCK:/ssh-agent" -e SSH_AUTH_SOCK=/ssh-agent)
else
    echo "WARN: SSH_AUTH_SOCK not set; git over SSH won't work." >&2
fi

CMD_ARGS=()
[ "${DEV_DOCTOR:-0}" = "1" ] && CMD_ARGS=(dev-doctor)

exec docker run --rm -it \
    --name "$CONTAINER_NAME" \
    --init \
    "${MOUNTS[@]}" \
    "${USB_ARGS[@]}" \
    "${GROUP_ARGS[@]}" \
    "${USER_ARGS[@]}" \
    "${ENV_ARGS[@]}" \
    "${SSH_ARGS[@]}" \
    "$IMAGE_NAME" "${CMD_ARGS[@]}"
