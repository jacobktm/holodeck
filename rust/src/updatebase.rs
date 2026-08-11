use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

use crate::{btrfs, boot, commands, config, mount};

const TEMP_SUBVOL: &str = "@overlay-update";

/// apt options used for the base update.
const APT_OPTS: &[&str] = &[
    "-y",
    "--allow-downgrades",
    "-o", "Dpkg::Lock::Timeout=120",
    "-o", "Acquire::Retries=3",
    "-o", "Dpkg::Options::=--force-confdef",
    "-o", "Dpkg::Options::=--force-confold",
    "-o", "Dpkg::Use-Pty=0",
];

struct TempGuard {
    path: Option<String>,
}

impl TempGuard {
    fn new(path: &str) -> Self {
        TempGuard { path: Some(path.to_string()) }
    }
    fn keep(&mut self) {
        self.path = None;
    }
}

impl Drop for TempGuard {
    fn drop(&mut self) {
        if let Some(p) = self.path.take() {
            let _ = btrfs::delete_subvol(&p);
        }
    }
}

fn cfg() -> config::Config {
    config::Config::load()
}

fn ensure_pool(cfg: &config::Config) -> Result<(), String> {
    if !cfg.pool_mounted() {
        mount::mount_pool(&cfg.pool)?;
    }
    Ok(())
}

/// Runs a command inside the overlay chroot as root, streaming its output.
fn chroot_run(root: &str, argv: &[&str]) -> Result<(), String> {
    let status = Command::new("chroot")
        .arg(root)
        .args(argv)
        .env("DEBIAN_FRONTEND", "noninteractive")
        .env("NEEDRESTART_MODE", "a")
        .status()
        .map_err(|e| format!("Failed to run command inside {root}: {e}"))?;
    if !status.success() {
        return Err(format!(
            "Command '{}' failed inside the update overlay (exit {:?})",
            argv.join(" "),
            status.code()
        ));
    }
    Ok(())
}

fn apt_argv(verb: &str) -> Vec<&str> {
    let mut argv = vec!["apt-get", verb];
    argv.extend_from_slice(APT_OPTS);
    argv
}

/// Remembers the overlay's original /etc/resolv.conf so the chroot copy made by
/// `mount_chroot` can be restored before the overlay is promoted to @base.
fn save_resolv(root: &str) -> Option<String> {
    let path = format!("{root}/etc/resolv.conf");
    if let Ok(target) = std::fs::read_link(&path) {
        return Some(format!("link:{}", target.to_string_lossy()));
    }
    std::fs::read_to_string(&path).ok().map(|c| format!("file:{c}"))
}

fn restore_resolv(root: &str, saved: &Option<String>) {
    let path = format!("{root}/etc/resolv.conf");
    let _ = std::fs::remove_file(&path);
    match saved {
        Some(s) if s.starts_with("link:") => {
            let _ = std::os::unix::fs::symlink(&s["link:".len()..], &path);
        }
        Some(s) if s.starts_with("file:") => {
            let _ = std::fs::write(&path, &s["file:".len()..]);
        }
        _ => {}
    }
}

/// Runs apt inside the temporary overlay. Kernel postinst/initramfs hooks write
/// the fresh kernel/initrd into the overlay's own ESP copy (bind-mounted at
/// /boot/efi), exactly as in an overlay shell.
fn run_apt_in_overlay(root: &str) -> Result<(), String> {
    let resolv = save_resolv(root);

    // Prevent dpkg maintainer scripts from starting services in the chroot; the
    // standard debootstrap mechanism. Removed again before promotion so the new
    // @base boots normally.
    let policy_path = format!("{root}/usr/sbin/policy-rc.d");
    let had_policy = Path::new(&policy_path).exists();
    if !had_policy {
        std::fs::write(&policy_path, "#!/bin/sh\nexit 101\n")
            .map_err(|e| format!("Failed to write policy-rc.d: {e}"))?;
        std::fs::set_permissions(&policy_path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("Failed to chmod policy-rc.d: {e}"))?;
    }

    let mut ctx = mount::mount_chroot(root)?;
    mount::mount_overlay_esp(&mut ctx, root)
        .map_err(|e| format!("Cannot mount the overlay ESP inside the update shell: {e}"))?;
    let _guard = mount::MountGuard::new(ctx);

    let result = (|| {
        // Repair any half-configured dpkg state from a previous interrupted run.
        if chroot_run(root, &["dpkg", "--configure", "-a"]).is_err() {
            let mut argv = vec!["apt-get", "-f", "install"];
            argv.extend_from_slice(APT_OPTS);
            chroot_run(root, &argv)?;
        }

        let mut update = vec!["/usr/bin/timeout", "1200"];
        update.extend(apt_argv("update"));
        chroot_run(root, &update)?;

        let mut upgrade = vec!["/usr/bin/timeout", "3600"];
        upgrade.extend(apt_argv("full-upgrade"));
        chroot_run(root, &upgrade)
    })();

    // _guard drops here: the chroot mounts are gone before the overlay is
    // promoted (renamed) into @base.

    if !had_policy {
        let _ = std::fs::remove_file(&policy_path);
    }
    restore_resolv(root, &resolv);

    result
}

/// Rewrites the subvol in the overlay's immutable.conf boot entry and pins
/// loader.conf to it.
fn fix_entries(subvol_root: &str, subvol: &str) {
    let conf = format!("{subvol_root}/boot/efi/loader/entries/immutable.conf");
    if let Ok(content) = std::fs::read_to_string(&conf) {
        let updated: Vec<String> = content
            .lines()
            .map(|line| {
                if line.contains("rootflags=subvol=") {
                    if let Some(start) = line.find("subvol=") {
                        let before = &line[..start];
                        let after = line[start..].split_whitespace().next().unwrap_or("");
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
        let _ = std::fs::write(&conf, updated.join("\n") + "\n");
    }
    let loader = format!("{subvol_root}/boot/efi/loader/loader.conf");
    let _ = std::fs::write(&loader, "default immutable.conf\ntimeout 0\nconsole-mode max\n");
}

/// Promotes the temporary update overlay to the new @base: shifts the base
/// chain (keeping two previous bases), renames @overlay-update into place,
/// locks @base read-only, and recreates @overlay-recovery. The real ESP is
/// left alone — it only ever reflects the active overlay (via its kernel
/// hooks) or whatever `immutable switch` deliberately loads next.
fn promote(cfg: &config::Config) -> Result<(), String> {
    let base = cfg.base_path();
    let base_old = format!("{}/@base-old", cfg.pool);
    let base_old2 = format!("{}/@base-old-2", cfg.pool);
    let recovery = cfg.recovery_path();
    let temp = cfg.overlay_path("update");

    // Shift the base chain (keep the two previous bases).
    if Path::new(&base_old2).is_dir() {
        btrfs::delete_subvol(&base_old2)?;
    }
    if Path::new(&base_old).is_dir() {
        std::fs::rename(&base_old, &base_old2)
            .map_err(|e| format!("Failed to shift @base-old: {e}"))?;
    }
    if Path::new(&base).is_dir() {
        std::fs::rename(&base, &base_old)
            .map_err(|e| format!("Failed to shift @base: {e}"))?;
    }

    // Promote the temporary update overlay to the new base.
    std::fs::rename(&temp, &base)
        .map_err(|e| format!("Failed to promote {TEMP_SUBVOL} to @base: {e}"))?;

    // Point the promoted base's own boot entry at itself before locking it.
    fix_entries(&base, "@base");
    btrfs::set_property(&base, "ro", "true")?;

    // Recreate @overlay-recovery from the new base.
    if Path::new(&recovery).is_dir() {
        let _ = btrfs::set_property(&recovery, "ro", "false");
        btrfs::delete_subvol(&recovery)?;
    }
    btrfs::snapshot(&base, &recovery)?;
    fix_entries(&recovery, "@overlay-recovery");
    btrfs::set_property(&recovery, "ro", "true")?;

    Ok(())
}

fn result_path(cfg: &config::Config) -> String {
    format!("{}/{}/update-base-result", cfg.pool, cfg.data_subvol)
}

fn remove_result(cfg: &config::Config) {
    let _ = std::fs::remove_file(result_path(cfg));
}

fn write_result(cfg: &config::Config, mode: &str) -> Result<(), String> {
    let msg = if mode == "restore" {
        "Last base restore completed: the previous @base was restored and promoted."
    } else {
        "Last base update completed: new @base is live (previous base kept as @base-old)."
    };
    std::fs::write(result_path(cfg), msg).map_err(|e| format!("Failed to write update result: {e}"))
}

/// Runs a base update (or restore) entirely in-process, without rebooting:
/// snapshot @base (or @base-old) into @overlay-update, run apt inside that
/// overlay, and promote it to the new @base on success. On any failure the
/// temporary overlay is deleted and @base is untouched.
fn run(mode: &str) -> Result<(), String> {
    if unsafe { libc::getuid() != 0 } {
        return Err("update-base requires root. Run with sudo.".to_string());
    }

    let cfg = cfg();
    ensure_pool(&cfg)?;

    let temp = cfg.overlay_path("update");
    if Path::new(&temp).exists() {
        return Err(format!(
            "Temporary overlay {TEMP_SUBVOL} already exists. Discard it with \
             'immutable delete update' and retry."
        ));
    }

    let (src, src_label) = if mode == "restore" {
        let old = format!("{}/@base-old", cfg.pool);
        if !Path::new(&old).is_dir() {
            return Err("No previous base found (@base-old). Nothing to restore.".to_string());
        }
        (old, "@base-old".to_string())
    } else {
        let base = cfg.base_path();
        if !Path::new(&base).is_dir() {
            return Err("Base system @base not found".to_string());
        }
        (base, "@base".to_string())
    };

    let active = btrfs::get_active_subvol(&cfg)
        .map_err(|e| format!("Failed to get boot config: {e}"))?
        .ok_or("No active overlay configured. Run 'immutable status'.")?;
    if active == TEMP_SUBVOL {
        return Err("A base update is already in progress (booted into @overlay-update).".to_string());
    }
    if active == "@overlay-recovery" {
        return Err("Cannot update the base while booted into @overlay-recovery.".to_string());
    }

    remove_result(&cfg);

    // 1. Snapshot the source into the temporary update overlay.
    println!("immutable: base {mode} from {src_label} into {TEMP_SUBVOL}");
    btrfs::snapshot(&src, &temp)?;
    let mut guard = TempGuard::new(&temp);

    // 2. Seed the temp overlay's ESP copy and point its boot entry at itself.
    commands::customize_overlay_esp(&temp, TEMP_SUBVOL, &cfg, &src);
    boot::validate_overlay_esp(&temp, TEMP_SUBVOL)?;

    // 3. Run apt inside the temp overlay (skipped for restore).
    if mode != "restore" {
        println!("immutable: updating base inside {TEMP_SUBVOL}...");
        run_apt_in_overlay(&temp)?;
    }

    // 4. Promote the temp overlay to the new @base.
    promote(&cfg)?;
    guard.keep();

    write_result(&cfg, mode)?;

    let what = if mode == "restore" { "restore" } else { "update" };
    println!(
        "immutable: base {what} complete. The new @base is live (previous base kept as @base-old)."
    );
    Ok(())
}

pub fn cmd_update_base() -> Result<(), String> {
    run("update")
}

pub fn cmd_restore_base() -> Result<(), String> {
    run("restore")
}
