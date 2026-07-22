"""Boot entry management."""
import re
from pathlib import Path
from typing import Optional, List


BOOT_ENTRY = "/boot/efi/loader/entries/immutable.conf"


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

    def show_config(self) -> List[str]:
        """Return lines describing the current boot configuration."""
        entry = Path(BOOT_ENTRY)
        if entry.exists():
            content = entry.read_text()
            match = re.search(r"subvol=(\S+)", content)
            subvol = match.group(1) if match else "unknown"
            return [f"Boot overlay: {subvol}"]
        return ["Boot config: not found (system not installed?)"]
