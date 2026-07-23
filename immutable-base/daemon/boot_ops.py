"""Boot entry management."""
import re
from pathlib import Path
from typing import Optional, List


BOOT_ENTRY = "/boot/efi/loader/entries/immutable.conf"
LOADER_CONF = "/boot/efi/loader/loader.conf"


class BootOps:
    def get_active_subvol(self) -> Optional[str]:
        """Read the currently configured boot subvolume."""
        try:
            content = Path(BOOT_ENTRY).read_text()
            match = re.search(r"subvol=(\S+)", content)
            if match:
                return match.group(1)
        except FileNotFoundError:
            pass
        return None

    def set_active_overlay(self, name: str):
        """Update the boot entry to use a different overlay."""
        subvol = f"@overlay-{name}"
        entry = Path(BOOT_ENTRY)

        if not entry.exists():
            raise RuntimeError(
                f"Boot entry not found at {BOOT_ENTRY}. "
                f"Manually set rootflags=subvol={subvol} in your boot config."
            )

        content = entry.read_text()
        new_content = re.sub(
            r"rootflags=subvol=\S+",
            f"rootflags=subvol={subvol}",
            content,
        )
        entry.write_text(new_content)

        # Ensure loader.conf defaults to immutable.conf
        self._ensure_loader_default()

    def _ensure_loader_default(self):
        """Make sure loader.conf points to immutable.conf as default."""
        loader = Path(LOADER_CONF)
        if not loader.exists():
            return

        content = loader.read_text()

        # Update default entry to immutable.conf
        if re.search(r"^default\s+.*immutable\.conf", content, re.MULTILINE):
            return  # Already correct

        if re.search(r"^default\s+", content, re.MULTILINE):
            content = re.sub(
                r"^default\s+.*",
                "default immutable.conf",
                content,
                flags=re.MULTILINE,
            )
        else:
            content += "\ndefault immutable.conf\n"

        loader.write_text(content)

    def show_config(self) -> List[str]:
        """Return lines describing the current boot configuration."""
        lines = []
        entry = Path(BOOT_ENTRY)
        if entry.exists():
            content = entry.read_text()
            match = re.search(r"subvol=(\S+)", content)
            subvol = match.group(1) if match else "unknown"
            lines.append(f"Boot overlay: {subvol}")
        else:
            lines.append("Boot config: not found (system not installed?)")

        loader = Path(LOADER_CONF)
        if loader.exists():
            content = loader.read_text()
            match = re.search(r"^default\s+(\S+)", content, re.MULTILINE)
            default_entry = match.group(1) if match else "unknown"
            lines.append(f"Loader default: {default_entry}")
            match = re.search(r"^timeout\s+(\S+)", content, re.MULTILINE)
            timeout = match.group(1) if match else "unknown"
            lines.append(f"Loader timeout: {timeout}")

        return lines
