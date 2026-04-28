#!/usr/bin/env bash
# Install the tailscale osquery extension on macOS or Linux.
#
# Run as root. Expects the tailscale.ext binary for the host's platform/arch
# to sit next to this script (or at a path passed as $1).

set -euo pipefail

BIN_SRC="${1:-$(dirname "$0")/tailscale.ext}"

if [[ $EUID -ne 0 ]]; then
  echo "install.sh must be run as root" >&2
  exit 1
fi

if [[ ! -f "$BIN_SRC" ]]; then
  echo "Binary not found at $BIN_SRC" >&2
  exit 1
fi

OS="$(uname -s)"
case "$OS" in
  Darwin)
    DEST_DIR="/var/osquery/extensions"
    OWNER="root:wheel"
    RESTART_CMD=("launchctl" "kickstart" "-k" "system/com.fleetdm.orbit")
    ;;
  Linux)
    DEST_DIR="/var/osquery/extensions"
    OWNER="root:root"
    RESTART_CMD=("systemctl" "restart" "orbit")
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    exit 1
    ;;
esac

EXT_LOAD="/var/osquery/extensions.load"

mkdir -p "$DEST_DIR"
install -m 0755 -o "${OWNER%%:*}" -g "${OWNER##*:}" "$BIN_SRC" "$DEST_DIR/tailscale.ext"

# Add to extensions.load if not already present.
touch "$EXT_LOAD"
chmod 0644 "$EXT_LOAD"
if ! grep -qxF "$DEST_DIR/tailscale.ext" "$EXT_LOAD"; then
  echo "$DEST_DIR/tailscale.ext" >> "$EXT_LOAD"
fi

echo "Installed tailscale.ext to $DEST_DIR"
echo "Registered in $EXT_LOAD"
echo "Restarting orbit..."
"${RESTART_CMD[@]}" || {
  echo "Automatic restart failed. Restart orbit/osqueryd manually." >&2
  exit 1
}

echo "Done. Query with: SELECT * FROM tailscale_status;"
