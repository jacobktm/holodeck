use std::path::Path;
use crate::config::Config;

pub fn set_active_overlay(cfg: &Config, name: &str) -> Result<(), String> {
    let esp = cfg.esp_path();
    let entries_dir = format!("{esp}/loader/entries");

    // Read the current immutable.conf and update the subvol line
    let conf_path = format!("{entries_dir}/immutable.conf");
    let original = std::fs::read_to_string(&conf_path)
        .map_err(|e| format!("Failed to read {conf_path}: {e}"))?;

    let mut lines: Vec<&str> = original.lines().collect();
    let mut found = false;
    for line in &mut lines {
        if line.starts_with("options ") {
            let rest = line.strip_prefix("options ").unwrap_or("");
            // Update subvol=... in kernel cmdline
            if let Some(pos) = rest.find("subvol=") {
                let before = &rest[..pos];
                let after = rest[pos..].split_whitespace().nth(0).unwrap_or("");
                let after_subvol = &rest[pos + after.len()..];
                // Reconstruct: keep everything before subvol=, replace value, keep everything after
                let new_rest = format!("{before}subvol=@overlay-{name}{after_subvol}");
                *line = Box::leak(new_rest.into_boxed_str());
            }
            found = true;
            break;
        }
    }

    if !found {
        return Err("No 'options' line found in immutable.conf".to_string());
    }

    let new_content = lines.join("\n");
    std::fs::write(&conf_path, &new_content)
        .map_err(|e| format!("Failed to write {conf_path}: {e}"))?;

    // Update loader.conf default
    let loader_conf = format!("{esp}/loader/loader.conf");
    let loader_content = format!("default immutable.conf\ntimeout 0\nconsole-mode max\n");
    std::fs::write(&loader_conf, &loader_content)
        .map_err(|e| format!("Failed to write {loader_conf}: {e}"))?;

    Ok(())
}

pub fn find_esp_dir(esp_base: &str) -> Option<String> {
    let efi_dir = format!("{esp_base}/EFI");
    let efi = Path::new(&efi_dir);
    if !efi.is_dir() {
        return None;
    }
    for entry in std::fs::read_dir(efi).ok()? {
        let entry = entry.ok()?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with("Pop_OS-") {
            return Some(format!("{efi_dir}/{name}"));
        }
    }
    // Try systemd directory
    let systemd = format!("{efi_dir}/systemd");
    if Path::new(&systemd).is_dir() {
        return Some(systemd);
    }
    None
}

pub fn sync_kernel_initrd(source_root: &str, esp_efi_dir: &str) -> Result<(), String> {
    let boot_dir = format!("{source_root}/boot");
    let boot = Path::new(&boot_dir);
    if !boot.is_dir() {
        return Err("Boot directory not found".to_string());
    }

    // Find latest kernel
    let mut kernels: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(boot) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy().to_string();
            if name.starts_with("vmlinuz-") && !entry.path().is_symlink() {
                kernels.push(name);
            }
        }
    }
    kernels.sort();
    let latest = kernels.last().ok_or("No kernels found")?;
    let version = latest.strip_prefix("vmlinuz-").unwrap_or(latest);

    let kernel_src = format!("{boot_dir}/{latest}");
    let initrd_src = format!("{boot_dir}/initrd.img-{version}");

    // Copy to ESP
    std::fs::create_dir_all(esp_efi_dir)
        .map_err(|e| format!("Failed to create {esp_efi_dir}: {e}"))?;

    std::fs::copy(&kernel_src, format!("{esp_efi_dir}/vmlinuz.efi"))
        .map_err(|e| format!("Failed to copy kernel: {e}"))?;
    std::fs::copy(&initrd_src, format!("{esp_efi_dir}/initrd.img"))
        .map_err(|e| format!("Failed to copy initrd: {e}"))?;

    Ok(())
}

pub fn esp_remount(mode: &str) -> Result<bool, String> {
    let output = std::process::Command::new("findmnt")
        .args(["-no", "OPTIONS", "/boot/efi"])
        .output()
        .map_err(|e| format!("findmnt failed: {e}"))?;

    let opts = String::from_utf8_lossy(&output.stdout);
    let was_ro = opts.contains("ro");

    if mode == "ro" && was_ro {
        return Ok(true);
    }
    if mode == "rw" && !was_ro {
        return Ok(false);
    }

    let status = std::process::Command::new("mount")
        .args(["-o", &format!("remount,{mode}"), "/boot/efi"])
        .status()
        .map_err(|e| format!("mount failed: {e}"))?;

    if !status.success() {
        return Err(format!("Failed to remount ESP {mode}"));
    }
    Ok(was_ro)
}

pub fn clean_boot_entries(cfg: &Config) -> Result<Vec<String>, String> {
    let esp = cfg.esp_path();
    let entries_dir = format!("{esp}/loader/entries");
    let dir = Path::new(&entries_dir);
    if !dir.is_dir() {
        return Err("Boot entries directory not found".to_string());
    }

    let protected = ["immutable.conf", "recovery.conf", "previous.conf"];
    let mut removed = Vec::new();

    for entry in std::fs::read_dir(dir).map_err(|e| format!("read dir failed: {e}"))? {
        let entry = entry.map_err(|e| format!("entry failed: {e}"))?;
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.ends_with(".conf") || protected.contains(&name.as_str()) {
            continue;
        }

        let content = std::fs::read_to_string(entry.path())
            .map_err(|e| format!("read entry failed: {e}"))?;

        // Check if referenced kernel exists
        let mut keep = true;
        for line in content.lines() {
            if let Some(path) = line.strip_prefix("linux ") {
                let kernel_path = format!("{esp}/{path}");
                if !Path::new(&kernel_path).is_file() {
                    keep = false;
                }
                break;
            }
        }

        if !keep {
            // Need ESP rw to delete
            let was_ro = esp_remount("rw")?;
            std::fs::remove_file(entry.path())
                .map_err(|e| format!("Failed to remove {name}: {e}"))?;
            if was_ro {
                esp_remount("ro")?;
            }
            removed.push(name);
        }
    }

    Ok(removed)
}
