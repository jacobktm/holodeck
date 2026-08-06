use std::path::Path;
use crate::{btrfs, boot, config, mount, pty};

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

    // Show last base-update result if present
    let ub_path = format!("{}/@data/update-base-result", cfg.pool);
    if let Ok(res) = std::fs::read_to_string(&ub_path) {
        let res = res.trim();
        if !res.is_empty() {
            println!("=== Base Update ===");
            println!("{}", res);
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
    if !is_valid_overlay_name(name) || SYSTEM_OVERLAYS.contains(&name) {
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

    // Customize overlay's ESP immutable.conf to point to the new subvol
    let new_subvol = format!("@overlay-{name}");
    customize_overlay_esp(&dst, &new_subvol, &cfg, &src);

    println!("Created overlay '{name}' from {src}");
    println!("{dst}");
    Ok(())
}

fn is_valid_overlay_name(name: &str) -> bool {
    !name.is_empty() && !name.starts_with('@') && name != "base" && name != "data"
}

pub(crate) fn customize_overlay_esp(overlay_root: &str, subvol: &str, cfg: &config::Config, source: &str) {
    let overlay_esp = format!("{overlay_root}/boot/efi");

    // Seed the new overlay's ESP copy from the source's ESP truth:
    //   - if the source is the currently active overlay, its local ESP copy lags
    //     the real ESP (kernel postinst hooks write only to the real ESP; the
    //     local copy is refreshed on `switch`), so seed from the real ESP.
    //   - otherwise the source's local ESP copy matches its own module lineage
    //     and must be used, or the overlay would boot a kernel whose
    //     /usr/lib/modules aren't present in its rootfs.
    let active = btrfs::get_active_subvol(cfg).ok().flatten();
    let is_active_source = active
        .map(|a| source == format!("{}/{}", cfg.pool, a))
        .unwrap_or(false);
    let seed = if is_active_source {
        cfg.esp_path().to_string()
    } else {
        format!("{source}/boot/efi")
    };

    if Path::new(&seed).is_dir() {
        let _ = std::process::Command::new("rsync")
            .args(["-a", &format!("{seed}/"), &format!("{overlay_esp}/")])
            .status();
    }
    // Fix immutable.conf to point to the correct subvol
    let conf_path = format!("{overlay_esp}/loader/entries/immutable.conf");
    if let Ok(content) = std::fs::read_to_string(&conf_path) {
        let updated: Vec<String> = content
            .lines()
            .map(|line| {
                if line.starts_with("options ") && line.contains("subvol=") {
                    if let Some(start) = line.find("subvol=") {
                        let before = &line[..start];
                        let after = line[start..].split_whitespace().nth(0).unwrap_or("");
                        let rest = &line[start + after.len()..];
                        format!("{before}subvol={subvol}{rest}")
                    } else {
                        line.to_string()
                    }
                } else {
                    line.to_string()
                }
            })
            .collect();
        let _ = std::fs::write(&conf_path, updated.join("\n") + "\n");
    }
    // Set loader.conf to default to immutable.conf
    let loader_conf_path = format!("{overlay_esp}/loader/loader.conf");
    let _ = std::fs::write(&loader_conf_path, "default immutable.conf\ntimeout 0\nconsole-mode max\n");
}

/// UUID of the btrfs pool that `/` lives on (shared by all subvolumes).
fn pool_fs_uuid() -> Option<String> {
    let out = std::process::Command::new("findmnt")
        .args(["-no", "UUID", "/"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let uuid = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if uuid.is_empty() { None } else { Some(uuid) }
}

/// The `Pop_OS-<uuid>` kernel-dir name for an ESP clone: an existing
/// `Pop_OS-*` directory if present, else the pool UUID.
fn esp_uuid(overlay_esp: &str) -> Option<String> {
    let efi_dir = format!("{overlay_esp}/EFI");
    if let Ok(mut entries) = std::fs::read_dir(&efi_dir) {
        if let Some(found) = entries.find_map(|e| {
            e.ok().and_then(|e| {
                let n = e.file_name();
                let n = n.to_string_lossy();
                n.strip_prefix("Pop_OS-").map(|s| s.to_string())
            })
        }) {
            return Some(found);
        }
    }
    pool_fs_uuid()
}

/// Ensure an overlay's local ESP copy is a complete, self-sufficient ESP for
/// that overlay before it is mounted into a shell: create the boot/efi
/// skeleton, seed a kernel/initrd from the overlay's own /boot when the copy
/// lacks one, and (re)write immutable.conf/loader.conf to point at this
/// overlay's subvol. Idempotent; never re-seeds wholesale from another source.
pub(crate) fn ensure_overlay_esp(overlay_root: &str, subvol: &str) -> Result<(), String> {
    let boot_dir = format!("{overlay_root}/boot");
    if !Path::new(&boot_dir).is_dir() {
        // Not a bootable overlay (e.g. @data): nothing to set up.
        return Ok(());
    }
    let overlay_esp = format!("{boot_dir}/efi");
    std::fs::create_dir_all(format!("{overlay_esp}/loader/entries"))
        .map_err(|e| format!("Failed to create {overlay_esp}: {e}"))?;

    let uuid = esp_uuid(&overlay_esp).unwrap_or_else(|| "unknown".to_string());
    let esp_dir = match boot::find_esp_dir(&overlay_esp) {
        Some(d) => d,
        None => {
            let d = format!("{overlay_esp}/EFI/Pop_OS-{uuid}");
            std::fs::create_dir_all(&d)
                .map_err(|e| format!("Failed to create {d}: {e}"))?;
            d
        }
    };

    // Seed the kernel/initrd from the overlay's own /boot if the copy lacks
    // them, so postinst hooks always have a target to update.
    if !Path::new(&format!("{esp_dir}/vmlinuz.efi")).is_file()
        || !Path::new(&format!("{esp_dir}/initrd.img")).is_file()
    {
        if let Err(e) = boot::sync_kernel_initrd(overlay_root, &esp_dir) {
            println!("immutable: warning: could not seed ESP kernel: {e}");
        }
    }

    // Boot entry must point at this overlay's subvol.
    let conf_path = format!("{overlay_esp}/loader/entries/immutable.conf");
    let conf_ok = std::fs::read_to_string(&conf_path)
        .map(|c| {
            c.lines()
                .any(|l| l.starts_with("options ") && l.contains(&format!("subvol={subvol}")))
        })
        .unwrap_or(false);
    if !conf_ok {
        let content = format!(
            "title Immutable\nlinux /EFI/Pop_OS-{uuid}/vmlinuz.efi\ninitrd /EFI/Pop_OS-{uuid}/initrd.img\noptions root=UUID={uuid} ro quiet splash rootflags=subvol={subvol}\n"
        );
        std::fs::write(&conf_path, content)
            .map_err(|e| format!("Failed to write {conf_path}: {e}"))?;
    }

    // loader.conf defaults to immutable.conf.
    let loader_conf = format!("{overlay_esp}/loader/loader.conf");
    let loader_ok = std::fs::read_to_string(&loader_conf)
        .map(|c| c.lines().any(|l| l.starts_with("default ") && l.contains("immutable.conf")))
        .unwrap_or(false);
    if !loader_ok {
        std::fs::write(&loader_conf, "default immutable.conf\ntimeout 0\nconsole-mode max\n")
            .map_err(|e| format!("Failed to write {loader_conf}: {e}"))?;
    }

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
            // Validate @overlay-init's ESP before pointing to it
            boot::validate_overlay_esp(&cfg.overlay_path("init"), "@overlay-init")?;
            // Sync @overlay-init's ESP to real ESP (includes correct immutable.conf)
            sync_overlay_to_esp(&cfg.overlay_path("init"), &cfg)?;
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
    if !is_valid_overlay_name(name) {
        return Err(format!("Cannot reset '{name}': name is reserved"));
    }

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
    let subvol = if name == "init" {
        "@overlay-init".to_string()
    } else {
        format!("@overlay-{name}")
    };
    customize_overlay_esp(&dst, &subvol, &cfg, &src);
    println!("Reset overlay '{name}' from {src}");
    Ok(())
}

pub fn cmd_switch(name: &str) -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;

    // Clear any stale rollback message — user is deliberately switching
    let msg_path = format!("{}/@data/rollback-message", cfg.pool);
    let _ = std::fs::remove_file(&msg_path);

    if !is_valid_overlay_name(name) {
        return Err(format!("Cannot switch to '{name}': name is reserved"));
    }

    let dst = cfg.overlay_path(name);
    if !Path::new(&dst).exists() {
        return Err(format!("Overlay '{name}' not found"));
    }

    // Validate new overlay's ESP BEFORE touching the real ESP
    boot::validate_overlay_esp(&dst, &format!("@overlay-{name}"))?;

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

    // 2. Load new overlay's ESP onto the real ESP for next boot
    //    (rsync copies immutable.conf with the correct subvol= already)
    sync_overlay_to_esp(&dst, &cfg)?;

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
    customize_overlay_esp(&recovery, "@overlay-recovery", &cfg, &src);
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

    // Mount chroot (no ESP bind mount — overlay's own /boot/efi is accessible directly)
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

    // Validate overlay ESP BEFORE touching the real ESP
    boot::validate_overlay_esp(&root, &active)?;

    // Sync overlay's ESP copy to the real ESP
    let was_ro = boot::esp_remount("rw")?;
    sync_overlay_to_esp(&root, &cfg)?;
    if was_ro {
        boot::esp_remount("ro")?;
    }

    println!("update-initramfs complete for {version}. ESP synced.");
    Ok(())
}

pub(crate) fn sync_overlay_to_esp(overlay_root: &str, cfg: &config::Config) -> Result<(), String> {
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

pub(crate) fn sync_esp_to_overlay(overlay_root: &str, cfg: &config::Config) -> Result<(), String> {
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

    // Determine the target subvol and whether it is the currently booted overlay.
    let target_subvol = if matches!(name, "base" | "@base") {
        "@base".to_string()
    } else if matches!(name, "data" | "@data") {
        "@data".to_string()
    } else {
        format!("@overlay-{name}")
    };
    let active = btrfs::get_active_subvol(&cfg).ok().flatten();
    let is_active = active.as_deref() == Some(target_subvol.as_str());

    // Make the overlay's local ESP copy complete before the shell starts so the
    // kernel/initramfs hooks have a target to update inside it. The active
    // overlay is skipped: its bootable ESP is the real one, which we mount below
    // and sync back to the clone when the session ends.
    if !is_active {
        ensure_overlay_esp(&root, &target_subvol)?;
    }

    use std::io::IsTerminal;

    // Mount chroot, ESP (real one for the active overlay, else the overlay's
    // own copy), and @data user directories into home
    let mut ctx = mount::mount_chroot(&root)?;
    let esp_mount = if is_active {
        mount::mount_real_esp(&mut ctx)
    } else {
        mount::mount_overlay_esp(&mut ctx, &root)
    };
    esp_mount.map_err(|e| format!("Cannot mount ESP for overlay shell: {e}"))?;
    let data_path = format!("{}/{}", cfg.pool, cfg.data_subvol);
    let _ = mount::mount_data_dirs(&mut ctx, &data_path, &root, &cfg.username);
    let _guard = mount::MountGuard::new(ctx);

    let mut envs = forwarded_env_vars();
    let overlay_name = name.strip_prefix("@overlay-").unwrap_or(name);
    envs.push(("IMMUTABLE_OVERLAY".to_string(), overlay_name.to_string()));

    let result = if !std::io::stdin().is_terminal() {
        // Non-interactive: pass env vars through sudo's KEY=val syntax
        let mut cmd = std::process::Command::new("chroot");
        cmd.arg(&root).arg("sudo");
        for (k, v) in &envs {
            cmd.arg(format!("{k}={v}"));
        }
        cmd.arg("-u").arg(&cfg.username);
        if !args.is_empty() {
            cmd.arg("/bin/bash").arg("-c").arg(format!("cd ~ && {}", args.join(" ")));
        } else {
            cmd.arg("/bin/bash").arg("-c").arg("cd ~ && exec /bin/bash --login");
        }
        cmd.status()
            .map_err(|e| format!("chroot exec failed: {e}"))
            .and_then(|status| {
                if status.success() {
                    Ok(())
                } else {
                    Err("Command failed".to_string())
                }
            })
    } else {
        // Interactive: allocate PTY natively so sudo inside the chroot can prompt
        // on the real terminal (e.g. for password entry)
        let env_strings: Vec<String> = envs.iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect();
        let shell_cmd = if args.is_empty() {
            "cd ~ && exec /bin/bash --login".to_string()
        } else {
            format!("cd ~ && {}", args.join(" "))
        };
        let mut cmd_args: Vec<&str> = vec!["chroot", &root, "sudo"];
        for es in &env_strings {
            cmd_args.push(es);
        }
        cmd_args.push("-u");
        cmd_args.push(&cfg.username);
        cmd_args.push("/bin/bash");
        cmd_args.push("-c");
        cmd_args.push(&shell_cmd);

        let status = pty::spawn_pty(&cmd_args)?;
        if status != 0 {
            Err(format!("Command exited with status {status}"))
        } else {
            Ok(())
        }
    };

    // Refresh the active overlay's local ESP clone so the kernel/initrd written
    // to the real ESP inside the shell is captured (mirrors sync_back_to_overlay
    // in the postinst hooks).
    if is_active {
        if let Err(e) = sync_esp_to_overlay(&root, &cfg) {
            println!("immutable: warning: could not refresh overlay ESP: {e}");
        }
    }

    result
}

pub fn cmd_run(name: &str, args: &[String]) -> Result<(), String> {
    cmd_shell(name, args)
}

pub fn cmd_ensure() -> Result<(), String> {
    let reinstall_script = "/usr/lib/immutable/hooks/immutable-hook-reinstall";
    if !Path::new(reinstall_script).is_file() {
        return Err("Reinstall hook not found at /usr/lib/immutable/hooks/immutable-hook-reinstall".to_string());
    }
    let status = std::process::Command::new(reinstall_script)
        .status()
        .map_err(|e| format!("Failed to execute reinstall hook: {e}"))?;
    if !status.success() {
        return Err("Hook reinstall exited with error".to_string());
    }
    println!("Immutable system files are up to date.");
    Ok(())
}
