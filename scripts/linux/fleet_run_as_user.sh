#!/bin/bash

################################################################################
# fleet_run_as_user.sh
#
# A modular library for FleetDM to execute commands in the context of the
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
        for pid in $(pgrep -u "$SESSION_UID"); do
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
    debug_log "XAUTHORITY=$XAUTHORITY_VAR"
    debug_log "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR_VAR"

    return 0
}

################################################################################
# run_as_session_user
#
# Runs a command as the active session user WITHOUT graphical environment.
# Use this for background tasks, file operations, or non-GUI commands.
#
# Arguments:
#   $1 - Command to execute (required)
#
# Example:
#   run_as_session_user "echo 'Hello' > /home/user/test.txt"
#
# Returns: Exit code of the executed command
################################################################################
run_as_session_user() {
    local command="$1"

    if [[ -z "$command" ]]; then
        error_log "No command provided to run_as_session_user"
        return 1
    fi

    if [[ -z "$SESSION_USER" ]]; then
        error_log "Session user not set. Call find_active_session first."
        return 1
    fi

    info_log "Executing as $SESSION_USER (no GUI): $command"

    su - "$SESSION_USER" -c "$command"
    return $?
}

################################################################################
# run_as_graphical_user
#
# Runs a command as the active session user WITH full graphical environment.
# Use this for GUI applications, notifications, or display-dependent commands.
#
# Arguments:
#   $1 - Command to execute (required)
#
# Example:
#   run_as_graphical_user "firefox https://example.com"
#   run_as_graphical_user "notify-send 'Title' 'Message'"
#
# Returns: Exit code of the executed command
################################################################################
run_as_graphical_user() {
    local command="$1"

    if [[ -z "$command" ]]; then
        error_log "No command provided to run_as_graphical_user"
        return 1
    fi

    if [[ -z "$SESSION_USER" ]]; then
        error_log "Session user not set. Call find_active_session first."
        return 1
    fi

    if [[ -z "$DISPLAY_VAR" && -z "$WAYLAND_DISPLAY_VAR" ]]; then
        error_log "Display environment not set. Call get_display_environment first."
        return 1
    fi

    info_log "Executing as $SESSION_USER (with GUI): $command"

    su - "$SESSION_USER" -c "DISPLAY='$DISPLAY_VAR' WAYLAND_DISPLAY='$WAYLAND_DISPLAY_VAR' XAUTHORITY='$XAUTHORITY_VAR' DBUS_SESSION_BUS_ADDRESS='$DBUS_ADDRESS_VAR' XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR_VAR' $command"
    return $?
}

################################################################################
# show_notification
#
# Shows a desktop notification to the active user.
# This is a convenience wrapper around run_as_graphical_user.
#
# Arguments:
#   $1 - Notification title (required)
#   $2 - Notification message (required)
#   $3 - Urgency level: low, normal, critical (optional, default: normal)
#
# Example:
#   show_notification "System Update" "Your system will restart in 5 minutes" "critical"
#
# Returns: 0 on success, 1 on failure
################################################################################
show_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"

    if [[ -z "$title" || -z "$message" ]]; then
        error_log "Title and message are required for show_notification"
        return 1
    fi

    run_as_graphical_user "notify-send -u '$urgency' '$title' '$message'"
    return $?
}

################################################################################
# launch_browser
#
# Launches a web browser with the specified URL.
# This is a convenience wrapper around run_as_graphical_user.
#
# Arguments:
#   $1 - URL to open (required)
#   $2 - Browser command (optional, default: firefox)
#
# Example:
#   launch_browser "https://example.com"
#   launch_browser "https://example.com" "google-chrome"
#
# Returns: 0 on success, 1 on failure
################################################################################
launch_browser() {
    local url="$1"
    local browser="${2:-firefox}"

    if [[ -z "$url" ]]; then
        error_log "URL is required for launch_browser"
        return 1
    fi

    run_as_graphical_user "$browser '$url'"
    return $?
}

# --- Main Execution Entry Point ---

################################################################################
# main
#
# Main entry point for the script. Customize this function for your specific
# use case or call the individual functions as needed.
################################################################################
main() {
    # Ensure we're running as root
    ensure_root || exit 1

    # Find the active user session
    find_active_session || exit 1

    # Get display environment variables
    get_display_environment || exit 1

    # --- CUSTOMIZE YOUR ACTION HERE ---
    # Choose one of the examples below or write your own:

    # Example 1: Launch a website
    launch_browser "https://www.fleetdm.com"

    # Example 2: Show a notification
    # show_notification "FleetDM" "System check complete" "normal"

    # Example 3: Run a custom command with GUI
    # run_as_graphical_user "zenity --info --text='Hello from FleetDM'"

    # Example 4: Run a background task (no GUI)
    # run_as_session_user "echo 'Task completed at $(date)' >> /tmp/fleet-log.txt"

    # Example 5: Install software silently (no user interaction needed)
    # apt-get update && apt-get install -y some-package

    exit $?
}

# --- Script Execution ---
# Only run main if the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

################################################################################
# run_as_session_user
#
# Runs a command as the active session user WITHOUT graphical environment.
# Use this for background tasks, file operations, or non-GUI commands.
#
# Arguments:
#   $1 - Command to execute (required)
#
# Example:
#   run_as_session_user "echo 'Hello' > /home/user/test.txt"
#
# Returns: Exit code of the executed command
################################################################################
run_as_session_user() {
    local command="$1"

    if [[ -z "$command" ]]; then
        error_log "No command provided to run_as_session_user"
        return 1
    fi

    if [[ -z "$SESSION_USER" ]]; then
        error_log "Session user not set. Call find_active_session first."
        return 1
    fi

    info_log "Executing as $SESSION_USER (no GUI): $command"

    su - "$SESSION_USER" -c "$command"
    return $?
}

################################################################################
# run_as_graphical_user
#
# Runs a command as the active session user WITH full graphical environment.
# Use this for GUI applications, notifications, or display-dependent commands.
#
# Arguments:
#   $1 - Command to execute (required)
#
# Example:
#   run_as_graphical_user "firefox https://example.com"
#   run_as_graphical_user "notify-send 'Title' 'Message'"
#
# Returns: Exit code of the executed command
################################################################################
run_as_graphical_user() {
    local command="$1"

    if [[ -z "$command" ]]; then
        error_log "No command provided to run_as_graphical_user"
        return 1
    fi

    if [[ -z "$SESSION_USER" ]]; then
        error_log "Session user not set. Call find_active_session first."
        return 1
    fi

    if [[ -z "$DISPLAY_VAR" && -z "$WAYLAND_DISPLAY_VAR" ]]; then
        error_log "Display environment not set. Call get_display_environment first."
        return 1
    fi

    info_log "Executing as $SESSION_USER (with GUI): $command"

    su - "$SESSION_USER" -c "DISPLAY='$DISPLAY_VAR' WAYLAND_DISPLAY='$WAYLAND_DISPLAY_VAR' XAUTHORITY='$XAUTHORITY_VAR' DBUS_SESSION_BUS_ADDRESS='$DBUS_ADDRESS_VAR' XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR_VAR' $command"
    return $?
}

################################################################################
# show_notification
#
# Shows a desktop notification to the active user.
# This is a convenience wrapper around run_as_graphical_user.
#
# Arguments:
#   $1 - Notification title (required)
#   $2 - Notification message (required)
#   $3 - Urgency level: low, normal, critical (optional, default: normal)
#
# Example:
#   show_notification "System Update" "Your system will restart in 5 minutes" "critical"
#
# Returns: 0 on success, 1 on failure
################################################################################
show_notification() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"

    if [[ -z "$title" || -z "$message" ]]; then
        error_log "Title and message are required for show_notification"
        return 1
    fi

    run_as_graphical_user "notify-send -u '$urgency' '$title' '$message'"
    return $?
}

################################################################################
# launch_browser
#
# Launches a web browser with the specified URL.
# This is a convenience wrapper around run_as_graphical_user.
#
# Arguments:
#   $1 - URL to open (required)
#   $2 - Browser command (optional, default: firefox)
#
# Example:
#   launch_browser "https://example.com"
#   launch_browser "https://example.com" "google-chrome"
#
# Returns: 0 on success, 1 on failure
################################################################################
launch_browser() {
    local url="$1"
    local browser="${2:-firefox}"

    if [[ -z "$url" ]]; then
        error_log "URL is required for launch_browser"
        return 1
    fi

    run_as_graphical_user "$browser '$url'"
    return $?
}

# --- Main Execution Entry Point ---

################################################################################
# main
#
# Main entry point for the script. Customize this function for your specific
# use case or call the individual functions as needed.
################################################################################
main() {
    # Ensure we're running as root
    ensure_root || exit 1

    # Find the active user session
    find_active_session || exit 1

    # Get display environment variables
    get_display_environment || exit 1

    # --- CUSTOMIZE YOUR ACTION HERE ---
    # Choose one of the examples below or write your own:

    # Example 1: Launch a website
    launch_browser "https://www.fleetdm.com"

    # Example 2: Show a notification
    # show_notification "FleetDM" "System check complete" "normal"

    # Example 3: Run a custom command with GUI
    # run_as_graphical_user "zenity --info --text='Hello from FleetDM'"

    # Example 4: Run a background task (no GUI)
    # run_as_session_user "echo 'Task completed at $(date)' >> /tmp/fleet-log.txt"

    # Example 5: Install software silently (no user interaction needed)
    # apt-get update && apt-get install -y some-package

    exit $?
}

# --- Script Execution ---
# Only run main if the script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
