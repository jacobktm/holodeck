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

pub fn mount_chroot(root: &str, overlay_esp: bool) -> Result<MountContext, String> {
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

    // ESP: mount overlay's own copy or real ESP
    let esp_src = if overlay_esp {
        let candidate = format!("{root}/boot/efi");
        if std::path::Path::new(&format!("{candidate}/loader/entries/immutable.conf")).exists() {
            candidate
        } else {
            "/boot/efi".to_string()
        }
    } else {
        "/boot/efi".to_string()
    };
    let esp_target = format!("{root}/boot/efi");
    if !std::path::Path::new(&esp_target).exists() {
        std::fs::create_dir_all(&esp_target)
            .map_err(|e| format!("Failed to create {esp_target}: {e}"))?;
    }
    let status = Command::new("mount")
        .args(["--bind", &esp_src, &esp_target])
        .status()
        .map_err(|e| format!("mount --bind {esp_src} failed: {e}"))?;
    if status.success() {
        ctx.mounts.push(esp_target);
    }

    // Copy resolv.conf for DNS inside chroot
    let resolv_dst = format!("{root}/etc/resolv.conf");
    let _ = std::fs::copy("/etc/resolv.conf", &resolv_dst);

    Ok(ctx)
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
