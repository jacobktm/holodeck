use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::{btrfs, boot, config, mount};

const SYSTEM_OVERLAYS: &[&str] = &["init", "recovery"];

/// Per-user directories removed from the artifact in sanitized mode.
const SECRET_DIRS: &[&str] = &[
    ".ssh",
    ".gnupg",
    ".local/share/keyrings",
    ".cache",
    ".mozilla",
    ".config/google-chrome",
    ".config/chromium",
    ".config/BraveSoftware",
    ".config/microsoft-edge",
];

fn cfg() -> config::Config {
    config::Config::load()
}

fn ensure_pool(cfg: &config::Config) -> Result<(), String> {
    if !cfg.pool_mounted() {
        mount::mount_pool(&cfg.pool)?;
    }
    Ok(())
}

fn is_valid_overlay_name(name: &str) -> bool {
    !name.is_empty() && !name.starts_with('@') && name != "base" && name != "data"
}

/// Deletes a btrfs subvolume on drop unless committed.
struct SubvolGuard {
    path: Option<String>,
}

impl SubvolGuard {
    fn new(path: &str) -> Self {
        Self { path: Some(path.to_string()) }
    }
    fn commit(&mut self) {
        self.path = None;
    }
}

impl Drop for SubvolGuard {
    fn drop(&mut self) {
        if let Some(path) = &self.path {
            let _ = Command::new("btrfs")
                .args(["subvolume", "delete", path])
                .status();
        }
    }
}

/// Removes a directory tree on drop.
struct DirGuard {
    path: String,
}

impl Drop for DirGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

pub fn cmd_export(name: &str, mode: &str, output: Option<&Path>) -> Result<(), String> {
    if !is_valid_overlay_name(name) || SYSTEM_OVERLAYS.contains(&name) {
        return Err(format!("Cannot export '{name}': name is reserved"));
    }
    if !["sanitized", "minimal", "full"].contains(&mode) {
        return Err(format!("Unknown export mode '{mode}' (expected sanitized, minimal, or full)"));
    }

    let cfg = cfg();
    ensure_pool(&cfg)?;

    let src = cfg.overlay_path(name);
    if !Path::new(&src).is_dir() {
        return Err(format!("Overlay '{name}' not found at {src}"));
    }

    let out_path = match output {
        Some(p) => p.to_path_buf(),
        None => PathBuf::from(format!("overlay-{name}.zst")),
    };

    // Temporary writable CoW snapshot so sanitization never touches the live overlay.
    let tmp = format!("{}/.export-tmp-{name}-{}", cfg.pool, std::process::id());
    if Path::new(&tmp).exists() {
        return Err(format!("Temporary snapshot {tmp} already exists"));
    }
    btrfs::snapshot(&src, &tmp)?;
    let _cleanup = SubvolGuard::new(&tmp);

    if mode != "full" {
        sanitize(&tmp, mode);
    }

    // btrfs send requires a read-only source.
    btrfs::set_property(&tmp, "ro", "true")?;

    let out = std::fs::File::create(&out_path)
        .map_err(|e| format!("Failed to create {}: {e}", out_path.display()))?;

    let mut sender = Command::new("btrfs")
        .arg("send")
        .arg(&tmp)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to run btrfs send: {e}"))?;
    let send_stdout = sender.stdout.take().ok_or("btrfs send produced no output")?;

    let mut compressor = Command::new("zstd")
        .arg("-T0")
        .stdin(Stdio::from(send_stdout))
        .stdout(Stdio::from(out))
        .spawn()
        .map_err(|e| format!("Failed to run zstd: {e}"))?;

    let send_status = sender.wait().map_err(|e| format!("btrfs send failed: {e}"))?;
    let zstd_status = compressor.wait().map_err(|e| format!("zstd failed: {e}"))?;

    if !send_status.success() {
        return Err("btrfs send failed".to_string());
    }
    if !zstd_status.success() {
        return Err("zstd compression failed".to_string());
    }

    let size = btrfs::get_size(out_path.to_str().unwrap_or(""));
    println!("Exported overlay '{name}' (mode {mode}) to {}", out_path.display());
    if let Ok(s) = size {
        println!("Artifact size: {s}");
    }
    Ok(())
}

/// Remove machine-specific or per-user data from a snapshot copy.
/// `sanitized` strips secrets and network state; `minimal` only strips
/// host identity (SSH host keys, machine-id). Both leave fstab/crypttab/
/// boot UUID rewrites to the importing system.
fn sanitize(root: &str, mode: &str) {
    if let Ok(entries) = std::fs::read_dir(format!("{root}/etc/ssh")) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("ssh_host_") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
    let _ = std::fs::remove_file(format!("{root}/etc/machine-id"));
    let _ = std::fs::remove_file(format!("{root}/var/lib/dbus/machine-id"));

    if mode == "minimal" {
        return;
    }

    // sanitized: also scrub network state, logs, and per-user secrets.
    let _ = std::fs::remove_dir_all(format!("{root}/var/lib/NetworkManager"));
    let _ = std::fs::remove_file(format!("{root}/etc/udev/rules.d/70-persistent-net.rules"));

    if let Ok(entries) = std::fs::read_dir(format!("{root}/var/log")) {
        for entry in entries.flatten() {
            let p = entry.path();
            let _ = std::fs::remove_file(&p);
            let _ = std::fs::remove_dir_all(&p);
        }
    }

    if let Ok(users) = std::fs::read_dir(format!("{root}/home")) {
        for user in users.flatten() {
            if !user.path().is_dir() {
                continue;
            }
            for dir in SECRET_DIRS {
                let p = format!("{}/{}", user.path().display(), dir);
                let _ = std::fs::remove_dir_all(&p);
            }
        }
    }
}

pub fn cmd_import(file: &Path, name: Option<&str>, do_switch: bool) -> Result<(), String> {
    let cfg = cfg();
    ensure_pool(&cfg)?;

    if !file.exists() {
        return Err(format!("Artifact not found: {}", file.display()));
    }

    let pool_uuid = pool_fs_uuid()?;
    let esp_uuid = esp_fs_uuid()?;
    let target_username = cfg.username.clone();
    let target_hostname = hostname()?;
    let target_fde = Path::new("/etc/crypttab").is_file();

    let tmpdir = format!("{}/.import-tmp-{}", cfg.pool, std::process::id());
    std::fs::create_dir_all(&tmpdir)
        .map_err(|e| format!("Failed to create {tmpdir}: {e}"))?;
    let _dir_guard = DirGuard { path: tmpdir.clone() };

    let mut decompressor = Command::new("zstd")
        .args(["-dc"])
        .arg(file)
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Failed to run zstd: {e}"))?;
    let dec_stdout = decompressor.stdout.take().ok_or("zstd produced no output")?;

    let mut receiver = Command::new("btrfs")
        .args(["receive", &tmpdir])
        .stdin(Stdio::from(dec_stdout))
        .spawn()
        .map_err(|e| format!("Failed to run btrfs receive: {e}"))?;

    let dec_status = decompressor.wait().map_err(|e| format!("zstd failed: {e}"))?;
    let recv_status = receiver.wait().map_err(|e| format!("btrfs receive failed: {e}"))?;

    if !dec_status.success() {
        return Err("Failed to decompress artifact".to_string());
    }
    if !recv_status.success() {
        return Err("btrfs receive failed".to_string());
    }

    // The receive directory should now contain exactly one subvolume.
    let entries: Vec<String> = std::fs::read_dir(&tmpdir)
        .map_err(|e| format!("Failed to read {tmpdir}: {e}"))?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    if entries.len() != 1 {
        return Err(format!("Expected 1 subvolume in artifact, found {}", entries.len()));
    }
    let received = entries[0].clone();
    let recv_path = format!("{tmpdir}/{received}");

    if !Path::new(&format!("{recv_path}/etc")).is_dir() {
        return Err("Artifact does not contain a valid overlay root".to_string());
    }

    // Determine the final overlay name.
    let mut final_name = name.unwrap_or_default().to_string();
    if final_name.is_empty() {
        let stream_name = received.strip_prefix("@overlay-").unwrap_or(&received);
        if !is_valid_overlay_name(stream_name) || SYSTEM_OVERLAYS.contains(&stream_name) {
            return Err(format!("Artifact subvolume '{stream_name}' is not a valid overlay name"));
        }
        final_name = stream_name.to_string();
    }
    if !is_valid_overlay_name(&final_name) || SYSTEM_OVERLAYS.contains(&final_name.as_str()) {
        return Err(format!("Cannot import as '{final_name}': name is reserved"));
    }

    let dst = cfg.overlay_path(&final_name);
    if Path::new(&dst).exists() {
        return Err(format!("Overlay '{final_name}' already exists"));
    }

    // Move into place (same filesystem — this moves the subvolume).
    std::fs::rename(&recv_path, &dst)
        .map_err(|e| format!("Failed to move overlay into place: {e}"))?;
    let _ = std::fs::remove_dir(&tmpdir);

    // If any re-init step fails, remove the half-initialized overlay.
    let mut guard = SubvolGuard::new(&dst);

    reinit_overlay(&dst, &final_name, &pool_uuid, &esp_uuid, &target_hostname, &target_username, target_fde)?;

    // Rebuild the overlay's ESP copy from this system's ESP, then drop in the
    // freshly rebuilt kernel/initrd. This keeps recovery/previous/loader.conf
    // and the EFI/Pop_OS-<uuid> directory target-correct.
    let overlay_esp = format!("{dst}/boot/efi");
    if Path::new(&overlay_esp).is_dir() {
        std::fs::remove_dir_all(&overlay_esp)
            .map_err(|e| format!("Failed to clear overlay ESP: {e}"))?;
    }
    std::fs::create_dir_all(&overlay_esp)
        .map_err(|e| format!("Failed to create {overlay_esp}: {e}"))?;
    crate::commands::customize_overlay_esp(&dst, &format!("@overlay-{final_name}"), &cfg);
    sync_imported_kernel(&dst)?;

    boot::validate_overlay_esp(&dst, &format!("@overlay-{final_name}"))?;
    guard.commit();

    if do_switch {
        crate::commands::cmd_switch(&final_name)?;
        println!("Imported overlay '{final_name}' and set it as the boot overlay.");
        println!("Reboot to activate.");
    } else {
        println!("Imported overlay '{final_name}'.");
        println!("Boot into it with: sudo immutable switch {final_name}");
    }
    Ok(())
}

/// Rewrite machine-specific state inside an imported overlay so it matches
/// the current system, then rebuild its initramfs for this hardware.
fn reinit_overlay(
    root: &str,
    name: &str,
    pool_uuid: &str,
    esp_uuid: &str,
    target_hostname: &str,
    target_username: &str,
    target_fde: bool,
) -> Result<(), String> {
    rewrite_fstab(root, pool_uuid, esp_uuid, name)?;

    if target_fde {
        std::fs::copy("/etc/crypttab", format!("{root}/etc/crypttab"))
            .map_err(|e| format!("Failed to copy target crypttab: {e}"))?;
    } else {
        let _ = std::fs::remove_file(format!("{root}/etc/crypttab"));
    }

    reinit_identity(root, target_hostname, target_username);

    let ctx = mount::mount_chroot(root)?;
    let _guard = mount::MountGuard::new(ctx);

    // Regenerate machine-id if the artifact was sanitized.
    let has_machine_id = std::fs::read_to_string(format!("{root}/etc/machine-id"))
        .map(|c| !c.trim().is_empty())
        .unwrap_or(false);
    if !has_machine_id {
        let _ = Command::new("chroot")
            .arg(root)
            .arg("systemd-machine-id-setup")
            .status();
    }

    // Regenerate SSH host keys if the artifact was sanitized.
    let ssh_dir = format!("{root}/etc/ssh");
    let has_ssh_keys = std::fs::read_dir(&ssh_dir)
        .map(|e| {
            e.flatten().any(|e| {
                e.file_name().to_string_lossy().starts_with("ssh_host_")
            })
        })
        .unwrap_or(true);
    if !has_ssh_keys && Path::new(&format!("{root}/usr/bin/ssh-keygen")).is_file() {
        let _ = Command::new("chroot")
            .arg(root)
            .arg("ssh-keygen")
            .arg("-A")
            .status();
    }

    // An encrypted target needs cryptsetup in the overlay to build a working initramfs.
    if target_fde && !Path::new(&format!("{root}/usr/sbin/cryptsetup")).is_file() {
        println!("Installing cryptsetup in imported overlay for encrypted boot...");
        let st = Command::new("chroot")
            .arg(root)
            .args(["apt-get", "install", "-y", "--no-install-recommends", "cryptsetup", "cryptsetup-initramfs"])
            .status()
            .map_err(|e| format!("chroot apt-get failed: {e}"))?;
        if !st.success() {
            return Err("Failed to install cryptsetup in imported overlay".to_string());
        }
    }

    // Rebuild initramfs for this system's hardware.
    let st = Command::new("chroot")
        .arg(root)
        .args(["update-initramfs", "-c", "-k", "all"])
        .status()
        .map_err(|e| format!("chroot update-initramfs failed: {e}"))?;
    if !st.success() {
        return Err("update-initramfs failed in imported overlay".to_string());
    }

    Ok(())
}

/// Rewrite fstab so root, /pool, and ESP point at this system's filesystems.
fn rewrite_fstab(root: &str, pool_uuid: &str, esp_uuid: &str, name: &str) -> Result<(), String> {
    let path = format!("{root}/etc/fstab");
    let content = std::fs::read_to_string(&path)
        .map_err(|e| format!("Cannot read {path}: {e}"))?;
    let new_subvol = format!("@overlay-{name}");
    let mut updated = String::new();

    for line in content.lines() {
        let mut line = line.to_string();
        if let Some(rest) = line.strip_prefix("UUID=") {
            let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
            let old_field = format!("UUID={}", &rest[..end]);
            if line.contains(" btrfs ") {
                line = line.replacen(&old_field, &format!("UUID={pool_uuid}"), 1);
                if let Some(i) = line.find("subvol=") {
                    let after = &line[i..];
                    let tok_end = after.find(char::is_whitespace).unwrap_or(after.len());
                    line = line.replacen(&after[..tok_end], &format!("subvol={new_subvol}"), 1);
                }
            } else if line.contains(" vfat ") {
                line = line.replacen(&old_field, &format!("UUID={esp_uuid}"), 1);
            }
        }
        updated.push_str(&line);
        updated.push('\n');
    }

    std::fs::write(&path, updated).map_err(|e| format!("Cannot write {path}: {e}"))?;
    Ok(())
}

/// Adopt this system's hostname and user, renaming the overlay's home
/// directory if the source user differs.
fn reinit_identity(root: &str, target_hostname: &str, target_username: &str) {
    let _ = std::fs::write(format!("{root}/etc/hostname"), format!("{target_hostname}\n"));

    let hosts_path = format!("{root}/etc/hosts");
    let mut hosts = std::fs::read_to_string(&hosts_path).unwrap_or_default();
    if !hosts.lines().any(|l| l.contains(target_hostname)) {
        if !hosts.is_empty() && !hosts.ends_with('\n') {
            hosts.push('\n');
        }
        hosts.push_str(&format!("127.0.1.1\t{target_hostname}\n"));
    }
    let _ = std::fs::write(&hosts_path, hosts);

    let ic_path = format!("{root}/etc/immutable.conf");
    if let Ok(content) = std::fs::read_to_string(&ic_path) {
        let src_user = content
            .lines()
            .find_map(|l| l.strip_prefix("USERNAME="))
            .map(|v| v.trim().to_string());

        if let Some(src) = &src_user {
            if src != target_username {
                let src_home = format!("{root}/home/{src}");
                let tgt_home = format!("{root}/home/{target_username}");
                if Path::new(&src_home).is_dir() && !Path::new(&tgt_home).exists() {
                    let _ = std::fs::rename(&src_home, &tgt_home);
                }
            }
        }

        let mut out = String::new();
        let mut seen = false;
        for line in content.lines() {
            if line.starts_with("USERNAME=") {
                out.push_str(&format!("USERNAME={target_username}\n"));
                seen = true;
            } else {
                out.push_str(line);
                out.push('\n');
            }
        }
        if !seen {
            out.push_str(&format!("USERNAME={target_username}\n"));
        }
        let _ = std::fs::write(&ic_path, out);
    }
}

/// Copy the freshly rebuilt kernel and initrd into the overlay's ESP copy.
fn sync_imported_kernel(root: &str) -> Result<(), String> {
    let overlay_esp = format!("{root}/boot/efi");
    let esp_dir = boot::find_esp_dir(&overlay_esp)
        .ok_or_else(|| format!("Cannot find ESP kernel directory in {overlay_esp}"))?;
    boot::sync_kernel_initrd(root, &esp_dir)
}

fn findmnt_uuid(path: &str) -> Result<String, String> {
    let out = Command::new("findmnt")
        .args(["-no", "UUID", path])
        .output()
        .map_err(|e| format!("findmnt {path} failed: {e}"))?;
    if !out.status.success() {
        return Err(format!("Cannot determine filesystem UUID of {path}"));
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        Err(format!("No UUID for {path}"))
    } else {
        Ok(s)
    }
}

fn pool_fs_uuid() -> Result<String, String> {
    for path in ["/pool", "/"] {
        if let Ok(u) = findmnt_uuid(path) {
            return Ok(u);
        }
    }
    Err("Cannot determine pool filesystem UUID".to_string())
}

fn esp_fs_uuid() -> Result<String, String> {
    findmnt_uuid("/boot/efi").map_err(|e| format!("Cannot determine ESP filesystem UUID: {e}"))
}

fn hostname() -> Result<String, String> {
    let out = Command::new("hostname")
        .output()
        .map_err(|e| format!("hostname failed: {e}"))?;
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}
