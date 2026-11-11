// SPDX-License-Identifier: GPL-3.0-or-later
//! Game assets and the Flatpak layout.
//!
//! Insanotic needs the maps, textures and sounds of Xonotic 0.8.6, which are
//! far too big to ship. This module finds them in an installed Xonotic,
//! links them in, or downloads the official release zip and unpacks the
//! three packs from it.
//!
//! Inside a Flatpak the program files live in a read-only bundle directory
//! ($INSANOTIC_BUNDLE). The game directory is then a small writable overlay
//! of symlinks to the bundle, so the asset packs can sit next to the game
//! code in data/ like in a development checkout.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

pub const VERSION: &str = "20230620";
const RELEASE_URL: &str = "https://dl.xonotic.org/xonotic-0.8.6.zip";

/// The release zip; $INSANOTIC_ASSETS_URL overrides it (mirrors, tests).
fn release_url() -> String {
    std::env::var("INSANOTIC_ASSETS_URL").unwrap_or_else(|_| RELEASE_URL.to_string())
}
const PACKS: [&str; 3] = ["maps", "music", "data"];

pub fn bundle_dir() -> Option<PathBuf> {
    std::env::var_os("INSANOTIC_BUNDLE")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

pub fn overlay_dir() -> PathBuf {
    gtk::glib::user_data_dir().join("insanotic").join("game")
}

fn link(target: &Path, at: &Path) -> io::Result<()> {
    if let Ok(meta) = std::fs::symlink_metadata(at) {
        if !meta.file_type().is_symlink() {
            return Ok(()); // a real file or directory of the user: keep it
        }
        if std::fs::read_link(at)? == target {
            return Ok(());
        }
        std::fs::remove_file(at)?;
    }
    std::os::unix::fs::symlink(target, at)
}

/// Makes `overlay` mirror `bundle` with symlinks (data/ one level deeper,
/// so packs can be added to it). Safe to run on every start.
pub fn prepare_overlay(bundle: &Path, overlay: &Path) -> io::Result<()> {
    std::fs::create_dir_all(overlay.join("data"))?;
    for entry in std::fs::read_dir(bundle)?.flatten() {
        let name = entry.file_name();
        if name == "data" {
            for sub in std::fs::read_dir(entry.path())?.flatten() {
                link(&sub.path(), &overlay.join("data").join(sub.file_name()))?;
            }
        } else {
            link(&entry.path(), &overlay.join(&name))?;
        }
    }
    // drop links to bundle files that a newer version no longer has
    if let Ok(rd) = std::fs::read_dir(overlay.join("data")) {
        for e in rd.flatten() {
            let p = e.path();
            if let Ok(t) = std::fs::read_link(&p) {
                if t.starts_with(bundle) && !t.exists() {
                    let _ = std::fs::remove_file(&p);
                }
            }
        }
    }
    Ok(())
}

fn pack_name(pack: &str) -> String {
    format!("xonotic-{VERSION}-{pack}.pk3")
}

/// True when the release map pack is reachable from the game or user data dir.
pub fn assets_present(game: &Path) -> bool {
    let name = pack_name("maps");
    game.join("data").join(&name).is_file() || crate::config::user_data_dir().join(&name).is_file()
}

/// Data directory of an installed Xonotic 0.8.6 (Flatpak or unpacked release).
pub fn find_installed() -> Option<PathBuf> {
    let home = gtk::glib::home_dir();
    let rel = "app/org.xonotic.Xonotic/current/active/files/share/xonotic/data";
    [
        PathBuf::from("/var/lib/flatpak").join(rel),
        home.join(".local/share/flatpak").join(rel),
        home.join("Xonotic/data"),
    ]
    .into_iter()
    .find(|d| d.join(pack_name("maps")).is_file())
}

/// Symlinks the release packs found in `src` into `<game>/data`.
pub fn link_installed(src: &Path, game: &Path) -> Result<(), String> {
    let dest = game.join("data");
    std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
    for pack in PACKS {
        let name = pack_name(pack);
        let from = src.join(&name);
        if from.is_file() {
            let at = dest.join(&name);
            let _ = std::fs::remove_file(&at);
            std::os::unix::fs::symlink(&from, &at).map_err(|e| format!("{}: {e}", at.display()))?;
        }
    }
    Ok(())
}

/// Progress of a running download, polled by the UI.
#[derive(Default)]
pub struct Progress {
    pub total: AtomicU64,
    /// Bytes downloaded, then bytes unpacked.
    pub done: AtomicU64,
    /// 0 downloading, 1 unpacking
    pub stage: AtomicU64,
}

fn zip_path() -> PathBuf {
    gtk::glib::user_cache_dir().join("insanotic").join("xonotic-0.8.6.zip")
}

/// Downloads the release zip with curl and unpacks the three packs into
/// `<game>/data`. Blocks; run it on a worker thread.
pub fn download(game: &Path, progress: Arc<Progress>) -> Result<(), String> {
    let zip = zip_path();
    std::fs::create_dir_all(zip.parent().unwrap()).map_err(|e| e.to_string())?;
    let head = std::process::Command::new("curl")
        .args(["-sIL", &release_url()])
        .output()
        .map_err(|e| format!("cannot run curl: {e}"))?;
    let total = String::from_utf8_lossy(&head.stdout)
        .lines()
        .filter_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse::<u64>().ok()))
        .flatten()
        .last()
        .unwrap_or(0);
    progress.total.store(total, Ordering::Relaxed);

    // -C - resumes an interrupted download
    let status = std::process::Command::new("curl")
        .args(["-fL", "--retry", "3", "-C", "-", "-o"])
        .arg(&zip)
        .arg(release_url())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("cannot run curl: {e}"))?;
    if !status.success() {
        return Err("The download failed. Check your network connection and try again.".into());
    }

    progress.stage.store(1, Ordering::Relaxed);
    progress.done.store(0, Ordering::Relaxed);
    let file = std::fs::File::open(&zip).map_err(|e| e.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| format!("The downloaded file is damaged: {e}"))?;
    let wanted: Vec<String> = PACKS.iter().map(|p| pack_name(p)).collect();
    let dest = game.join("data");
    std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
    let mut found = 0;
    let total_unpack: u64 = (0..archive.len())
        .filter_map(|i| archive.by_index_raw(i).ok().map(|f| (f.name().to_string(), f.size())))
        .filter(|(n, _)| wanted.iter().any(|w| n.ends_with(w.as_str())))
        .map(|(_, s)| s)
        .sum();
    progress.total.store(total_unpack, Ordering::Relaxed);
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let Some(name) = wanted.iter().find(|w| entry.name().ends_with(w.as_str())) else { continue };
        let out_path = dest.join(name);
        let _ = std::fs::remove_file(&out_path); // may be a symlink
        let mut out = std::fs::File::create(&out_path).map_err(|e| format!("{}: {e}", out_path.display()))?;
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = io::Read::read(&mut entry, &mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            io::Write::write_all(&mut out, &buf[..n]).map_err(|e| e.to_string())?;
            progress.done.fetch_add(n as u64, Ordering::Relaxed);
        }
        found += 1;
    }
    if found == 0 {
        return Err("The downloaded archive does not contain the game packs.".into());
    }
    let _ = std::fs::remove_file(&zip);
    Ok(())
}

/// Bytes of the partial download on disk (for the progress display).
pub fn partial_size() -> u64 {
    std::fs::metadata(zip_path()).map(|m| m.len()).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn download_unpacks_the_packs_from_a_zip() {
        let dir = std::env::temp_dir().join(format!("insanotic-assets-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let zip_file = dir.join("release.zip");
        {
            let mut zw = zip::ZipWriter::new(std::fs::File::create(&zip_file).unwrap());
            let opts = zip::write::SimpleFileOptions::default();
            for pack in PACKS {
                zw.start_file(format!("Xonotic/data/{}", pack_name(pack)), opts).unwrap();
                zw.write_all(pack.as_bytes()).unwrap();
            }
            zw.start_file("Xonotic/README.txt", opts).unwrap();
            zw.write_all(b"not a pack").unwrap();
            zw.finish().unwrap();
        }
        std::env::set_var("INSANOTIC_ASSETS_URL", format!("file://{}", zip_file.display()));
        std::env::set_var("XDG_CACHE_HOME", dir.join("cache"));
        let game = dir.join("game");
        download(&game, Arc::new(Progress::default())).unwrap();
        for pack in PACKS {
            let got = std::fs::read_to_string(game.join("data").join(pack_name(pack))).unwrap();
            assert_eq!(got, pack);
        }
        assert!(!game.join("data/README.txt").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
