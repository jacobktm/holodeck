use std::path::Path;
use libc;

const DEFAULT_POOL: &str = "/pool";
const DEFAULT_BASE: &str = "@base";
const DEFAULT_INIT: &str = "@overlay-init";
const DEFAULT_RECOVERY: &str = "@overlay-recovery";
const DEFAULT_DATA: &str = "@data";

pub struct Config {
    pub pool: String,
    pub base_subvol: String,
    pub init_overlay: String,
    pub recovery_overlay: String,
    pub data_subvol: String,
    pub username: String,
}

impl Config {
    pub fn load() -> Self {
        let username = resolve_username();
        Self {
            pool: DEFAULT_POOL.to_string(),
            base_subvol: DEFAULT_BASE.to_string(),
            init_overlay: DEFAULT_INIT.to_string(),
            recovery_overlay: DEFAULT_RECOVERY.to_string(),
            data_subvol: DEFAULT_DATA.to_string(),
            username,
        }
    }

    pub fn load_with_pool(pool: &str) -> Self {
        let mut cfg = Self::load();
        cfg.pool = pool.to_string();
        cfg
    }

    pub fn overlay_path(&self, name: &str) -> String {
        format!("{}/@overlay-{}", self.pool, name)
    }

    pub fn base_path(&self) -> String {
        format!("{}/{}", self.pool, self.base_subvol)
    }

    pub fn init_path(&self) -> String {
        format!("{}/{}", self.pool, self.init_overlay)
    }

    pub fn recovery_path(&self) -> String {
        format!("{}/{}", self.pool, self.recovery_overlay)
    }

    pub fn subvol_path(&self, name: &str) -> String {
        if name == self.base_subvol {
            self.base_path()
        } else if name == self.data_subvol {
            format!("{}/{}", self.pool, self.data_subvol)
        } else {
            self.overlay_path(name)
        }
    }

    pub fn pool_mounted(&self) -> bool {
        Path::new(&self.pool).join("BASE_SUBVOL").exists()
            || Path::new(&self.base_path()).exists()
    }

    pub fn esp_path(&self) -> &str {
        "/boot/efi"
    }
}

fn resolve_username() -> String {
    // 1. SUDO_USER — the user who ran sudo
    if let Ok(name) = std::env::var("SUDO_USER") {
        if !name.is_empty() {
            return name;
        }
    }

    // 2. Running directly as root — stay root
    if unsafe { libc::getuid() == 0 } {
        return "root".to_string();
    }

    // 3. /etc/immutable.conf — explicit configuration
    if let Ok(content) = std::fs::read_to_string("/etc/immutable.conf") {
        for line in content.lines() {
            if let Some(val) = line.strip_prefix("USERNAME=") {
                let val = val.trim();
                if !val.is_empty() {
                    return val.to_string();
                }
            }
        }
    }

    // 4. Scan /home/* for real user directories (skip root)
    if let Ok(entries) = std::fs::read_dir("/home") {
        let mut users: Vec<String> = entries
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().to_string();
                if name == "root" || name.starts_with('.') {
                    None
                } else {
                    Some(name)
                }
            })
            .collect();
        users.sort();
        if let Some(name) = users.into_iter().next() {
            return name;
        }
    }

    // 5. Last resort
    "user".to_string()
}
