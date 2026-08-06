use std::path::Path;
use crate::{btrfs, boot, commands, config, mount};

const TEMP_SUBVOL: &str = "@overlay-update";

const UPDATE_TARGET: &str = r#"[Unit]
Description=Immutable base update (transactional)
Requires=immutable-update-base.service
AllowIsolate=yes
"#;

const UPDATE_SERVICE: &str = r#"[Unit]
Description=Immutable base update worker (apt inside @overlay-update)
Requires=basic.target local-fs.target
After=basic.target local-fs.target NetworkManager.service systemd-resolved.service
Wants=NetworkManager.service systemd-resolved.service
RequiresMountsFor=/pool

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/immutable-update-base.sh
TimeoutStartSec=infinity

[Install]
WantedBy=immutable-update-base.target
"#;

const UPDATE_SCRIPT: &str = r#"#!/bin/bash
set -euo pipefail

# Transactional base update/restore worker.
# Runs inside @overlay-update during a dedicated update boot. Applies apt
# updates (update mode) or skips them (restore mode), then stages promotion
# and reboots back to the overlay the user came from. On any failure the boot
# entry is restored and the machine reboots; @base is never touched in place.

POOL="${IMMUTABLE_POOL:-/pool}"
DATA="$POOL/@data"
TEMP_SUBVOL="@overlay-update"
TEMP_ROOT="$POOL/$TEMP_SUBVOL"
REAL_ESP="/boot/efi"
RETURN_FILE="$DATA/update-base-return"
MODE_FILE="$DATA/update-base-mode"
PROMOTE_FILE="$DATA/update-base-promote"
FAILED_FILE="$DATA/update-base-failed"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

APT_OPTS=(
  -y
  --allow-downgrades
  -o Dpkg::Lock::Timeout=120
  -o Acquire::Retries=3
  -o Dpkg::Options::=--force-confdef
  -o Dpkg::Options::=--force-confold
  -o Dpkg::Use-Pty=0
)

log() { echo "immutable-update-base: $*"; }

ensure_pool() {
    if ! mountpoint -q "$POOL" 2>/dev/null; then
        local dev fstype
        dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
        fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
        [ "$fstype" = "btrfs" ] || return 1
        mkdir -p "$POOL"
        mount -o subvolid=5 "$dev" "$POOL" 2>/dev/null || return 1
    fi
    mkdir -p "$DATA" 2>/dev/null || true
}

wait_for_network() {
    local i
    for i in $(seq 1 18); do
        if command -v nm-online >/dev/null 2>&1 && nm-online -q -t 5; then
            return 0
        fi
        if getent hosts archive.ubuntu.com >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

restore_return_entry() {
    local return_subvol src
    return_subvol=$(cat "$RETURN_FILE" 2>/dev/null || true)
    [ -n "$return_subvol" ] || return 0
    src="$POOL/$return_subvol/boot/efi"
    [ -d "$src" ] || return 0
    mount -o remount,rw "$REAL_ESP" 2>/dev/null || true
    rsync -a "$src/" "$REAL_ESP/"
    mount -o remount,ro "$REAL_ESP" 2>/dev/null || true
    sync
    log "restored boot entry for $return_subvol"
}

fail() {
    local reason="$1"
    log "FAILED: $reason"
    echo "$reason" > "$FAILED_FILE" 2>/dev/null || true
    restore_return_entry
    sync
    systemctl reboot
}

trap 'fail "update interrupted"' ERR INT TERM HUP

ensure_pool || fail "cannot mount /pool"

mode=$(cat "$MODE_FILE" 2>/dev/null || echo "update")

if [ "$mode" = "restore" ]; then
    log "restore mode: skipping apt"
else
    log "self-healing dpkg state"
    dpkg --configure -a || true
    apt-get -f install "${APT_OPTS[@]}" || true

    wait_for_network || log "warning: network may be unavailable"

    log "updating package lists"
    timeout 1200 apt-get update "${APT_OPTS[@]}"

    log "applying full upgrade"
    timeout 3600 apt-get full-upgrade "${APT_OPTS[@]}"
fi

# 1. Sync the real ESP back into the temp overlay so the promoted base's ESP
#    copy captures any kernel/initrd written by postinst hooks this boot.
mount -o remount,rw "$REAL_ESP" 2>/dev/null || true
rsync -a "$REAL_ESP/" "$TEMP_ROOT/boot/efi/"
mount -o remount,ro "$REAL_ESP" 2>/dev/null || true

# 2. Strip the one-shot systemd.unit= flag from the temp overlay's own copy so
#    the promoted @base never boots into the update target.
sed -i 's/ systemd\.unit=immutable-update-base\.target//g' \
    "$TEMP_ROOT/boot/efi/loader/entries/immutable.conf" 2>/dev/null || true

# 3. Remove the injected update machinery so the promoted base is pristine.
rm -f "$TEMP_ROOT/etc/systemd/system/immutable-update-base.target" \
      "$TEMP_ROOT/etc/systemd/system/immutable-update-base.service" \
      "$TEMP_ROOT/usr/local/sbin/immutable-update-base.sh"

# 4. Stage promotion and hand back to the return overlay.
echo "1" > "$PROMOTE_FILE"
log "update complete; promotion staged"

restore_return_entry
sync
systemctl reboot
"#;

const PROMOTE_SERVICE: &str = r#"[Unit]
Description=Immutable base update promoter
DefaultDependencies=no
After=local-fs.target immutable-data-mount.service
Before=multi-user.target immutable-boot-counter.service
RequiresMountsFor=/pool

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/immutable-update-base-promote.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"#;

const PROMOTE_SCRIPT: &str = r#"#!/bin/bash
set -euo pipefail

# Promote (or discard) a staged base update/restore. Injected into the user's
# overlay before the update boot; runs on every boot until the update is
# finalized, then removes itself. Refuses to run inside @overlay-update itself.

POOL="${IMMUTABLE_POOL:-/pool}"
DATA="$POOL/@data"

TEMP_SUBVOL="@overlay-update"
TEMP_ROOT="$POOL/$TEMP_SUBVOL"

BASE="$POOL/@base"
BASE_OLD="$POOL/@base-old"
BASE_OLD2="$POOL/@base-old-2"
RECOVERY="$POOL/@overlay-recovery"

PROMOTE_FILE="$DATA/update-base-promote"
FAILED_FILE="$DATA/update-base-failed"
MODE_FILE="$DATA/update-base-mode"
RETURN_FILE="$DATA/update-base-return"
RESULT_FILE="$DATA/update-base-result"

log() { echo "immutable-update-base-promote: $*"; }

ensure_pool() {
    if ! mountpoint -q "$POOL" 2>/dev/null; then
        local dev fstype
        dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
        fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || true)
        [ "$fstype" = "btrfs" ] || return 1
        mkdir -p "$POOL"
        mount -o subvolid=5 "$dev" "$POOL" 2>/dev/null || return 1
    fi
    mkdir -p "$DATA" 2>/dev/null || true
}

clear_markers() {
    rm -f "$PROMOTE_FILE" "$FAILED_FILE" "$MODE_FILE" "$RETURN_FILE"
}

remove_self() {
    rm -f /etc/systemd/system/multi-user.target.wants/immutable-update-base-promote.service \
          /etc/systemd/system/immutable-update-base-promote.service \
          /usr/local/sbin/immutable-update-base-promote.sh
}

# Never run inside the temp overlay itself.
running=$(findmnt -n -o OPTIONS / 2>/dev/null | tr ',' '\n' | sed -n 's/^subvol=//p')
if [ "$running" = "$TEMP_SUBVOL" ]; then
    log "refusing to promote while booted into $TEMP_SUBVOL"
    exit 0
fi

ensure_pool || exit 0

# Nothing pending: remove the injected machinery and go away.
if [ ! -f "$PROMOTE_FILE" ] && [ ! -f "$FAILED_FILE" ]; then
    remove_self
    exit 0
fi

# Failed update/restore: discard the temp overlay and report.
if [ -f "$FAILED_FILE" ]; then
    reason=$(cat "$FAILED_FILE" 2>/dev/null || echo "unknown failure")
    log "previous update failed: $reason"
    echo "Last base update FAILED and was rolled back: $reason" > "$RESULT_FILE" 2>/dev/null || true
    if [ -d "$TEMP_ROOT" ]; then
        btrfs subvolume delete "$TEMP_ROOT" 2>/dev/null || log "warning: could not delete $TEMP_ROOT"
    fi
    clear_markers
    remove_self
    exit 0
fi

# ── Promote ──
if [ ! -d "$TEMP_ROOT" ]; then
    log "temp overlay missing; nothing to promote"
    clear_markers
    remove_self
    exit 0
fi

mode=$(cat "$MODE_FILE" 2>/dev/null || echo "update")

log "shifting base chain (keep 2)"
[ -d "$BASE_OLD2" ] && btrfs subvolume delete "$BASE_OLD2"
[ -d "$BASE_OLD" ] && mv "$BASE_OLD" "$BASE_OLD2"
[ -d "$BASE" ] && mv "$BASE" "$BASE_OLD"

log "promoting $TEMP_SUBVOL to @base"
mv "$TEMP_ROOT" "$BASE"

# Point the promoted base's own boot entry at itself before locking it.
sed -i 's|rootflags=subvol=[^ ]*|rootflags=subvol=@base|g' \
    "$BASE/boot/efi/loader/entries/immutable.conf" 2>/dev/null || true

btrfs property set "$BASE" ro true

log "recreating @overlay-recovery from new @base"
if [ -d "$RECOVERY" ]; then
    btrfs property set "$RECOVERY" ro false 2>/dev/null || true
    btrfs subvolume delete "$RECOVERY"
fi
btrfs subvolume snapshot "$BASE" "$RECOVERY"
sed -i 's|rootflags=subvol=[^ ]*|rootflags=subvol=@overlay-recovery|g' \
    "$RECOVERY/boot/efi/loader/entries/immutable.conf" 2>/dev/null || true
sed -i 's|^default .*|default immutable.conf|' \
    "$RECOVERY/boot/efi/loader/loader.conf" 2>/dev/null || true
btrfs property set "$RECOVERY" ro true

clear_markers
if [ "$mode" = "restore" ]; then
    echo "Last base restore completed: the previous @base was restored and promoted." > "$RESULT_FILE" 2>/dev/null || true
else
    echo "Last base update completed: new @base is live (previous base kept as @base-old)." > "$RESULT_FILE" 2>/dev/null || true
fi
remove_self
log "promotion complete"
exit 0
"#;

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

fn data_path(cfg: &config::Config, name: &str) -> String {
    format!("{}/{}/{}", cfg.pool, cfg.data_subvol, name)
}

fn marker_exists(cfg: &config::Config, name: &str) -> bool {
    Path::new(&data_path(cfg, name)).exists()
}

fn write_marker(cfg: &config::Config, name: &str, value: &str) -> Result<(), String> {
    let path = data_path(cfg, name);
    std::fs::write(&path, value).map_err(|e| format!("Failed to write {path}: {e}"))
}

fn remove_marker(cfg: &config::Config, name: &str) {
    let _ = std::fs::remove_file(data_path(cfg, name));
}

fn write_file(path: &str, contents: &str) -> Result<(), String> {
    if let Some(parent) = Path::new(path).parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create {}: {e}", parent.display()))?;
    }
    std::fs::write(path, contents).map_err(|e| format!("Failed to write {path}: {e}"))
}

fn write_symlink(link: &str, target: &str) -> Result<(), String> {
    if let Some(parent) = Path::new(link).parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create {}: {e}", parent.display()))?;
    }
    let _ = std::fs::remove_file(link);
    std::os::unix::fs::symlink(target, link)
        .map_err(|e| format!("Failed to symlink {link} -> {target}: {e}"))
}

fn inject_update_files(root: &str) -> Result<(), String> {
    let sys = format!("{root}/etc/systemd/system");
    write_file(&format!("{sys}/immutable-update-base.target"), UPDATE_TARGET)?;
    write_file(&format!("{sys}/immutable-update-base.service"), UPDATE_SERVICE)?;
    write_file(&format!("{root}/usr/local/sbin/immutable-update-base.sh"), UPDATE_SCRIPT)?;
    Ok(())
}

fn inject_promote_files(root: &str) -> Result<(), String> {
    let sys = format!("{root}/etc/systemd/system");
    write_file(&format!("{sys}/immutable-update-base-promote.service"), PROMOTE_SERVICE)?;
    write_file(&format!("{root}/usr/local/sbin/immutable-update-base-promote.sh"), PROMOTE_SCRIPT)?;
    write_symlink(
        &format!("{sys}/multi-user.target.wants/immutable-update-base-promote.service"),
        "../immutable-update-base-promote.service",
    )?;
    Ok(())
}

fn add_update_unit_to_esp(cfg: &config::Config) -> Result<(), String> {
    let conf = format!("{}/loader/entries/immutable.conf", cfg.esp_path());
    let content = std::fs::read_to_string(&conf)
        .map_err(|e| format!("Cannot read {conf}: {e}"))?;
    let marker = "systemd.unit=immutable-update-base.target";
    if content.contains(marker) {
        return Ok(());
    }
    let updated: Vec<String> = content
        .lines()
        .map(|line| {
            if line.starts_with("options ") {
                format!("{line} {marker}")
            } else {
                line.to_string()
            }
        })
        .collect();
    std::fs::write(&conf, updated.join("\n") + "\n")
        .map_err(|e| format!("Failed to write {conf}: {e}"))
}

fn stage_real_esp(cfg: &config::Config, temp: &str) -> Result<(), String> {
    let was_ro = boot::esp_remount("rw")?;
    let res = (|| -> Result<(), String> {
        commands::sync_overlay_to_esp(temp, cfg)?;
        add_update_unit_to_esp(cfg)?;
        Ok(())
    })();
    if was_ro {
        boot::esp_remount("ro")?;
    }
    res
}

fn stage(mode: &str, no_reboot: bool) -> Result<(), String> {
    if unsafe { libc::getuid() != 0 } {
        return Err("update-base requires root. Run with sudo.".to_string());
    }

    let cfg = cfg();
    ensure_pool(&cfg)?;

    let temp = cfg.overlay_path("update");
    if Path::new(&temp).exists() {
        return Err(format!(
            "Temporary overlay {TEMP_SUBVOL} already exists. Finalize or discard the previous \
             update (it completes on your next normal boot), or delete it with \
             'immutable delete update'."
        ));
    }
    if marker_exists(&cfg, "update-base-promote") || marker_exists(&cfg, "update-base-failed") {
        return Err(
            "A previous base update has not been finalized. Boot into your normal overlay so it \
             can complete, then retry."
                .to_string(),
        );
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
    let return_root = format!("{}/{}", cfg.pool, active);

    remove_marker(&cfg, "update-base-result");

    // 1. Snapshot the source into the temporary update overlay.
    btrfs::snapshot(&src, &temp)?;
    let mut guard = TempGuard::new(&temp);

    // 2. Seed the temp overlay's ESP copy and point it at itself.
    commands::customize_overlay_esp(&temp, TEMP_SUBVOL, &cfg, &src);
    boot::validate_overlay_esp(&temp, TEMP_SUBVOL)?;

    // 3. Inject the update worker into the temp overlay.
    inject_update_files(&temp)?;

    // 4. Save the real ESP into the return overlay's copy and record return info.
    let was_ro = boot::esp_remount("rw")?;
    let res = commands::sync_esp_to_overlay(&return_root, &cfg)
        .and_then(|_| write_marker(&cfg, "update-base-return", &active))
        .and_then(|_| write_marker(&cfg, "update-base-mode", mode));
    if was_ro {
        boot::esp_remount("ro")?;
    }
    res?;

    // 5. Inject the promoter into the return overlay so it finalizes the update.
    inject_promote_files(&return_root)?;

    // 6. Stage the real ESP for the update boot.
    stage_real_esp(&cfg, &temp)?;

    guard.keep();

    if no_reboot {
        println!("Base {mode} staged into {TEMP_SUBVOL}.");
        println!("  source:        {src_label}");
        println!("  return after:  {active}");
        println!("Reboot to begin. The update runs unattended and returns here.");
        Ok(())
    } else {
        println!("Base {mode} staged. Rebooting into {TEMP_SUBVOL}...");
        let status = std::process::Command::new("systemctl")
            .arg("reboot")
            .status()
            .map_err(|e| format!("Failed to reboot: {e}"))?;
        if !status.success() {
            return Err("Reboot command failed — please reboot manually.".to_string());
        }
        Ok(())
    }
}

pub fn cmd_update_base(no_reboot: bool) -> Result<(), String> {
    stage("update", no_reboot)
}

pub fn cmd_restore_base(no_reboot: bool) -> Result<(), String> {
    stage("restore", no_reboot)
}
