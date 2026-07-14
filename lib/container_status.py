"""Container process tree display with cgroup info."""
import subprocess
from pathlib import Path


def _get_cgroup(pid):
    try:
        with open(f"/proc/{pid}/cgroup") as f:
            for line in f:
                if line.startswith("0::"):
                    return line.strip().split(":", 2)[2]
    except (FileNotFoundError, IndexError):
        pass
    return "?"


def _get_comm(pid):
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip()
    except FileNotFoundError:
        return "?"


def _get_children(pid):
    result = subprocess.run(
        ["ps", "--ppid", str(pid), "-o", "pid="],
        capture_output=True, text=True, check=False,
    )
    out = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line:
            try:
                out.append(int(line))
            except ValueError:
                pass
    return out


def container_status(name, container_pid=None):
    if container_pid is None:
        from .docker_ops import container_pid as get_pid
        container_pid = get_pid(name)

    if not container_pid:
        print("WARN: Could not determine container PID")
        return

    print(f"Entrypoint PID: {container_pid}")
    print("Entrypoint cgroup:")
    cgroup = _get_cgroup(container_pid)
    print(f"  {cgroup}")

    print("\nChild processes:")
    for p in _get_children(container_pid):
        comm = _get_comm(p)
        cg = _get_cgroup(p)
        print(f"  PID {p} ({comm}) -> {cg}")

    print("\nGrandchild processes:")
    for p in _get_children(container_pid):
        for gp in _get_children(p):
            comm = _get_comm(gp)
            cg = _get_cgroup(gp)
            print(f"  PID {gp} ({comm}) -> {cg}")
