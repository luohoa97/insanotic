// SPDX-License-Identifier: GPL-3.0-or-later
//! Launcher settings, stored as JSON in ~/.config/insanotic/launcher.json.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(default)]
pub struct Config {
    /// Insanotic checkout or install directory; empty means "detect".
    pub game_path: String,
    pub fullscreen: bool,
    /// "native" or "<width>x<height>".
    pub resolution: String,
    pub extra_args: String,
    pub map: String,
    pub bots: u32,
    pub port: u32,
    pub server_plugins: bool,
    /// Folder names of client mods switched off (passed as cl_lua_disabled).
    pub disabled_mods: Vec<String>,
    /// Folder names of server plugins switched off (passed as sv_lua_disabled).
    pub disabled_plugins: Vec<String>,
    pub aim_assist_mode: u32,
    pub touch_controls_force: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            game_path: String::new(),
            fullscreen: false,
            resolution: "native".into(),
            extra_args: String::new(),
            map: String::new(),
            bots: 3,
            port: 26000,
            server_plugins: true,
            disabled_mods: Vec::new(),
            disabled_plugins: Vec::new(),
            aim_assist_mode: 2,
            touch_controls_force: false,
        }
    }
}

fn config_file() -> PathBuf {
    gtk::glib::user_config_dir().join("insanotic").join("launcher.json")
}

impl Config {
    pub fn load() -> Config {
        std::fs::read_to_string(config_file())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let path = config_file();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            if let Err(e) = std::fs::write(&path, json) {
                eprintln!("cannot save {}: {e}", path.display());
            }
        }
    }

    /// The Insanotic directory: the configured path, else $INSANOTIC_DIR,
    /// else the checkout this launcher was built from, else a checkout
    /// found next to (or above) the executable.
    pub fn game_dir(&self) -> PathBuf {
        if !self.game_path.trim().is_empty() {
            return PathBuf::from(self.game_path.trim());
        }
        default_game_dir()
    }
}

pub fn default_game_dir() -> PathBuf {
    if crate::assets::bundle_dir().is_some() {
        return crate::assets::overlay_dir();
    }
    if let Ok(dir) = std::env::var("INSANOTIC_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    let built_from = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    if built_from.join("darkplaces").is_dir() {
        return built_from.canonicalize().unwrap_or(built_from);
    }
    if let Ok(exe) = std::env::current_exe() {
        for dir in exe.ancestors().skip(1) {
            if dir.join("darkplaces").is_dir() {
                return dir.to_path_buf();
            }
        }
    }
    built_from
}

/// The per-user Xonotic data directory (~/.xonotic/data).
pub fn user_data_dir() -> PathBuf {
    gtk::glib::home_dir().join(".xonotic").join("data")
}
