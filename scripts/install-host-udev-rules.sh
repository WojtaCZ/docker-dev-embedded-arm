#!/usr/bin/env bash
# Installs udev rules for all supported debug probes on the HOST machine.
#
# Run this ONCE on the Linux host so probe device nodes get correct group
# ownership and are accessible through the container's /dev/bus/usb bind mount.
#
# udev does NOT run inside a container — the rules shipped inside the image (at
# /opt/embedded/udev-rules/) have no effect there. They exist so this script can
# install them on the host, including when you only have the image and not a
# repo checkout:
#
#   docker run --rm ghcr.io/wojtacz/docker-dev-embedded-base:latest \
#       tar -C /opt/embedded -c udev-rules | tar -x -C /tmp
#   sudo /tmp/udev-rules/../install-host-udev-rules.sh
#
# Usage: sudo ./scripts/install-host-udev-rules.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_DEST="/etc/udev/rules.d"

# Locate the rules whether we are in a repo checkout (../udev-rules) or running
# the copy baked into the image (/opt/embedded/udev-rules).
for candidate in \
    "$SCRIPT_DIR/../udev-rules" \
    "$SCRIPT_DIR/udev-rules" \
    "/opt/embedded/udev-rules"
do
    if [ -d "$candidate" ]; then
        RULES_SRC="$(cd "$candidate" && pwd)"
        break
    fi
done

if [ -z "${RULES_SRC:-}" ]; then
    echo "ERROR: could not find a udev-rules directory next to $SCRIPT_DIR" >&2
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run with sudo" >&2
    exit 1
fi

if ! command -v udevadm >/dev/null 2>&1; then
    echo "ERROR: udevadm not found. You are probably running this INSIDE the" >&2
    echo "       container. These rules must be installed on the HOST." >&2
    exit 1
fi

echo "Installing udev rules from $RULES_SRC to $RULES_DEST ..."
cp -v "$RULES_SRC"/*.rules "$RULES_DEST/"

echo "Ensuring the plugdev group exists ..."
groupadd -f plugdev

echo "Reloading udev rules ..."
udevadm control --reload-rules
udevadm trigger

echo ""
echo "Done. Next:"
echo "  1. sudo usermod -aG dialout,plugdev \$USER   (then log out and back in)"
echo "  2. Replug your debug probe."
echo "  3. Start the container AFTER the probe is plugged in — /dev/bus/usb is"
echo "     bind-mounted at container start and will not pick up later devices."
echo "  4. Verify inside the container with:  dev-doctor   or   /probe-detect"
