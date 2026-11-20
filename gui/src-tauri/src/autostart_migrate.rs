//! One-time move of the old start-with-Windows entry. Earlier versions were called "PikPak Backup"
//! and registered themselves under that name in the current user's Run key. The autostart plugin
//! now uses the new product name, so the old value would start a second copy (or a stale exe).
//! At start-up: if the old value exists, turn autostart on under the new name, then delete the old
//! value. No old value: nothing happens. Never fails start-up: every problem is logged and ignored,
//! and the next start simply tries again.

use crate::bridge;
use std::os::windows::process::CommandExt;
use std::process::Command;

pub const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
pub const OLD_VALUE_NAME: &str = "PikPak Backup";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// The few registry operations the migration needs on one Run-style key.
pub trait RunKey {
    fn has_value(&self, name: &str) -> Result<bool, String>;
    fn delete_value(&self, name: &str) -> Result<(), String>;
}

/// Reads and deletes values with the `reg` tool that ships with Windows.
pub struct RegExe {
    pub key: String,
}

impl RegExe {
    pub fn run_key() -> Self {
        RegExe { key: RUN_KEY.to_string() }
    }

    fn reg(&self, args: &[&str]) -> Result<std::process::Output, String> {
        Command::new("reg")
            .args(args)
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .map_err(|e| format!("couldn't run reg: {e}"))
    }
}

impl RunKey for RegExe {
    fn has_value(&self, name: &str) -> Result<bool, String> {
        let out = self.reg(&["query", &self.key, "/v", name])?;
        // reg exits 0 when the value is there and 1 when it (or the key) is not.
        Ok(out.status.success())
    }

    fn delete_value(&self, name: &str) -> Result<(), String> {
        let out = self.reg(&["delete", &self.key, "/v", name, "/f"])?;
        if out.status.success() {
            Ok(())
        } else {
            Err(format!("reg delete failed ({})", out.status))
        }
    }
}

/// Returns true when the old entry was found and replaced. `preview` (the app's preview mode)
/// changes nothing. `enable` turns autostart on under the new name.
pub fn migrate(
    run_key: &dyn RunKey,
    preview: bool,
    enable: impl FnOnce() -> Result<(), String>,
) -> bool {
    if preview {
        return false;
    }
    match run_key.has_value(OLD_VALUE_NAME) {
        Ok(true) => {}
        Ok(false) => return false,
        Err(e) => {
            bridge::log(&format!("autostart migration: couldn't look for the old entry: {e}"));
            return false;
        }
    }
    // Enable first: if that fails the old entry stays and works until the next start retries.
    if let Err(e) = enable() {
        bridge::log(&format!("autostart migration: couldn't turn autostart on: {e}"));
        return false;
    }
    if let Err(e) = run_key.delete_value(OLD_VALUE_NAME) {
        bridge::log(&format!("autostart migration: couldn't remove the old entry: {e}"));
        return false;
    }
    bridge::log("autostart migration: moved the old PikPak Backup entry to PikPak Sync");
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct Fake {
        values: RefCell<Vec<String>>,
        fail_delete: bool,
        fail_query: bool,
    }

    impl Fake {
        fn with(values: &[&str]) -> Self {
            Fake {
                values: RefCell::new(values.iter().map(|s| s.to_string()).collect()),
                fail_delete: false,
                fail_query: false,
            }
        }
    }

    impl RunKey for Fake {
        fn has_value(&self, name: &str) -> Result<bool, String> {
            if self.fail_query {
                return Err("denied".into());
            }
            Ok(self.values.borrow().iter().any(|v| v == name))
        }
        fn delete_value(&self, name: &str) -> Result<(), String> {
            if self.fail_delete {
                return Err("denied".into());
            }
            self.values.borrow_mut().retain(|v| v != name);
            Ok(())
        }
    }

    #[test]
    fn no_old_value_does_nothing() {
        let key = Fake::with(&["Other App"]);
        let enabled = RefCell::new(false);
        let moved = migrate(&key, false, || {
            *enabled.borrow_mut() = true;
            Ok(())
        });
        assert!(!moved);
        assert!(!*enabled.borrow(), "autostart is not touched");
        assert_eq!(key.values.borrow().as_slice(), ["Other App"]);
    }

    #[test]
    fn old_value_is_replaced_and_other_values_stay() {
        let key = Fake::with(&["Other App", OLD_VALUE_NAME]);
        let enabled = RefCell::new(false);
        let moved = migrate(&key, false, || {
            *enabled.borrow_mut() = true;
            Ok(())
        });
        assert!(moved);
        assert!(*enabled.borrow());
        assert_eq!(key.values.borrow().as_slice(), ["Other App"]);
    }

    #[test]
    fn preview_changes_nothing() {
        let key = Fake::with(&[OLD_VALUE_NAME]);
        let moved = migrate(&key, true, || panic!("must not enable in preview"));
        assert!(!moved);
        assert_eq!(key.values.borrow().as_slice(), [OLD_VALUE_NAME]);
    }

    #[test]
    fn failed_enable_keeps_the_old_value() {
        let key = Fake::with(&[OLD_VALUE_NAME]);
        let moved = migrate(&key, false, || Err("no".into()));
        assert!(!moved);
        assert_eq!(key.values.borrow().as_slice(), [OLD_VALUE_NAME]);
    }

    #[test]
    fn registry_errors_never_panic() {
        let mut key = Fake::with(&[OLD_VALUE_NAME]);
        key.fail_query = true;
        assert!(!migrate(&key, false, || Ok(())));
        let mut key = Fake::with(&[OLD_VALUE_NAME]);
        key.fail_delete = true;
        assert!(!migrate(&key, false, || Ok(())));
    }

    #[test]
    fn reg_exe_reads_and_deletes_in_a_scratch_key() {
        // A throw-away key under HKCU\Software, never the real Run key.
        let key = format!(r"HKCU\Software\PikPakSyncMigrationTest{}", std::process::id());
        let reg = RegExe { key: key.clone() };
        assert_eq!(reg.has_value(OLD_VALUE_NAME), Ok(false), "missing key is just 'not there'");
        let add = Command::new("reg")
            .args(["add", &key, "/v", OLD_VALUE_NAME, "/t", "REG_SZ", "/d", "x", "/f"])
            .creation_flags(CREATE_NO_WINDOW)
            .output()
            .unwrap();
        assert!(add.status.success());
        assert_eq!(reg.has_value(OLD_VALUE_NAME), Ok(true));
        assert_eq!(reg.delete_value(OLD_VALUE_NAME), Ok(()));
        assert_eq!(reg.has_value(OLD_VALUE_NAME), Ok(false));
        let _ = Command::new("reg")
            .args(["delete", &key, "/f"])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
    }
}
