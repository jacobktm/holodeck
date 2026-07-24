# Immutable Pop!_OS Prototype

An immutable Pop!_OS base with BTRFS overlay management for testing different package versions.

## Architecture

```
/dev/sda2 (BTRFS)
├── @base          # Read-only base (immutable)
├── @overlay-0     # Writable overlay for testing v1
├── @overlay-1     # Writable overlay for testing v2
├── @data          # User data (Documents, Downloads, etc.)
├── @snapshots     # Snapshot storage
└── subvolid=5     # Top-level for management
```

## Quick Start

### 1. Build the base rootfs

```bash
sudo ./build-base.sh
```

This creates a compressed rootfs tarball at `/tmp/immutable-build/base-rootfs.tar.zst`.

### 2. Install to disk

```bash
sudo ./install.sh --device /dev/sdX
```

**WARNING: This erases all data on the target disk.**

### 3. Boot and use

After rebooting into the new system:

```bash
# Show overlays
immutable list

# Create an overlay for testing
immutable create cosmic-files-v1

# Enter the overlay
immutable shell cosmic-files-v1

# Inside the overlay, install your packages
apt update
apt install cosmic-files

# Test your packages
cosmic-files /path/to/files

# If it works, set as boot overlay
immutable switch cosmic-files-v1
reboot

# If not, delete and try another
immutable delete cosmic-files-v1
```

## Commands

| Command | Description |
|---------|-------------|
| `immutable create <name>` | Snapshot @base → new overlay |
| `immutable shell <name>` | Chroot into overlay |
| `immutable run <name> <cmd>` | Run command in overlay |
| `immutable list` | Show all overlays |
| `immutable switch <name>` | Set default boot overlay (needs reboot) |
| `immutable reset <name>` | Wipe overlay, re-snapshot from @base |
| `immutable delete <name>` | Remove an overlay |
| `immutable status` | Show current status |
| `immutable lock` | Make @base read-only |
| `immutable unlock` | Make @base writable |
| `immutable recovery` | Switch to recovery overlay (needs reboot) |
| `immutable reset-recovery` | Recreate recovery from @base (read-only) |
| `immutable clean-boot` | Remove stale boot entries from the ESP |

## Testing Workflow

1. **Create overlay** — instant snapshot of base
2. **Chroot in** — install/test your packages
3. **Decide** — works? `immutable switch` + reboot. Doesn't? `immutable delete`

No rebuilding, no waiting. Create → test → decide.

## User Data

The `@data` partition holds Documents, Downloads, Pictures, etc. It's bind-mounted into whichever overlay is active, so your files are always available regardless of which overlay you're testing.

## How It Works

- **@base** is a read-only BTRFS subvolume containing the base Pop!_OS system
- **Overlays** are writable snapshots of @base
- Each overlay has its own `/usr`, `/etc`, `/home/.config`, `/home/.local`
- **@data** is shared across all overlays (user files)
- **Switching** updates the boot entry to use a different overlay
