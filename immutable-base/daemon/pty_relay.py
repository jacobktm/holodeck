"""PTY relay for interactive shell sessions."""
import os
import pty
import select
import signal
import socket
import struct
import fcntl
import termios
import errno
import logging
from typing import Dict, Any

log = logging.getLogger("immutable-daemon")

RESIZE_PREFIX = b"\x1b[8;"
RESIZE_SUFFIX = b"t"

RELAY_BUF_SIZE = 256 * 1024


class PtyRelay:
    """Manages a PTY session between a socket client and a chroot shell."""

    def __init__(self, sock, mount_ctx: Dict[str, Any], overlay_name: str,
                 args: list, env: dict = None):
        self.sock = sock
        self.mount_ctx = mount_ctx
        self.root = mount_ctx["root"]
        self.username = mount_ctx["username"]
        self.overlay_name = overlay_name
        self.args = args
        self.env = env or {}
        self.child_pid = None
        self.master_fd = None

    def run(self) -> int:
        """Execute the shell session. Returns the shell's exit code."""
        master_fd, slave_fd = pty.openpty()
        log.info("PTY allocated: master_fd=%d slave_fd=%d open_fds=%d",
                 master_fd, slave_fd, len(os.listdir(f"/proc/{os.getpid()}/fd")))

        try:
            winsize = struct.pack("HHHH", 24, 80, 0, 0)
            fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, winsize)
        except Exception:
            pass

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
            try:
                os.close(master_fd)
                os.setsid()
                fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)

                os.dup2(slave_fd, 0)
                os.dup2(slave_fd, 1)
                os.dup2(slave_fd, 2)
                if slave_fd > 2:
                    os.close(slave_fd)

                for fd in range(3, 1024):
                    try:
                        os.close(fd)
                    except OSError:
                        pass

                os.chroot(self.root)
                os.chdir(f"/home/{self.username}")

                os.setgroups([gid])
                os.setgid(gid)
                os.setuid(uid)

                shell_args = ["/bin/bash", "--login"]
                if self.args:
                    shell_args.extend(self.args)

                os.execve(shell_args[0], shell_args, env)
                os._exit(127)
            except Exception as e:
                try:
                    os.write(2, f"\r\nPTY child setup FAILED: {e}\r\n".encode())
                except OSError:
                    pass
                os._exit(1)

        os.close(slave_fd)
        self.child_pid = pid
        self.master_fd = master_fd

        log.info("PTY session started: pid=%d root=%s user=%s",
                 pid, self.root, self.username)

        try:
            exit_code = self._relay_loop()
        finally:
            # Drain any remaining PTY output before checking exit status.
            # This must happen before waitpid: if SIGCHLD is SIG_IGN the
            # child is already auto-reaped and waitpid would raise ECHILD,
            # skipping the drain entirely and losing output.
            try:
                self._drain_remaining(b"")
            except Exception:
                pass

            try:
                _, status = os.waitpid(pid, os.WNOHANG)
                if pid != 0 and _ == 0:
                    log.warning("PTY child %d not yet reaped after relay exit", pid)
                if os.WIFEXITED(status):
                    code = os.WEXITSTATUS(status)
                    log.info("PTY child exited: code=%d", code)
                    if code != 0:
                        log.warning("Shell exited with error code %d", code)
                elif os.WIFSIGNALED(status):
                    sig = os.WTERMSIG(status)
                    log.warning("PTY child killed by signal %d (%s)",
                                sig, signal.Signals(sig).name)
            except ChildProcessError:
                log.warning("PTY child already reaped")
            try:
                os.close(master_fd)
                log.info("master_fd %d closed, open_fds=%d",
                         master_fd, len(os.listdir(f"/proc/{os.getpid()}/fd")))
            except OSError:
                pass

        return exit_code

    def _relay_loop(self) -> int:
        """Relay bytes between socket and PTY master.

        Uses non-blocking sends (MSG_DONTWAIT) to avoid deadlocks when the
        client is slow to read.  Data that couldn't be sent is retained in
        write_buf and retried on the next select() iteration.
        """
        self.sock.setblocking(True)
        os.set_blocking(self.master_fd, False)

        write_buf = b""
        child_exited = False
        exit_status = None

        while True:
            # Reap the child if it has exited.  With SIGCHLD=SIG_IGN the
            # child may already be auto-reaped, so ECHILD is expected.
            if not child_exited:
                try:
                    pid, status = os.waitpid(self.child_pid, os.WNOHANG)
                    if pid != 0:
                        child_exited = True
                        exit_status = status
                except ChildProcessError:
                    child_exited = True

            # When the child has exited and all buffered data has been sent,
            # drain any remaining PTY output and return the exit code.
            if child_exited and not write_buf:
                self._drain_remaining(b"")
                if exit_status is not None:
                    if os.WIFEXITED(exit_status):
                        return os.WEXITSTATUS(exit_status)
                    elif os.WIFSIGNALED(exit_status):
                        return 128 + os.WTERMSIG(exit_status)
                return 0

            read_fds = [self.sock]
            if len(write_buf) < RELAY_BUF_SIZE:
                read_fds.append(self.master_fd)

            write_fds = [self.sock] if write_buf else []

            try:
                readable, writable, _ = select.select(
                    read_fds, write_fds, [], 0.1
                )
            except (ValueError, OSError) as e:
                log.error("PTY relay: select failed: %s", e)
                break

            # Non-blocking send: push as much as the kernel will accept.
            # This prevents deadlocks when the client is slow to read.
            if write_buf and self.sock in writable:
                try:
                    sent = self.sock.send(write_buf, socket.MSG_DONTWAIT)
                    if sent > 0:
                        write_buf = write_buf[sent:]
                except (BrokenPipeError, ConnectionResetError):
                    return 1
                except BlockingIOError:
                    pass
                except OSError as e:
                    if e.errno == errno.EAGAIN or e.errno == errno.EWOULDBLOCK:
                        pass
                    else:
                        log.error("PTY relay: socket send failed: %s", e)
                        return 1

            for fd in readable:
                if fd is self.sock:
                    try:
                        data = self.sock.recv(RELAY_BUF_SIZE)
                    except (BrokenPipeError, ConnectionResetError):
                        return 1
                    if not data:
                        try:
                            os.kill(-self.child_pid, signal.SIGHUP)
                        except ProcessLookupError:
                            pass
                        return 0

                    data = self._process_relay_data(data)
                    if data:
                        try:
                            os.write(self.master_fd, data)
                        except BlockingIOError:
                            pass
                        except OSError:
                            return 1

                elif fd is self.master_fd:
                    try:
                        data = os.read(self.master_fd, RELAY_BUF_SIZE)
                    except BlockingIOError:
                        continue
                    except OSError as e:
                        if e.errno == errno.EIO:
                            return 1
                        log.error("PTY relay: PTY read failed: %s", e)
                        return 1
                    if not data:
                        return 1
                    write_buf += data

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

    def _drain_remaining(self, write_buf: bytes):
        """Drain PTY and write buffer after child exits."""
        while write_buf:
            try:
                self.sock.sendall(write_buf)
                write_buf = b""
                break
            except (BrokenPipeError, ConnectionResetError, OSError):
                break

        for _ in range(100):
            try:
                readable, _, _ = select.select([self.master_fd], [], [], 0.05)
                if not readable:
                    break
                data = os.read(self.master_fd, RELAY_BUF_SIZE)
                if not data:
                    break
                try:
                    self.sock.sendall(data)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    break
            except (OSError, ValueError):
                break
