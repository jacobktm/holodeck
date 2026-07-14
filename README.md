# holodeck

Docker-based testing and diagnostics for Linux desktop packages.

Run package PRs in isolated containers with host D-Bus, Wayland, and cgroup integration — realistic testing without touching your host system.

## Quick Start

```bash
git clone git@github.com:jacobktm/holodeck.git
cd holodeck
./test-cosmic-pr.sh cosmic-files:testing-cosmic-files-pr1885 rebuild
```

On first run, holodeck automatically:
1. Creates a Python virtual environment and installs dependencies
2. Builds the base Docker images (`pop-os:24.04-latest`)
3. Builds a PR image with the specified package and branch
4. Launches the container with host integration

## Usage

```
./test-cosmic-pr.sh <pkg:branch,...> [rebuild] [--nested]
```

### Examples

```bash
# Test a single package PR
./test-cosmic-pr.sh cosmic-files:testing-cosmic-files-pr1885 rebuild

# Test with a different branch name
./test-cosmic-pr.sh cosmic-settings:my-feature-branch rebuild

# Test multiple packages together
./test-cosmic-pr.sh "cosmic-settings:pr-2068,cosmic-settings-daemon:daemon-branch" --nested
```

### Flags

| Flag | Description |
|------|-------------|
| `rebuild` | Force rebuild the Docker image (otherwise reuses existing) |
| `--nested` | Run a full nested COSMIC session inside the container (experimental) |

## How It Works

holodeck builds Docker images with Pop!_OS staging apt repos for specific package branches, then launches containers with deep host integration:

- **D-Bus session bus** — shared with the host for daemon communication
- **Wayland socket** — for GPU-accelerated rendering
- **cgroup membership** — processes are moved into the user's logind session for polkit authorization (USB mounting, brightness control, etc.)
- **Device access** — GPU, FUSE, backlight, input devices
- **Filesystem mounts** — home directory, config, fonts, icons, applications

### Container Lifecycle

1. Host builds PR image from base + staging repos
2. Container starts, entrypoint waits for host-side cgroup fix
3. Host moves container processes into user's session cgroup
4. Host signals entrypoint to proceed
5. Entrypoint launches daemons, then apps
6. Diagnostics run automatically
7. Ctrl-C detaches; container persists for reattachment

### Package Configuration

Each package has a `packages/<name>/config.toml` declaring everything the container needs:

```toml
type = "app"                          # "app" or "daemon"
needs_logind = true                   # requires cgroup session fix
needs_udev = false                    # requires udev socket fix
args = ["HOME"]                       # launch arguments
extra_packages = ["dbus", "fuse3"]    # additional apt packages
groups = ["render", "video"]          # host groups to add

[[mounts]]
host = "HOME"
container = "HOME"
options = "rw"
```

## Diagnostics

Run diagnostics independently on a running container:

```bash
# Host checks only
./diagnostics.py

# Host + container checks
./diagnostics.py cosmic-cosmic-files

# Full checks including build artifacts
./diagnostics.py --full cosmic-cosmic-files
```

Diagnostics include:
- Docker and base image status
- GPU, Wayland, D-Bus connectivity
- Cgroup membership and logind session access
- GIO volume detection and mount testing
- polkit authorization chain verification
- Host and container log analysis

## Project Structure

```
holodeck/
├── test-cosmic-pr.sh     # Entry point (auto-creates venv and base images)
├── setup.sh              # Python environment setup
├── cosmic_test.py        # Main orchestrator
├── diagnostics.py        # Diagnostic suite
├── entrypoint.sh         # Container entrypoint (runs inside Docker)
├── lib/
│   ├── config.py         # TOML config parsing
│   ├── docker_ops.py     # Docker build and lifecycle
│   ├── process.py        # psutil process management and cgroup fix
│   ├── container_status.py
│   └── udev.py
├── packages/             # Per-package TOML configs
│   ├── cosmic-files/
│   ├── cosmic-settings/
│   └── cosmic-settings-daemon/
└── base/                 # Base Docker images
    ├── Dockerfile
    └── Dockerfile.cosmic
```

## Requirements

- Linux with Docker
- Python 3.11+ (for `tomllib`)
- COSMIC desktop session (for Wayland/D-Bus integration)
- Sudo access (for cgroup session fix)
