"""Chroot filesystem mounting and unmounting."""
import os
import shutil
import subprocess
import logging
from pathlib import Path
from typing import List, Dict, Any, Optional

log = logging.getLogger("immutable-daemon")

DATA_DIRS = ["Documents", "Downloads", "Pictures", "Videos", "Music"]
DOTFILES = [".bash_history", ".profile", ".bashrc", ".gitconfig"]


class ChrootMount:
    """Manages chroot mount setup and teardown."""

    def __init__(self, pool: str = None, data_subvol: str = "@data"):
        self.pool = pool or os.environ.get("IMMUTABLE_POOL", "/pool")
        self.data_subvol = data_subvol

    def mount(self, root: str) -> Dict[str, Any]:
        """Set up all chroot mounts. Returns a context dict for teardown."""
        username = self._get_username()
        data_path = f"{self.pool}/{self.data_subvol}"
        mounts_done = []

        def _bind(src, dst):
            os.makedirs(dst, exist_ok=True)
            try:
                subprocess.run(
                    ["mount", "--bind", src, dst],
                    check=True, capture_output=True,
                )
                mounts_done.append(dst)
                return True
            except subprocess.CalledProcessError as e:
                log.warning("Mount failed: %s -> %s: %s", src, dst, e)
                return False

        # API filesystems
        _bind("/dev", f"{root}/dev")
        _bind("/dev/pts", f"{root}/dev/pts")

        subprocess.run(
            ["mount", "-t", "proc", "proc", f"{root}/proc"],
            check=False, capture_output=True,
        )
        if os.path.ismount(f"{root}/proc"):
            mounts_done.append(f"{root}/proc")

        subprocess.run(
            ["mount", "--rbind", "/sys", f"{root}/sys"],
            check=False, capture_output=True,
        )
        subprocess.run(
            ["mount", "--make-rslave", f"{root}/sys"],
            check=False, capture_output=True,
        )
        if os.path.ismount(f"{root}/sys"):
            mounts_done.append(f"{root}/sys")

        _bind("/run", f"{root}/run")
        _bind("/tmp", f"{root}/tmp")

        # User data mounts
        home_dir = f"{root}/home/{username}"
        data_mounts = []

        if os.path.isdir(data_path):
            os.makedirs(home_dir, exist_ok=True)
            for dir_name in DATA_DIRS:
                src = f"{data_path}/{dir_name}"
                dst = f"{home_dir}/{dir_name}"
                os.makedirs(src, exist_ok=True)
                os.makedirs(dst, exist_ok=True)
                if _bind(src, dst):
                    data_mounts.append(dst)

            for dotfile in DOTFILES:
                src = f"{data_path}/{dotfile}"
                dst = f"{home_dir}/{dotfile}"
                if not os.path.exists(src):
                    Path(src).touch()
                if _bind(src, dst):
                    data_mounts.append(dst)

        # DNS resolution
        try:
            shutil.copy2("/etc/resolv.conf", f"{root}/etc/resolv.conf")
        except (OSError, shutil.Error) as e:
            log.warning("Failed to copy resolv.conf: %s", e)

        return {
            "root": root,
            "username": username,
            "mounts_done": mounts_done,
            "data_mounts": data_mounts,
        }

    def unmount(self, root: str, ctx: Dict[str, Any]):
        """Tear down all chroot mounts."""
        all_mounts = list(reversed(ctx.get("data_mounts", []) +
                                   ctx.get("mounts_done", [])))

        for mount_point in all_mounts:
            if os.path.ismount(mount_point):
                try:
                    subprocess.run(
                        ["umount", "-R", mount_point] if mount_point.endswith(("/dev", "/sys"))
                        else ["umount", mount_point],
                        check=False, capture_output=True, timeout=10,
                    )
                except subprocess.TimeoutExpired:
                    log.warning("Unmount timed out: %s", mount_point)
                    try:
                        subprocess.run(
                            ["umount", "-l", mount_point],
                            check=False, capture_output=True,
                        )
                    except Exception:
                        pass

    def _get_username(self) -> str:
        """Read the configured username."""
        try:
            conf = Path("/etc/immutable.conf").read_text()
            for line in conf.splitlines():
                if line.startswith("USERNAME="):
                    return line.split("=", 1)[1].strip()
        except (FileNotFoundError, ValueError):
            pass

        for d in sorted(os.listdir("/home")):
            if os.path.isdir(f"/home/{d}") and d != "root":
                return d

        return "USERNAME"
