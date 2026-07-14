"""Process tree management with psutil, cgroup fixes, daemon lifecycle."""
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

try:
    import psutil
except ImportError:
    psutil = None


def get_session_cgroup():
    """Get the host session cgroup path from /proc/self/cgroup."""
    try:
        with open("/proc/self/cgroup") as f:
            for line in f:
                if line.startswith("0::"):
                    return line.strip().split(":", 2)[2]
    except (FileNotFoundError, IndexError):
        pass
    return None


def get_pid_cgroup(pid):
    """Get the cgroup path for a PID."""
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            for line in f:
                if line.startswith("0::"):
                    return line.strip().split(":", 2)[2]
    except (FileNotFoundError, IndexError):
        pass
    return None


def cgroup_session_fix(container_pid):
    """Move all container processes into the host session cgroup.

    Must be run as root (sudo).
    """
    if not container_pid:
        print("WARN: No container PID provided, skipping cgroup fix")
        return

    session_cgroup = get_session_cgroup()
    if not session_cgroup:
        print("WARN: Could not determine session cgroup")
        return

    docker_cgroup = get_pid_cgroup(container_pid)
    if not docker_cgroup:
        print(f"WARN: Could not determine Docker cgroup for PID {container_pid}")
        return

    print(f"Cgroup fix: moving PIDs from {docker_cgroup} -> {session_cgroup}")

    procs_path = Path(f"/sys/fs/cgroup{docker_cgroup}/cgroup.procs")
    target_path = Path(f"/sys/fs/cgroup{session_cgroup}/cgroup.procs")

    if not procs_path.exists():
        print(f"WARN: {procs_path} not found")
        return

    moved = 0
    for line in procs_path.read_text().splitlines():
        pid_str = line.strip()
        if not pid_str:
            continue
        try:
            subprocess.run(
                ["sudo", "tee", str(target_path)],
                input=(pid_str + "\n").encode(),
                check=True,
                capture_output=True,
            )
            moved += 1
        except subprocess.CalledProcessError:
            pass

    print(f"  -> Moved {moved} process(es)")


def kill_process_tree(pid, sig=signal.SIGKILL):
    """Kill a process and all its descendants."""
    if psutil is not None:
        try:
            parent = psutil.Process(pid)
            for child in parent.children(recursive=True):
                try:
                    child.kill()
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    pass
            parent.kill()
        except psutil.NoSuchProcess:
            pass
    else:
        # Fallback without psutil
        try:
            subprocess.run(["pkill", "-P", str(pid)], check=False, capture_output=True)
            os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            pass


def kill_by_name_pattern(pattern):
    """Kill processes matching a name pattern (for orphan cleanup)."""
    if psutil is not None:
        killed = 0
        for proc in psutil.process_iter(["pid", "name", "cmdline"]):
            try:
                cmdline = " ".join(proc.info["cmdline"] or [])
                if pattern in cmdline:
                    proc.kill()
                    killed += 1
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        return killed
    else:
        result = subprocess.run(
            ["pkill", "-f", pattern], check=False, capture_output=True,
        )
        return 0 if result.returncode != 0 else 1


def daemon_kill(name):
    """Kill a host daemon by name, waiting for it to exit."""
    result = subprocess.run(
        ["pgrep", "-f", name], capture_output=True, text=True, check=False,
    )
    pids_str = result.stdout.strip()
    if not pids_str:
        return

    print(f"Killing host {name} (PIDs: {pids_str}) to avoid D-Bus name conflict...")
    for pid_str in pids_str.splitlines():
        pid_str = pid_str.strip()
        if pid_str:
            try:
                os.kill(int(pid_str), signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass

    # Wait up to 5 seconds for exit
    for _ in range(10):
        time.sleep(0.5)
        result = subprocess.run(
            ["pgrep", "-f", name], capture_output=True, text=True, check=False,
        )
        if not result.stdout.strip():
            break

    result = subprocess.run(
        ["pgrep", "-f", name], capture_output=True, text=True, check=False,
    )
    if result.stdout.strip():
        print(f"  WARN: {name} did not exit cleanly")
    else:
        print(f"  {name} stopped")


def daemon_restart(name):
    """Restart a host daemon that was previously killed."""
    result = subprocess.run(
        ["pgrep", "-f", name], capture_output=True, text=True, check=False,
    )
    if result.stdout.strip():
        print(f"  {name} already running")
        return

    print(f"Restarting host {name}...")
    try:
        subprocess.Popen(
            [name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except FileNotFoundError:
        print(f"  WARN: {name} binary not found")
        return

    time.sleep(2)
    result = subprocess.run(
        ["pgrep", "-f", name], capture_output=True, text=True, check=False,
    )
    if result.stdout.strip():
        print(f"  {name} restarted")
    else:
        print(f"  WARN: {name} failed to restart")


def kill_container_processes(container_name):
    """Kill ALL processes belonging to a container using psutil.

    With --pid host, daemonized processes (like cosmic-files) get reparented
    to PID 1 and escape the entrypoint's process group. This function walks
    the full process tree and kills anything in the container's cgroup.
    """
    if psutil is None:
        # Fallback: docker kill + pkill by entrypoint path
        subprocess.run(["docker", "kill", container_name],
                       capture_output=True, check=False)
        return

    # Get the container's entrypoint PID from Docker
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{.State.Pid}}", container_name],
        capture_output=True, text=True, check=False,
    )
    try:
        entrypoint_pid = int(result.stdout.strip())
    except (ValueError, AttributeError):
        entrypoint_pid = None

    if not entrypoint_pid:
        return

    # Find the container's docker cgroup
    docker_cgroup = get_pid_cgroup(entrypoint_pid)
    if not docker_cgroup:
        return

    print(f"Cleaning up container processes (cgroup: {docker_cgroup})...")

    # Kill ALL processes in the container's cgroup
    killed = 0
    for proc in psutil.process_iter(["pid", "cmdline"]):
        try:
            proc_cgroup = get_pid_cgroup(proc.pid)
            if proc_cgroup and docker_cgroup in proc_cgroup:
                proc.kill()
                killed += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass

    # Also kill by entrypoint PID tree (catches reparented processes)
    try:
        parent = psutil.Process(entrypoint_pid)
        for child in parent.children(recursive=True):
            try:
                child.kill()
                killed += 1
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass
        parent.kill()
        killed += 1
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        pass

    # Final sweep: kill any process whose cmdline matches the container's apps
    # This catches daemonized processes that escaped to PID 1
    result = subprocess.run(
        ["docker", "inspect", "--format",
         "{{.Config.Entrypoint}} {{.Config.Cmd}}", container_name],
        capture_output=True, text=True, check=False,
    )

    # Give processes a moment to die
    time.sleep(0.5)

    # Verify cleanup
    remaining = 0
    for proc in psutil.process_iter(["pid"]):
        try:
            proc_cgroup = get_pid_cgroup(proc.pid)
            if proc_cgroup and docker_cgroup in proc_cgroup:
                remaining += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass

    if remaining:
        print(f"  {killed} killed, {remaining} still alive (will be reaped by docker rm)")
    else:
        print(f"  {killed} process(es) killed")
