"""Command dispatch and implementations."""
import os
import re
import subprocess
from pathlib import Path
from typing import Dict, Any, Optional, Generator, List

from .btrfs_ops import BtrfsOps
from .boot_ops import BootOps
from .chroot_ops import ChrootMount


POOL = os.environ.get("IMMUTABLE_POOL", "/pool")
BASE_SUBVOL = "@base"
DATA_SUBVOL = "@data"
OVERLAY_PREFIX = "@overlay-"
RECOVERY_OVERLAY = "recovery"
IMMUTABLE_CONF = "/etc/immutable.conf"


class CommandHandler:
    """Dispatches incoming JSON commands to privileged operations."""

    def __init__(self):
        self.btrfs = BtrfsOps(POOL)
        self.boot = BootOps()
        self.chroot = ChrootMount()

    def execute(self, msg: Dict[str, Any]) -> Dict[str, Any]:
        """Execute a simple (non-streaming) command."""
        cmd = msg["cmd"]

        dispatch = {
            "list":            self._cmd_list,
            "status":          self._cmd_status,
            "create":          self._cmd_create,
            "delete":          self._cmd_delete,
            "reset":           self._cmd_reset,
            "switch":          self._cmd_switch,
            "lock":            self._cmd_lock,
            "unlock":          self._cmd_unlock,
            "reset-recovery":  self._cmd_reset_recovery,
            "healthcheck":     self._cmd_healthcheck,
            "boot-ok":         self._cmd_boot_ok,
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
        """Set up chroot mounts for a PTY session."""
        overlay = msg.get("overlay")
        if not overlay:
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

        src = f"{POOL}/{BASE_SUBVOL}"
        if not os.path.isdir(src):
            return {"ok": False, "error": f"Base system not found at {src}"}

        self.btrfs.snapshot(src, dst)
        return {
            "ok": True,
            "output": (
                f"Creating overlay '{name}' from @base...\n"
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

        current = self.boot.get_active_subvol()
        if current == f"@overlay-{name}":
            return {"ok": False, "error": "Cannot delete active boot overlay. Switch to another first."}

        self.btrfs.delete_subvol(dst)
        return {"ok": True, "output": f"Deleted overlay '{name}'."}

    def _cmd_reset(self, msg):
        name = msg.get("name")
        if not name:
            return {"ok": False, "error": "Missing 'name' field"}

        self._ensure_pool()
        dst = f"{POOL}/{OVERLAY_PREFIX}{name}"
        if not os.path.isdir(dst):
            return {"ok": False, "error": f"Overlay '{name}' not found"}

        src = f"{POOL}/{BASE_SUBVOL}"
        self.btrfs.delete_subvol(dst)
        self.btrfs.snapshot(src, dst)
        return {"ok": True, "output": f"Resetting overlay '{name}' from @base...\nReset complete: {dst}"}

    def _cmd_switch(self, msg):
        name = msg.get("name")
        if not name:
            return {"ok": False, "error": "Missing 'name' field"}

        self._ensure_pool()
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
        return {"ok": True, "output": f"Recovery overlay created at {recovery}"}

    def _cmd_healthcheck(self, msg):
        healthy = True
        issues = []

        test = Path("/.healthcheck-test")
        try:
            test.touch()
            test.unlink()
        except OSError:
            healthy = False
            issues.append("Root filesystem not writable")

        result = subprocess.run(
            ["systemctl", "is-system-running"],
            capture_output=True, text=True, timeout=5,
        )
        state = result.stdout.strip()
        if state == "maintenance":
            healthy = False
            issues.append("Systemd in maintenance mode")

        status = "PASS" if healthy else "FAIL"
        msg_text = f"Boot healthcheck: {status}"
        if issues:
            msg_text += "\n" + "\n".join(f"  - {i}" for i in issues)

        return {"ok": healthy, "output": msg_text}

    def _cmd_boot_ok(self, msg):
        self._ensure_pool()
        data = f"{POOL}/{DATA_SUBVOL}"
        os.makedirs(data, exist_ok=True)
        Path(f"{data}/boot-ok").write_text("1")
        Path(f"{data}/boot-counter").write_text("0")
        return {"ok": True, "output": "Boot marked as healthy."}

    def _exec_in_chroot(self, root, args, env, mount_ctx):
        """Execute a command inside the chroot, streaming stdout/stderr."""
        username = self.chroot._get_username()
        cmd = ["chroot", root, "su", "-", username, "-c"]

        if len(args) == 1:
            cmd.append(args[0])
        else:
            quoted = " ".join(repr(a) for a in args)
            cmd.append(quoted)

        full_env = os.environ.copy()
        full_env["HOME"] = f"/home/{username}"
        full_env["USER"] = username
        full_env["TERM"] = env.get("TERM", os.environ.get("TERM", "xterm-256color"))
        full_env.update({k: v for k, v in env.items() if k not in ("HOME", "USER")})

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=full_env,
            preexec_fn=os.setsid,
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
