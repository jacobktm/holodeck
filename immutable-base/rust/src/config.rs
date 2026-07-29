use std::path::Path;

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
}

impl Config {
    pub fn load() -> Self {
        Self {
            pool: DEFAULT_POOL.to_string(),
            base_subvol: DEFAULT_BASE.to_string(),
            init_overlay: DEFAULT_INIT.to_string(),
            recovery_overlay: DEFAULT_RECOVERY.to_string(),
            data_subvol: DEFAULT_DATA.to_string(),
        }
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
