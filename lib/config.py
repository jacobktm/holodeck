"""Parse package TOML configs."""
import tomllib
from pathlib import Path
from dataclasses import dataclass, field


@dataclass
class Mount:
    host: str
    container: str
    options: str = "ro"


@dataclass
class PackageConfig:
    name: str
    type: str = "app"
    needs_logind: bool = False
    needs_udev: bool = False
    nested_session: bool = False
    mount_host_libs: bool = False
    args: list = field(default_factory=list)
    extra_packages: list = field(default_factory=list)
    groups: list = field(default_factory=list)
    host_bins: list = field(default_factory=list)
    mounts: list = field(default_factory=list)


def load_config(toml_path: Path) -> PackageConfig:
    with open(toml_path, "rb") as f:
        cfg = tomllib.load(f)

    mounts = []
    for m in cfg.get("mounts", []):
        mounts.append(Mount(
            host=m["host"],
            container=m["container"],
            options=m.get("options", "ro"),
        ))

    return PackageConfig(
        name=toml_path.parent.name,
        type=cfg.get("type", "app"),
        needs_logind=cfg.get("needs_logind", False),
        needs_udev=cfg.get("needs_udev", False),
        nested_session=cfg.get("nested_session", False),
        mount_host_libs=cfg.get("mount_host_libs", False),
        args=cfg.get("args", []),
        extra_packages=cfg.get("extra_packages", []),
        groups=cfg.get("groups", []),
        host_bins=cfg.get("host_bins", []),
        mounts=mounts,
    )
