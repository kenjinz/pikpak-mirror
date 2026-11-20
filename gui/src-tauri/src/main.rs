// No console window in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod autostart_migrate;
mod bridge;
mod engine;
mod tray;

use serde::Serialize;
use serde_json::Value;
use std::path::PathBuf;
use tauri::{Manager, State, WindowEvent};
use tauri_plugin_window_state::{AppHandleExt, StateFlags};

/// Fixed at start-up; shared by the commands and the tray.
pub struct AppState {
    pub repo_root: Option<PathBuf>,
    pub preview_setup: bool,
}

#[derive(Serialize)]
struct AppInfo {
    preview_setup: bool,
    repo_root: String,
    version: String,
    pc_name: String,
}

fn has_flag(flag: &str) -> bool {
    std::env::args_os().skip(1).any(|a| a == flag)
}

/// Runs one bridge action off the UI thread and returns its envelope as-is.
/// Write actions run one at a time (`bridge::is_write_action`); reads stay concurrent.
/// In preview mode (`--preview-setup`) every call runs as a preview, whatever the page asks.
#[tauri::command]
async fn gui_action(
    state: State<'_, AppState>,
    action: String,
    args: Value,
    preview: bool,
) -> Result<Value, String> {
    let root = state.repo_root.clone();
    let preview = preview || state.preview_setup;
    bridge::run_async(root, action, args, preview).await
}

#[tauri::command]
fn app_info(app: tauri::AppHandle, state: State<'_, AppState>) -> AppInfo {
    AppInfo {
        preview_setup: state.preview_setup,
        repo_root: state
            .repo_root
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_default(),
        version: app.package_info().version.to_string(),
        pc_name: std::env::var("COMPUTERNAME").unwrap_or_default(),
    }
}

/// Size, position, maximized etc. but not visibility: start-up decides whether the window shows.
fn window_state_flags() -> StateFlags {
    StateFlags::all() & !StateFlags::VISIBLE
}

fn main() {
    let preview_setup = has_flag("--preview-setup");
    let start_minimized = has_flag("--minimized");
    // PIKPAK_BACKUP_REPO, then the folders above the exe (a dev build), then the engine the exe carries.
    let repo_root = bridge::resolve_repo_root().or_else(engine::embedded_root);
    if repo_root.is_none() {
        bridge::log("start-up: no repo folder with scripts\\Invoke-GuiAction.ps1 was found and the built-in scripts could not be unpacked");
    }

    tauri::Builder::default()
        // Must be first: a second launch hands over to this one and exits.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            // A sign-in autostart while the app already runs stays in the tray.
            if !argv.iter().skip(1).any(|a| a == "--minimized") {
                tray::show_main_window(app);
            }
        }))
        .plugin(
            tauri_plugin_window_state::Builder::default()
                .with_state_flags(window_state_flags())
                .build(),
        )
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(
            tauri_plugin_autostart::Builder::new()
                .args(["--minimized"])
                .build(),
        )
        .manage(AppState {
            repo_root,
            preview_setup,
        })
        .invoke_handler(tauri::generate_handler![
            gui_action,
            app_info,
            tray::set_tray_status,
            tray::set_tray_paused
        ])
        .setup(move |app| {
            tray::create(app.handle())?;
            {
                // Old "PikPak Backup" start-with-Windows entry: move it to the new name (never fails start-up).
                use tauri_plugin_autostart::ManagerExt;
                let handle = app.handle().clone();
                autostart_migrate::migrate(
                    &autostart_migrate::RegExe::run_key(),
                    preview_setup,
                    move || handle.autolaunch().enable().map_err(|e| e.to_string()),
                );
            }
            if !start_minimized {
                tray::show_main_window(app.handle());
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            // Closing the window hides it to the tray; Quit is in the tray menu.
            if let WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == tray::MAIN_WINDOW {
                    api.prevent_close();
                    // Save size/position now too: a Windows sign-out may end the app
                    // without the plugin's own save at exit.
                    let _ = window.app_handle().save_window_state(window_state_flags());
                    let _ = window.hide();
                }
            }
        })
        .run(tauri::generate_context!())
        .expect("PikPak Sync failed to start");
}
