#!/bin/bash

#
# fleet_launch_ubuntu_website.sh
#
# A self-contained script for FleetDM to launch a specific website on the
# active graphical user's desktop. This script is intended to be run directly
# by FleetDM without needing any pre-existing scripts on the host.
# Must be run as root.
#
# Supports both X11 and Wayland display servers.
#

# --- Start of Core Logic ---

# Ensure the script is run as root.
if [[ "$(id -u)" -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# Function to find the active graphical session and export its context.
get_active_session_info() {
    local session_id
    local session_user
    local session_uid
    local leader_pid
    
    # Try to find a graphical/user session with a seat (physical display)
    # Look for 'graphical' or 'user' class with seat0
    session_id=$(loginctl list-sessions --no-legend | awk '/seat0/ && (/graphical/ || /user/) {print $1; exit}')
    
    # If no seat0 session found, try any graphical session
    if [[ -z "$session_id" ]]; then
        session_id=$(loginctl list-sessions --no-legend | awk '/graphical/ {print $1; exit}')
    fi
    
    # If still nothing, try any user session (not manager)
    if [[ -z "$session_id" ]]; then
        session_id=$(loginctl list-sessions --no-legend | awk '/user/ && !/manager/ {print $1; exit}')
    fi

    if [[ -z "$session_id" ]]; then
        echo "Error: Could not find an active user session." >&2
        echo "Available sessions:" >&2
        loginctl list-sessions >&2
        return 1
    fi
    
    echo "Found session: $session_id" >&2

    session_user=$(loginctl show-session "$session_id" -p Name --value)
    session_uid=$(loginctl show-session "$session_id" -p User --value)
    
    leader_pid=$(loginctl show-session "$session_id" -p Leader --value)

    if [[ -z "$leader_pid" || "$leader_pid" -eq 0 ]]; then
        echo "Error: Could not find a leader process for session $session_id." >&2
        return 1
    fi
    
    export TARGET_USER="$session_user"
    export TARGET_UID="$session_uid"
    
    # Try to find environment variables from the session leader process
    local env_file="/proc/$leader_pid/environ"
    
    if [[ -r "$env_file" ]]; then
        export TARGET_DISPLAY=$(grep -z "^DISPLAY=" "$env_file" | tr -d '\0' | sed 's/^DISPLAY=//')
        export TARGET_XAUTHORITY=$(grep -z "^XAUTHORITY=" "$env_file" | tr -d '\0' | sed 's/^XAUTHORITY=//')
        export TARGET_DBUS_ADDRESS=$(grep -z "^DBUS_SESSION_BUS_ADDRESS=" "$env_file" | tr -d '\0' | sed 's/^DBUS_SESSION_BUS_ADDRESS=//')
        export TARGET_WAYLAND_DISPLAY=$(grep -z "^WAYLAND_DISPLAY=" "$env_file" | tr -d '\0' | sed 's/^WAYLAND_DISPLAY=//')
    fi
    
    # If display variables are not found in leader process, search other user processes
    # This is necessary because the session leader may not have display environment set
    if [[ -z "$TARGET_DISPLAY" && -z "$TARGET_WAYLAND_DISPLAY" ]]; then
        echo "Searching for DISPLAY/WAYLAND_DISPLAY in user processes..." >&2
        for pid in $(pgrep -u "$session_uid"); do
            if [[ -r "/proc/$pid/environ" ]]; then
                FOUND_DISPLAY=$(grep -z "^DISPLAY=" "/proc/$pid/environ" 2>/dev/null | tr -d '\0' | sed 's/^DISPLAY=//')
                FOUND_WAYLAND=$(grep -z "^WAYLAND_DISPLAY=" "/proc/$pid/environ" 2>/dev/null | tr -d '\0' | sed 's/^WAYLAND_DISPLAY=//')
                if [[ -n "$FOUND_DISPLAY" || -n "$FOUND_WAYLAND" ]]; then
                    export TARGET_DISPLAY="$FOUND_DISPLAY"
                    export TARGET_WAYLAND_DISPLAY="$FOUND_WAYLAND"
                    export TARGET_XAUTHORITY=$(grep -z "^XAUTHORITY=" "/proc/$pid/environ" 2>/dev/null | tr -d '\0' | sed 's/^XAUTHORITY=//')
                    export TARGET_DBUS_ADDRESS=$(grep -z "^DBUS_SESSION_BUS_ADDRESS=" "/proc/$pid/environ" 2>/dev/null | tr -d '\0' | sed 's/^DBUS_SESSION_BUS_ADDRESS=//')
                    echo "Found DISPLAY=$TARGET_DISPLAY WAYLAND_DISPLAY=$TARGET_WAYLAND_DISPLAY from PID $pid" >&2
                    break
                fi
            fi
        done
    fi
    
    # Set default display values if still not found
    if [[ -z "$TARGET_DISPLAY" && -z "$TARGET_WAYLAND_DISPLAY" ]]; then
        export TARGET_DISPLAY=":0"
        export TARGET_WAYLAND_DISPLAY="wayland-0"
        echo "Using defaults: DISPLAY=:0 WAYLAND_DISPLAY=wayland-0" >&2
    fi
    
    # Set default XAUTHORITY if not found
    if [[ -z "$TARGET_XAUTHORITY" ]]; then
        export TARGET_XAUTHORITY="/home/$TARGET_USER/.Xauthority"
        echo "Using default XAUTHORITY=$TARGET_XAUTHORITY" >&2
    fi
    
    echo "Using DISPLAY=$TARGET_DISPLAY" >&2
    echo "Using WAYLAND_DISPLAY=$TARGET_WAYLAND_DISPLAY" >&2
    echo "Using XAUTHORITY=$TARGET_XAUTHORITY" >&2
    
    if [[ -z "$TARGET_DBUS_ADDRESS" ]]; then
        echo "Note: DBUS_SESSION_BUS_ADDRESS not set. Desktop notifications may not work." >&2
    fi

    return 0
}

# --- End of Core Logic ---

# --- Main Execution ---

# Define the specific command to be run.
COMMAND_TO_RUN="firefox https://www.fleetdm.com"

# Find the user and their session context.
get_active_session_info
if [[ $? -ne 0 ]]; then
    exit 1
fi

echo "Executing command as user: $TARGET_USER"
echo "Command: $COMMAND_TO_RUN"

# Use su to execute the command as the target user with proper environment.
# This sets up both X11 (DISPLAY/XAUTHORITY) and Wayland (WAYLAND_DISPLAY) variables,
# along with XDG_RUNTIME_DIR which is required for Wayland socket access.
su - "$TARGET_USER" -c "DISPLAY='$TARGET_DISPLAY' WAYLAND_DISPLAY='$TARGET_WAYLAND_DISPLAY' XAUTHORITY='$TARGET_XAUTHORITY' DBUS_SESSION_BUS_ADDRESS='$TARGET_DBUS_ADDRESS' XDG_RUNTIME_DIR='/run/user/$TARGET_UID' $COMMAND_TO_RUN"

exit 0