"""Message framing and serialization for the daemon protocol."""
import json
import socket
from typing import Optional, Dict, Any


class ProtocolError(Exception):
    pass


class Message:
    """Handles newline-delimited JSON message framing."""

    @staticmethod
    def send(sock: socket.socket, data: Dict[str, Any]) -> None:
        """Send a JSON message followed by a newline."""
        raw = json.dumps(data, separators=(",", ":")) + "\n"
        sock.sendall(raw.encode("utf-8"))

    @staticmethod
    def recv(sock: socket.socket, max_size: int = 1048576) -> Optional[Dict[str, Any]]:
        """Receive a newline-delimited JSON message."""
        buf = b""
        while len(buf) < max_size:
            try:
                chunk = sock.recv(1)
            except (ConnectionResetError, BrokenPipeError, OSError):
                return None

            if not chunk:
                return None

            if chunk == b"\n":
                break

            buf += chunk
        else:
            raise ProtocolError(f"Message exceeds {max_size} byte limit")

        if not buf:
            return None

        try:
            return json.loads(buf.decode("utf-8"))
        except json.JSONDecodeError as e:
            raise ProtocolError(f"Invalid JSON: {e}")
