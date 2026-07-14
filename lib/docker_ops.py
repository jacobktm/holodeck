"""Docker image build, container lifecycle, version display."""
import subprocess
import sys


def run(cmd, check=True, capture=False, input_data=None, **kwargs):
    result = subprocess.run(
        cmd, check=False, capture_output=capture, text=True,
        input=input_data, **kwargs,
    )
    if check and result.returncode != 0:
        print(f"Command failed: {' '.join(cmd)}", file=sys.stderr)
        if capture and result.stderr:
            print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return result


def image_exists(tag):
    result = run(["docker", "image", "inspect", tag], check=False, capture=True)
    return result.returncode == 0


def build_image(image_tag, packages_csv, branches_csv, force=False, nested=False, extra_packages=""):
    base_image = "pop-os:24.04-cosmic-latest" if nested else "pop-os:24.04-latest"

    if not force and image_exists(image_tag):
        print(f"Skipping build: image {image_tag} already exists. Pass 'rebuild' to force.")
        return

    print("=" * 40)
    print(f" BUILDING PR IMAGE: {image_tag}")
    print(f" BASE: {base_image}")
    print("=" * 40)

    branches = [b.strip() for b in branches_csv.split(",") if b.strip()]
    seen = set()
    unique = []
    for b in branches:
        if b not in seen:
            seen.add(b)
            unique.append(b)

    branch_sources = ""
    branch_pins = ""
    priority = 1002
    for branch in unique:
        branch_sources += (
            f"RUN printf 'X-Repolib-ID: popdev-{branch}\\\\n"
            f"X-Repolib-Name: Pop Development Branch {branch}\\\\n"
            f"Enabled: yes\\\\n"
            f"Types: deb\\\\n"
            f"URIs: http://apt.pop-os.org/staging/{branch}\\\\n"
            f"Suites: noble\\\\n"
            f"Components: main\\\\n"
            f"Signed-By: /etc/apt/keyrings/popdev-archive-keyring.gpg\\\\n"
            f"X-Repolib-Prefs: /etc/apt/preferences.d/pop-os-staging-{branch}\\\\n"
            f"' > /etc/apt/sources.list.d/popdev-{branch}.sources\n"
        )
        branch_pins += (
            f"RUN printf 'Package: *\\\\n"
            f"Pin: release o=pop-os-staging-{branch}\\\\n"
            f"Pin-Priority: {priority}\\\\n"
            f"' > /etc/apt/preferences.d/pop-os-staging-{branch}\n"
        )
        priority += 1

    extra = f" {extra_packages}" if extra_packages else ""
    dockerfile = f"""FROM {base_image}
ENV DEBIAN_FRONTEND=noninteractive

COPY lib/popdev-archive-keyring.gpg /etc/apt/keyrings/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

{branch_sources}{branch_pins}
RUN apt-get update
RUN apt-get full-upgrade -y --allow-downgrades
RUN apt-get install -y --allow-downgrades {packages_csv}{extra}
RUN rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/entrypoint.sh"]
"""

    result = subprocess.run(
        ["docker", "build", "--no-cache", "-t", image_tag, "-f", "-", "."],
        input=dockerfile, text=True, check=False,
    )
    if result.returncode != 0:
        print("Build failed!", file=sys.stderr)
        sys.exit(1)


def show_versions(image_tag, packages_csv):
    print()
    print("=" * 40)
    print(" PACKAGE VERSIONS")
    print("=" * 40)
    subprocess.run([
        "docker", "run", "--rm", "--entrypoint", "bash", image_tag,
        "-c",
        f"for pkg in {packages_csv}; do apt policy $pkg 2>/dev/null; echo; done",
    ])


def container_state(name):
    result = run(
        ["docker", "inspect", "--format", "{{.State.Status}}", name],
        check=False, capture=True,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return "missing"


def container_pid(name):
    result = run(
        ["docker", "inspect", "--format", "{{.State.Pid}}", name],
        check=False, capture=True,
    )
    if result.returncode == 0 and result.stdout.strip():
        try:
            return int(result.stdout.strip())
        except ValueError:
            pass
    return None


def container_rm_force(name):
    run(["docker", "rm", "-f", name], check=False, capture=True)


def container_logs_follow(name):
    """Follow container logs. Blocks until Ctrl-C or container stops."""
    subprocess.run(["docker", "logs", "-f", name])


def container_run(name, image_tag, args):
    """Run a container with the given docker args."""
    cmd = ["docker", "run", "-d", "--name", name] + args
    result = run(cmd, check=False, capture=True)
    if result.returncode != 0:
        print(f"Failed to start container: {result.stderr}", file=sys.stderr)
        sys.exit(1)
