#!/usr/bin/env python3
"""Comprehensive diagnostics for the COSMIC PR testing framework.

Usage:
    ./diagnostics.py                    # host-side checks only
    ./diagnostics.py <container_name>   # host + container checks
    ./diagnostics.py --full             # host + build + container checks
"""
import os
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

PASS = 0
WARN = 0
FAIL = 0


def pass_(msg):
    global PASS
    PASS += 1
    print(f"  [PASS] {msg}")


def warn(msg):
    global WARN
    WARN += 1
    print(f"  [WARN] {msg}")


def fail(msg):
    global FAIL
    FAIL += 1
    print(f"  [FAIL] {msg}")


def info(msg):
    print(f"  [INFO] {msg}")


def section(msg):
    print(f"\n── {msg} ──")


def sh(cmd, check=False):
    """Run a shell command, return stdout."""
    result = subprocess.run(
        cmd, shell=isinstance(cmd, str), capture_output=True, text=True, check=check,
    )
    return result.stdout.strip(), result.returncode


def sh_ok(cmd):
    stdout, rc = sh(cmd)
    return rc == 0, stdout


# ══════════════════════════════════════════════════════════════════════
# HOST CHECKS
# ══════════════════════════════════════════════════════════════════════
def host_checks():
    print("=" * 40)
    print(" HOST DIAGNOSTICS")
    print("=" * 40)

    # Docker
    section("Docker")
    ok, out = sh_ok("docker --version")
    if ok:
        pass_(f"docker binary found: {out.splitlines()[0] if out else 'unknown'}")
    else:
        fail("docker not installed")
        return

    ok, _ = sh_ok("docker info")
    if ok:
        pass_("docker daemon running")
    else:
        fail("docker daemon not running (or no permission)")
        return

    # Base image
    section("Base Image")
    for img in ["pop-os:24.04-latest", "pop-os:24.04-cosmic-latest"]:
        ok, _ = sh_ok(f"docker image inspect {img}")
        if ok:
            label = "(nested session)" if "cosmic" in img else ""
            pass_(f"{img} exists {label}".strip())
        elif "cosmic" in img:
            info(f"{img} not found (only needed for nested session packages)")
        else:
            fail(f"{img} not found — run base/update-base-image.sh")

    # User groups
    section("User Groups")
    ok, groups = sh_ok("id -Gn")
    if ok:
        for g in ["render", "video", "netdev"]:
            if g in groups.split():
                pass_(f"user in group {g}")
            else:
                warn(f"user NOT in group {g} — GPU/network access may fail")

    # DRI devices
    section("GPU / DRI Devices")
    for dev in ["/dev/dri/renderD128", "/dev/dri/card0"]:
        if os.path.exists(dev):
            ok, gid = sh_ok(f"stat -c '%g' {dev}")
            pass_(f"{dev} exists (gid={gid})" if ok else f"{dev} exists")
        else:
            if "renderD128" in dev:
                fail(f"{dev} not found")
            else:
                warn(f"{dev} not found")

    # Wayland
    section("Wayland")
    wayland = os.environ.get("WAYLAND_DISPLAY")
    xdg = os.environ.get("XDG_RUNTIME_DIR")

    if wayland:
        pass_(f"WAYLAND_DISPLAY={wayland}")
    else:
        fail("WAYLAND_DISPLAY not set")

    if xdg:
        pass_(f"XDG_RUNTIME_DIR={xdg}")
        wayland_sock = os.path.join(xdg, wayland or "")
        if os.path.exists(wayland_sock) and os.stat(wayland_sock).st_mode & 0o170 == 0o170:
            pass_(f"Wayland socket exists: {wayland_sock}")
        else:
            fail(f"Wayland socket missing: {wayland_sock}")

        bus = os.path.join(xdg, "bus")
        if os.path.exists(bus):
            pass_("D-Bus session socket exists")
        else:
            fail(f"D-Bus session socket missing: {bus}")
    else:
        fail("XDG_RUNTIME_DIR not set")

    # udev
    section("udev Socket")
    udev_ctrl = "/run/udev/control"
    if os.path.exists(udev_ctrl):
        ok, perms = sh_ok(f"stat -c '%a' {udev_ctrl}")
        if ok and perms in ("666", "660"):
            pass_(f"/run/udev/control accessible (mode {perms})")
        else:
            warn(f"/run/udev/control mode {perms} — run: sudo chmod a+rw /run/udev/control")
    else:
        warn("/run/udev/control not found")

    # Backlight
    section("Backlight Devices")
    bl_dir = Path("/sys/class/backlight")
    if bl_dir.exists():
        devs = [d.name for d in bl_dir.iterdir()] if bl_dir.is_dir() else []
        if devs:
            pass_(f"backlight devices: {' '.join(devs)}")
            for d in devs:
                max_b = bl_dir / d / "max_brightness"
                max_val = max_b.read_text().strip() if max_b.exists() else "?"
                info(f"  {d}: max_brightness={max_val}")
        else:
            warn("no backlight devices in /sys/class/backlight/")
    else:
        warn("/sys/class/backlight/ not found")

    # Host daemons
    section("Host Daemons")
    for daemon in ["cosmic-settings-daemon", "cosmic-session", "cosmic-comp"]:
        ok, out = sh_ok(f"pgrep -x {daemon}")
        if ok and out:
            pass_(f"{daemon} running (PIDs: {out})")
        else:
            warn(f"{daemon} not running")

    # Host config files
    section("Host Config Files")
    home = os.environ.get("HOME", "")
    config_dirs = [
        f"{home}/.config/cosmic/com.system76.CosmicPanel.Panel/v1",
        f"{home}/.config/cosmic/com.system76.CosmicPanel.Dock/v1",
        f"{home}/.config/cosmic/com.system76.CosmicPanel/v1",
        f"{home}/.config/cosmic/com.system76.CosmicSettings/v1",
    ]
    for d in config_dirs:
        if os.path.isdir(d):
            name_file = os.path.join(d, "name")
            if os.path.exists(name_file):
                val = Path(name_file).read_text().strip()
                pass_(f"{d} (name={val})")
            else:
                warn(f"{d} exists but name file MISSING")
        else:
            warn(f"{d} does not exist")

    # NetworkManager
    section("Host NetworkManager")
    ok, _ = sh_ok("which nmcli")
    if ok:
        ok, wifi = sh_ok("nmcli radio wifi")
        pass_(f"nmcli available, WiFi radio: {wifi}" if ok else "nmcli available")
        ok, devices = sh_ok("nmcli device status")
        if ok and devices:
            info("Devices:")
            for line in devices.splitlines()[1:]:
                info(f"    {line.strip()}")
    else:
        warn("nmcli not found")


# ══════════════════════════════════════════════════════════════════════
# BUILD CHECKS
# ══════════════════════════════════════════════════════════════════════
def build_checks():
    section("Build Artifacts")
    ok, images = sh_ok("docker images --format '{{.Repository}}:{{.Tag}}' | grep '^cosmic-pr:'")
    if ok and images:
        pass_("PR images found:")
        for line in images.splitlines():
            info(f"    {line.strip()}")
    else:
        info("No PR images built yet")

    section("Package Configs")
    packages_dir = SCRIPT_DIR / "packages"
    if packages_dir.exists():
        for toml_path in sorted(packages_dir.glob("*/config.toml")):
            try:
                from lib.config import load_config
                cfg = load_config(toml_path)
                extra = " (nested session)" if cfg.nested_session else ""
                pass_(f"{cfg.name} config.toml parsed OK{extra}")
                info(f"    type={cfg.type} logind={cfg.needs_logind} udev={cfg.needs_udev}")
                if cfg.extra_packages:
                    info(f"    extra_packages={' '.join(cfg.extra_packages)}")
                if cfg.groups:
                    info(f"    groups={' '.join(cfg.groups)}")
                if cfg.mounts:
                    info(f"    mounts={len(cfg.mounts)} entries")
            except Exception as e:
                fail(f"{toml_path.parent.name} config.toml parse FAILED: {e}")


# ══════════════════════════════════════════════════════════════════════
# CONTAINER CHECKS
# ══════════════════════════════════════════════════════════════════════
def container_checks(name):
    print()
    print("=" * 40)
    print(f" CONTAINER DIAGNOSTICS: {name}")
    print("=" * 40)

    ok, pid_out = sh_ok(f"docker inspect --format '{{{{.State.Pid}}}}' {name}")
    pid = int(pid_out) if ok and pid_out and pid_out != "0" else None

    if not pid:
        fail(f"Container '{name}' not running or PID unavailable")
        return
    pass_(f"Container running, entrypoint PID: {pid}")

    # Process tree
    section("Process Tree")
    ok, children = sh_ok(f"ps --ppid {pid} -o pid=")
    child_pids = []
    if ok and children:
        for p in children.splitlines():
            p = p.strip()
            if p:
                child_pids.append(p)
                ok2, comm = sh_ok(f"cat /proc/{p}/comm")
                ok3, cg = sh_ok(f"grep '^0::' /proc/{p}/cgroup | cut -d: -f3")
                info(f"  PID {p} ({comm}) -> {cg}")
    else:
        warn("No child processes found")

    # Cgroup membership
    section("Cgroup Membership")
    ok, session_cg = sh_ok("grep '^0::' /proc/self/cgroup | cut -d: -f3")
    info(f"Host session cgroup: {session_cg}")

    for p in child_pids:
        ok, cg = sh_ok(f"grep '^0::' /proc/{p}/cgroup | cut -d: -f3")
        if ok and cg == session_cg:
            pass_(f"PID {p} in session cgroup (logind access OK)")
        else:
            warn(f"PID {p} in {cg} (NOT in session cgroup — logind may reject)")

    # D-Bus session bus
    section("D-Bus Session Bus (inside container)")
    ok, out = sh_ok(f"docker exec {name} busctl --user list")
    if ok:
        pass_("Session bus accessible from container")
        for line in out.splitlines()[:5]:
            info(f"  {line.strip()}")
    else:
        fail("Cannot access session bus from container")

    # Daemon registration
    section("Daemon Registration")
    ok, out = sh_ok(f"docker exec {name} busctl --user status com.system76.CosmicSettingsDaemon 2>/dev/null")
    if ok:
        pass_("cosmic-settings-daemon registered on session bus")
    else:
        warn("cosmic-settings-daemon NOT on session bus")

    # System D-Bus
    section("System D-Bus (inside container)")
    for svc in ["org.freedesktop.login1", "org.freedesktop.NetworkManager", "org.freedesktop.UPower"]:
        ok, _ = sh_ok(f"docker exec {name} busctl status {svc}")
        if ok:
            pass_(f"{svc} available")
        else:
            warn(f"{svc} NOT available")

    # Config files
    section("Config Files (inside container)")
    home = os.environ.get("HOME", "")
    config_dirs = [
        f"{home}/.config/cosmic/com.system76.CosmicPanel.Panel/v1",
        f"{home}/.config/cosmic/com.system76.CosmicPanel.Dock/v1",
        f"{home}/.config/cosmic/com.system76.CosmicPanel/v1",
        f"{home}/.config/cosmic/com.system76.CosmicSettings/v1",
    ]
    for d in config_dirs:
        ok, _ = sh_ok(f"docker exec {name} test -d '{d}'")
        if ok:
            name_file = f"{d}/name"
            ok2, val = sh_ok(f"docker exec {name} cat '{name_file}' 2>/dev/null")
            if ok2:
                pass_(f"{d} (name={val})")
            else:
                warn(f"{d} exists but name file MISSING")
        else:
            warn(f"{d} NOT visible inside container")

    # Logind session
    section("Logind Session (inside container)")
    ok, _ = sh_ok(f"docker exec {name} busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager GetSession s 'auto'")
    if ok:
        pass_("logind session accessible")
    else:
        warn("logind session not accessible from container — brightness control may fail")

    # ── USB / Mounting diagnostics ──────────────────────────────────
    section("USB / Mounting (inside container)")

    # GVFS on session bus
    ok, out = sh_ok(f"docker exec {name} busctl --user list")
    if ok and "gvfs" in out.lower():
        pass_("GVFS services on session bus")
    else:
        warn("no GVFS services on session bus — volume detection may fail")

    # udisks2 on system bus
    ok, _ = sh_ok(f"docker exec {name} busctl call org.freedesktop.UDisks2 /org/freedesktop/UDisks2Manager org.freedesktop.DBus.Peer Ping")
    if ok:
        pass_("udisks2 on system bus")
    else:
        warn("udisks2 not reachable on system bus — mounting may fail")

    # GIO volume listing
    ok, gio_out = sh_ok(f"docker exec {name} gio mount -l 2>&1")
    if ok and gio_out:
        pass_("GIO volumes detected:")
        for line in gio_out.splitlines()[:10]:
            info(f"    {line.strip()}")
    else:
        warn("GIO reports no volumes — volume detection failing")

    # Check /media and /run/media mount points for permissions
    ok, media_out = sh_ok(f"docker exec {name} ls -la /media/ 2>&1")
    if ok and media_out:
        info("  /media contents:")
        for line in media_out.splitlines()[:5]:
            info(f"    {line}")
    else:
        info("  /media/ not accessible or empty")

    ok, runmedia_out = sh_ok(f"docker exec {name} ls -la /run/media/ 2>&1")
    if ok and runmedia_out:
        info("  /run/media contents:")
        for line in runmedia_out.splitlines()[:5]:
            info(f"    {line}")
    else:
        info("  /run/media/ not accessible or empty")

    # Check container user
    ok, whoami_out = sh_ok(f"docker exec {name} id 2>&1")
    if whoami_out:
        info(f"  Container user: {whoami_out.strip()}")

    # Try to access mounted drives directly
    for mount_dir in ["/media", "/run/media"]:
        ok, ls_out = sh_ok(f"docker exec {name} ls -la {mount_dir}/ 2>&1")
        if ok and ls_out:
            for line in ls_out.splitlines():
                if "USERNAME" in line or "root" in line or "total" in line:
                    info(f"  {mount_dir}: {line}")

    # Try to mount an unmounted volume
    ok, vol_out = sh_ok(
        f"docker exec {name} gio mount -l 2>/dev/null "
        f"| grep -i 'volume\\|drive\\|usb' "
        f"| grep -v 'Mount:' | head -1 | awk '{{print $2}}'"
    )
    if ok and vol_out:
        ok2, mount_out = sh_ok(f"docker exec {name} timeout 10 gio mount '{vol_out}' 2>&1")
        mount_lower = (mount_out or "").lower()
        if any(w in mount_lower for w in ["error", "fail", "denied", "not authorized"]):
            warn(f"volume mount FAILED: {mount_out}")
        elif not mount_out:
            pass_("volume mount succeeded (no output = success)")
        else:
            pass_(f"volume mount result: {mount_out}")
    else:
        info("no unmounted volumes to test mount")

    # Host gvfsd processes
    ok, gvfs_out = sh_ok("pgrep -a gvfs")
    if ok and gvfs_out:
        pass_(f"host gvfsd running: {gvfs_out.splitlines()[0].strip()}")
    else:
        warn("host gvfsd not running — volume detection may fail")

    # polkit-agent-helper-1
    polkit_helper = "/usr/lib/polkit-1/polkit-agent-helper-1"
    if os.path.exists(polkit_helper):
        ok, perms = sh_ok(f"stat -c '%a' {polkit_helper}")
        if ok and perms == "4755":
            pass_(f"polkit-agent-helper-1 has SetUID ({perms})")
        else:
            warn(f"polkit-agent-helper-1 perms={perms} (expected 4755) — auth may fail")
    else:
        warn("polkit-agent-helper-1 not found")

    # cosmic-files app log
    ok, log_out = sh_ok(f"docker exec {name} cat /tmp/cosmic-files.log 2>/dev/null")
    if ok and log_out:
        errors = [l for l in log_out.splitlines()
                  if any(w in l.lower() for w in ["error", "fail", "denied", "permission"])]
        if errors:
            warn("cosmic-files log errors:")
            for line in errors[:5]:
                info(f"    {line.strip()}")
        else:
            pass_(f"cosmic-files log clean ({len(log_out.splitlines())} lines)")
    else:
        info("no cosmic-files log yet")

    # Host mount logs
    section("Host Mount Logs")
    for unit in ["cosmic-gvfs", "udisks2"]:
        flag = "--user" if unit == "cosmic-gvfs" else ""
        ok, log_out = sh_ok(f"journalctl {flag} -u {unit} -n 20 --no-pager 2>/dev/null")
        if ok and log_out:
            errors = [l for l in log_out.splitlines()
                      if any(w in l.lower() for w in ["error", "fail", "denied", "mount", "polkit", "auth"])]
            if errors:
                warn(f"{unit} errors:")
                for line in errors[-5:]:
                    info(f"    {line.strip()}")
            else:
                pass_(f"{unit} logs clean")
        else:
            info(f"no {unit} logs")


# ══════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════
def main():
    container_name = ""
    do_build = False

    for arg in sys.argv[1:]:
        if arg == "--full":
            do_build = True
        else:
            container_name = arg

    host_checks()

    if do_build:
        build_checks()

    if container_name:
        container_checks(container_name)

    print()
    print("=" * 40)
    print(f" SUMMARY: {PASS} passed, {WARN} warnings, {FAIL} failures")
    print("=" * 40)


if __name__ == "__main__":
    main()
