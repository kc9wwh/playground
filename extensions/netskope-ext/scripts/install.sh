#!/usr/bin/env bash
# Installs the netskope.ext extension into Fleet's orbit-managed osquery.
#
# Run as root. Safe to re-run — it overwrites the existing binary and updates
# extensions.load idempotently.

set -euo pipefail

BINARY_SRC="${1:-netskope.ext}"
EXT_DIR="/opt/orbit/osquery-extensions"
LOAD_FILE="/var/osquery/extensions.load"
TARGET="${EXT_DIR}/netskope.ext"

if [[ $EUID -ne 0 ]]; then
  echo "install.sh must be run as root" >&2
  exit 1
fi

if [[ ! -f "$BINARY_SRC" ]]; then
  echo "source binary not found at $BINARY_SRC" >&2
  exit 1
fi

os="$(uname -s)"
case "$os" in
  Darwin) owner="root:wheel" ;;
  Linux)  owner="root:root"  ;;
  *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac

mkdir -p "$EXT_DIR"
install -m 0755 -o "${owner%:*}" -g "${owner#*:}" "$BINARY_SRC" "$TARGET" 2>/dev/null || {
  # `install` on macOS doesn't accept -o/-g without coreutils; fall back.
  cp "$BINARY_SRC" "$TARGET"
  chown "$owner" "$TARGET"
  chmod 0755 "$TARGET"
}

mkdir -p "$(dirname "$LOAD_FILE")"
touch "$LOAD_FILE"
if ! grep -qxF "$TARGET" "$LOAD_FILE"; then
  echo "$TARGET" >> "$LOAD_FILE"
fi
chmod 0644 "$LOAD_FILE"

# Restart orbit so osqueryd picks up the new extensions.load entry.
case "$os" in
  Darwin)
    launchctl stop com.fleetdm.orbit 2>/dev/null || true
    launchctl start com.fleetdm.orbit 2>/dev/null || true
    ;;
  Linux)
    systemctl restart orbit 2>/dev/null || service orbit restart 2>/dev/null || true
    ;;
esac

echo "Installed $TARGET and registered in $LOAD_FILE"
