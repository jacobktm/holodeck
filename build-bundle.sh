#!/bin/bash
set -euo pipefail

# Assemble dist/immutable-bundle/ — the data payload distinst consumes at install
# time to provision the immutable system. Mirrors the @data/immutable layout used
# by install.sh so provisioning in the native port is a direct copy.

cd "$(dirname "$0")"

OUT="dist/immutable-bundle"
rm -rf "$OUT"
mkdir -p "$OUT"

# ── Rust immutable CLI (must be built first) ──
BIN="$(pwd)/immutable"
if [ ! -f "$BIN" ] || ! file "$BIN" | grep -q ELF; then
    echo "ERROR: immutable CLI not built. Run './build-rust.sh' first." >&2
    exit 1
fi
install -Dm755 "$BIN" "$OUT/bin/immutable"

# ── Bash completions + man page ──
install -Dm644 immutable.bash "$OUT/bash-completion/immutable"
install -Dm644 <(gzip -c immutable.1) "$OUT/man/immutable.1.gz"

# ── Boot/recovery scripts (live on @data, overridable) ──
install -Dm755 immutable-boot-counter.sh "$OUT/immutable-boot-counter.sh"
install -Dm755 immutable-healthcheck.sh "$OUT/immutable-healthcheck.sh"
install -Dm644 immutable-prompt.sh "$OUT/profile.d/immutable-prompt.sh"

# ── Hooks (protected source for overlay reinstalls) ──
for dir in kernel-postinst.d initramfs-post-update.d; do
    for hook in hooks/$dir/*; do
        [ -f "$hook" ] || continue
        install -Dm755 "$hook" "$OUT/hooks/$dir/$(basename "$hook")"
    done
done
install -Dm755 hooks/immutable-hook-reinstall "$OUT/hooks/immutable-hook-reinstall"
install -Dm644 hooks/dpkg-immutable "$OUT/hooks/dpkg-immutable"
install -Dm644 hooks/immutable-hooks-apt-hook "$OUT/hooks/immutable-hooks-apt-hook"
install -Dm755 hooks/apt-proxy-detect "$OUT/hooks/apt-proxy-detect"
install -Dm755 hooks/apt-proxy-detect.sh "$OUT/hooks/apt-proxy-detect.sh"

# ── Systemd units (fix-devpts mirrors install.sh's heredoc) ──
install -Dm644 immutable-data-mount.service "$OUT/services/immutable-data-mount.service"
install -Dm644 immutable-boot-counter.service "$OUT/services/immutable-boot-counter.service"
install -Dm644 immutable-healthcheck.service "$OUT/services/immutable-healthcheck.service"
cat > "$OUT/services/fix-devpts.service" <<'UNIT'
[Unit]
Description=Fix devpts ptmxmode for PTY allocation
After=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/bin/mount -o remount,ptmxmode=0666 /dev/pts
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT

# ── Immutable config template (USERNAME filled in by distinst) ──
cat > "$OUT/immutable.conf" <<'CONF'
# Immutable overlay configuration
# Overlay definitions
[overlays]
# Uncomment to set the default overlay at install time
# default = @overlay-init

# User account configured at install time
[user]
# USERNAME is set by the installer
CONF

echo "==> Bundle assembled at $OUT"
du -sh "$OUT"
