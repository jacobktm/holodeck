"""udev socket fix for container device access."""
import subprocess


def udev_socket_fix():
    result = subprocess.run(
        ["sudo", "chmod", "a+rw", "/run/udev/control"],
        capture_output=True, check=False,
    )
    if result.returncode == 0:
        print("udev socket opened for container access")
    else:
        print("WARN: Could not chmod udev socket — device enumeration may fail")
