"""Command dispatch and implementations."""
import os
import re
import select
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Dict, Any, Optional, Generator, List

from btrfs_ops import BtrfsOps
from boot_ops import BootOps
from chroot_ops import ChrootMount


POOL = os.environ.get("IMMUTABLE_POOL", "/pool")
BASE_SUBVOL = "@base"
DATA_SUBVOL = "@data"
OVERLAY_PREFIX = "@overlay-"
RECOVERY_OVERLAY = "recovery"
INIT_OVERLAY = "init"
IMMUTABLE_CONF = "/etc/immutable.conf"
CHROOT_BIN = shutil.which("chroot") or "/usr/sbin/chroot"

# System overlays that must never be deleted or reset
SYSTEM_OVERLAYS = frozenset({INIT_OVERLAY, RECOVERY_OVERLAY})

# Commands that require password authentication
AUTH_REQUIRED = {"unlock", "switch"}

# Commands allowed on @base without authentication (read-only inspection).
# When @base is locked (btrfs ro=true), even these can't write anything.
# apt/dpkg excluded — they modify state even on read-only roots.
READONLY_CMDS = {
    # File inspection
    "ls", "cat", "head", "tail", "wc", "find", "grep", "egrep", "fgrep",
    "less", "more", "file", "stat", "du", "df", "tree",
    # Command lookup
    "which", "type", "command",
    # Conditional checks
    "test", "[",
    # Checksums and metadata
    "sha256sum", "md5sum", "sha1sum", "shasum",
    # System info
    "uname", "hostname", "id", "whoami", "who", "w",
    # Output
    "echo", "printf",
    # Environment
    "env", "printenv",
    # Path manipulation
    "readlink", "realpath", "basename", "dirname",
    # Text processing (read-only transforms)
    "sort", "uniq", "cut", "tr", "sed", "awk", "column",
    # Other
    "date", "cal", "true", "false",
}


def _is_readonly_cmd(args: list) -> bool:
    """Check if a command args list is a whitelisted read-only command."""
    if not args:
        return False
    # Get the actual command name (last component of path)
    cmd_name = os.path.basename(args[0])
    return cmd_name in READONLY_CMDS


def verify_password(username: str, password: str) -> bool:
    """Verify a user's password via PAM (su)."""
    try:
        result = subprocess.run(
            ["su", "-c", "true", username],
            input=password.encode(),
            capture_output=True,
            timeout=5,
        )
        return result.returncode == 0
    except Exception:
        return False


class CommandHandler:
    """Dispatches incoming JSON commands to privileged operations."""

    def __init__(self):
        self.btrfs = BtrfsOps(POOL)
        self.boot = BootOps()
        self.chroot = ChrootMount()

    def execute(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        """Execute a simple (non-streaming) command."""
        cmd = msg["cmd"]

        # Check if this command needs authentication
        if cmd in AUTH_REQUIRED:
            password = msg.get("password")
            if not password:
                return {"ok": False, "error": "Password required", "auth_required": True}
            username = self.chroot._get_username()
            if not verify_password(username, password):
                return {"ok": False, "error": "Authentication failed"}

        dispatch = {
            "list":            self._cmd_list,
            "list-names":      self._cmd_list_names,
            "status":          self._cmd_status,
            "create":          self._cmd_create,
            "delete":          self._cmd_delete,
            "reset":           self._cmd_reset,
            "switch":          self._cmd_switch,
            "lock":            self._cmd_lock,
            "unlock":          self._cmd_unlock,
            "reset-recovery":  self._cmd_reset_recovery,
            "clean-boot":      self._cmd_clean_boot,
            "update-initramfs": self._cmd_update_initramfs,
        }

        handler = dispatch.get(cmd)
        if handler is None:
            return {"ok": False, "error": f"Unknown command: {cmd}"}

        try:
            return handler(msg)
        except Exception as e:
            return {"ok": False, "error": str(e)}

    def execute_run(self, msg: Dict[str, Any]) -> Generator[Dict[str, Any], None, None]:
        """Execute a streaming 'run' command. Yields event dicts."""
        overlay = msg.get("overlay")
        args = msg.get("args", [])
        env = msg.get("env", {})

        if not overlay:
            yield {"ok": False, "error": "Missing 'overlay' field"}
            return
        if not args:
            yield {"ok": False, "error": "Missing 'args' field"}
            return

        # @base: require auth for non-whitelisted (potentially mutating) commands
        if overlay == "@base" and not _is_readonly_cmd(args):
            password = msg.get("password")
            if not password:
                yield {"ok": False, "error": "Password required for @base write operations", "auth_required": True}
                return
            username = self.chroot._get_username()
            if not verify_password(username, password):
                yield {"ok": False, "error": "Authentication failed"}
                return

        root = self._resolve_overlay_path(overlay)
        if root is None:
            yield {"ok": False, "error": f"Overlay '{overlay}' not found"}
            return

        mount_ctx = self.chroot.mount(root)
        try:
            yield from self._exec_in_chroot(root, args, env, mount_ctx)
        finally:
            self.chroot.unmount(root, mount_ctx)

    def setup_chroot(self, msg: Dict[str, Any]) -> Optional[Any]:
        """Set up chroot mounts for a PTY session.
        Returns mount context dict, or None on failure.
        Sets self._last_auth_required = True if auth was needed but missing."""
        self._last_auth_required = False
        overlay = msg.get("overlay")
        if not overlay:
            return None

        # All interactive shells require auth — any overlay has a writable
        # ESP and kernelstub will run without further prompts.
        password = msg.get("password")
        if not password:
            self._last_auth_required = True
            return None
        username = self.chroot._get_username()
        if not verify_password(username, password):
            return None

        root = self._resolve_overlay_path(overlay)
        if root is None:
            return None

        return self.chroot.mount(root)

    def teardown_chroot(self, mount_ctx):
        """Clean up chroot mounts."""
        if mount_ctx:
            self.chroot.unmount(mount_ctx["root"], mount_ctx)

    def _resolve_overlay_path(self, name: str) -> Optional[str]:
        """Resolve an overlay name to its filesystem path."""
        self._ensure_pool()
        if name == "@base":
            return f"{POOL}/{BASE_SUBVOL}"
        elif name == "@data":
            return f"{POOL}/{DATA_SUBVOL}"
        else:
            path = f"{POOL}/{OVERLAY_PREFIX}{name}"
            return path if os.path.isdir(path) else None

    def _ensure_pool(self):
        """Ensure /pool is mounted."""
        if not os.path.ismount(POOL):
            self.btrfs.mount_pool()

    def get_running_subvol(self) -> Optional[str]:
        """Detect the currently running root subvolume from /proc/mounts."""
        try:
            with open("/proc/mounts") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 4 and parts[1] == "/":
                        for opt in parts[3].split(","):
                            if opt.startswith("subvol="):
                                return opt.split("=", 1)[1]
        except (FileNotFoundError, OSError):
            pass
        return None

    def _revert_boot_to_init(self):
        """Revert the boot entry to @overlay-init."""
        try:
            self.boot.set_active_overlay(INIT_OVERLAY)
        except Exception:
            pass

    def _cmd_list(self, msg):
        self._ensure_pool()
        lines = ["Overlays:", ""]

        base = f"{POOL}/{BASE_SUBVOL}"
        if os.path.isdir(base):
            ro = self.btrfs.get_property(base, "ro")
            lines.append(f"  @base (read-only: {ro}) -- {base}")

        count = 0
        for path in self.btrfs.list_subvolumes(POOL):
            basename = os.path.basename(path)
            if basename.startswith(OVERLAY_PREFIX):
                name = basename[len(OVERLAY_PREFIX):]
                full = f"{POOL}/{path}"
                size = self._get_size(full)
                lines.append(f"  {name} ({size}) -- {full}")
                count += 1

        if count == 0:
            lines.append("  (none)")

        data = f"{POOL}/{DATA_SUBVOL}"
        if os.path.isdir(data):
            lines.append("")
            lines.append(f"  @data -- {data}")

        lines.append("")
        lines.extend(self.boot.show_config())

        return {"ok": True, "output": "\n".join(lines)}

    def _cmd_list_names(self, msg):
        """Return overlay names, one per line. Used by shell completions."""
        self._ensure_pool()
        names = []
        for path in self.btrfs.list_subvolumes(POOL):
            basename = os.path.basename(path)
            if basename.startswith(OVERLAY_PREFIX):
                names.append(basename[len(OVERLAY_PREFIX):])
        names.append("@base")
        names.append("@data")
        return {"ok": True, "output": "\n".join(names)}

    def _cmd_status(self, msg):
        self._ensure_pool()
        lines = ["=== Immutable Status ===", ""]
        lines.extend(self.boot.show_config())
        lines.append("")
        lines.append("=== Subvolumes ===")
        for sv in self.btrfs.list_subvolumes(POOL):
            lines.append(f"  {sv}")
        return {"ok": True, "output": "\n".join(lines)}

    def _cmd_create(self, msg):
        name = msg.get("name")
        if not name:
            return {"ok": False, "error": "Missing 'name' field"}

        self._ensure_pool()
        dst = f"{POOL}/{OVERLAY_PREFIX}{name}"
        if os.path.isdir(dst):
            return {"ok": False, "error": f"Overlay '{name}' already exists"}

        # Resolve source: explicit --from, active boot overlay, or @base fallback
        source = msg.get("source")
        if source:
            if source == "@base":
                src = f"{POOL}/{BASE_SUBVOL}"
            elif source.startswith("@overlay-"):
                src = f"{POOL}/{source}"
            else:
                src = f"{POOL}/{OVERLAY_PREFIX}{source}"
            source_label = source
        else:
            active = self.boot.get_active_subvol()
            src = f"{POOL}/{active}" if active else f"{POOL}/{BASE_SUBVOL}"
            source_label = active or "@base"

        if not os.path.isdir(src):
            return {"ok": False, "error": f"Source system not found at {src}"}

        self.btrfs.snapshot(src, dst)
        return {
            "ok": True,
            "output": (
                f"Creating overlay '{name}' from {source_label}...\n"
                f"Created: {dst}\n\n"
                f"Next steps:\n"
                f"  immutable shell {name}      # enter overlay\n"
                f"  immutable switch {name}     # set as boot default (needs reboot)"
            ),
        }

    def _cmd_delete(self, msg):
        name = msg.get("name")
        if not name:
            return {"ok": False, "error": "Missing 'name' field"}

        self._ensure_pool()
        dst = f"{POOL}/{OVERLAY_PREFIX}{name}"
        if not os.path.isdir(dst):
            return {"ok": False, "error": f"Overlay '{name}' not found"}

        if name == RECOVERY_OVERLAY:
            return {"ok": False, "error": "Recovery overlay cannot be deleted. It is the immutable safety net."}

        if name == INIT_OVERLAY:
            return {"ok": False, "error": "Init overlay cannot be deleted. Use 'immutable reset init' to restore it from recovery."}

        running = self.get_running_subvol()
        if running == f"@overlay-{name}":
            return {"ok": False, "error": "Cannot delete the currently running overlay. Switch to another first and reboot."}

        boot_subvol = self.boot.get_active_subvol()
        boot_reverted = False
        if boot_subvol == f"@overlay-{name}":
            self._revert_boot_to_init()
            boot_reverted = True

        self.btrfs.delete_subvol(dst)

        output = f"Deleted overlay '{name}'."
        if boot_reverted:
            output += "\nBoot entry was set to this overlay — reverted to @overlay-init."
        return {"ok": True, "output": output}

    def _cmd_reset(self, msg):
        name = msg.get("name")
        if not name:
            return {"ok": False, "error": "Missing 'name' field"}

        self._ensure_pool()
        dst = f"{POOL}/{OVERLAY_PREFIX}{name}"
        if not os.path.isdir(dst):
            return {"ok": False, "error": f"Overlay '{name}' not found"}

        if name == RECOVERY_OVERLAY:
            return {"ok": False, "error": "Cannot reset recovery directly. Use 'immutable reset-recovery' to recreate it from @base."}

        running = self.get_running_subvol()
        if running == f"@overlay-{name}":
            return {"ok": False, "error": "Cannot reset the currently running overlay. Switch to another first and reboot."}

        if name == INIT_OVERLAY:
            src = f"{POOL}/{OVERLAY_PREFIX}{RECOVERY_OVERLAY}"
            if not os.path.isdir(src):
                return {"ok": False, "error": "Recovery overlay not found — cannot reset init."}
            self.btrfs.delete_subvol(dst)
            self.btrfs.snapshot(src, dst)
            return {"ok": True, "output": f"Resetting init overlay from recovery...\nReset complete: {dst}"}

        active = self.boot.get_active_subvol()
        src = f"{POOL}/{active}" if active else f"{POOL}/{BASE_SUBVOL}"
        self.btrfs.delete_subvol(dst)
        self.btrfs.snapshot(src, dst)
        return {"ok": True, "output": f"Resetting overlay '{name}' from {active or '@base'}...\nReset complete: {dst}"}

    def _cmd_switch(self, msg):
        name = msg.get("name")
        if not name:
            return {"ok": False, "error": "Missing 'name' field"}

        self._ensure_pool()

        # Sync current boot overlay's ESP to the real ESP before switching
        current = self.boot.get_active_subvol()
        if current:
            current_root = f"{POOL}/{current}"
            if os.path.isdir(current_root):
                self.chroot.sync_esp(current_root)

        dst = f"{POOL}/{OVERLAY_PREFIX}{name}"
        if not os.path.isdir(dst):
            return {"ok": False, "error": f"Overlay '{name}' not found"}

        self.boot.set_active_overlay(name)
        return {"ok": True, "output": f"Boot entry updated to: @overlay-{name}\nReboot to activate."}

    def _cmd_lock(self, msg):
        self._ensure_pool()
        base = f"{POOL}/{BASE_SUBVOL}"
        if not os.path.isdir(base):
            return {"ok": False, "error": "Base system not found"}
        self.btrfs.set_property(base, "ro", "true")
        return {"ok": True, "output": "Making @base read-only...\n@base is now read-only. Use 'immutable unlock' when done."}

    def _cmd_unlock(self, msg):
        self._ensure_pool()
        base = f"{POOL}/{BASE_SUBVOL}"
        if not os.path.isdir(base):
            return {"ok": False, "error": "Base system not found"}
        self.btrfs.set_property(base, "ro", "false")
        return {"ok": True, "output": "Making @base writable...\n@base is now writable. Run apt update/upgrade as needed.\nUse 'immutable lock' when done."}

    def _cmd_reset_recovery(self, msg):
        self._ensure_pool()
        recovery = f"{POOL}/{OVERLAY_PREFIX}{RECOVERY_OVERLAY}"
        src = f"{POOL}/{BASE_SUBVOL}"
        if os.path.isdir(recovery):
            self.btrfs.delete_subvol(recovery)
        self.btrfs.snapshot(src, recovery)
        self.btrfs.set_property(recovery, "ro", "true")
        return {"ok": True, "output": f"Recovery overlay recreated from @base (read-only)\n{recovery}"}

    def _cmd_clean_boot(self, msg):
        """Remove stale boot entries whose kernel files no longer exist on the ESP."""
        esp = "/boot/efi"
        entries_dir = f"{esp}/loader/entries"
        if not os.path.isdir(entries_dir):
            return {"ok": False, "error": f"Boot entries directory not found: {entries_dir}"}

        # Entries managed by the immutable system — never delete these
        protected = {"immutable.conf", "recovery.conf", "previous.conf"}

        removed = []
        kept = []
        for entry in sorted(Path(entries_dir).glob("*.conf")):
            name = entry.name
            if name in protected:
                kept.append(name)
                continue

            # Check if the kernel referenced by this entry exists on the ESP
            content = entry.read_text()
            linux_match = re.search(r"^linux\s+(\S+)", content, re.MULTILINE)
            if not linux_match:
                kept.append(name)
                continue

            kernel_path = f"{esp}/{linux_match.group(1)}"
            if not os.path.isfile(kernel_path):
                entry.unlink()
                removed.append(name)
            else:
                kept.append(name)

        lines = []
        if removed:
            lines.append(f"Removed {len(removed)} stale boot entry/entries:")
            for r in removed:
                lines.append(f"  - {r}")
        else:
            lines.append("No stale boot entries found.")

        if kept:
            lines.append(f"\nKept {len(kept)} active entry/entries:")
            for k in kept:
                lines.append(f"  + {k}")

        return {"ok": True, "output": "\n".join(lines)}

    def _cmd_update_initramfs(self, msg):
        """Run update-initramfs in the current boot overlay and copy to ESP.

        Only operates on the active boot overlay. All arguments are passed
        through to update-initramfs (e.g. -k6.8.0-40-generic, -c, -u).
        """
        import re as _re
        import shutil as _shutil
        import subprocess

        args = msg.get("args", [])

        self._ensure_pool()

        boot_subvol = self.boot.get_active_subvol()
        if not boot_subvol:
            return {"ok": False, "error": "No boot overlay configured"}

        root = f"{POOL}/{boot_subvol}"
        if not os.path.isdir(root):
            return {"ok": False, "error": f"Boot overlay not found: {boot_subvol}"}

        mount_ctx = self.chroot.mount(root)
        try:
            # Run update-initramfs inside the chroot with passthrough args
            result = subprocess.run(
                ["chroot", root, "/usr/sbin/update-initramfs"] + args,
                capture_output=True, text=True, timeout=120,
            )
            if result.returncode != 0:
                return {"ok": False, "error": f"update-initramfs failed:\n{result.stderr}"}

            # Find the latest kernel in the overlay's /boot to copy to ESP
            boot_dir = f"{root}/boot"
            kernels = sorted(
                [f for f in os.listdir(boot_dir) if f.startswith("vmlinuz-") and not os.path.islink(os.path.join(boot_dir, f))],
            ) if os.path.isdir(boot_dir) else []
            if not kernels:
                return {"ok": False, "error": f"No kernels found in {boot_dir}"}

            latest = kernels[-1]
            version = latest.removeprefix("vmlinuz-")
            kernel_path = f"{boot_dir}/{latest}"
            initrd_path = f"{boot_dir}/initrd.img-{version}"

            # Find ESP kernel directory inside the overlay's /boot/efi copy
            overlay_esp = f"{root}/boot/efi"
            esp_kernel_dir = None
            boot_entry = f"{overlay_esp}/loader/entries/immutable.conf"
            try:
                entry_content = Path(boot_entry).read_text()
                linux_match = _re.search(r"^linux\s+(\S+)", entry_content, _re.MULTILINE)
                if linux_match:
                    esp_kernel_dir = f"{overlay_esp}/{Path(linux_match.group(1)).parent}"
            except FileNotFoundError:
                pass

            if not esp_kernel_dir:
                efi_base = f"{overlay_esp}/EFI"
                if os.path.isdir(efi_base):
                    for d in os.listdir(efi_base):
                        if d.startswith("Pop_OS-"):
                            esp_kernel_dir = f"{efi_base}/{d}"
                            break

            if not esp_kernel_dir:
                return {"ok": False, "error": "Cannot find ESP kernel directory in overlay"}

            # Copy kernel and initrd to the overlay's ESP copy
            os.makedirs(esp_kernel_dir, exist_ok=True)
            _shutil.copy2(kernel_path, f"{esp_kernel_dir}/vmlinuz.efi")
            _shutil.copy2(initrd_path, f"{esp_kernel_dir}/initrd.img")
            _shutil.copy2(f"{esp_kernel_dir}/vmlinuz.efi", f"{esp_kernel_dir}/vmlinuz-previous.efi")
            _shutil.copy2(f"{esp_kernel_dir}/initrd.img", f"{esp_kernel_dir}/initrd.img-previous")

            # Sync overlay's ESP copy to the real ESP
            self.chroot.sync_esp(root)

            return {"ok": True, "output": (
                f"update-initramfs completed for {version}\n"
                f"Overlay: {boot_subvol}\n"
                f"ESP updated: {esp_kernel_dir}\n"
                f"Synced to real ESP"
            )}

        finally:
            self.chroot.unmount(root, mount_ctx)

    def _exec_in_chroot(self, root, args, env, mount_ctx):
        """Execute a command inside the chroot as the configured user, streaming stdout/stderr."""
        import pwd as _pwd
        username = self.chroot._get_username()
        pw = _pwd.getpwnam(username)

        # Build environment
        full_env = {
            "HOME": f"/home/{username}",
            "USER": username,
            "LOGNAME": username,
            "SHELL": "/bin/bash",
            "TERM": env.get("TERM", "xterm-256color"),
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "LANG": "en_US.UTF-8",
        }
        full_env.update({k: v for k, v in env.items() if k not in ("HOME", "USER")})

        # CWD: user's home inside the overlay (chroot preserves CWD)
        home_dir = f"{root}/home/{username}"
        cwd = home_dir if os.path.isdir(home_dir) else root

        # Exec user's login shell directly — no su wrapper.
        # preexec_fn drops privileges after fork, before exec.
        def _setup():
            os.chroot(root)
            # CWD is already the host-side home_dir; after chroot it becomes /home/user
            os.setgroups([pw.pw_gid])
            os.setgid(pw.pw_gid)
            os.setuid(pw.pw_uid)

        if args:
            cmd = ["/bin/bash", "--login", "-c", shlex.join(args)]
        else:
            cmd = ["/bin/bash", "--login"]

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=full_env,
            cwd=cwd,
            preexec_fn=_setup,
        )

        fds = {proc.stdout: "stdout", proc.stderr: "stderr"}
        remaining = set(fds.keys())

        while remaining:
            readable, _, _ = select.select(list(remaining), [], [], 0.1)
            for fd in readable:
                chunk = fd.read(4096)
                if chunk:
                    stream_name = fds[fd]
                    yield {"stream": stream_name, "data": chunk.decode("utf-8", errors="replace")}
                else:
                    remaining.discard(fd)

        proc.wait()
        yield {"type": "done", "exit_code": proc.returncode}

    def _get_size(self, path):
        """Get human-readable size of a directory."""
        result = subprocess.run(
            ["du", "-sh", path],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            return result.stdout.split()[0]
        return "unknown"
