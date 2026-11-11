// SPDX-License-Identifier: GPL-3.0-or-later
//! Finds maps, client mods and server plugins on disk.

use serde::Deserialize;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[derive(Deserialize, Default)]
struct Meta {
    name: Option<String>,
    version: Option<String>,
    description: Option<String>,
    order: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct Extension {
    /// Folder name, as used by cl_lua_disabled.
    pub folder: String,
    pub name: String,
    pub version: String,
    pub description: String,
    pub order: i64,
    /// "Bundled" or "User".
    pub origin: &'static str,
}

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    Mod,
    Plugin,
}

impl Kind {
    fn dir(self) -> &'static str {
        match self {
            Kind::Mod => "mods",
            Kind::Plugin => "plugins",
        }
    }
    fn meta(self) -> &'static str {
        match self {
            Kind::Mod => "mod.json",
            Kind::Plugin => "plugin.json",
        }
    }
}

/// Folder that holds bundled mods and plugins.
pub fn bundled_dir(game: &Path, kind: Kind) -> PathBuf {
    game.join("data/insanotic.pk3dir").join(kind.dir())
}

/// Folder in the user's data directory (created on demand by the UI).
pub fn user_dir(kind: Kind) -> PathBuf {
    crate::config::user_data_dir().join(kind.dir())
}

pub fn scan_extensions(game: &Path, kind: Kind) -> Vec<Extension> {
    let mut out = Vec::new();
    for (dir, origin) in [(bundled_dir(game, kind), "Bundled"), (user_dir(kind), "User")] {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let path = e.path();
            if !path.join("init.lua").is_file() {
                continue;
            }
            let folder = e.file_name().to_string_lossy().into_owned();
            let meta: Meta = std::fs::read_to_string(path.join(kind.meta()))
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();
            out.push(Extension {
                name: meta.name.unwrap_or_else(|| folder.clone()),
                version: meta.version.unwrap_or_default(),
                description: meta.description.unwrap_or_default(),
                order: meta.order.unwrap_or(0),
                folder,
                origin,
            });
        }
    }
    out.sort_by(|a, b| (a.order, &a.folder).cmp(&(b.order, &b.folder)));
    out
}

/// Map names from data/*.pk3 (zip archives) and data/*.pk3dir/maps/*.bsp,
/// in the game directory and in the user's data directory.
pub fn scan_maps(game: &Path) -> Vec<String> {
    let mut maps = BTreeSet::new();
    for data in [game.join("data"), crate::config::user_data_dir()] {
        let Ok(rd) = std::fs::read_dir(&data) else { continue };
        for e in rd.flatten() {
            let path = e.path();
            let name = e.file_name().to_string_lossy().into_owned();
            if name.ends_with(".pk3dir") {
                if let Ok(files) = std::fs::read_dir(path.join("maps")) {
                    for f in files.flatten() {
                        add_bsp(&mut maps, &f.file_name().to_string_lossy());
                    }
                }
            } else if name.ends_with(".pk3") {
                let Ok(file) = std::fs::File::open(&path) else { continue };
                let Ok(zip) = zip::ZipArchive::new(file) else { continue };
                for entry in zip.file_names() {
                    if let Some(rest) = entry.strip_prefix("maps/") {
                        add_bsp(&mut maps, rest);
                    }
                }
            }
        }
    }
    maps.into_iter().collect()
}

fn add_bsp(set: &mut BTreeSet<String>, file: &str) {
    if let Some(stem) = file.strip_suffix(".bsp") {
        if !stem.is_empty() && !stem.contains('/') && !stem.starts_with('_') {
            set.insert(stem.to_string());
        }
    }
}
