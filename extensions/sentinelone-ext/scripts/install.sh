#!/bin/bash
set -euo pipefail

# ============================================================================
# SentinelOne osquery extension installer (macOS and Linux)
#
# Usage: sudo ./install.sh /path/to/sentinelone.ext_<platform>
#
# Steps:
#   1. Copies the extension binary to /usr/local/bin/sentinelone.ext
#   2. Sets correct ownership and 755 permissions
#   3. Adds the binary to osquery's extensions.load
#   4. Restarts orbit to load the extension
# ============================================================================

EXTENSION_NAME="sentinelone.ext"
INSTALL_DIR="/usr/local/bin"
BINARY_SOURCE="${1:?Usage: $0 /path/to/extension/binary}"

OS="$(uname -s)"
case "${OS}" in
    Darwin)
        OWNER="root:wheel"
        EXTENSIONS_LOAD="/var/osquery/extensions.load"
        restart_orbit() {
            launchctl stop com.fleetdm.orbit 2>/dev/null || true
            sleep 2
            launchctl start com.fleetdm.orbit
        }
        ;;
    Linux)
        OWNER="root:root"
        if [ -d "/var/osquery" ]; then
            EXTENSIONS_LOAD="/var/osquery/extensions.load"
        else
            EXTENSIONS_LOAD="/etc/osquery/extensions.load"
        fi
        restart_orbit() {
            systemctl restart orbit 2>/dev/null || true
        }
        ;;
    *)
        echo "Error: Unsupported OS: ${OS}" >&2
        exit 1
        ;;
esac

EXTENSION_PATH="${INSTALL_DIR}/${EXTENSION_NAME}"

echo "==> Installing ${EXTENSION_NAME}..."

if [ ! -f "${BINARY_SOURCE}" ]; then
    echo "Error: Binary not found at ${BINARY_SOURCE}" >&2
    exit 1
fi

mkdir -p "${INSTALL_DIR}"

cp "${BINARY_SOURCE}" "${EXTENSION_PATH}"
chown "${OWNER}" "${EXTENSION_PATH}"
chmod 755 "${EXTENSION_PATH}"
echo "    Binary installed to ${EXTENSION_PATH}"

mkdir -p "$(dirname "${EXTENSIONS_LOAD}")"

if ! grep -qF "${EXTENSION_PATH}" "${EXTENSIONS_LOAD}" 2>/dev/null; then
    echo "${EXTENSION_PATH}" >> "${EXTENSIONS_LOAD}"
    echo "    Added to ${EXTENSIONS_LOAD}"
else
    echo "    Already in ${EXTENSIONS_LOAD}"
fi

echo "==> Restarting orbit..."
restart_orbit
echo "    Orbit restarted"

echo ""
echo "==> Done. Verify with:"
echo "    sudo orbit shell"
echo "    osquery> SELECT * FROM sentinelone_info;"
