"""BTRFS subvolume management operations."""
import subprocess
import os
from typing import List, Optional


class BtrfsOps:
    def __init__(self, pool_path: str):
        self.pool = pool_path

    def mount_pool(self):
        """Mount the BTRFS pool (subvolid=5) at the pool path."""
        os.makedirs(self.pool, exist_ok=True)

        result = subprocess.run(
            ["findmnt", "-n", "-o", "SOURCE", "/"],
            capture_output=True, text=True,
        )
        dev = result.stdout.strip()
        if not dev:
            raise RuntimeError("Cannot determine root device")

        result = subprocess.run(
            ["findmnt", "-n", "-o", "FSTYPE", "/"],
            capture_output=True, text=True,
        )
        if result.stdout.strip() != "btrfs":
            raise RuntimeError(f"Root filesystem is not BTRFS (found {result.stdout.strip()})")

        subprocess.run(
            ["mount", "-o", "subvolid=5", dev, self.pool],
            check=True,
        )

    def list_subvolumes(self, pool: str) -> List[str]:
        """List all subvolume paths under the pool."""
        result = subprocess.run(
            ["btrfs", "subvolume", "list", pool],
            capture_output=True, text=True,
        )
        paths = []
        for line in result.stdout.splitlines():
            parts = line.rsplit("path ", 1)
            if len(parts) == 2:
                paths.append(parts[1].strip())
        return paths

    def snapshot(self, src: str, dst: str):
        """Create a read-write snapshot of src at dst."""
        subprocess.run(
            ["btrfs", "subvolume", "snapshot", src, dst],
            check=True,
        )

    def delete_subvol(self, path: str):
        """Delete a BTRFS subvolume."""
        subprocess.run(
            ["btrfs", "subvolume", "delete", path],
            check=True,
        )

    def get_property(self, path: str, prop: str) -> Optional[str]:
        """Get a BTRFS property. Returns the value string."""
        result = subprocess.run(
            ["btrfs", "property", "get", path, prop],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            parts = result.stdout.strip().split("=", 1)
            if len(parts) == 2:
                return parts[1]
        return None

    def set_property(self, path: str, prop: str, value: str):
        """Set a BTRFS property."""
        subprocess.run(
            ["btrfs", "property", "set", path, prop, value],
            check=True,
        )
