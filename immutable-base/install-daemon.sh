#!/bin/bash
set -euo pipefail

# Install immutable daemon and CLI

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing immutable daemon..."

# Create immutable group
if ! getent group immutable >/dev/null 2>&1; then
    groupadd immutable
    echo "  Created group 'immutable'"
fi

# Add USERNAMEuser to immutable group
if id USERNAME&>/dev/null; then
    usermod -aG immutable USERNAME
    echo "  Added USERNAMEto 'immutable' group"
fi

# Install daemon modules
mkdir -p /usr/lib/immutable
cp -r "$SCRIPT_DIR/daemon/"*.py /usr/lib/immutable/
touch /usr/lib/immutable/__init__.py
echo "  Installed daemon modules to /usr/lib/immutable/"

# Install CLI
cp "$SCRIPT_DIR/immutable" /usr/local/bin/immutable
chmod +x /usr/local/bin/immutable
echo "  Installed CLI to /usr/local/bin/immutable"

# Install systemd units
cp "$SCRIPT_DIR/immutable-daemon.service" /etc/systemd/system/
cp "$SCRIPT_DIR/immutable-daemon.socket" /etc/systemd/system/
cp "$SCRIPT_DIR/tmpfiles-immutable.conf" /etc/tmpfiles.d/immutable.conf
echo "  Installed systemd units"

# Create socket directory
mkdir -p /run/immutable
chmod 770 /run/immutable

# Reload and enable
systemctl daemon-reload
systemctl enable immutable-daemon.socket
echo "  Enabled immutable-daemon.socket"

# Install immutable-aware kernelstub hooks
echo "Installing immutable-aware kernelstub hooks..."
HOOKS_SRC="$SCRIPT_DIR/hooks"
if [ -d "$HOOKS_SRC" ]; then
    # Install hooks to protected source directory (for dpkg-triggered reinstall)
    for dir in kernel-postinst.d initramfs-post-update.d; do
        if [ -d "$HOOKS_SRC/$dir" ]; then
            for hook in "$HOOKS_SRC/$dir"/*; do
                [ -f "$hook" ] || continue
                install -Dm755 "$hook" "/usr/lib/immutable/hooks/$dir/$(basename "$hook")"
            done
        fi
    done

    # Install hooks to active locations (override stock hooks)
    for dir in kernel-postinst.d initramfs-post-update.d; do
        if [ -d "$HOOKS_SRC/$dir" ]; then
            for hook in "$HOOKS_SRC/$dir"/*; do
                [ -f "$hook" ] || continue
                install -Dm755 "$hook" "/etc/$dir/$(basename "$hook")"
            done
        fi
    done

    # Install dpkg config: auto-keep our modified hooks (no prompts)
    install -Dm644 "$HOOKS_SRC/dpkg-immutable" \
        "/etc/dpkg/dpkg.cfg.d/99-immutable"

    # Install dpkg hook — reinstalls our hooks after kernelstub/systemd-boot updates
    install -Dm644 "$HOOKS_SRC/immutable-hooks-apt-hook" \
        "/etc/apt/apt.conf.d/99-immutable-hooks"

    # Install reinstall script to protected location
    install -Dm755 "$HOOKS_SRC/immutable-hook-reinstall" \
        "/usr/lib/immutable/hooks/immutable-hook-reinstall"

    echo "  Installed kernelstub hooks"
fi

echo ""
echo "Done! Log out and back in for group changes to take effect."
echo "Then start the daemon: systemctl start immutable-daemon.socket"
