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

    def run(self):
        """Main daemon loop."""
        signal.signal(signal.SIGTERM, self._handle_signal)

        sock = self._create_listener()

        log.info("Immutable daemon started on %s",
                 sock.getsockname() if not hasattr(sock, '_from_systemd')
                 else SOCKET_PATH)

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
                self._handle_client(client_sock)
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
            sock = socket.fromfd(SOCKET_FD, socket.AF_UNIX, socket.SOCK_STREAM)
            sock._from_systemd = True
            return sock

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

        sock._from_systemd = False
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
        mount_ctx = self.handler.setup_chroot(msg)
        if mount_ctx is None:
            Message.send(sock, {"ok": False, "error": "Failed to set up chroot"})
            return

        overlay_name = msg.get("overlay", "@base")
        args = msg.get("args", [])

        # After this response, socket enters raw relay mode
        Message.send(sock, {"ok": True})

        relay = PtyRelay(sock, mount_ctx, overlay_name, args)
        exit_code = relay.run()

        self.handler.teardown_chroot(mount_ctx)

        log.info("PTY session ended, exit_code=%d", exit_code)

    def _handle_signal(self, signum, frame):
        log.info("Received signal %d, shutting down", signum)
        self.running = False


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.SysLogHandler("/dev/log"),
            logging.StreamHandler(sys.stderr),
        ],
    )
    Daemon().run()
