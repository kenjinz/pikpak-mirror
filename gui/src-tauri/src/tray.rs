//! Tray icon: status colour + tooltip set by the page, and a small menu.
//! Menu actions go through the same bridge as the page and are reported to the
//! page as a `tray-action` event ({action, result: <envelope>}).

use crate::{bridge, AppState};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_dialog::{DialogExt, MessageDialogKind};

pub const MAIN_WINDOW: &str = "main";
const TRAY_ID: &str = "main";
/// Windows keeps at most 127 characters of a tray tooltip.
const TOOLTIP_MAX_CHARS: usize = 127;

const ICON_OK: &[u8] = include_bytes!("../icons/tray-ok.ico");
const ICON_WORKING: &[u8] = include_bytes!("../icons/tray-working.ico");
const ICON_ATTENTION: &[u8] = include_bytes!("../icons/tray-attention.ico");

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    Ok,
    Working,
    Attention,
}

/// The page sends exactly one of `ok`, `working`, `attention`.
pub fn tone_from_str(tone: &str) -> Option<Tone> {
    match tone {
        "ok" => Some(Tone::Ok),
        "working" => Some(Tone::Working),
        "attention" => Some(Tone::Attention),
        _ => None,
    }
}

fn icon(tone: Tone) -> tauri::Result<Image<'static>> {
    Image::from_bytes(match tone {
        Tone::Ok => ICON_OK,
        Tone::Working => ICON_WORKING,
        Tone::Attention => ICON_ATTENTION,
    })
}

pub fn pause_label(paused: bool) -> &'static str {
    if paused {
        "Resume syncing"
    } else {
        "Pause syncing"
    }
}

/// Holds the Pause/Resume item so its text can follow the schedule.
struct TrayMenu {
    pause: MenuItem<tauri::Wry>,
}

pub fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(MAIN_WINDOW) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

pub fn create(app: &AppHandle, app_name: &str) -> tauri::Result<()> {
    let open = MenuItem::with_id(app, "open", "Open", true, None::<&str>)?;
    let sync_now = MenuItem::with_id(app, "backup", "Sync now", true, None::<&str>)?;
    let pause = MenuItem::with_id(app, "pause", pause_label(false), true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&open, &sync_now, &pause, &separator, &quit])?;

    TrayIconBuilder::with_id(TRAY_ID)
        // Neutral until the page reports the real status: never look "fine" by default.
        .icon(icon(Tone::Working)?)
        .tooltip(app_name)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main_window(app),
            "backup" => run_tray_action(app.clone(), back_up_now),
            "pause" => run_tray_action(app.clone(), toggle_pause),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main_window(tray.app_handle());
            }
        })
        .build(app)?;

    app.manage(TrayMenu { pause });
    refresh_pause_label(app.clone());
    Ok(())
}

fn set_pause_label(app: &AppHandle, paused: bool) -> Result<(), String> {
    app.state::<TrayMenu>()
        .pause
        .set_text(pause_label(paused))
        .map_err(|e| format!("internal: {e}"))
}

fn call(app: &AppHandle, action: &str, args: Value) -> Result<Value, String> {
    let state = app.state::<AppState>();
    bridge::run(state.repo_root.as_deref(), action, &args, state.preview_setup)
}

/// `data` of an ok envelope, or the envelope's own error message.
fn ok_data(envelope: &Value) -> Result<&Value, String> {
    if envelope["ok"] == Value::Bool(true) {
        Ok(&envelope["data"])
    } else {
        Err(envelope["error"]["message"]
            .as_str()
            .unwrap_or("Something went wrong.")
            .to_string())
    }
}

/// Reads the schedule once at start-up so the menu says Pause or Resume correctly.
fn refresh_pause_label(app: AppHandle) {
    std::thread::spawn(move || {
        if let Ok(envelope) = call(&app, "schedule.get", json!({})) {
            if let Ok(data) = ok_data(&envelope) {
                if let Some(paused) = data["paused"].as_bool() {
                    let _ = set_pause_label(&app, paused);
                }
            }
        }
    });
}

/// One tray action at a time: a double click on Pause must not toggle twice.
static TRAY_BUSY: AtomicBool = AtomicBool::new(false);

/// Holds the busy flag; dropping it (normal end, error, panic) frees the tray again.
struct BusyGuard;

impl BusyGuard {
    fn try_take() -> Option<BusyGuard> {
        (!TRAY_BUSY.swap(true, Ordering::SeqCst)).then_some(BusyGuard)
    }
}

impl Drop for BusyGuard {
    fn drop(&mut self) {
        TRAY_BUSY.store(false, Ordering::SeqCst);
    }
}

/// Bridge calls have deadlines (`bridge::action_timeout`), so a tray action always ends.
fn run_tray_action(app: AppHandle, job: fn(&AppHandle)) {
    let Some(guard) = BusyGuard::try_take() else {
        return;
    };
    std::thread::spawn(move || {
        let _guard = guard;
        job(&app);
    });
}

fn back_up_now(app: &AppHandle) {
    let result = call(app, "sync.start", json!({}));
    report(app, "sync.start", result);
}

fn toggle_pause(app: &AppHandle) {
    let result = call(app, "schedule.get", json!({})).and_then(|envelope| {
        match ok_data(&envelope).map(|d| d["paused"].as_bool()) {
            Ok(Some(paused)) => call(app, "schedule.set", json!({ "paused": !paused })),
            Ok(None) => Err("internal: the schedule didn't say whether syncing is paused".to_string()),
            // Not ok: report what schedule.get said.
            Err(_) => Ok(envelope),
        }
    });
    if let Ok(envelope) = &result {
        if let Ok(Some(paused)) = ok_data(envelope).map(|d| d["paused"].as_bool()) {
            let _ = set_pause_label(app, paused);
        }
    }
    report(app, "schedule.set", result);
}

/// Tells the page what happened; a failure also gets a small Windows message,
/// because the window may be hidden.
fn report(app: &AppHandle, action: &str, result: Result<Value, String>) {
    let envelope = match result {
        Ok(envelope) => envelope,
        Err(message) => json!({ "ok": false, "error": { "code": "internal", "message": message } }),
    };
    let _ = app.emit("tray-action", json!({ "action": action, "result": envelope }));
    if let Err(message) = ok_data(&envelope) {
        let message = if envelope["error"]["code"] == "internal" {
            "Something went wrong inside the app. The details are in the app's log.".to_string()
        } else {
            message
        };
        app.dialog()
            .message(message)
            .title(app.state::<AppState>().app_name.clone())
            .kind(MessageDialogKind::Warning)
            .show(|_| {});
    }
}

/// Page -> tray: icon colour (`ok` | `working` | `attention`) and tooltip.
#[tauri::command]
pub fn set_tray_status(app: AppHandle, tone: String, tooltip: String) -> Result<(), String> {
    let tone = tone_from_str(&tone).ok_or_else(|| format!("bad-request: unknown tray tone '{tone}'"))?;
    let tray = app
        .tray_by_id(TRAY_ID)
        .ok_or_else(|| "internal: the tray icon is missing".to_string())?;
    let image = icon(tone).map_err(|e| format!("internal: {e}"))?;
    tray.set_icon(Some(image)).map_err(|e| format!("internal: {e}"))?;
    let tooltip = tooltip.trim();
    let tooltip: String = if tooltip.is_empty() {
        app.state::<AppState>().app_name.clone()
    } else {
        tooltip.chars().take(TOOLTIP_MAX_CHARS).collect()
    };
    tray.set_tooltip(Some(tooltip)).map_err(|e| format!("internal: {e}"))
}

/// Page -> tray: keeps the Pause/Resume item in step when Settings changes it.
#[tauri::command]
pub fn set_tray_paused(app: AppHandle, paused: bool) -> Result<(), String> {
    set_pause_label(&app, paused)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tone_from_str_accepts_only_the_three_tones() {
        assert_eq!(tone_from_str("ok"), Some(Tone::Ok));
        assert_eq!(tone_from_str("working"), Some(Tone::Working));
        assert_eq!(tone_from_str("attention"), Some(Tone::Attention));
        assert_eq!(tone_from_str("bad"), None);
        assert_eq!(tone_from_str(""), None);
    }

    #[test]
    fn tray_icons_decode() {
        for tone in [Tone::Ok, Tone::Working, Tone::Attention] {
            let image = icon(tone).expect("tray icon decodes");
            assert!(image.width() >= 16 && image.height() >= 16);
        }
    }

    #[test]
    fn busy_guard_is_freed_on_drop_and_on_panic() {
        let first = BusyGuard::try_take().expect("free at start");
        assert!(BusyGuard::try_take().is_none(), "second action refused while busy");
        drop(first);
        let panicked = std::thread::spawn(|| {
            let _guard = BusyGuard::try_take().expect("free after drop");
            panic!("job failed (expected in this test)");
        })
        .join();
        assert!(panicked.is_err());
        assert!(BusyGuard::try_take().is_some(), "freed after a panic");
    }

    #[test]
    fn pause_label_follows_state() {
        assert_eq!(pause_label(false), "Pause syncing");
        assert_eq!(pause_label(true), "Resume syncing");
    }
}
