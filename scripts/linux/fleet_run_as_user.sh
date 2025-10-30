#!/bin/bash

################################################################################
# fleet_run_as_user.sh
#
# A modular library for Fleet to execute commands in the context of the
# active graphical user session on Linux systems.
#
# Supports both X11 and Wayland display servers.
# Must be run as root.
#
# USAGE EXAMPLES:
#   1. Launch a website:
#      run_as_graphical_user "firefox https://example.com"
#
#   2. Show a notification:
#      run_as_graphical_user "notify-send 'System Update' 'Your system will restart in 5 minutes'"
#
#   3. Run a script:
#      run_as_graphical_user "/path/to/user-script.sh"
#
#   4. Silent background task (no GUI needed):
#      run_as_session_user "echo 'Task completed' >> /home/user/log.txt"
#
################################################################################

# --- Configuration ---
# Set to 1 to enable debug output
DEBUG=0

# --- Helper Functions ---

# Print debug messages if DEBUG is enabled
debug_log() {
    if [[ "$DEBUG" -eq 1 ]]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Print error messages
error_log() {
    echo "[ERROR] $*" >&2
}

# Print info messages
info_log() {
    echo "[INFO] $*" >&2
}

# --- Core Functions ---

################################################################################
# ensure_root
#
# Ensures the script is run as root. Exits with error if not.
################################################################################
ensure_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error_log "This script must be run as root."
        return 1
    fi
    return 0
}

################################################################################
# find_active_session
#
# Finds the active graphical user session using loginctl.
# Sets global variables: SESSION_ID, SESSION_USER, SESSION_UID
#
# Returns: 0 on success, 1 on failure
################################################################################
find_active_session() {
    local session_id

    debug_log "Searching for active graphical session..."

    # Try to find a graphical/user session with a seat (physical display)
    # Look for 'graphical' or 'user' class with seat0
    session_id=$(loginctl list-sessions --no-legend | awk '/seat0/ && (/graphical/ || /user/) {print $1; exit}')

    # If no seat0 session found, try any graphical session
    if [[ -z "$session_id" ]]; then
        debug_log "No seat0 session found, trying any graphical session..."
        session_id=$(loginctl list-sessions --no-legend | awk '/graphical/ {print $1; exit}')
    fi

    # If still nothing, try any user session (not manager)
    if [[ -z "$session_id" ]]; then
        debug_log "No graphical session found, trying any user session..."
        session_id=$(loginctl list-sessions --no-legend | awk '/user/ && !/manager/ {print $1; exit}')
    fi

    if [[ -z "$session_id" ]]; then
        error_log "Could not find an active user session."
        error_log "Available sessions:"
        loginctl list-sessions >&2
        return 1
    fi

    # Export session information as global variables
    export SESSION_ID="$session_id"
    export SESSION_USER=$(loginctl show-session "$session_id" -p Name --value)
    export SESSION_UID=$(loginctl show-session "$session_id" -p User --value)

    info_log "Found session: $SESSION_ID (user: $SESSION_USER, uid: $SESSION_UID)"
    return 0
}

################################################################################
# get_display_environment
#
# Extracts display-related environment variables from the active session.
# Sets global variables: DISPLAY_VAR, WAYLAND_DISPLAY_VAR, XAUTHORITY_VAR,
#                        DBUS_ADDRESS_VAR, XDG_RUNTIME_DIR_VAR
#
# Requires: SESSION_ID and SESSION_UID must be set (call find_active_session first)
# Returns: 0 on success, 1 on failure
################################################################################
get_display_environment() {
    if [[ -z "$SESSION_ID" || -z "$SESSION_UID" ]]; then
        error_log "Session information not available. Call find_active_session first."
        return 1
    fi

    local leader_pid
    leader_pid=$(loginctl show-session "$SESSION_ID" -p Leader --value)

    if [[ -z "$leader_pid" || "$leader_pid" -eq 0 ]]; then
        error_log "Could not find a leader process for session $SESSION_ID."
        return 1
    fi

    debug_log "Session leader PID: $leader_pid"

    # Try to find environment variables from the session leader process
    local env_file="/proc/$leader_pid/environ"

    if [[ -r "$env_file" ]]; then
        export DISPLAY_VAR=$(grep -z "^DISPLAY=" "$env_file" | tr -d '\0' | sed 's/^DISPLAY=//')
        export XAUTHORITY_VAR=$(grep -z "^XAUTHORITY=" "$env_file" | tr -d '\0' | sed 's/^XAUTHORITY=//')
        export DBUS_ADDRESS_VAR=$(grep -z "^DBUS_SESSION_BUS_ADDRESS=" "$env_file" | tr -d '\0' | sed 's/^DBUS_SESSION_BUS_ADDRESS=//')
        export WAYLAND_DISPLAY_VAR=$(grep -z "^WAYLAND_DISPLAY=" "$env_file" | tr -d '\0' | sed 's/^WAYLAND_DISPLAY=//')
    fi

    # If display variables are not found in leader process, search other user processes
    if [[ -z "$DISPLAY_VAR" && -z "$WAYLAND_DISPLAY_VAR" ]]; then
        debug_log "Display vars not in leader process, searching user processes..."
        for pid in $(pgrep -u "$SESSION_UID" | head -20); do
            if [[ -r "/proc/$pid/environ" ]]; then
                local found_display=$(grep -z "^DISPLAY=" "/proc/$pid/environ" 2>/dev/null | tr -d '\0' | sed 's/^DISPLAY=//')
                local found_wayland=$(grep -z "^WAYLAND_DISPLAY=" "/proc/$pid/environ" 2>/dev/null | tr -d '\0' | sed 's/^WAYLAND_DISPLAY=//')
                if [[ -n "$found_display" || -n "$found_wayland" ]]; then
                    export DISPLAY_VAR="$found_display"
                    export WAYLAND_DISPLAY_VAR="$found_wayland"
                    export XAUTHORITY_VAR=$(grep -z "^XAUTHORITY=" "/proc/$pid/environ" 2>/dev/null | tr -d '\0' | sed 's/^XAUTHORITY=//')
                    export DBUS_ADDRESS_VAR=$(grep -z "^DBUS_SESSION_BUS_ADDRESS=" "/proc/$pid/environ" 2>/dev/null | tr -d '\0' | sed 's/^DBUS_SESSION_BUS_ADDRESS=//')
                    debug_log "Found display environment from PID $pid"
                    break
                fi
            fi
        done
    fi

    # Set default display values if still not found
    if [[ -z "$DISPLAY_VAR" && -z "$WAYLAND_DISPLAY_VAR" ]]; then
        export DISPLAY_VAR=":0"
        export WAYLAND_DISPLAY_VAR="wayland-0"
        debug_log "Using default display values"
    fi

    # Set default XAUTHORITY if not found
    if [[ -z "$XAUTHORITY_VAR" ]]; then
        export XAUTHORITY_VAR="/home/$SESSION_USER/.Xauthority"
        debug_log "Using default XAUTHORITY"
    fi

    # Set XDG_RUNTIME_DIR (required for Wayland)
    export XDG_RUNTIME_DIR_VAR="/run/user/$SESSION_UID"

    debug_log "DISPLAY=$DISPLAY_VAR"
    debug_log "WAYLAND_DISPLAY=$WAYLAND_DISPLAY_VAR"
