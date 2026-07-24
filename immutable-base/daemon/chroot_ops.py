"""Chroot filesystem mounting and unmounting."""
import os
import shutil
import subprocess
import logging
from pathlib import Path
from typing import Dict, Any

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
        data_mounts = []

        def _bind(src, dst):
            try:
                subprocess.run(
                    ["mount", "--bind", src, dst],
                    check=True, capture_output=True,
                )
                mounts_done.append(dst)
                return True
            except subprocess.CalledProcessError as e:
                log.debug("Mount failed: %s -> %s: %s", src, dst, e)
                return False

        def _mkdir_p(path):
            """mkdir -p that handles existing files and read-only filesystems."""
            try:
                os.makedirs(path, exist_ok=True)
            except (FileExistsError, OSError):
                pass

        # API filesystems
        _mkdir_p(f"{root}/dev")
        _bind("/dev", f"{root}/dev")
        _mkdir_p(f"{root}/dev/pts")
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

        # --- /run bind mount ---
        host_run_user = "/run/user/1000"
        log.debug("=== /run bind mount diagnostics ===")
        log.debug("Host %s exists=%s", host_run_user, os.path.exists(host_run_user))
        if os.path.exists(host_run_user):
            try:
                st = os.stat(host_run_user)
                log.debug("Host %s uid=%d gid=%d mode=%o", host_run_user, st.st_uid, st.st_gid, st.st_mode & 0o777)
                log.debug("Host %s contents: %s", host_run_user, os.listdir(host_run_user))
            except OSError as e:
                log.debug("Host %s stat failed: %s", host_run_user, e)
        log.debug("Host /run top-level: %s", sorted(os.listdir("/run")))

        overlay_run = f"{root}/run"
        if os.path.isdir(overlay_run):
            try:
                log.debug("Overlay /run before mount: %s", sorted(os.listdir(overlay_run)))
                overlay_run_user = f"{overlay_run}/user/1000"
                if os.path.exists(overlay_run_user):
                    st = os.stat(overlay_run_user)
                    log.debug("Overlay %s before mount: uid=%d gid=%d mode=%o",
                             overlay_run_user, st.st_uid, st.st_gid, st.st_mode & 0o777)
            except OSError as e:
                log.debug("Overlay /run inspection failed: %s", e)

        _mkdir_p(overlay_run)
        subprocess.run(
            ["mount", "--rbind", "/run", overlay_run],
            check=False, capture_output=True,
        )
        subprocess.run(
            ["mount", "--make-rslave", overlay_run],
            check=False, capture_output=True,
        )
        run_mounted = os.path.ismount(overlay_run)

        log.debug("After rbind: ismount=%s", run_mounted)
        try:
            log.debug("Overlay /run after mount: %s", sorted(os.listdir(overlay_run)))
            if os.path.exists(f"{overlay_run}/user/1000"):
                st = os.stat(f"{overlay_run}/user/1000")
                log.debug("Overlay /run/user/1000 after mount: uid=%d gid=%d mode=%o",
                         st.st_uid, st.st_gid, st.st_mode & 0o777)
                log.debug("Overlay /run/user/1000 contents: %s", os.listdir(f"{overlay_run}/user/1000"))
        except OSError as e:
            log.debug("Overlay /run after-mount inspection failed: %s", e)

        # --- /tmp bind mount ---
        _mkdir_p(f"{root}/tmp")
        _bind("/tmp", f"{root}/tmp")

        # User data mounts — skip for @base (read-only, mounts won't persist)
        base_ro = subprocess.run(
            ["btrfs", "property", "get", root, "ro"],
            capture_output=True, text=True,
        )
        is_readonly = "ro=true" in base_ro.stdout

        if not is_readonly and os.path.isdir(data_path):
            _mkdir_p(home_dir := f"{root}/home/{username}")

            for dir_name in DATA_DIRS:
                src = f"{data_path}/{dir_name}"
                dst = f"{home_dir}/{dir_name}"
                _mkdir_p(src)
                _mkdir_p(dst)
                if _bind(src, dst):
                    data_mounts.append(dst)

            for dotfile in DOTFILES:
                src = f"{data_path}/{dotfile}"
                dst = f"{home_dir}/{dotfile}"
                if not os.path.exists(src):
                    Path(src).touch()
                if os.path.exists(dst) and not os.path.isfile(dst):
                    # dst is a dir where we expect a file — remove it
                    try:
                        os.rmdir(dst)
                    except OSError:
                        pass
                if _bind(src, dst):
                    data_mounts.append(dst)

        # DNS resolution
        try:
            src_resolv = Path("/etc/resolv.conf").resolve()
            dst_resolv = Path(f"{root}/etc/resolv.conf").resolve()
            if src_resolv != dst_resolv:
                shutil.copy2("/etc/resolv.conf", f"{root}/etc/resolv.conf")
        except (OSError, shutil.Error) as e:
            log.debug("Failed to copy resolv.conf: %s", e)

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
                        ["umount", "-R", mount_point] if mount_point.endswith(("/dev", "/sys", "/run"))
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
