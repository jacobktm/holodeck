#!/bin/bash
set -e
cd "$HOME" 2>/dev/null || cd /

# ── Nested session mode ──────────────────────────────────────────────
# If NESTED_SESSION=1, start a full COSMIC desktop session inside the
# container. cosmic-comp runs nested (Wayland client of host compositor),
# cosmic-settings connects to the container's session bus.
if [ "${NESTED_SESSION:-0}" = "1" ]; then
    echo "[entrypoint] Starting nested COSMIC session..."

    # Create container-local runtime directory
    CONTAINER_RUNTIME="/tmp/container-runtime"
    mkdir -p "$CONTAINER_RUNTIME"

    # Symlink the host's Wayland socket into the container runtime
    # so cosmic-comp can connect to the host compositor
    if [ -S "/host-runtime/$WAYLAND_DISPLAY" ]; then
        ln -sf "/host-runtime/$WAYLAND_DISPLAY" "$CONTAINER_RUNTIME/$WAYLAND_DISPLAY"
        echo "[entrypoint] Linked host Wayland socket: /host-runtime/$WAYLAND_DISPLAY"
    else
        echo "[entrypoint] WARN: No Wayland socket found at /host-runtime/$WAYLAND_DISPLAY"
    fi

    export XDG_RUNTIME_DIR="$CONTAINER_RUNTIME"

    # Debug: verify socket and GPU before starting
    echo "[entrypoint] XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
    echo "[entrypoint] WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
    echo "[entrypoint] Socket at $CONTAINER_RUNTIME/$WAYLAND_DISPLAY: $(file "$CONTAINER_RUNTIME/$WAYLAND_DISPLAY" 2>&1)"
    echo "[entrypoint] GPU devices:"
    ls -la /dev/dri/ 2>&1 || echo "[entrypoint] No /dev/dri"
    echo "[entrypoint] Groups: $(id -Gn 2>&1)"
    echo "[entrypoint] /dev/dri/renderD128 permissions: $(ls -la /dev/dri/renderD128 2>&1)"

    # Start user D-Bus session bus inside container
    echo "[entrypoint] Starting D-Bus session bus..."
    eval "$(dbus-launch --sh-syntax)"
    echo "[entrypoint] DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"

    # Start cosmic-session (launches cosmic-comp, cosmic-panel, etc.)
    # Capture its output so we can see why cosmic-comp crashes
    echo "[entrypoint] Starting cosmic-session..."
    export RUST_BACKTRACE=1
    cosmic-session > /tmp/cosmic-session.log 2>&1 &
    SESSION_PID=$!

    # Wait for cosmic-settings-daemon to register on D-Bus
    echo "[entrypoint] Waiting for cosmic-settings-daemon..."
    for i in $(seq 1 30); do
        if busctl --user list 2>/dev/null | grep -q cosmic-settings-daemon; then
            echo "[entrypoint] cosmic-settings-daemon registered"
            break
        fi
        sleep 1
    done

    # Start cosmic-settings (the PR build)
    echo "[entrypoint] Starting cosmic-settings..."
    cosmic-settings &

    echo "[entrypoint] Nested session running. Waiting..."
    wait $SESSION_PID
    EXIT_CODE=$?

    # Dump cosmic-session log on failure
    if [ $EXIT_CODE -ne 0 ]; then
        echo "[entrypoint] cosmic-session exited with code $EXIT_CODE"
        echo "[entrypoint] === cosmic-session log ==="
        cat /tmp/cosmic-session.log 2>&1 || true
    fi

    exit $EXIT_CODE
fi

# ── Standard mode (daemons and/or apps) ─────────────────────────────

# Wait for host-side cgroup fix to complete before launching apps
# Uses a shared bind-mount dir ($HOME/.local) so host can signal without docker exec
if [ "${NEEDS_LOGIND:-}" = "1" ] || [ "${NEEDS_LOGIND:-}" = "true" ]; then
    SIGNAL_DIR="$HOME/.local/share/cosmic-docker-signal"
    mkdir -p "$SIGNAL_DIR"
    touch "$SIGNAL_DIR/waiting"
    echo "[entrypoint] Waiting for cgroup fix..."
    while [ -f "$SIGNAL_DIR/waiting" ]; do
        sleep 0.5
    done
    echo "[entrypoint] Cgroup fix applied, launching apps"
fi

DAEMONS=""
APPS=""
for arg in "$@"; do
    case "$arg" in
        *-daemon|*-osd|*-background) DAEMONS="$DAEMONS $arg" ;;
        *) APPS="$APPS $arg" ;;
    esac
done

if [ -n "$DAEMONS" ]; then
    for d in $DAEMONS; do
        echo "[entrypoint] Starting daemon: $d"
        $d &
    done
    echo "[entrypoint] Waiting for daemons to register on D-Bus..."
    sleep 3

    echo "[entrypoint] Verifying daemon instances:"
    for d in $DAEMONS; do
        pids=$(pgrep -f "^${d}$" 2>/dev/null || true)
        count=$(echo "$pids" | grep -c . 2>/dev/null || echo 0)
        echo "  $d: $count instance(s)"
        for pid in $pids; do
            echo "    PID $pid"
        done
    done
fi

# Start gvfsd-fuse for volume/mount detection (USB drives, network shares)
# The host's gvfsd should already be on the session bus, but gvfsd-fuse
# needs to run here for the FUSE mount point at /run/user/$UID/gvfs/
if command -v gvfsd-fuse >/dev/null 2>&1; then
    mkdir -p "/run/user/$(id -u)/gvfs" 2>/dev/null || true
    (gvfsd-fuse "/run/user/$(id -u)/gvfs" 2>/dev/null || true) &
    echo "[entrypoint] Started gvfsd-fuse"
fi

# Parse LAUNCH_ARGS env var (format: "pkg:arg1 arg2 pkg2:arg3")
get_args() {
    local pkg="$1"
    for entry in $LAUNCH_ARGS; do
        case "$entry" in
            ${pkg}:*) echo "${entry#${pkg}:}" ;;
        esac
    done
}

for a in $APPS; do
    args=$(get_args "$a")
    echo "[entrypoint] Starting app: $a $args"
    RUST_BACKTRACE=1 $a $args > "/tmp/${a}.log" 2>&1 &
done

# Dump logs on exit (Ctrl-C, SIGTERM, etc.)
cleanup() {
    echo ""
    echo "[entrypoint] Shutting down..."
    for a in $APPS; do
        if [ -s "/tmp/${a}.log" ]; then
            echo "[entrypoint] === $a log ==="
            cat "/tmp/${a}.log"
        fi
    done
    # Kill child processes. With --pid host, daemonized processes get
    # reparented to PID 1, so -P $$ only catches direct children.
    # We do NOT use pkill -f here — it matches ALL host processes and
    # would kill the user's cosmic-session. The Python orchestrator
    # handles targeted cleanup via docker kill + docker rm -f.
    pkill -P $$ 2>/dev/null || true
    kill -- -$$ 2>/dev/null || true
    kill $$ 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "[entrypoint] All processes started. Press Ctrl-C to stop."
sleep infinity
