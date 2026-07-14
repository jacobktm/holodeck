#!/usr/bin/env bash
# Reusable signal file pattern for inter-process communication.
# Usage:
#   Source this in any script: source "$(dirname "$0")/lib/signal.sh"
#   signal_wait [file]       - block until file exists (for receivers)
#   signal_send <file>       - create the file (for senders)
#   signal_clear <file>      - remove the file

SIGNAL_DEFAULT="/tmp/cosmic-exit"

signal_wait() {
    local file="${1:-$SIGNAL_DEFAULT}"
    while [ ! -f "$file" ]; do
        sleep 1
    done
    rm -f "$file"
}

signal_send() {
    local file="${1:-$SIGNAL_DEFAULT}"
    touch "$file"
}

signal_clear() {
    local file="${1:-$SIGNAL_DEFAULT}"
    rm -f "$file"
}
