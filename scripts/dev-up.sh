#!/usr/bin/env bash
# Headless build + run for the ARM embedded dev container on Linux.
# Targets: STM32, RP2040, TI MSPM0, and any other Cortex-M device.
#
# Usage:
#   ./scripts/dev-up.sh                   # workspace = $(pwd)
#   ./scripts/dev-up.sh /path/to/firmware
#
# Env vars:
#   DEV_IMAGE=<name>       image tag              (default: dev-template-embedded-arm)
#   DEV_CONTAINER=<name>   running container name (default: dev-emb-arm)
#   DEV_NO_BUILD=1         skip docker build
#   DEV_NO_PULL=1          don't --pull the base image (offline / pin)
#   DEV_REBUILD=1          docker build --no-cache
#   DEV_PROBE=/dev/ttyXX   additional device to pass through

set -euo pipefail

IMAGE_NAME="${DEV_IMAGE:-dev-template-embedded-arm}"
CONTAINER_NAME="${DEV_CONTAINER:-dev-emb-arm}"
WORKSPACE="${1:-$(pwd)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${DEV_NO_BUILD:-0}" != "1" ]; then
    BUILD_FLAGS=()
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

USB_ARGS=()
[ -d /dev/bus/usb ] && USB_ARGS+=(--device=/dev/bus/usb)
[ -d /dev/serial/by-id ] && USB_ARGS+=(-v /dev/serial/by-id:/dev/serial/by-id:ro)
USB_ARGS+=(-v /sys/bus/usb:/sys/bus/usb)
[ -n "${DEV_PROBE:-}" ] && [ -e "$DEV_PROBE" ] && USB_ARGS+=(--device="$DEV_PROBE")

GROUP_ARGS=()
DIALOUT_GID="$(getent group dialout 2>/dev/null | cut -d: -f3 || true)"
PLUGDEV_GID="$(getent group plugdev 2>/dev/null | cut -d: -f3 || true)"
[ -n "$DIALOUT_GID" ] && GROUP_ARGS+=(--group-add "$DIALOUT_GID")
[ -n "$PLUGDEV_GID" ] && GROUP_ARGS+=(--group-add "$PLUGDEV_GID")

SSH_ARGS=()
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    SSH_ARGS=(-v "$SSH_AUTH_SOCK:/ssh-agent" -e SSH_AUTH_SOCK=/ssh-agent)
else
    echo "WARN: SSH_AUTH_SOCK not set; git over SSH won't work." >&2
fi

exec docker run --rm -it \
    --name "$CONTAINER_NAME" \
    --init \
    "${MOUNTS[@]}" \
    "${USB_ARGS[@]}" \
    "${GROUP_ARGS[@]}" \
    "${SSH_ARGS[@]}" \
    "$IMAGE_NAME"
