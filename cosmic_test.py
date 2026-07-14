#!/usr/bin/env python3
"""Main orchestrator for COSMIC PR container testing.

Called by test-cosmic-pr.sh after environment setup.
"""
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from lib.config import load_config
from lib.docker_ops import (
    build_image, show_versions, container_state, container_pid,
    container_rm_force, container_signal_exit, container_logs_follow,
    container_run,
)
from lib.process import (
    cgroup_session_fix, kill_by_name_pattern, daemon_kill, daemon_restart,
    kill_container_processes,
)
from lib.udev import udev_socket_fix
from lib.container_status import container_status

HOME = os.environ["HOME"]


def parse_args(argv):
    force_rebuild = False
    nested_requested = False
    packages_arg = None

    positional = []
    for arg in argv[1:]:
        if arg == "rebuild":
            force_rebuild = True
        elif arg == "--nested":
            nested_requested = True
        else:
            positional.append(arg)

    if len(positional) != 1:
        print("Usage: test-cosmic-pr.sh <pkg:branch,...> [rebuild] [--nested]")
        print()
        print("Examples:")
        print("  test-cosmic-pr.sh cosmic-settings:testing-cosmic-settings-pr2067")
        print('  test-cosmic-pr.sh "cosmic-settings:pr-2068,cosmic-settings-daemon:daemon-branch" --nested')
        print()
        print("Flags:")
        print("  rebuild      Force rebuild image")
        print("  --nested     Enable nested COSMIC session (experimental)")
        sys.exit(1)

    packages_arg = positional[0]

    # Parse "pkg:branch,..." format
    pkg_names = []
    branches = []
    for entry in packages_arg.split(","):
        entry = entry.strip()
        if ":" not in entry:
            print(f"ERROR: Invalid format '{entry}' — expected pkg:branch")
            sys.exit(1)
        parts = entry.split(":", 1)
        pkg_names.append(parts[0])
        branches.append(parts[1])

    # Deduplicate branches, preserve order
    seen = set()
    unique_branches = []
    for b in branches:
        if b not in seen:
            seen.add(b)
            unique_branches.append(b)

    image_tag = "cosmic-pr:" + "-".join(unique_branches)

    return {
        "force_rebuild": force_rebuild,
        "nested_requested": nested_requested,
        "pkg_names": pkg_names,
        "branches": branches,
        "unique_branches": unique_branches,
        "image_tag": image_tag,
    }


def load_package_configs(pkg_names, script_dir):
    """Load TOML configs for all packages, return merged state."""
    configs = []
    needs_logind = False
    needs_udev = False
    nested_session = False
    mount_host_libs = False
    all_packages = []
    extra_packages = []
    groups = []
    host_bins = []
    mount_args = []
    pkg_types = []
    pkg_args = {}  # pkg -> args string

    for pkg in pkg_names:
        toml_path = script_dir / "packages" / pkg / "config.toml"
        if not toml_path.exists():
            print(f"ERROR: No config.toml for '{pkg}' in packages/")
            print(f"Create one at: packages/{pkg}/config.toml")
            sys.exit(1)

        cfg = load_config(toml_path)
        configs.append(cfg)

        all_packages.append(cfg.name)
        pkg_types.append(cfg.type)

        if cfg.needs_logind:
            needs_logind = True
        if cfg.needs_udev:
            needs_udev = True
        if cfg.nested_session:
            nested_session = True
        if cfg.mount_host_libs:
            mount_host_libs = True

        if cfg.extra_packages:
            extra_packages.extend(cfg.extra_packages)
        if cfg.groups:
            groups.extend(cfg.groups)
        if cfg.host_bins:
            host_bins.extend(cfg.host_bins)

        # Resolve HOME in args
        args_list = [a.replace("HOME", HOME) for a in cfg.args]
        if args_list:
            pkg_args[cfg.name] = " ".join(args_list)

        # Resolve HOME in mounts and build docker -v args
        for m in cfg.mounts:
            host = m.host.replace("HOME", HOME)
            container = m.container.replace("HOME", HOME)
            mount_args.extend(["-v", f"{host}:{container}:{m.options}"])

    return {
        "configs": configs,
        "needs_logind": needs_logind,
        "needs_udev": needs_udev,
        "nested_session": nested_session,
        "mount_host_libs": mount_host_libs,
        "all_packages": all_packages,
        "extra_packages": extra_packages,
        "groups": groups,
        "host_bins": host_bins,
        "mount_args": mount_args,
        "pkg_types": pkg_types,
        "pkg_args": pkg_args,
    }


def resolve_group_gids(groups):
    """Resolve group names to GIDs via getent. Skip groups that don't exist."""
    args = []
    for g in groups:
        try:
            result = subprocess.run(
                ["timeout", "2", "getent", "group", g],
                capture_output=True, text=True, check=False,
            )
            if result.returncode == 0 and result.stdout:
                gid = result.stdout.strip().split(":")[2]
                args.extend(["--group-add", gid])
            else:
                print(f"WARN: group '{g}' not found on host, skipping")
        except Exception:
            print(f"WARN: group '{g}' lookup failed, skipping")
    return args


def ensure_base_images(needed_nested):
    """Build base images if missing. Returns True if build succeeded."""
    has_standard = subprocess.run(
        ["docker", "image", "inspect", "pop-os:24.04-latest"],
        capture_output=True, check=False,
    ).returncode == 0

    has_cosmic = subprocess.run(
        ["docker", "image", "inspect", "pop-os:24.04-cosmic-latest"],
        capture_output=True, check=False,
    ).returncode == 0

    if has_standard and (not needed_nested or has_cosmic):
        return True

    print("=" * 40)
    print(" BUILDING BASE IMAGES")
    print("=" * 40)

    base_dir = SCRIPT_DIR / "base"

    if not has_standard:
        print("Building pop-os:24.04-latest...")
        result = subprocess.run(
            ["docker", "build", "-t", "pop-os:24.04-latest", "-f", "Dockerfile", "."],
            cwd=str(base_dir), check=False,
        )
        if result.returncode != 0:
            print("ERROR: Failed to build base image", file=sys.stderr)
            return False

    if needed_nested and not has_cosmic:
        print("Building pop-os:24.04-cosmic-latest...")
        result = subprocess.run(
            ["docker", "build", "-t", "pop-os:24.04-cosmic-latest", "-f", "Dockerfile.cosmic", "."],
            cwd=str(base_dir), check=False,
        )
        if result.returncode != 0:
            print("ERROR: Failed to build nested session base image", file=sys.stderr)
            return False

    subprocess.run(["docker", "image", "prune", "-f"], capture_output=True, check=False)
    return True


def wait_for_signal_file(timeout=15):
    """Wait for the entrypoint's signal file to appear."""
    signal_file = f"{HOME}/.local/share/cosmic-docker-signal/waiting"
    start = time.time()
    while not os.path.exists(signal_file):
        if time.time() - start >= timeout:
            return False
        time.sleep(0.25)
    return True


def build_docker_run_args(state, pkg_state, session_cgroup, group_add_args, nested):
    """Build the docker run argument list."""
    args = []

    if not nested:
        args.extend(["--pid", "host"])

    args.extend(["--user", f"{os.getuid()}:{os.getgid()}"])
    args.extend(group_add_args)
    args.extend(["--device", "/dev/dri"])
    args.extend(["--device", "/dev/fuse"])
    args.extend(["--cap-add", "SYS_ADMIN"])
    args.extend(["--network", "host"])

    if nested:
        args.extend(["-e", "NESTED_SESSION=1"])

    # Environment variables
    wayland_display = os.environ.get("WAYLAND_DISPLAY", "")
    xdg_runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "")

    if wayland_display:
        args.extend(["-e", f"WAYLAND_DISPLAY={wayland_display}"])

    if not nested and xdg_runtime_dir:
        args.extend(["-e", f"XDG_RUNTIME_DIR={xdg_runtime_dir}"])
        args.extend(["-e", f"DBUS_SESSION_BUS_ADDRESS=unix:path={xdg_runtime_dir}/bus"])

    args.extend(["-e", f"HOME={HOME}"])

    if not nested:
        args.extend(["-e", f"XDG_CONFIG_HOME={HOME}/.config"])

    xdg_data_dirs = os.environ.get("XDG_DATA_DIRS", "/usr/share/cosmic:/usr/share/pop:/usr/share")
    xdg_config_dirs = os.environ.get("XDG_CONFIG_DIRS", "/etc/xdg")
    args.extend(["-e", f"XDG_DATA_DIRS={xdg_data_dirs}"])
    args.extend(["-e", f"XDG_CONFIG_DIRS={xdg_config_dirs}"])

    # Build LAUNCH_ARGS string
    launch_args_parts = []
    for pkg, a in pkg_state["pkg_args"].items():
        if a:
            launch_args_parts.append(f"{pkg}:{a}")
    launch_args = " ".join(launch_args_parts)

    args.extend(["-e", f"LAUNCH_ARGS={launch_args}"])
    args.extend(["-e", f"SESSION_CGROUP={session_cgroup}"])
    args.extend(["-e", f"NEEDS_LOGIND={str(pkg_state['needs_logind']).lower()}"])

    if pkg_state["host_bins"]:
        args.extend(["-e", f"HOST_BINS={':'.join(pkg_state['host_bins'])}"])

    # Base mounts
    base_mounts = [
        "-v", f"/etc/passwd:/etc/passwd:ro",
        "-v", f"/etc/group:/etc/group:ro",
        "-v", f"/usr/share/pop:/usr/share/pop:ro",
        "-v", f"/run/dbus/system_bus_socket:/run/dbus/system_bus_socket",
        "-v", f"/media:/media:rw",
    ]
    if Path("/opt").exists():
        base_mounts.extend(["-v", "/opt:/host/opt:ro"])
    if Path("/snap").exists():
        base_mounts.extend(["-v", "/snap:/host/snap:ro"])
    if pkg_state["mount_host_libs"]:
        base_mounts.extend([
            "-v", "/usr/bin:/host/usr/bin:ro",
            "-v", "/usr/sbin:/host/usr/sbin:ro",
            "-v", "/usr/lib:/host/usr/lib:ro",
            "-v", "/usr/share:/host/usr/share:ro",
        ])
    args.extend(base_mounts)

    # Package-specific mounts
    args.extend(pkg_state["mount_args"])

    # XDG_RUNTIME_DIR mount
    if not nested and xdg_runtime_dir:
        args.extend(["-v", f"{xdg_runtime_dir}:{xdg_runtime_dir}"])

    # Config/data/cache mounts
    args.extend(["-v", f"{HOME}/.config:{HOME}/.config"])
    args.extend(["-v", f"{HOME}/.local:{HOME}/.local"])
    args.extend(["-v", f"{HOME}/.cache:{HOME}/.cache"])

    if nested and xdg_runtime_dir:
        args.extend(["-v", f"{xdg_runtime_dir}:/host-runtime:ro"])

    return args


def main():
    state = parse_args(sys.argv)
    pkg_state = load_package_configs(state["pkg_names"], SCRIPT_DIR)

    # Check nested session requirement
    if pkg_state["nested_session"] and not state["nested_requested"]:
        print()
        print("╔══════════════════════════════════════════════════════════════╗")
        print("║  EXPERIMENTAL: nested COSMIC session required")
        print("╚══════════════════════════════════════════════════════════════╝")
        print()
        print("This package needs a nested COSMIC session to run in a container.")
        print("To continue, re-run with --nested:")
        print(f"  {sys.argv[0]} {' '.join(sys.argv[1:])} --nested")
        print()
        sys.exit(1)

    # Ensure base images exist
    if not ensure_base_images(pkg_state["nested_session"]):
        sys.exit(1)

    # Print header
    nested = pkg_state["nested_session"]
    print("=" * 40)
    for i, pkg in enumerate(state["pkg_names"]):
        print(f" {pkg}:{state['branches'][i]} [{pkg_state['pkg_types'][i]}]")
    print(f" IMAGE: {state['image_tag']}")
    if nested:
        print(" MODE: nested session (EXPERIMENTAL)")
    if pkg_state["needs_logind"]:
        print(" LOGIND: yes (cgroup fix will be applied)")
    if pkg_state["needs_udev"]:
        print(" UDEV: yes (socket will be opened)")
    print("=" * 40)

    # Pre-cache sudo
    if pkg_state["needs_logind"]:
        if subprocess.run(["sudo", "-v"], check=False).returncode != 0:
            print("ERROR: sudo authentication required for cgroup fix. Aborting.")
            sys.exit(1)

    # Clean stale signal files
    signal_dir = Path(HOME) / ".local" / "share" / "cosmic-docker-signal"
    signal_file = signal_dir / "waiting"
    signal_file.unlink(missing_ok=True)

    # Compute container name
    if nested:
        container_name = f"cosmic-nested-{state['pkg_names'][0]}"
    else:
        container_name = f"cosmic-{state['pkg_names'][0]}"

    # Signal handler for clean shutdown on SIGTERM
    def shutdown_handler(signum, frame):
        print(f"\nReceived signal {signum}, cleaning up...")
        kill_container_processes(container_name, state["pkg_names"])
        container_rm_force(container_name)
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown_handler)

    # Remove existing container on rebuild
    if state["force_rebuild"]:
        container_rm_force(container_name)

    # Clean up orphaned processes from previous runs (--pid host lets them escape)
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Pid}}", container_name],
        capture_output=True, text=True, check=False,
    )
    if result.stdout.strip():
        print(f"Cleaning up orphaned processes from previous run...")
        kill_container_processes(container_name, state["pkg_names"])
        container_rm_force(container_name)

    # Build image
    build_image(
        state["image_tag"],
        " ".join(pkg_state["all_packages"]),
        ",".join(state["unique_branches"]),
        force=state["force_rebuild"],
        nested=nested,
        extra_packages=" ".join(pkg_state["extra_packages"]),
    )
    show_versions(state["image_tag"], " ".join(pkg_state["all_packages"]))

    # Classify packages
    daemon_idxs = [i for i, t in enumerate(pkg_state["pkg_types"]) if t == "daemon"]
    app_idxs = [i for i, t in enumerate(pkg_state["pkg_types"]) if t != "daemon"]

    # ── Container mode ──────────────────────────────────────────────
    if not nested:
        # Kill conflicting host daemons
        for i in daemon_idxs:
            daemon_kill(pkg_state["all_packages"][i])

        # Pre-launch fixes
        if pkg_state["needs_udev"]:
            udev_socket_fix()

        # Ensure host settings daemon is running
        result = subprocess.run(
            ["pgrep", "-f", "cosmic-settings-daemon"],
            capture_output=True, check=False,
        )
        if not result.stdout.strip():
            print("Starting host cosmic-settings-daemon for config propagation...")
            subprocess.Popen(
                ["cosmic-settings-daemon"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            time.sleep(2)
            result = subprocess.run(
                ["pgrep", "-f", "cosmic-settings-daemon"],
                capture_output=True, check=False,
            )
            if result.stdout.strip():
                print("  cosmic-settings-daemon started")
            else:
                print("  WARN: cosmic-settings-daemon failed to start")

    print()
    print("=" * 40)
    print(" LAUNCHING CONTAINER")
    print("=" * 40)

    # Build launch list: apps first, then daemons
    launch_pkgs = []
    for i in app_idxs:
        launch_pkgs.append(pkg_state["all_packages"][i])
    for i in daemon_idxs:
        launch_pkgs.append(pkg_state["all_packages"][i])

    # Resolve groups
    group_add_args = resolve_group_gids(pkg_state["groups"])

    # Compute session cgroup
    session_cgroup = ""
    if pkg_state["needs_logind"]:
        from lib.process import get_session_cgroup
        session_cgroup = get_session_cgroup() or ""

    # Check existing container
    state_str = container_state(container_name)
    if state_str == "running":
        print(f"Container {container_name} already running. Attaching...")
        container_logs_follow(container_name)
        return
    if state_str == "exited":
        print(f"Container {container_name} exists (stopped). Recreating...")
        subprocess.run(
            ["docker", "rm", container_name],
            capture_output=True, check=False,
        )

    # Build docker run args and launch
    docker_args = build_docker_run_args(state, pkg_state, session_cgroup, group_add_args, nested)
    container_run(container_name, state["image_tag"], docker_args, launch_pkgs)

    print("Waiting for container to start...")
    time.sleep(3)

    # Post-launch: cgroup fix
    if not nested and pkg_state["needs_logind"]:
        if wait_for_signal_file():
            cp = container_pid(container_name)
            if cp:
                cgroup_session_fix(cp)
            signal_file.unlink(missing_ok=True)
            time.sleep(0.5)
        else:
            print("WARN: Signal file not found after 15s — cgroup fix may have failed")

    print()
    print("=" * 40)
    print(" CONTAINER STATUS")
    print("=" * 40)
    container_status(container_name)

    # Wait for entrypoint setup to complete before running diagnostics
    print("Waiting for container setup to complete...")
    for _ in range(50):  # 5 seconds max
        result = subprocess.run(
            ["docker", "exec", container_name, "test", "-f", "/tmp/cosmic-setup-done"],
            capture_output=True, check=False,
        )
        if result.returncode == 0:
            break
        time.sleep(0.1)
    else:
        print("WARN: Setup signal not found after 5s — proceeding anyway")

    # Run diagnostics
    diagnostics_path = SCRIPT_DIR / "diagnostics.py"
    if diagnostics_path.exists():
        subprocess.run([sys.executable, str(diagnostics_path), container_name])

    print()
    print("=" * 40)
    print(f" Container running. Ctrl-C to detach.")
    print(f" Container '{container_name}' persists after detach.")
    print("=" * 40)

    # Follow logs — Ctrl-C detaches us, then we clean up
    try:
        container_logs_follow(container_name)
    except KeyboardInterrupt:
        print("\nDetaching from container...")

    # Kill all container processes (including daemonized ones that escaped to PID 1)
    kill_container_processes(container_name, state["pkg_names"])
    container_rm_force(container_name)

    # Restart host daemons we killed
    if not nested:
        for i in daemon_idxs:
            daemon_restart(pkg_state["all_packages"][i])


if __name__ == "__main__":
    main()
