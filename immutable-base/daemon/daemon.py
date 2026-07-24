#!/usr/bin/env python3
"""Immutable overlay management daemon.

Activated by systemd socket activation. Listens on an inherited socket FD
from systemd (FD 3 by default) or a configured path.
"""
import os
import sys
import signal
import socket
import logging
import logging.handlers

# Add daemon directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from protocol import Message, ProtocolError
from commands import CommandHandler
from pty_relay import PtyRelay

SOCKET_FD = 3
SOCKET_PATH = "/run/immutable/daemon.sock"
MAX_MSG_SIZE = 1 * 1024 * 1024

log = logging.getLogger("immutable-daemon")


class Daemon:
    def __init__(self):
        self.handler = CommandHandler()
        self.running = True
        self.from_systemd = False

    def run(self):
        """Main daemon loop."""
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)

        sock = self._create_listener()

        # Ensure /pool is mounted before accepting clients.
        # This is normally handled by fstab + local-fs.target, but
        # verify as a safety net so commands don't fail with confusing errors.
        try:
            if not os.path.ismount("/pool"):
                log.info("/pool not mounted, attempting mount...")
                self.handler.btrfs.mount_pool()
                log.info("/pool mounted successfully")
        except Exception as e:
            log.warning("Failed to mount /pool: %s — commands may fail", e)

        log.info("Immutable daemon started on %s",
                 SOCKET_PATH if self.from_systemd
                 else sock.getsockname())

        while self.running:
            try:
                client_sock, client_addr = sock.accept()
            except OSError:
                if not self.running:
                    break
                continue

            pid = os.fork()
            if pid == 0:
                sock.close()
                log.info("Client child %d started, open_fds=%d",
                         os.getpid(), len(os.listdir(f"/proc/{os.getpid()}/fd")))
                self._handle_client(client_sock)
                log.info("Client child %d exiting, open_fds=%d",
                         os.getpid(), len(os.listdir(f"/proc/{os.getpid()}/fd")))
                os._exit(0)
            else:
                client_sock.close()

        sock.close()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)

    def _create_listener(self):
        """Create the listening socket, preferring systemd FD."""
        systemd_fd = int(os.environ.get("LISTEN_FDS", 0))
        if systemd_fd > 0:
            self.from_systemd = True
            return socket.fromfd(SOCKET_FD, socket.AF_UNIX, socket.SOCK_STREAM)

        # Fallback for development/testing
        os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(SOCKET_PATH)
        sock.listen(5)
        os.chmod(SOCKET_PATH, 0o660)

        try:
            import grp
            immutable_gid = grp.getgrnam("immutable").gr_gid
            os.chown(SOCKET_PATH, 0, immutable_gid)
        except (KeyError, ImportError):
            pass

        return sock

    def _handle_client(self, client_sock):
        """Handle a single client connection."""
        try:
            client_sock.settimeout(60)

            msg = Message.recv(client_sock, MAX_MSG_SIZE)
            if msg is None:
                return

            cmd = msg.get("cmd")
            if cmd is None:
                Message.send(client_sock, {"ok": False, "error": "Missing 'cmd' field"})
                return

            # Reset SIGCHLD to default so PTY relay can waitpid() its child.
            # The main daemon uses SIG_IGN to auto-reap client-handler
            # children, but PTY sessions need explicit waitpid for exit status.
            signal.signal(signal.SIGCHLD, signal.SIG_DFL)

            if cmd == "pty":
                self._handle_pty_session(client_sock, msg)
            elif cmd == "run":
                self._handle_run(client_sock, msg)
            else:
                self._handle_simple(client_sock, msg)

        except Exception as e:
            log.exception("Error handling client")
            try:
                Message.send(client_sock, {"ok": False, "error": str(e)})
            except Exception:
                pass
        finally:
            try:
                client_sock.close()
            except Exception:
                pass

    def _handle_simple(self, sock, msg):
        """Handle a simple command."""
        result = self.handler.execute(msg)
        Message.send(sock, result)

    def _handle_run(self, sock, msg):
        """Handle a non-interactive run command with streaming output."""
        Message.send(sock, {"ok": True, "stream": True})

        for event in self.handler.execute_run(msg):
            Message.send(sock, event)

    def _handle_pty_session(self, sock, msg):
        """Handle an interactive PTY session."""
        import time
        mount_ctx = self.handler.setup_chroot(msg)
        if mount_ctx is None:
            if self.handler._last_auth_required:
                Message.send(sock, {"ok": False, "error": "Password required for @base shell", "auth_required": True})
            else:
                Message.send(sock, {"ok": False, "error": "Failed to set up chroot"})
            return

        overlay_name = msg.get("overlay", "@base")
        args = msg.get("args", [])
        env = msg.get("env", {})

        # After this response, socket enters raw relay mode.
        # Remove the handshake timeout — the relay manages its own I/O.
        sock.settimeout(None)
        Message.send(sock, {"ok": True})

        t0 = time.monotonic()
        relay = PtyRelay(sock, mount_ctx, overlay_name, args, env=env)
        exit_code = relay.run()
        t1 = time.monotonic()
        log.info("PTY relay ran for %.2fs, exit_code=%d", t1 - t0, exit_code)

        t2 = time.monotonic()
        self.handler.teardown_chroot(mount_ctx)
        t3 = time.monotonic()
        log.info("teardown_chroot took %.2fs", t3 - t2)

        log.info("PTY session ended, exit_code=%d", exit_code)

    def _handle_signal(self, signum, frame):
        log.info("Received signal %d, shutting down", signum)
        self.running = False


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.handlers.SysLogHandler("/dev/log"),
            logging.StreamHandler(sys.stderr),
        ],
    )
    Daemon().run()
