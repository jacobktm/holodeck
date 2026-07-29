use std::process::Command;
use crate::config::Config;

pub struct SubvolInfo {
    pub name: String,
    pub path: String,
    pub readonly: bool,
    pub size: String,
}

pub fn list_overlays(cfg: &Config) -> Result<Vec<SubvolInfo>, String> {
    let output = Command::new("btrfs")
        .args(["subvolume", "list", "-a", "-q", &cfg.pool])
        .output()
        .map_err(|e| format!("Failed to run btrfs: {e}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("btrfs subvolume list failed: {stderr}"));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut overlays = Vec::new();

    for line in stdout.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 4 {
            continue;
        }
        // btrfs subvolume list -q: path is last column
        let subvol_path = parts.last().unwrap_or(&"");
        if !subvol_path.starts_with("@overlay-") && *subvol_path != "@base" {
            continue;
        }

        let name = subvol_path.trim_start_matches('@');
        let full_path = format!("{}/{}", cfg.pool, subvol_path);

        // Check readonly
        let ro = is_readonly(&full_path).unwrap_or(false);

        // Get size
        let size = get_size(&full_path).unwrap_or_default();

        overlays.push(SubvolInfo {
            name: name.to_string(),
            path: full_path,
            readonly: ro,
            size,
        });
    }

    Ok(overlays)
}

pub fn snapshot(source: &str, dest: &str) -> Result<(), String> {
    let status = Command::new("btrfs")
        .args(["subvolume", "snapshot", source, dest])
        .status()
        .map_err(|e| format!("Failed to run btrfs snapshot: {e}"))?;

    if !status.success() {
        return Err(format!("btrfs snapshot failed: {source} -> {dest}"));
    }
    Ok(())
}

pub fn delete_subvol(path: &str) -> Result<(), String> {
    let status = Command::new("btrfs")
        .args(["subvolume", "delete", path])
        .status()
        .map_err(|e| format!("Failed to run btrfs delete: {e}"))?;

    if !status.success() {
        return Err(format!("btrfs delete failed: {path}"));
    }
    Ok(())
}

pub fn set_property(path: &str, key: &str, value: &str) -> Result<(), String> {
    let status = Command::new("btrfs")
        .args(["property", "set", path, key, value])
        .status()
        .map_err(|e| format!("Failed to run btrfs property set: {e}"))?;

    if !status.success() {
        return Err(format!("btrfs property set failed: {path} {key}={value}"));
    }
    Ok(())
}

fn is_readonly(path: &str) -> Result<bool, String> {
    let output = Command::new("btrfs")
        .args(["property", "get", path, "ro"])
        .output()
        .map_err(|e| format!("btrfs property get failed: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.trim() == "ro=true")
}

fn get_size(path: &str) -> Result<String, String> {
    let output = Command::new("du")
        .args(["-sh", path])
        .output()
        .map_err(|e| format!("du failed: {e}"))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.split_whitespace().next().unwrap_or("?").to_string())
}

pub fn get_active_subvol(cfg: &Config) -> Result<Option<String>, String> {
    let boot_entry = format!("{}/loader/entries/immutable.conf", cfg.esp_path());
    let content = match std::fs::read_to_string(&boot_entry) {
        Ok(c) => c,
        Err(_) => return Ok(None),
    };
    // Match subvol=... in the options line (e.g. rootflags=subvol=@overlay-init)
    if let Some(pos) = content.find("subvol=") {
        let rest = &content[pos + 7..];
        let end = rest.find(|c: char| c.is_whitespace()).unwrap_or(rest.len());
        let subvol = &rest[..end];
        if !subvol.is_empty() {
            return Ok(Some(subvol.to_string()));
        }
    }
    Ok(None)
}
