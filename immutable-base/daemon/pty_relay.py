"""PTY relay for interactive shell sessions."""
import os
import pty
import select
import shlex
import signal
import struct
import fcntl
import termios
import shutil
import logging
from typing import Dict, Any

log = logging.getLogger("immutable-daemon")

CHROOT_BIN = shutil.which("chroot") or "/usr/sbin/chroot"
RESIZE_PREFIX = b"\x1b[8;"
RESIZE_SUFFIX = b"t"


class PtyRelay:
    """Manages a PTY session between a socket client and a chroot shell."""

    def __init__(self, sock, mount_ctx: Dict[str, Any], overlay_name: str, args: list):
        self.sock = sock
        self.mount_ctx = mount_ctx
        self.root = mount_ctx["root"]
        self.username = mount_ctx["username"]
        self.overlay_name = overlay_name
        self.args = args
        self.child_pid = None
        self.master_fd = None

    def run(self) -> int:
        """Execute the shell session. Returns the shell's exit code."""
        master_fd, slave_fd = pty.openpty()

        try:
            winsize = struct.pack("HHHH", 24, 80, 0, 0)
            fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsize)
        except Exception:
            pass

        pid = os.fork()
        if pid == 0:
            # Child process
            os.close(master_fd)
            os.setsid()
            fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

            os.dup2(slave_fd, 0)
            os.dup2(slave_fd, 1)
            os.dup2(slave_fd, 2)
            if slave_fd > 2:
                os.close(slave_fd)

            exec_cmd = [
                CHROOT_BIN, self.root,
                "su", self.username,
                "-c", shlex.join(self.args),
            ] if self.args else [
                CHROOT_BIN, self.root,
                "su", self.username,
            ]

            env = {
                "HOME": f"/home/{self.username}",
                "USER": self.username,
                "LOGNAME": self.username,
                "SHELL": "/bin/bash",
                "TERM": os.environ.get("TERM", "xterm-256color"),
                "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "LANG": "en_US.UTF-8",
            }

            os.execve(CHROOT_BIN, exec_cmd, env)
            os._exit(127)

        # Parent process (daemon)
        os.close(slave_fd)
        self.child_pid = pid
        self.master_fd = master_fd

        try:
            exit_code = self._relay_loop()
        finally:
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            try:
                os.close(master_fd)
            except OSError:
                pass

        return exit_code

    def _relay_loop(self) -> int:
        """Relay bytes between socket and PTY master."""
        self.sock.setblocking(False)
        os.set_blocking(self.master_fd, False)

        while True:
            pid, status = os.waitpid(self.child_pid, os.WNOHANG)
            if pid != 0:
                self._drain_pty()
                if os.WIFEXITED(status):
                    return os.WEXITSTATUS(status)
                elif os.WIFSIGNALED(status):
                    return 128 + os.WTERMSIG(status)
                return 1

            try:
                readable, _, _ = select.select(
                    [self.sock, self.master_fd], [], [], 0.1
                )
            except (ValueError, OSError):
                break

            for fd in readable:
                try:
                    if fd == self.sock:
                        data = self.sock.recv(4096)
                        if not data:
                            try:
                                os.kill(-self.child_pid, signal.SIGHUP)
                            except ProcessLookupError:
                                pass
                            return 0

                        data = self._process_relay_data(data)
                        if data:
                            os.write(self.master_fd, data)

                    elif fd == self.master_fd:
                        data = os.read(self.master_fd, 4096)
                        if not data:
                            continue
                        self._send_all(data)

                except (OSError, BrokenPipeError):
                    return 1

        return 1

    def _process_relay_data(self, data: bytes) -> bytes:
        """Intercept resize escapes from the client."""
        if not data or b"\x1b" not in data:
            return data

        result = bytearray()
        i = 0
        while i < len(data):
            if (data[i:i+3] == b"\x1b[8" and
                RESIZE_PREFIX in data[i:i+20]):
                end = data.find(b"t", i + 3)
                if end != -1 and end - i < 30:
                    seq = data[i+3:end]
                    parts = seq.split(b";")
                    if len(parts) == 3:
                        try:
                            rows = int(parts[1])
                            cols = int(parts[2])
                            winsize = struct.pack("HHHH", rows, cols, 0, 0)
                            fcntl.ioctl(
                                self.master_fd,
                                termios.TIOCSWINSZ,
                                winsize,
                            )
                            log.debug("PTY resize: %dx%d", cols, rows)
                        except (ValueError, OSError) as e:
                            log.warning("Resize failed: %s", e)
                    i = end + 1
                    continue

            result.append(data[i])
            i += 1

        return bytes(result)

    def _drain_pty(self):
        """Drain any remaining data from the PTY master after child exit."""
        while True:
            try:
                readable, _, _ = select.select([self.master_fd], [], [], 0.1)
                if not readable:
                    break
                data = os.read(self.master_fd, 4096)
                if not data:
                    break
                self._send_all(data)
            except (OSError, ValueError):
                break

    def _send_all(self, data: bytes):
        """Send all data to the client socket."""
        total = 0
        while total < len(data):
            try:
                sent = self.sock.send(data[total:])
                total += sent
            except (BrokenPipeError, OSError):
                break
