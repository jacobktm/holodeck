# Testing COSMIC Packages with Immutable Overlays

This document describes how to use the immutable Pop!_OS prototype to safely
test COSMIC package updates before committing them to your daily system.

COSMIC ships as dozens of small `cosmic-*` packages and is updated frequently.
Trying the latest build on a working daily driver is risky — a bad `apt
upgrade` can leave you without a usable session. With btrfs overlays you can:

- Test an update in isolation, in seconds
- Promote it to your boot system only if it works
- Roll back instantly if it doesn't

## Getting the code

```bash
git clone https://github.com/jacobktm/holodeck.git
cd holodeck
```

## Installing the system

The prototype installs an immutable Pop!_OS base onto its own disk. It
targets UEFI systems (systemd-boot); there is no BIOS/GRUB support.

Prerequisites — run from a Pop!_OS live USB or any Debian/Ubuntu-based system:

- a spare disk to erase (`--device /dev/sdX` — **destructive**)
- root access (the build and install scripts must run with `sudo`)
- tools: `debootstrap`, `zstd`, `btrfs-progs`, `parted`, `dosfstools`,
  `cryptsetup` (only needed if you enable encryption)

```bash
sudo apt install debootstrap zstd btrfs-progs parted dosfstools cryptsetup
```

### 1. Build the base rootfs

```bash
sudo ./build-base.sh
```

Downloads and configures a minimal Pop!_OS (`noble`) rootfs, installs the
immutable hooks and CLI, and packages it to
`/tmp/immutable-build/base-rootfs.tar.zst`. Set `BUILD_DIR` to relocate the
output; on a live ISO where `/tmp` is missing, the script automatically falls
back to a writable location. If Rust with the `x86_64-unknown-linux-musl`
target is available, the static `immutable` CLI is built into the rootfs;
otherwise the script warns and continues.

### 2. Build the immutable CLI

```bash
./build-rust.sh
```

Compiles the Rust `immutable` CLI and copies it to `./immutable` at the repo
root. **`install.sh` requires this binary** and will refuse to run without it.
The CLI built here is what `install.sh` copies into `@data` and `@base`; the
static-musl build from `build-base.sh` is only a fallback inside the rootfs.

### 3. Install to disk

```bash
sudo ./install.sh --device /dev/sdX
```

Creates a GPT layout (ESP, encrypted swap, BTRFS), extracts the rootfs into
`@base`, snapshots it into `@overlay-init` and `@overlay-recovery`, creates
`@data`, installs systemd-boot, and prompts for your username and password
(override with `--username`/`--password`). It also asks whether to encrypt
the root filesystem with LUKS — answer no by default, or pass `--encrypt` for
full-disk encryption (root + swap; the ESP stays unencrypted). It also
accepts `--swap SIZE` and `--rootfs PATH`. **This erases the target disk.**

### 4. First boot

Boot into the installed system. You land in `@overlay-init`; verify the
pieces are in place:

```bash
immutable list     # @overlay-init and @overlay-recovery present
immutable status
```

If the install doesn't boot (missing firmware modules, etc.), boot from
`@overlay-recovery` via systemd-boot and re-run
`sudo immutable update-initramfs`.

From here, follow the core loop below to snapshot and test COSMIC packages.

## How overlays map to testing

```
@base                  # your known-good, read-only foundation
@overlay-cosmic-test   # where you apply candidate COSMIC updates
@overlay-init          # your current boot overlay (what you run today)
@overlay-recovery      # locked fallback snapshot of @base
@data                  # shared user files (Documents, Downloads, ...)
```

An overlay is a writable snapshot of `@base`. Changes you make inside it live
only in that overlay. Your boot entry points at a specific overlay, so
switching which one boots is a one-word command plus a reboot.

## The core loop

```bash
# 1. Snapshot a fresh testing environment
immutable create cosmic-test

# 2. Enter it — a shell in the overlay with working sudo (PTY relayed)
immutable shell cosmic-test

# 3. Pull in the COSMIC updates you want to evaluate
sudo apt update
sudo apt upgrade

# 4. Leave the shell
exit

# 5. Make the overlay your boot target and reboot
immutable switch cosmic-test
reboot

# 6. Use COSMIC normally. If it's good, you're done — the overlay is now
#    your system. If it's bad, roll back (next section).
```

## Rollback

### Manual rollback

From any working state, switch back to a known-good overlay:

```bash
immutable switch @overlay-init
reboot
```

### Automatic rollback

If a boot fails before the system reaches the login manager, the boot counter
is not reset. After **3 consecutive failed boots**, the boot entry
automatically reverts:

1. Failed overlay → `@overlay-init`
2. Failed `@overlay-init` → `@overlay-recovery`

A `SYSTEM ROLLBACK` message is written to `@data` and shown by
`immutable status`. After rolling back, you can keep the broken overlay around
for debugging or delete it:

```bash
immutable list                 # see what's there
immutable status               # rollback notice
immutable delete cosmic-test   # remove the broken overlay
```

### Start over from a clean slate

To discard all changes in a test overlay and re-snapshot from `@base`:

```bash
immutable reset cosmic-test
```

## Enabling COSMIC development packages

System76 publishes development builds on `apt.pop-os.org`. Inside your test
overlay shell:

```bash
sudo add-apt-repository "deb [arch=amd64] http://apt.pop-os.org/staging/master $(lsb_release -cs) main"
sudo apt update
sudo apt upgrade
```

Because the repo change is made inside the overlay, the staging repository
only affects that overlay. Your boot system's `/etc/apt` stays untouched.

## Side-by-side testing: PR build vs. released version

The shell forwards your display environment (`WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, `PULSE_SERVER`), so
any app you launch from inside an overlay talks to the live compositor and
appears as a normal window. You can therefore run the released version and a
PR build of the same app at the same time, on the same desktop, each from its
own overlay.

Setup:

```bash
# 1. Create an overlay dedicated to the PR
immutable create cosmic-files-pr

# 2. Build the PR branch inside that overlay (COSMIC is Rust)
immutable shell cosmic-files-pr
git clone https://github.com/pop-os/cosmic-files.git
cd cosmic-files
git checkout <pr-branch>
cargo build --release
exit
```

Testing, in two terminals:

```bash
# Terminal 1 — released version, from the booted overlay
immutable shell init
cosmic-files

# Terminal 2 — PR build, from its overlay
immutable shell cosmic-files-pr
./target/release/cosmic-files
```

Both apps appear on your live desktop side by side. `@overlay-init` is the
overlay you booted into, so it still carries the released packages — this is
why it's used for the released instance. The PR build lives only in its own
overlay, so anything it needs (including library upgrades) stays out of the
running system.

Notes and caveats:

- **App config is per-overlay.** Each overlay has its own `~/.config` and
  `~/.local`, so the released and PR instances use separate config state by
  default — the released one gets your daily settings (from init), the PR one
  gets whatever the PR overlay's home dir holds. If you want the PR build to
  start from identical settings, copy the relevant `cosmic-*` config into the
  PR overlay's home first.
- **Only one can own the single-instance lock.** Some COSMIC apps are
  single-instance; the second launch may just focus the first. A separate
  `XDG_RUNTIME_DIR`-scoped state directory usually resolves this, but if the
  app hard-requires exclusivity you may only be able to run one at a time.
- **Keep `@overlay-init` clean.** You're booted into it, so anything you
  install there affects the live system and future boots. Only run the
  released app from it; do all package work in the PR overlay.

## A/B testing two versions

Create one overlay per candidate version:

```bash
immutable create cosmic-candidate-A
immutable create cosmic-candidate-B
```

- Shell into A, apply the update, `immutable switch cosmic-candidate-A`,
  reboot, test.
- Shell into B, apply a different version, switch, reboot, test.

Both overlays see the same `@data` user files, so you can compare behavior
against identical documents and settings context. Configs under `~/.config`
and `~/.local` are per-overlay, so each candidate can carry its own COSMIC
settings.

## Testing individual packages

You don't have to upgrade everything. Target just the packages under test:

```bash
sudo apt install cosmic-files cosmic-settings
# or pin a specific version
apt-cache policy cosmic-files
```

If a single app misbehaves, you can often keep it working by installing a
previous version from the release repo instead of rolling back the whole
overlay:

```bash
sudo apt install cosmic-files/<pop-release>
```

## Notes and caveats

- **Kernel and initramfs updates** inside an overlay are handled by the
  immutable hooks: they replicate kernelstub's ESP operations into the
  overlay's own `/boot/efi` copy and keep it in sync with the real ESP. You
  don't need to do anything extra after a kernel upgrade.
- **NVIDIA / GPU options** (e.g. `nvidia-drm.modeset=1`) are read from
  kernelstub's config and merged into the boot entry automatically, so
  driver flags survive across overlays.
- **`sudo` inside `immutable shell`** prompts on your real terminal via the
  native PTY relay — no workarounds needed.
- **`@data` is shared, `~/.config` and `~/.local` are not.** Your documents
  persist across every overlay; per-app COSMIC settings do not. Deleting an
  overlay also deletes its app configs.
- **Keep a known-good overlay.** Create one before testing anything new and
  leave it alone; it's your manual rollback target.
- **The recovery overlay is read-only** and tracks `@base`. Rebuild it after
  installing base updates with `immutable reset-recovery`.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| System rolled back automatically | `immutable status` for the notice; switch back to a good overlay |
| Test overlay won't boot | Wait for auto-rollback or boot from `@overlay-init` in systemd-boot |
| PR and released app show different settings | Expected — `~/.config` is per-overlay; copy `cosmic-*` config into the PR overlay to start identical |
| Second instance won't launch | App is single-instance; scope a separate state dir or run one at a time |
| PR build needs a newer system library | Keep it in the PR overlay (isolated); avoid touching `@overlay-init` |
| Apt repo changed in overlay but not on boot system | Expected — repo config is per-overlay |
| Cosmic session config lost after switch | Overlays keep separate `~/.config`; re-apply settings in each overlay |
| Need a clean test env | `immutable reset <name>` |
