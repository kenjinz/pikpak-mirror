//! The PowerShell engine travels inside the app. `build.rs` embeds `scripts\*.ps1` and the two
//! config templates; on a start where no scripts folder is found, `ensure_unpacked` puts them in
//! `%LOCALAPPDATA%\PikPakSync\` (same shape as the repo) so the engine, the scheduled task and the
//! helper scripts all resolve from there.

use std::fs::{self, OpenOptions};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

mod generated {
    // FILES and HASH, written by build.rs.
    include!(concat!(env!("OUT_DIR"), "/engine_bundle.rs"));
}

/// The bridge script every root must have (also the "is this a usable root" test).
pub const BRIDGE_REL: &str = "scripts/Invoke-GuiAction.ps1";
const MARKER: &str = "engine.hash";
const LOCK: &str = "engine.lock";
/// Config templates the user may edit: written only when missing.
const KEEP_IF_PRESENT: [&str; 1] = ["config/filters.txt"];
const LOCK_WAIT: Duration = Duration::from_secs(10);
const LOCK_STALE: Duration = Duration::from_secs(60);
const LOCK_POLL: Duration = Duration::from_millis(50);

/// What gets unpacked: relative paths (with `/`) under `scripts/` and `config/`, and one hash of all of it.
pub struct Bundle<'a> {
    pub files: &'a [(&'a str, &'a [u8])],
    pub hash: &'a str,
}

/// The bundle `build.rs` embedded.
pub fn embedded() -> Bundle<'static> {
    Bundle { files: generated::FILES, hash: generated::HASH }
}

/// `%LOCALAPPDATA%\PikPakSync`; `None` when `LOCALAPPDATA` is unset or empty.
pub fn engine_root() -> Option<PathBuf> {
    let base = std::env::var_os("LOCALAPPDATA").filter(|v| !v.is_empty())?;
    Some(PathBuf::from(base).join("PikPakSync"))
}

fn rel_path(root: &Path, rel: &str) -> PathBuf {
    rel.split('/').fold(root.to_path_buf(), |p, part| p.join(part))
}

fn is_current(root: &Path, bundle: &Bundle) -> bool {
    rel_path(root, BRIDGE_REL).is_file()
        && fs::read_to_string(root.join(MARKER)).map(|h| h.trim() == bundle.hash).unwrap_or(false)
}

/// Holds `engine.lock` (created exclusively) and removes it when dropped.
struct UnpackLock(PathBuf);

impl UnpackLock {
    fn take(root: &Path) -> Result<UnpackLock, String> {
        let path = root.join(LOCK);
        let started = std::time::Instant::now();
        loop {
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(_) => return Ok(UnpackLock(path)),
                Err(e) if e.kind() == ErrorKind::AlreadyExists => {
                    let age = fs::metadata(&path)
                        .and_then(|m| m.modified())
                        .ok()
                        .and_then(|t| SystemTime::now().duration_since(t).ok());
                    if age.is_some_and(|a| a > LOCK_STALE) {
                        let _ = fs::remove_file(&path);
                        continue;
                    }
                    if started.elapsed() > LOCK_WAIT {
                        return Err(format!("another PikPak Sync is still unpacking ({} exists)", path.display()));
                    }
                    std::thread::sleep(LOCK_POLL);
                }
                Err(e) => return Err(format!("cannot create {}: {e}", path.display())),
            }
        }
    }
}

impl Drop for UnpackLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    }
    fs::write(path, bytes).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// Puts `bundle` in `root` unless it is already there (same hash and the bridge script exists).
/// `scripts\` is replaced as a whole (old files go); `config\mirror.config.psd1` and friends are never
/// touched. When the swap fails (for example a sync is running from the old scripts) the old engine and
/// its marker stay as they were and an `Err` says why.
pub fn ensure_unpacked(root: &Path, bundle: &Bundle) -> Result<(), String> {
    if is_current(root, bundle) {
        return Ok(());
    }
    fs::create_dir_all(root).map_err(|e| format!("cannot create {}: {e}", root.display()))?;
    let _lock = UnpackLock::take(root)?;
    if is_current(root, bundle) {
        return Ok(()); // another copy of the app finished while we waited
    }

    let (scripts, fresh, old) = (root.join("scripts"), root.join("scripts.new"), root.join("scripts.old"));
    let _ = fs::remove_dir_all(&fresh);
    let _ = fs::remove_dir_all(&old);
    for (rel, bytes) in bundle.files.iter().filter(|(rel, _)| rel.starts_with("scripts/")) {
        let target = rel_path(&fresh, &rel["scripts/".len()..]);
        if let Err(e) = write_file(&target, bytes) {
            let _ = fs::remove_dir_all(&fresh);
            return Err(e);
        }
    }

    if scripts.exists() {
        if let Err(e) = fs::rename(&scripts, &old) {
            let _ = fs::remove_dir_all(&fresh);
            return Err(format!("cannot replace {} (in use?): {e}", scripts.display()));
        }
    }
    if let Err(e) = fs::rename(&fresh, &scripts) {
        let _ = fs::rename(&old, &scripts);
        let _ = fs::remove_dir_all(&fresh);
        return Err(format!("cannot put the new scripts in {}: {e}", scripts.display()));
    }
    let _ = fs::remove_dir_all(&old);

    for (rel, bytes) in bundle.files.iter().filter(|(rel, _)| rel.starts_with("config/")) {
        let target = rel_path(root, rel);
        if KEEP_IF_PRESENT.contains(rel) && target.exists() {
            continue;
        }
        write_file(&target, bytes)?;
    }
    write_file(&root.join(MARKER), bundle.hash.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, OpenOptions};
    use std::os::windows::fs::OpenOptionsExt;
    use std::path::PathBuf;
    use std::time::{Duration, Instant, SystemTime};

    fn temp_root(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pikpak-engine-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    fn b(s: &'static str) -> &'static [u8] {
        s.as_bytes()
    }

    fn v1() -> [(&'static str, &'static [u8]); 5] {
        [
            ("scripts/Invoke-GuiAction.ps1", b("bridge1")),
            ("scripts/lib/a.ps1", b("a1")),
            ("scripts/old.ps1", b("old")),
            ("config/mirror.config.sample.psd1", b("sample1")),
            ("config/filters.txt", b("filters1")),
        ]
    }

    /// Drops `scripts/old.ps1`, changes the rest.
    fn v2() -> [(&'static str, &'static [u8]); 4] {
        [
            ("scripts/Invoke-GuiAction.ps1", b("bridge2")),
            ("scripts/lib/a.ps1", b("a2")),
            ("config/mirror.config.sample.psd1", b("sample2")),
            ("config/filters.txt", b("filters2")),
        ]
    }

    fn read(root: &PathBuf, rel: &str) -> String {
        fs::read_to_string(root.join(rel)).unwrap_or_else(|e| format!("<{rel}: {e}>"))
    }

    #[test]
    fn fresh_unpack_writes_scripts_config_and_marker() {
        let root = temp_root("fresh");
        let files = v1();
        ensure_unpacked(&root, &Bundle { files: &files, hash: "h1" }).unwrap();
        assert_eq!(read(&root, "scripts/Invoke-GuiAction.ps1"), "bridge1");
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a1");
        assert_eq!(read(&root, "config/mirror.config.sample.psd1"), "sample1");
        assert_eq!(read(&root, "config/filters.txt"), "filters1");
        assert_eq!(read(&root, "engine.hash"), "h1");
        assert!(!root.join("engine.lock").exists(), "the lock is released");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn same_hash_is_a_no_op() {
        let root = temp_root("noop");
        let files = v1();
        let bundle = Bundle { files: &files, hash: "h1" };
        ensure_unpacked(&root, &bundle).unwrap();
        fs::write(root.join("scripts/lib/a.ps1"), "tampered").unwrap();
        ensure_unpacked(&root, &bundle).unwrap();
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "tampered");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn missing_bridge_script_unpacks_again_even_with_the_same_hash() {
        let root = temp_root("repair");
        let files = v1();
        let bundle = Bundle { files: &files, hash: "h1" };
        ensure_unpacked(&root, &bundle).unwrap();
        fs::remove_file(root.join("scripts/Invoke-GuiAction.ps1")).unwrap();
        ensure_unpacked(&root, &bundle).unwrap();
        assert_eq!(read(&root, "scripts/Invoke-GuiAction.ps1"), "bridge1");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn new_hash_refreshes_scripts_and_removes_stale_files() {
        let root = temp_root("upgrade");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &Bundle { files: &f1, hash: "h1" }).unwrap();
        ensure_unpacked(&root, &Bundle { files: &f2, hash: "h2" }).unwrap();
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a2");
        assert_eq!(read(&root, "scripts/Invoke-GuiAction.ps1"), "bridge2");
        assert!(!root.join("scripts/old.ps1").exists(), "a script the new version dropped is gone");
        assert_eq!(read(&root, "engine.hash"), "h2");
        assert!(!root.join("scripts.new").exists() && !root.join("scripts.old").exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn upgrade_keeps_user_config() {
        let root = temp_root("keepconfig");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &Bundle { files: &f1, hash: "h1" }).unwrap();
        fs::write(root.join("config/mirror.config.psd1"), "mine").unwrap();
        fs::write(root.join("config/mirror.config.psd1.bak"), "mine.bak").unwrap();
        fs::write(root.join("config/mirror.config.original.psd1"), "mine.original").unwrap();
        fs::write(root.join("config/filters.txt"), "my edited filters").unwrap();
        ensure_unpacked(&root, &Bundle { files: &f2, hash: "h2" }).unwrap();
        assert_eq!(read(&root, "config/mirror.config.psd1"), "mine");
        assert_eq!(read(&root, "config/mirror.config.psd1.bak"), "mine.bak");
        assert_eq!(read(&root, "config/mirror.config.original.psd1"), "mine.original");
        assert_eq!(read(&root, "config/filters.txt"), "my edited filters");
        assert_eq!(read(&root, "config/mirror.config.sample.psd1"), "sample2", "the template is refreshed");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn locked_old_scripts_keep_the_old_engine() {
        let root = temp_root("locked");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &Bundle { files: &f1, hash: "h1" }).unwrap();
        // Read-share only: a running script that blocks renaming the folder it lives in.
        let held = OpenOptions::new().read(true).share_mode(1).open(root.join("scripts/lib/a.ps1")).unwrap();
        let err = ensure_unpacked(&root, &Bundle { files: &f2, hash: "h2" }).unwrap_err();
        assert!(!err.is_empty());
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a1", "the old engine is intact");
        assert_eq!(read(&root, "scripts/old.ps1"), "old");
        assert_eq!(read(&root, "engine.hash"), "h1", "the marker still says the old version");
        assert!(!root.join("scripts.new").exists() && !root.join("scripts.old").exists(), "no half-state left");
        assert!(!root.join("engine.lock").exists(), "the lock is released after a failure");
        drop(held);
        ensure_unpacked(&root, &Bundle { files: &f2, hash: "h2" }).unwrap();
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a2");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn second_process_waits_for_the_lock() {
        let root = temp_root("lockwait");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("engine.lock"), "").unwrap();
        let files = v1();
        let started = Instant::now();
        std::thread::scope(|s| {
            let worker = s.spawn(|| ensure_unpacked(&root, &Bundle { files: &files, hash: "h1" }));
            std::thread::sleep(Duration::from_millis(300));
            assert!(!root.join("engine.hash").exists(), "nothing is written while the lock is held");
            fs::remove_file(root.join("engine.lock")).unwrap();
            worker.join().unwrap().unwrap();
        });
        assert!(started.elapsed() >= Duration::from_millis(250));
        assert_eq!(read(&root, "engine.hash"), "h1");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn stale_lock_is_replaced() {
        let root = temp_root("stalelock");
        fs::create_dir_all(&root).unwrap();
        let lock = root.join("engine.lock");
        fs::write(&lock, "").unwrap();
        let old = SystemTime::now() - Duration::from_secs(120);
        OpenOptions::new().write(true).open(&lock).unwrap().set_modified(old).unwrap();
        let files = v1();
        ensure_unpacked(&root, &Bundle { files: &files, hash: "h1" }).unwrap();
        assert_eq!(read(&root, "engine.hash"), "h1");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn embedded_bundle_matches_the_allowlist() {
        let bundle = embedded();
        let paths: Vec<&str> = bundle.files.iter().map(|(p, _)| *p).collect();
        for needed in [
            BRIDGE_REL,
            "scripts/lib/GuiActions.ps1",
            "config/mirror.config.sample.psd1",
            "config/filters.txt",
        ] {
            assert!(paths.contains(&needed), "{needed} is embedded");
        }
        for p in &paths {
            let ok = (p.starts_with("scripts/") && p.ends_with(".ps1"))
                || *p == "config/mirror.config.sample.psd1"
                || *p == "config/filters.txt";
            assert!(ok, "{p} is not on the allowlist");
        }
        assert!(!paths.contains(&"config/mirror.config.psd1"), "the owner's real config is never embedded");
        assert_eq!(bundle.hash.len(), 16);
        assert!(bundle.hash.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(bundle.files.iter().all(|(_, bytes)| !bytes.is_empty()));
    }
}
