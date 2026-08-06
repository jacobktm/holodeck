use std::path::Path;
use std::fs;
use crate::config::Config;



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

    let vmlinuz_path = format!("{esp_efi_dir}/vmlinuz.efi");
    let header = std::fs::read(&kernel_src)
        .map_err(|e| format!("Failed to read kernel {kernel_src}: {e}"))?
        .get(..2)
        .map(|b| b.to_vec())
        .unwrap_or_default();
    if header == [0x1f, 0x8b] {
        // Gzip-compressed kernel (Pop): decompress so systemd-boot gets a PE
        // image, matching what the postinst hooks write to vmlinuz.efi.
        let out = std::process::Command::new("gunzip")
            .arg("-c")
            .arg(&kernel_src)
            .output()
            .map_err(|e| format!("Failed to run gunzip: {e}"))?;
        if !out.status.success() {
            return Err(format!("gunzip failed for {kernel_src}"));
        }
        std::fs::write(&vmlinuz_path, out.stdout)
            .map_err(|e| format!("Failed to write {vmlinuz_path}: {e}"))?;
    } else {
        std::fs::copy(&kernel_src, &vmlinuz_path)
            .map_err(|e| format!("Failed to copy kernel: {e}"))?;
    }
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

pub fn validate_overlay_esp(overlay_root: &str, expected_subvol: &str) -> Result<(), String> {
    let overlay_esp = format!("{overlay_root}/boot/efi");
    let esp = Path::new(&overlay_esp);
    if !esp.is_dir() {
        return Err(format!("Overlay ESP directory not found: {overlay_esp}"));
    }

    // Check boot entry exists and has correct subvol
    let conf_path = format!("{overlay_esp}/loader/entries/immutable.conf");
    let content = fs::read_to_string(&conf_path)
        .map_err(|e| format!("Cannot read {conf_path}: {e}"))?;

    let has_subvol = content
        .lines()
        .any(|line| line.starts_with("options ") && line.contains(&format!("subvol={expected_subvol}")));
    if !has_subvol {
        return Err(format!(
            "Boot entry {conf_path} does not point to {expected_subvol}. \
             The overlay's ESP copy is misconfigured and cannot be safely activated."
        ));
    }

    // Check kernel and initrd exist inside overlay's ESP copy
    let found = find_esp_dir(&overlay_esp)
        .ok_or_else(|| format!("Cannot find ESP kernel directory in {overlay_esp}"))?;

    let kernel = format!("{found}/vmlinuz.efi");
    let initrd = format!("{found}/initrd.img");

    if !Path::new(&kernel).is_file() {
        return Err(format!("Kernel not found at {kernel}"));
    }
    if !Path::new(&initrd).is_file() {
        return Err(format!("Initrd not found at {initrd}"));
    }

    Ok(())
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
