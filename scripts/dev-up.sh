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
#   DEV_PROBE=/dev/ttyXX   additional device to pass through
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
if [ ! -f "$CLAUDE_JSON" ]; then
    echo "WARN: $CLAUDE_JSON not found. Run 'claude' on the host at least once." >&2
fi
mkdir -p "$CLAUDE_DIR"

MOUNTS=(
    -v "$WORKSPACE:/workspace"
    -v "$CLAUDE_JSON:/host-claude-auth.json"
    -v "$CLAUDE_DIR:/host-claude-dir"
)

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

# USB / probe passthrough. Resolved at container START — a probe plugged in
# afterwards will not appear until the container is restarted.
USB_ARGS=()
[ -d /dev/bus/usb ] && USB_ARGS+=(--device=/dev/bus/usb)
[ -d /dev/serial/by-id ] && USB_ARGS+=(-v /dev/serial/by-id:/dev/serial/by-id:ro)
USB_ARGS+=(-v /sys/bus/usb:/sys/bus/usb)
[ -n "${DEV_PROBE:-}" ] && [ -e "$DEV_PROBE" ] && USB_ARGS+=(--device="$DEV_PROBE")

if [ ! -d /dev/bus/usb ]; then
    echo "WARN: /dev/bus/usb not present on this host — no probe passthrough." >&2
fi

# The numeric dialout/plugdev GIDs differ between the Arch container and the
# host distro, so pass the host's through explicitly.
GROUP_ARGS=()
DIALOUT_GID="$(getent group dialout 2>/dev/null | cut -d: -f3 || true)"
PLUGDEV_GID="$(getent group plugdev 2>/dev/null | cut -d: -f3 || true)"
[ -n "$DIALOUT_GID" ] && GROUP_ARGS+=(--group-add "$DIALOUT_GID")
[ -n "$PLUGDEV_GID" ] && GROUP_ARGS+=(--group-add "$PLUGDEV_GID")

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
