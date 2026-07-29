use std::path::Path;
use crate::{btrfs, boot, config, mount};

const SYSTEM_OVERLAYS: &[&str] = &["init", "recovery"];

fn cfg() -> config::Config {
    config::Config::load()
}

fn ensure_pool(cfg: &config::Config) -> Result<(), String> {
    if !cfg.pool_mounted() {
        mount::mount_pool(&cfg.pool)?;
    }
    Ok(())
}

pub fn cmd_list() -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;

    let overlays = btrfs::list_overlays(&cfg)?;
    println!("{:<20} {:>8}  {}", "Overlay", "Size", "Type");
    println!("{}", "-".repeat(50));
    for ov in &overlays {
        let label = if ov.readonly { "readonly" } else { "writable" };
        println!("{:<20} {:>8}  {}", ov.name, ov.size, label);
    }
    // Also show @data if it exists
    let data = format!("{}/@data", cfg.pool);
    if Path::new(&data).is_dir() {
        let size = btrfs::get_size(&data).unwrap_or_default();
        println!("{:<20} {:>8}  {}", "@data", size, "writable");
    }
    Ok(())
}

pub fn cmd_list_names() -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;
    let overlays = btrfs::list_overlays(&cfg)?;
    for ov in &overlays {
        println!("{}", ov.name);
    }
    let data = format!("{}/@data", cfg.pool);
    if Path::new(&data).is_dir() {
        println!("@data");
    }
    Ok(())
}

pub fn cmd_status() -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;

    let active = btrfs::get_active_subvol(&cfg)
        .map_err(|e| format!("Failed to get boot config: {e}"))?;
    let active_name = active
        .as_deref()
        .and_then(|s| s.strip_prefix("@overlay-"))
        .unwrap_or("unknown");

    println!("Pool:     {}", cfg.pool);
    println!("Active:   {active_name}");
    println!();

    // Show boot health
    let counter_path = format!("{}/@data/boot-counter", cfg.pool);
    if let Ok(content) = std::fs::read_to_string(&counter_path) {
        if let Ok(count) = content.trim().parse::<u32>() {
            if count > 0 {
                println!("Health:   {} consecutive boot(s) since last successful boot", count);
                println!();
            }
        }
    }

    // Show rollback message if present
    let msg_path = format!("{}/@data/rollback-message", cfg.pool);
    if let Ok(msg) = std::fs::read_to_string(&msg_path) {
        let msg = msg.trim();
        if !msg.is_empty() {
            println!("=== Rollback Alert ===");
            println!("{}", msg);
            println!();
        }
    }

    println!("Overlays:");
    let overlays = btrfs::list_overlays(&cfg)?;
    for ov in &overlays {
        let marker = if ov.name == active_name {
            " ← active"
        } else {
            ""
        };
        println!("  {:<18} {:>8}  {}{}", ov.name, ov.size,
                 if ov.readonly { "ro" } else { "rw" }, marker);
    }
    Ok(())
}

pub fn cmd_create(name: &str, from: Option<&str>) -> Result<(), String> {
    if name == "base" || SYSTEM_OVERLAYS.contains(&name) {
        return Err(format!("Cannot create overlay '{name}': name is reserved"));
    }

    let cfg = cfg();
    ensure_pool(&cfg)?;

    let dst = cfg.overlay_path(name);
    if Path::new(&dst).exists() {
        return Err(format!("Overlay '{name}' already exists"));
    }

    let src = match from {
        Some(src_name) => {
            if src_name == "base" || src_name == "@base" {
                cfg.base_path()
            } else {
                cfg.overlay_path(src_name)
            }
        }
        None => {
            // Default: snapshot from current active overlay, or @base
            let active = btrfs::get_active_subvol(&cfg)
                .ok()
                .flatten()
                .map(|s| format!("{}/{}", cfg.pool, s));
            active.unwrap_or_else(|| cfg.base_path())
        }
    };

    if !Path::new(&src).exists() {
        return Err(format!("Source '{src}' not found"));
    }

    btrfs::snapshot(&src, &dst)?;
    println!("Created overlay '{name}' from {src}");
    println!("{dst}");
    Ok(())
}

pub fn cmd_delete(name: &str) -> Result<(), String> {
    if SYSTEM_OVERLAYS.contains(&name) {
        return Err(format!("Cannot delete {name}: it is a system overlay"));
    }

    let cfg = cfg();
    ensure_pool(&cfg)?;

    let dst = cfg.overlay_path(name);
    if !Path::new(&dst).exists() {
        return Err(format!("Overlay '{name}' not found"));
    }

    // Reject deletion of the currently running overlay
    let running = btrfs::get_running_subvol();
    if running.as_deref() == Some(&format!("@overlay-{name}")) {
        return Err(format!("Cannot delete overlay '{name}': it is the currently running system"));
    }

    // If this is the active boot overlay, revert boot to init first
    let active = btrfs::get_active_subvol(&cfg)
        .map_err(|e| format!("Failed to get boot config: {e}"))?;

    if let Some(ref a) = active {
        if *a == format!("@overlay-{name}") {
            let was_ro = boot::esp_remount("rw")?;
            boot::set_active_overlay(&cfg, "init")
                .map_err(|e| format!("Failed to revert boot entry: {e}"))?;
            if was_ro {
                boot::esp_remount("ro")?;
            }
            println!("Boot entry reverted to @overlay-init");
        }
    }

    btrfs::delete_subvol(&dst)?;
    println!("Deleted overlay '{name}'");
    Ok(())
}

pub fn cmd_reset(name: &str) -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;

    if name == "recovery" {
        return Err("Cannot reset recovery directly. Use 'reset-recovery' instead.".to_string());
    }

    let dst = if name == "init" {
        cfg.init_path()
    } else {
        if SYSTEM_OVERLAYS.contains(&name) {
            return Err(format!("Cannot reset {name}: it is a system overlay"));
        }
        cfg.overlay_path(name)
    };

    if !Path::new(&dst).exists() {
        return Err(format!("Overlay '{name}' not found"));
    }

    // Reject reset of the currently running overlay
    let running = btrfs::get_running_subvol();
    if running.as_deref() == Some(&format!("@overlay-{name}")) {
        return Err(format!("Cannot reset overlay '{name}': it is the currently running system"));
    }

    let src = if name == "init" {
        cfg.recovery_path()
    } else {
        let active = btrfs::get_active_subvol(&cfg)
            .ok()
            .flatten()
            .map(|s| format!("{}/{}", cfg.pool, s));
        active.unwrap_or_else(|| cfg.base_path())
    };

    if !Path::new(&src).exists() {
        return Err(format!("Source '{src}' not found"));
    }

    btrfs::delete_subvol(&dst)?;
    btrfs::snapshot(&src, &dst)?;
    println!("Reset overlay '{name}' from {src}");
    Ok(())
}

pub fn cmd_switch(name: &str) -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;

    // Clear any stale rollback message — user is deliberately switching
    let msg_path = format!("{}/@data/rollback-message", cfg.pool);
    let _ = std::fs::remove_file(&msg_path);

    let dst = cfg.overlay_path(name);
    if !Path::new(&dst).exists() {
        return Err(format!("Overlay '{name}' not found"));
    }

    let was_ro = boot::esp_remount("rw")?;

    let active = btrfs::get_active_subvol(&cfg)
        .map_err(|e| format!("Failed to get boot config: {e}"))?;

    // 1. Save real ESP state back to current overlay's /boot/efi
    //    (ensures A's copy is fresh if kernelstub hooks didn't sync back)
    if let Some(ref a) = active {
        let active_root = format!("{}/{}", cfg.pool, a);
        if Path::new(&active_root).is_dir() {
            sync_esp_to_overlay(&active_root, &cfg)?;
        }
    }

    // 2. Load new overlay's kernel/initrd onto the real ESP for next boot
    sync_overlay_to_esp(&dst, &cfg)?;

    // 3. Point boot entry to the new subvolume
    boot::set_active_overlay(&cfg, name)?;

    if was_ro {
        boot::esp_remount("ro")?;
    }

    println!("Boot entry updated to: @overlay-{name}");
    println!("Reboot to activate.");
    Ok(())
}

pub fn cmd_lock() -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;
    let base = cfg.base_path();
    if !Path::new(&base).exists() {
        return Err("Base system not found".to_string());
    }
    btrfs::set_property(&base, "ro", "true")?;
    println!("@base is now read-only. Use 'unlock' when done.");
    Ok(())
}

pub fn cmd_unlock() -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;
    let base = cfg.base_path();
    if !Path::new(&base).exists() {
        return Err("Base system not found".to_string());
    }
    btrfs::set_property(&base, "ro", "false")?;
    println!("@base is now writable.");
    Ok(())
}

pub fn cmd_reset_recovery() -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;
    let recovery = cfg.recovery_path();
    let src = cfg.base_path();
    if Path::new(&recovery).exists() {
        btrfs::delete_subvol(&recovery)?;
    }
    btrfs::snapshot(&src, &recovery)?;
    btrfs::set_property(&recovery, "ro", "true")?;
    println!("Recovery overlay recreated from @base (read-only)");
    Ok(())
}

pub fn cmd_clean_boot() -> Result<(), String> {
    let cfg = cfg();
    let removed = boot::clean_boot_entries(&cfg)?;
    if removed.is_empty() {
        println!("No stale boot entries found.");
    } else {
        println!("Removed {} stale entries:", removed.len());
        for r in &removed {
            println!("  - {r}");
        }
    }
    Ok(())
}

pub fn cmd_update_initramfs(args: &[String]) -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;

    let active = btrfs::get_active_subvol(&cfg)
        .map_err(|e| format!("Failed to get boot config: {e}"))?
        .ok_or("No active overlay configured")?;

    let root = format!("{}/{}", cfg.pool, active);
    if !Path::new(&root).is_dir() {
        return Err(format!("Active overlay not found: {active}"));
    }

    // Mount chroot (guard ensures cleanup on all paths)
    let ctx = mount::mount_chroot(&root)?;
    let _guard = mount::MountGuard::new(ctx);

    // Run update-initramfs inside chroot
    let status = std::process::Command::new("chroot")
        .arg(&root)
        .arg("update-initramfs")
        .args(args)
        .status()
        .map_err(|e| format!("chroot update-initramfs failed: {e}"))?;

    if !status.success() {
        return Err("update-initramfs failed".to_string());
    }

    // Find latest kernel in overlay's /boot
    let boot_dir = format!("{root}/boot");
    let mut kernels: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&boot_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("vmlinuz-") && !entry.path().is_symlink() {
                kernels.push(name);
            }
        }
    }
    kernels.sort();
    let latest = kernels.last().ok_or("No kernels found in overlay /boot")?;
    let version = latest.strip_prefix("vmlinuz-").unwrap_or(latest);

    // Find ESP kernel directory within the overlay's ESP copy
    let overlay_esp = format!("{root}/boot/efi");
    let esp_dir = boot::find_esp_dir(&overlay_esp)
        .ok_or("Cannot find ESP kernel directory in overlay".to_string())?;

    // Copy kernel/initrd to overlay's ESP copy, saving previous
    std::fs::create_dir_all(&esp_dir)
        .map_err(|e| format!("Failed to create {esp_dir}: {e}"))?;

    let kernel_src = format!("{boot_dir}/{latest}");
    let initrd_src = format!("{boot_dir}/initrd.img-{version}");

    // Save previous kernel/initrd before overwriting
    let prev_kernel = format!("{esp_dir}/vmlinuz-previous.efi");
    let prev_initrd = format!("{esp_dir}/initrd.img-previous");
    let cur_kernel = format!("{esp_dir}/vmlinuz.efi");
    let cur_initrd = format!("{esp_dir}/initrd.img");
    let _ = std::fs::copy(&cur_kernel, &prev_kernel);
    let _ = std::fs::copy(&cur_initrd, &prev_initrd);

    std::fs::copy(&kernel_src, &cur_kernel)
        .map_err(|e| format!("Failed to copy kernel: {e}"))?;
    std::fs::copy(&initrd_src, &cur_initrd)
        .map_err(|e| format!("Failed to copy initrd: {e}"))?;

    // Sync overlay's ESP copy to the real ESP
    let was_ro = boot::esp_remount("rw")?;
    sync_overlay_to_esp(&root, &cfg)?;
    if was_ro {
        boot::esp_remount("ro")?;
    }

    println!("update-initramfs complete for {version}. ESP synced.");
    Ok(())
}

fn sync_overlay_to_esp(overlay_root: &str, cfg: &config::Config) -> Result<(), String> {
    let overlay_esp = format!("{overlay_root}/boot/efi");
    let real_esp = cfg.esp_path();
    if !Path::new(&overlay_esp).is_dir() {
        return Ok(());
    }
    let status = std::process::Command::new("rsync")
        .args(["-a", &format!("{overlay_esp}/"), &format!("{real_esp}/")])
        .status()
        .map_err(|e| format!("rsync failed: {e}"))?;
    if !status.success() {
        return Err("Failed to sync overlay ESP to real ESP".to_string());
    }
    Ok(())
}

fn sync_esp_to_overlay(overlay_root: &str, cfg: &config::Config) -> Result<(), String> {
    let overlay_esp = format!("{overlay_root}/boot/efi");
    let real_esp = cfg.esp_path();
    std::fs::create_dir_all(&overlay_esp)
        .map_err(|e| format!("Failed to create {overlay_esp}: {e}"))?;
    let status = std::process::Command::new("rsync")
        .args(["-a", &format!("{real_esp}/"), &format!("{overlay_esp}/")])
        .status()
        .map_err(|e| format!("rsync failed: {e}"))?;
    if !status.success() {
        return Err("Failed to sync real ESP to overlay ESP".to_string());
    }
    Ok(())
}

fn forwarded_env_vars() -> Vec<(String, String)> {
    let keys = [
        "WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR",
        "DBUS_SESSION_BUS_ADDRESS",
        "DISPLAY",
        "PULSE_SERVER",
    ];
    keys.iter()
        .filter_map(|k| {
            std::env::var(k).ok().map(|v| (k.to_string(), v))
        })
        .collect()
}

fn build_env_args(envs: &[(String, String)]) -> Vec<String> {
    envs.iter().map(|(k, v)| format!("{k}={v}")).collect()
}

pub fn cmd_shell(name: &str, args: &[String]) -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;

    let root = if name == "@base" || name == "base" {
        cfg.base_path()
    } else if name == "@data" || name == "data" {
        format!("{}/{}", cfg.pool, "@data")
    } else {
        cfg.overlay_path(name)
    };

    if !Path::new(&root).is_dir() {
        return Err(format!("Overlay '{name}' not found at {root}"));
    }

    use std::io::IsTerminal;

    // Mount chroot (guard ensures cleanup on all paths)
    let ctx = mount::mount_chroot(&root)?;
    let _guard = mount::MountGuard::new(ctx);

    let envs = forwarded_env_vars();

    if !std::io::stdin().is_terminal() {
        // Non-interactive: pass env vars through sudo's KEY=val syntax
        let mut cmd = std::process::Command::new("chroot");
        cmd.arg(&root).arg("sudo");
        for (k, v) in &envs {
            cmd.arg(format!("{k}={v}"));
        }
        cmd.arg("-u").arg(&cfg.username);
        if !args.is_empty() {
            cmd.args(args);
        }
        let status = cmd.status()
            .map_err(|e| format!("chroot exec failed: {e}"))?;
        if !status.success() {
            return Err("Command failed".to_string());
        }
        return Ok(());
    }

    // Interactive: allocate PTY via script(1)
    // Pass env vars through sudo's KEY=val syntax (survives env_reset)
    let env_args = build_env_args(&envs);
    let env_prefix = if env_args.is_empty() {
        String::new()
    } else {
        format!("{} ", env_args.join(" "))
    };

    let shell_cmd = if args.is_empty() {
        format!("chroot {root} sudo {env_prefix}-u {} /bin/bash --login", cfg.username)
    } else {
        let joined: Vec<String> = args.iter().map(|a| {
            if a.contains(' ') {
                format!("'{a}'")
            } else {
                a.clone()
            }
        }).collect();
        format!("chroot {root} sudo {env_prefix}-u {} /bin/bash --login -c {}", cfg.username, joined.join(" "))
    };

    let status = std::process::Command::new("script")
        .args(["-q", "-c", &shell_cmd, "/dev/null"])
        .status()
        .map_err(|e| format!("script failed: {e}"))?;

    if !status.success() {
        return Err("Shell exited with error".to_string());
    }
    Ok(())
}

pub fn cmd_run(name: &str, args: &[String]) -> Result<(), String> {
    cmd_shell(name, args)
}
