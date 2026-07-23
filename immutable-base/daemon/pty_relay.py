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
import traceback
from typing import Dict, Any

log = logging.getLogger("immutable-daemon")

RESIZE_PREFIX = b"\x1b[8;"
RESIZE_SUFFIX = b"t"


class PtyRelay:
    """Manages a PTY session between a socket client and a chroot shell."""

    def __init__(self, sock, mount_ctx: Dict[str, Any], overlay_name: str, args: list, env: dict = None, norc: bool = False):
        self.sock = sock
        self.mount_ctx = mount_ctx
        self.root = mount_ctx["root"]
        self.username = mount_ctx["username"]
        self.overlay_name = overlay_name
        self.args = args
        self.env = env or {}
        self.norc = norc
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

        # Resolve the user's UID/GID for privilege drop
        import pwd
        pw = pwd.getpwnam(self.username)
        uid, gid = pw.pw_uid, pw.pw_gid

        env = {
            "HOME": f"/home/{self.username}",
            "USER": self.username,
            "LOGNAME": self.username,
            "SHELL": "/bin/bash",
            "TERM": "xterm-256color",
            "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "LANG": "en_US.UTF-8",
        }
        env.update(self.env)

        pid = os.fork()
        if pid == 0:
            # Child process
            try:
                os.close(master_fd)
                os.setsid()
                fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

                os.dup2(slave_fd, 0)
                os.dup2(slave_fd, 1)
                os.dup2(slave_fd, 2)
                if slave_fd > 2:
                    os.close(slave_fd)

                # Close all other inherited FDs (from daemon fork)
                for fd in range(3, 1024):
                    try:
                        os.close(fd)
                    except OSError:
                        pass

                # Chroot first (requires root), then drop privileges.
                os.chroot(self.root)
                os.chdir(f"/home/{self.username}")

                os.setgroups([gid])
                os.setgid(gid)
                os.setuid(uid)

                # Build shell args
                if self.norc:
                    shell_args = ["/bin/bash", "--norc", "--noprofile"]
                else:
                    shell_args = ["/bin/bash", "--login"]

                if self.args:
                    shell_args.extend(self.args)

                os.execve(shell_args[0], shell_args, env)
                os._exit(127)
            except Exception as e:
                # Write error to fd 2 (PTY slave) so parent sees it
                try:
                    os.write(2, f"\r\nPTY child setup FAILED: {e}\r\n".encode())
                except OSError:
                    pass
                os._exit(1)

        # Parent process (daemon)
        os.close(slave_fd)
        self.child_pid = pid
        self.master_fd = master_fd

        log.info("PTY session started: pid=%d root=%s user=%s", pid, self.root, self.username)

        try:
            exit_code = self._relay_loop()
        finally:
            try:
                _, status = os.waitpid(pid, os.WNOHANG)
                if os.WIFEXITED(status):
                    code = os.WEXITSTATUS(status)
                    log.info("PTY child exited: code=%d (0=clean exit, non-zero=error)", code)
                    if code != 0:
                        log.warning("Shell exited with error code %d — likely crash during .bashrc/.profile sourcing", code)
                elif os.WIFSIGNALED(status):
                    sig = os.WTERMSIG(status)
                    log.warning("PTY child killed by signal %d (%s)", sig, signal.Signals(sig).name)
            except ChildProcessError:
                log.warning("PTY child already reaped")
            try:
                os.close(master_fd)
            except OSError:
                pass

        return exit_code

    def _relay_loop(self) -> int:
        """Relay bytes between socket and PTY master using buffered writes."""
        self.sock.setblocking(False)
        os.set_blocking(self.master_fd, False)

        WRITE_HIGH_WATER = 256 * 1024  # Stop reading PTY when buf > 256KB
        write_buf = b""

        while True:
            try:
                pid, status = os.waitpid(self.child_pid, os.WNOHANG)
                if pid != 0:
                    self._drain_pty(write_buf)
                    if os.WIFEXITED(status):
                        return os.WEXITSTATUS(status)
                    elif os.WIFSIGNALED(status):
                        return 128 + os.WTERMSIG(status)
                    return 1
            except ChildProcessError:
                log.warning("PTY relay: child already reaped")
                return 1

            # Only monitor PTY for reading when write buffer is below threshold.
            # This creates backpressure: PTY buffer fills → bash blocks on write.
            read_fds = [self.sock]
            if len(write_buf) < WRITE_HIGH_WATER:
                read_fds.append(self.master_fd)

            write_fds = [self.sock] if write_buf else []

            try:
                readable, writable, _ = select.select(
                    read_fds, write_fds, [], 0.1
                )
            except (ValueError, OSError) as e:
                log.error("PTY relay: select failed: %s", e)
                break

            # Drain write buffer first — prevents PTY backpressure
            for fd in writable:
                if fd is self.sock and write_buf:
                    try:
                        sent = self.sock.send(write_buf)
                        write_buf = write_buf[sent:]
                    except BlockingIOError:
                        pass
                    except (BrokenPipeError, OSError):
                        return 1

            for fd in readable:
                try:
                    if fd is self.sock:
                        data = self.sock.recv(4096)
                        if not data:
                            # Client disconnected
                            try:
                                os.kill(-self.child_pid, signal.SIGHUP)
                            except ProcessLookupError:
                                pass
                            return 0

                        data = self._process_relay_data(data)
                        if data:
                            os.write(self.master_fd, data)

                    elif fd is self.master_fd:
                        data = os.read(self.master_fd, 4096)
                        if data:
                            write_buf += data

                except (OSError, BrokenPipeError) as e:
                    log.error("PTY relay: I/O error: %s", e)
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
                        except (ValueError, OSError) as e:
                            log.warning("Resize failed: %s", e)
                    i = end + 1
                    continue

            result.append(data[i])
            i += 1

        return bytes(result)

    def _drain_pty(self, write_buf: bytes = b""):
        """Drain any remaining data from the PTY master after child exit."""
        while True:
            try:
                readable, writable, _ = select.select(
                    [self.master_fd],
                    [self.sock] if write_buf else [],
                    [],
                    0.1,
                )
            except (OSError, ValueError):
                break

            # Send any buffered data
            for fd in writable:
                if fd is self.sock and write_buf:
                    try:
                        sent = self.sock.send(write_buf)
                        write_buf = write_buf[sent:]
                    except BlockingIOError:
                        pass
                    except (BrokenPipeError, OSError):
                        return

            if not readable:
                break
            data = os.read(self.master_fd, 4096)
            if not data:
                break
            write_buf += data
