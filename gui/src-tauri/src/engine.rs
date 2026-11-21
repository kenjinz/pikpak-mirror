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

/// Filesystem renames are retried: antivirus or the search indexer can hold freshly written files for a moment.
const SWAP_TRIES: u32 = 10;
const SWAP_PAUSE: Duration = Duration::from_millis(300);

/// What gets unpacked: relative paths (with `/`) under `scripts/` and `config/`, one hash of all of it,
/// and the version of the app that carries it (an older app never replaces a newer engine).
pub struct Bundle<'a> {
    pub files: &'a [(&'a str, &'a [u8])],
    pub hash: &'a str,
    pub version: &'a str,
}

/// The bundle `build.rs` embedded.
pub fn embedded() -> Bundle<'static> {
    Bundle { files: generated::FILES, hash: generated::HASH, version: env!("CARGO_PKG_VERSION") }
}

/// Numeric dotted-version order ("0.10.0" is newer than "0.9.0"); a suffix such as "-beta" is ignored.
fn version_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    fn parts(v: &str) -> Vec<u64> {
        v.split('.')
            .map(|p| p.chars().take_while(char::is_ascii_digit).collect::<String>().parse().unwrap_or(0))
            .collect()
    }
    let (a, b) = (parts(a), parts(b));
    for i in 0..a.len().max(b.len()) {
        match a.get(i).unwrap_or(&0).cmp(b.get(i).unwrap_or(&0)) {
            std::cmp::Ordering::Equal => continue,
            other => return other,
        }
    }
    std::cmp::Ordering::Equal
}

/// The `engine.hash` marker: `<app version> <hash>`. `None` when missing or not in that form.
fn read_marker(root: &Path) -> Option<(String, String)> {
    let text = fs::read_to_string(root.join(MARKER)).ok()?;
    let (version, hash) = text.trim().split_once(' ')?;
    Some((version.to_string(), hash.to_string()))
}

fn rename_with_retry(from: &Path, to: &Path) -> std::io::Result<()> {
    let mut attempt = 1;
    loop {
        match fs::rename(from, to) {
            Err(e) if attempt >= SWAP_TRIES => return Err(e),
            Err(_) => {
                attempt += 1;
                std::thread::sleep(SWAP_PAUSE);
            }
            Ok(()) => return Ok(()),
        }
    }
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
        && read_marker(root).is_some_and(|(version, hash)| version == bundle.version && hash == bundle.hash)
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

/// Puts `bundle` in `root` unless it is already there (same version and hash, and the bridge script exists).
/// `scripts\` is replaced as a whole (old files go); `config\mirror.config.psd1` and friends are never
/// touched. An app older than the engine already unpacked leaves that engine alone (an `Err` says so, and the
/// caller keeps using it). When the swap fails (for example a file is in use) the old engine and its marker
/// stay as they were and an `Err` says why.
pub fn ensure_unpacked(root: &Path, bundle: &Bundle) -> Result<(), String> {
    if is_current(root, bundle) {
        return Ok(());
    }
    fs::create_dir_all(root).map_err(|e| format!("cannot create {}: {e}", root.display()))?;
    let _lock = UnpackLock::take(root)?;
    if is_current(root, bundle) {
        return Ok(()); // another copy of the app finished while we waited
    }
    if let Some((installed, _)) = read_marker(root) {
        if version_cmp(&installed, bundle.version) == std::cmp::Ordering::Greater && rel_path(root, BRIDGE_REL).is_file() {
            return Err(format!(
                "the scripts in {} come from a newer PikPak Sync ({installed}); this app ({}) keeps using them",
                root.display(),
                bundle.version
            ));
        }
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
        if let Err(e) = rename_with_retry(&scripts, &old) {
            let _ = fs::remove_dir_all(&fresh);
            return Err(format!("cannot replace {} (in use?): {e}", scripts.display()));
        }
    }
    if let Err(e) = rename_with_retry(&fresh, &scripts) {
        let _ = rename_with_retry(&old, &scripts);
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
    write_file(&root.join(MARKER), format!("{} {}", bundle.version, bundle.hash).as_bytes())
}

/// Unpacks `bundle` into `root` and says where the engine is. A failed upgrade is logged through `log`;
/// the old engine in `root` is still used when its bridge script is there. `None`: nothing usable.
pub fn embedded_root_in(root: &Path, bundle: &Bundle, log: &dyn Fn(&str)) -> Option<PathBuf> {
    match ensure_unpacked(root, bundle) {
        Ok(()) => Some(root.to_path_buf()),
        Err(e) => {
            log(&format!("engine: could not unpack the PikPak Sync scripts into {}: {e}", root.display()));
            rel_path(root, BRIDGE_REL).is_file().then(|| root.to_path_buf())
        }
    }
}

/// The app's name as shown in the window title, tray and app bar.
pub const APP_NAME: &str = "PikPak Sync";

fn same_folder(a: &Path, b: &Path) -> bool {
    let key = |p: &Path| p.to_string_lossy().trim_end_matches(['\\', '/']).replace('/', "\\").to_lowercase();
    key(a) == key(b)
}

/// `Some(folder name)` when the app runs scripts from somewhere other than its own engine folder
/// (`engine`): a dev build started from the repo or a worktree. `None` for the app's own engine.
pub fn dev_label(repo_root: Option<&Path>, engine: Option<&Path>) -> Option<String> {
    let root = repo_root?;
    if engine.is_some_and(|e| same_folder(root, e)) {
        return None;
    }
    let name = root
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| root.display().to_string());
    Some(name)
}

/// "PikPak Sync", or "PikPak Sync (dev · <folder>)" for a dev build.
pub fn app_name(dev_label: Option<&str>) -> String {
    match dev_label {
        Some(label) => format!("{APP_NAME} (dev \u{b7} {label})"),
        None => APP_NAME.to_string(),
    }
}

/// The last step of the root lookup: the engine this app carries, unpacked in `%LOCALAPPDATA%\PikPakSync`.
pub fn embedded_root() -> Option<PathBuf> {
    embedded_root_in(&engine_root()?, &embedded(), &crate::bridge::log)
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

    /// A bundle of app version 1.0.0.
    fn bun<'a>(files: &'a [(&'a str, &'a [u8])], hash: &'a str) -> Bundle<'a> {
        bun_v(files, hash, "1.0.0")
    }

    fn bun_v<'a>(files: &'a [(&'a str, &'a [u8])], hash: &'a str, version: &'a str) -> Bundle<'a> {
        Bundle { files, hash, version }
    }

    #[test]
    fn version_order_is_numeric_not_textual() {
        use std::cmp::Ordering::*;
        assert_eq!(version_cmp("0.10.0", "0.9.0"), Greater);
        assert_eq!(version_cmp("0.1.0", "0.1.0"), Equal);
        assert_eq!(version_cmp("0.1", "0.1.0"), Equal);
        assert_eq!(version_cmp("1.0.0", "0.99.99"), Greater);
        assert_eq!(version_cmp("0.1.0", "0.2.0"), Less);
        assert_eq!(version_cmp("0.1.0-beta", "0.1.0"), Equal, "a suffix is ignored");
    }

    #[test]
    fn an_older_app_does_not_replace_a_newer_engine() {
        let root = temp_root("downgrade");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &bun_v(&f2, "h2", "0.2.0")).unwrap();
        let err = ensure_unpacked(&root, &bun_v(&f1, "h1", "0.1.0")).unwrap_err();
        assert!(err.contains("0.2.0"), "the message names the newer version: {err}");
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a2", "the newer scripts stay");
        assert_eq!(read(&root, "engine.hash"), "0.2.0 h2", "the marker stays");
        assert!(!root.join("scripts/old.ps1").exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_newer_app_replaces_an_older_engine() {
        let root = temp_root("upgrade-version");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &bun_v(&f1, "h1", "0.1.0")).unwrap();
        ensure_unpacked(&root, &bun_v(&f2, "h2", "0.10.0")).unwrap();
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a2");
        assert_eq!(read(&root, "engine.hash"), "0.10.0 h2");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_same_version_with_a_new_hash_is_replaced() {
        // A rebuild during development: same app version, different scripts.
        let root = temp_root("rebuild");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &bun_v(&f1, "h1", "0.1.0")).unwrap();
        ensure_unpacked(&root, &bun_v(&f2, "h2", "0.1.0")).unwrap();
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a2");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_unreadable_marker_is_replaced() {
        let root = temp_root("badmarker");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &bun_v(&f1, "h1", "0.1.0")).unwrap();
        fs::write(root.join("engine.hash"), "garbage").unwrap();
        ensure_unpacked(&root, &bun_v(&f2, "h2", "0.1.0")).unwrap();
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a2");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn the_swap_is_retried_while_a_file_is_briefly_held() {
        // Antivirus or the search indexer can hold a freshly written file for a moment.
        let root = temp_root("retry");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &bun_v(&f1, "h1", "0.1.0")).unwrap();
        let held = OpenOptions::new().read(true).share_mode(1).open(root.join("scripts/lib/a.ps1")).unwrap();
        std::thread::scope(|s| {
            s.spawn(move || {
                std::thread::sleep(Duration::from_millis(500));
                drop(held);
            });
            ensure_unpacked(&root, &bun_v(&f2, "h2", "0.2.0")).unwrap();
        });
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a2");
        let _ = fs::remove_dir_all(&root);
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
        ensure_unpacked(&root, &bun(&files, "h1")).unwrap();
        assert_eq!(read(&root, "scripts/Invoke-GuiAction.ps1"), "bridge1");
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a1");
        assert_eq!(read(&root, "config/mirror.config.sample.psd1"), "sample1");
        assert_eq!(read(&root, "config/filters.txt"), "filters1");
        assert_eq!(read(&root, "engine.hash"), "1.0.0 h1");
        assert!(!root.join("engine.lock").exists(), "the lock is released");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn same_hash_is_a_no_op() {
        let root = temp_root("noop");
        let files = v1();
        let bundle = bun(&files, "h1");
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
        let bundle = bun(&files, "h1");
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
        ensure_unpacked(&root, &bun(&f1, "h1")).unwrap();
        ensure_unpacked(&root, &bun(&f2, "h2")).unwrap();
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a2");
        assert_eq!(read(&root, "scripts/Invoke-GuiAction.ps1"), "bridge2");
        assert!(!root.join("scripts/old.ps1").exists(), "a script the new version dropped is gone");
        assert_eq!(read(&root, "engine.hash"), "1.0.0 h2");
        assert!(!root.join("scripts.new").exists() && !root.join("scripts.old").exists());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn upgrade_keeps_user_config() {
        let root = temp_root("keepconfig");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &bun(&f1, "h1")).unwrap();
        fs::write(root.join("config/mirror.config.psd1"), "mine").unwrap();
        fs::write(root.join("config/mirror.config.psd1.bak"), "mine.bak").unwrap();
        fs::write(root.join("config/mirror.config.original.psd1"), "mine.original").unwrap();
        fs::write(root.join("config/filters.txt"), "my edited filters").unwrap();
        ensure_unpacked(&root, &bun(&f2, "h2")).unwrap();
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
        ensure_unpacked(&root, &bun(&f1, "h1")).unwrap();
        // Read-share only: a running script that blocks renaming the folder it lives in.
        let held = OpenOptions::new().read(true).share_mode(1).open(root.join("scripts/lib/a.ps1")).unwrap();
        let err = ensure_unpacked(&root, &bun(&f2, "h2")).unwrap_err();
        assert!(!err.is_empty());
        assert_eq!(read(&root, "scripts/lib/a.ps1"), "a1", "the old engine is intact");
        assert_eq!(read(&root, "scripts/old.ps1"), "old");
        assert_eq!(read(&root, "engine.hash"), "1.0.0 h1", "the marker still says the old version");
        assert!(!root.join("scripts.new").exists() && !root.join("scripts.old").exists(), "no half-state left");
        assert!(!root.join("engine.lock").exists(), "the lock is released after a failure");
        drop(held);
        ensure_unpacked(&root, &bun(&f2, "h2")).unwrap();
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
            let worker = s.spawn(|| ensure_unpacked(&root, &bun(&files, "h1")));
            std::thread::sleep(Duration::from_millis(300));
            assert!(!root.join("engine.hash").exists(), "nothing is written while the lock is held");
            fs::remove_file(root.join("engine.lock")).unwrap();
            worker.join().unwrap().unwrap();
        });
        assert!(started.elapsed() >= Duration::from_millis(250));
        assert_eq!(read(&root, "engine.hash"), "1.0.0 h1");
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
        ensure_unpacked(&root, &bun(&files, "h1")).unwrap();
        assert_eq!(read(&root, "engine.hash"), "1.0.0 h1");
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn dev_label_is_none_for_the_apps_own_engine() {
        let engine = PathBuf::from(r"C:\Users\u\AppData\Local\PikPakSync");
        assert_eq!(dev_label(Some(&engine), Some(&engine)), None);
        // Different spelling of the same folder (case, trailing backslash, slashes).
        let spelled = PathBuf::from(r"c:/users/U/AppData/Local/pikpaksync\");
        assert_eq!(dev_label(Some(&spelled), Some(&engine)), None);
        assert_eq!(dev_label(None, Some(&engine)), None, "no scripts at all is not a dev build");
    }

    #[test]
    fn dev_label_names_the_repo_or_worktree_folder() {
        let engine = PathBuf::from(r"C:\Users\u\AppData\Local\PikPakSync");
        let repo = PathBuf::from(r"G:\pikpak-mirror");
        let worktree = PathBuf::from(r"G:\pikpak-mirror\.worktrees\my-feature");
        assert_eq!(dev_label(Some(&repo), Some(&engine)).as_deref(), Some("pikpak-mirror"));
        assert_eq!(dev_label(Some(&worktree), Some(&engine)).as_deref(), Some("my-feature"));
        assert_eq!(dev_label(Some(&repo), None).as_deref(), Some("pikpak-mirror"), "no LOCALAPPDATA");
    }

    #[test]
    fn app_name_marks_a_dev_build() {
        assert_eq!(app_name(None), "PikPak Sync");
        assert_eq!(app_name(Some("my-feature")), "PikPak Sync (dev \u{b7} my-feature)");
    }

    #[test]
    fn embedded_root_in_returns_the_root_after_unpacking() {
        let root = temp_root("resolve-ok");
        let files = v1();
        let logged = std::cell::RefCell::new(Vec::<String>::new());
        let got = embedded_root_in(&root, &bun(&files, "h1"), &|m| logged.borrow_mut().push(m.to_string()));
        assert_eq!(got, Some(root.clone()));
        assert!(logged.borrow().is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn embedded_root_in_keeps_the_old_engine_when_the_upgrade_fails() {
        let root = temp_root("resolve-locked");
        let (f1, f2) = (v1(), v2());
        ensure_unpacked(&root, &bun(&f1, "h1")).unwrap();
        let held = OpenOptions::new().read(true).share_mode(1).open(root.join("scripts/lib/a.ps1")).unwrap();
        let logged = std::cell::RefCell::new(Vec::<String>::new());
        let got = embedded_root_in(&root, &bun(&f2, "h2"), &|m| logged.borrow_mut().push(m.to_string()));
        assert_eq!(got, Some(root.clone()), "the old engine still works, so the app starts with it");
        assert_eq!(logged.borrow().len(), 1, "the failure is logged once");
        drop(held);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn embedded_root_in_gives_none_when_nothing_is_usable() {
        let blocker = temp_root("resolve-none");
        fs::write(&blocker, "a file, so nothing can be created below it").unwrap();
        let root = blocker.join("PikPakSync");
        let files = v1();
        let logged = std::cell::RefCell::new(Vec::<String>::new());
        let got = embedded_root_in(&root, &bun(&files, "h1"), &|m| logged.borrow_mut().push(m.to_string()));
        assert_eq!(got, None);
        assert_eq!(logged.borrow().len(), 1);
        let _ = fs::remove_file(&blocker);
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
