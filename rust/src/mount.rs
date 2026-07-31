use std::process::Command;

pub struct MountContext {
    pub root: String,
    pub mounts: Vec<String>,
}

impl Drop for MountContext {
    fn drop(&mut self) {
        for mount in self.mounts.iter().rev() {
            Command::new("umount")
                .args(["-l", mount])
                .status()
                .ok();
        }
    }
}

/// Guard that ensures chroot mounts are cleaned up on drop
pub struct MountGuard {
    ctx: MountContext,
}

impl MountGuard {
    pub fn new(ctx: MountContext) -> Self {
        MountGuard { ctx }
    }

    pub fn root(&self) -> &str {
        &self.ctx.root
    }

    pub fn unmount(mut self) {
        // Take ownership and drop, which triggers MountContext::drop
        drop(self);
    }
}

pub fn mount_chroot(root: &str) -> Result<MountContext, String> {
    let mut ctx = MountContext {
        root: root.to_string(),
        mounts: Vec::new(),
    };

    let bind_mounts = [
        ("/proc", "/proc"),
        ("/sys", "/sys"),
        ("/dev", "/dev"),
        ("/dev/pts", "/dev/pts"),
        ("/run", "/run"),
        ("/tmp", "/tmp"),
    ];

    for (src, dst) in &bind_mounts {
        let target = format!("{root}{dst}");
        if !std::path::Path::new(&target).exists() {
            std::fs::create_dir_all(&target)
                .map_err(|e| format!("Failed to create {target}: {e}"))?;
        }
        let status = Command::new("mount")
            .args(["--bind", src, &target])
            .status()
            .map_err(|e| format!("mount --bind {src} failed: {e}"))?;
        if status.success() {
            ctx.mounts.push(target);
        }
    }

    // Copy resolv.conf for DNS inside chroot
    let resolv_dst = format!("{root}/etc/resolv.conf");
    let _ = std::fs::copy("/etc/resolv.conf", &resolv_dst);

    Ok(ctx)
}

/// Bind-mount an overlay's own /boot/efi into the chroot.
/// The mount is tracked in ctx for cleanup on drop.
pub fn mount_overlay_esp(ctx: &mut MountContext, overlay_root: &str) -> Result<(), String> {
    let esp_src = format!("{overlay_root}/boot/efi");
    let esp_target = format!("{}/boot/efi", ctx.root);
    if !std::path::Path::new(&esp_src).is_dir() {
        return Err("Overlay has no /boot/efi directory".to_string());
    }
    std::fs::create_dir_all(&esp_target)
        .map_err(|e| format!("Failed to create {esp_target}: {e}"))?;
    let status = Command::new("mount")
        .args(["--bind", &esp_src, &esp_target])
        .status()
        .map_err(|e| format!("mount --bind {esp_src} failed: {e}"))?;
    if !status.success() {
        return Err("Failed to bind-mount overlay ESP".to_string());
    }
    ctx.mounts.push(esp_target);
    Ok(())
}

/// Bind-mount @data user directories, dotfiles, and immutable system data (hooks, CLI, etc.)
/// into the overlay chroot. User files go under \$home; immutable files go under system paths.
pub fn mount_data_dirs(ctx: &mut MountContext, data_path: &str, root: &str, username: &str) -> Result<(), String> {
    if !std::path::Path::new(data_path).is_dir() {
        return Ok(());
    }

    let home_dir = format!("{root}/home/{username}");

    // ── User data directories ──

    if !std::path::Path::new(&home_dir).is_dir() {
        std::fs::create_dir_all(&home_dir)
            .map_err(|e| format!("Failed to create {home_dir}: {e}"))?;
    }

    for dir in &["Documents", "Downloads", "Pictures", "Videos", "Music"] {
        let src = format!("{data_path}/{dir}");
        if !std::path::Path::new(&src).is_dir() {
            continue;
        }
        let dst = format!("{home_dir}/{dir}");
        std::fs::create_dir_all(&dst)
            .map_err(|e| format!("Failed to create {dst}: {e}"))?;
        let status = std::process::Command::new("mount")
            .args(["--bind", &src, &dst])
            .status()
            .map_err(|e| format!("mount --bind {src} {dst} failed: {e}"))?;
        if status.success() {
            ctx.mounts.push(dst);
        }
    }

    // ── Dotfiles ──

    for file in &[".bash_history", ".profile", ".bashrc", ".gitconfig"] {
        let src = format!("{data_path}/{file}");
        if !std::path::Path::new(&src).is_file() {
            continue;
        }
        let dst = format!("{home_dir}/{file}");
        if let Some(parent) = std::path::Path::new(&dst).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if !std::path::Path::new(&dst).exists() {
            let _ = std::fs::write(&dst, "");
        }
        let status = std::process::Command::new("mount")
            .args(["--bind", &src, &dst])
            .status()
            .map_err(|e| format!("mount --bind {src} {dst} failed: {e}"))?;
        if status.success() {
            ctx.mounts.push(dst);
        }
    }

    // ── Immutable system data ──
    // Replicates immutable-data-mount.service inside the chroot,
    // so hooks, CLI, completions, and man page are the @data versions.

    let imm_src = format!("{data_path}/immutable");
    if !std::path::Path::new(&imm_src).is_dir() {
        return Ok(());
    }

    // Hooks — bind-mount the entire hooks directory so immutable-hook-reinstall
    // inside the chroot gets the latest @data versions.
    let hooks_src = format!("{imm_src}/hooks");
    let hooks_dst = format!("{root}/usr/lib/immutable/hooks");
    if std::path::Path::new(&hooks_src).is_dir() {
        std::fs::create_dir_all(&hooks_dst)
            .map_err(|e| format!("Failed to create {hooks_dst}: {e}"))?;
        let status = std::process::Command::new("mount")
            .args(["--bind", &hooks_src, &hooks_dst])
            .status()
            .map_err(|e| format!("mount --bind {hooks_src} failed: {e}"))?;
        if status.success() {
            ctx.mounts.push(hooks_dst);
        }
    }

    // CLI binary
    let bin_src = format!("{imm_src}/bin/immutable");
    let bin_dst = format!("{root}/usr/local/bin/immutable");
    if std::path::Path::new(&bin_src).is_file() {
        if let Some(parent) = std::path::Path::new(&bin_dst).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if !std::path::Path::new(&bin_dst).exists() {
            let _ = std::fs::write(&bin_dst, "");
        }
        let status = std::process::Command::new("mount")
            .args(["--bind", &bin_src, &bin_dst])
            .status()
            .map_err(|e| format!("mount --bind {bin_src} failed: {e}"))?;
        if status.success() {
            ctx.mounts.push(bin_dst);
        }
    }

    // Bash completions
    let comp_src = format!("{imm_src}/bash-completion/immutable");
    let comp_dst = format!("{root}/usr/share/bash-completion/completions/immutable");
    if std::path::Path::new(&comp_src).is_file() {
        if let Some(parent) = std::path::Path::new(&comp_dst).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if !std::path::Path::new(&comp_dst).exists() {
            let _ = std::fs::write(&comp_dst, "");
        }
        let status = std::process::Command::new("mount")
            .args(["--bind", &comp_src, &comp_dst])
            .status()
            .map_err(|e| format!("mount --bind {comp_src} failed: {e}"))?;
        if status.success() {
            ctx.mounts.push(comp_dst);
        }
    }

    // Man page
    let man_src = format!("{imm_src}/man/immutable.1.gz");
    let man_dst = format!("{root}/usr/share/man/man1/immutable.1.gz");
    if std::path::Path::new(&man_src).is_file() {
        if let Some(parent) = std::path::Path::new(&man_dst).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if !std::path::Path::new(&man_dst).exists() {
            let _ = std::fs::write(&man_dst, "");
        }
        let status = std::process::Command::new("mount")
            .args(["--bind", &man_src, &man_dst])
            .status()
            .map_err(|e| format!("mount --bind {man_src} failed: {e}"))?;
        if status.success() {
            ctx.mounts.push(man_dst);
        }
    }

    Ok(())
}

pub fn unmount_chroot(ctx: &MountContext) {
    for mount in ctx.mounts.iter().rev() {
        Command::new("umount")
            .args(["-l", mount])
            .status()
            .ok();
    }
}

pub fn pool_mounted(pool: &str) -> bool {
    let output = Command::new("findmnt")
        .args(["-no", "TARGET", pool])
        .output();
    match output {
        Ok(out) => !out.stdout.is_empty(),
        Err(_) => false,
    }
}

pub fn mount_pool(pool: &str) -> Result<(), String> {
    if pool_mounted(pool) {
        return Ok(());
    }
    let output = Command::new("findmnt")
        .args(["-no", "SOURCE", "--df", "/"])
        .output()
        .map_err(|e| format!("findmnt failed: {e}"))?;
    let source = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if source.is_empty() {
        return Err("Cannot determine root device".to_string());
    }
    let status = Command::new("mount")
        .args(["-t", "btrfs", "-o", "subvolid=5", &source, pool])
        .status()
        .map_err(|e| format!("mount pool failed: {e}"))?;
    if !status.success() {
        return Err("Failed to mount pool".to_string());
    }
    Ok(())
}
