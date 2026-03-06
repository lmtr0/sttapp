use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::{
    AppHandle, Emitter, Manager, Runtime, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};

use std::thread;
use std::time::Duration;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use enigo::{Direction, Enigo, Key, Keyboard, Settings};

const TRAY_ID: &str = "main-tray";
const TRAY_ICON_SIZE: u32 = 18;

fn circle_icon_rgba(size: u32, color: [u8; 4]) -> Vec<u8> {
    let mut rgba = vec![0u8; (size * size * 4) as usize];
    let center = (size as f32 - 1.0) / 2.0;
    let radius = size as f32 * 0.42;
    let edge = 0.75;

    for y in 0..size {
        for x in 0..size {
            let dx = x as f32 - center;
            let dy = y as f32 - center;
            let distance = (dx * dx + dy * dy).sqrt();
            let alpha = ((radius + edge - distance) / edge).clamp(0.0, 1.0);

            let idx = ((y * size + x) * 4) as usize;
            rgba[idx] = color[0];
            rgba[idx + 1] = color[1];
            rgba[idx + 2] = color[2];
            rgba[idx + 3] = (color[3] as f32 * alpha) as u8;
        }
    }

    rgba
}

fn tray_state_icon(recording: bool) -> tauri::image::Image<'static> {
    let color = if recording {
        [224, 60, 60, 255]
    } else {
        [42, 119, 255, 255]
    };
    tauri::image::Image::new_owned(
        circle_icon_rgba(TRAY_ICON_SIZE, color),
        TRAY_ICON_SIZE,
        TRAY_ICON_SIZE,
    )
}

fn set_tray_icon_state<R: Runtime>(app: &AppHandle<R>, recording: bool) -> Result<(), String> {
    if let Some(tray) = app.tray_by_id(TRAY_ID) {
        tray.set_icon(Some(tray_state_icon(recording)))
            .map_err(|e| e.to_string())?;
    }

    Ok(())
}

fn configure_main_window<R: Runtime>(window: &WebviewWindow<R>) -> Result<(), String> {
    // Position the window at bottom-center of the primary monitor,
    // 40 px above the bottom edge.
    if let Some(monitor) = window.current_monitor().map_err(|e| e.to_string())? {
        let screen = monitor.size();
        let win = window.outer_size().map_err(|e| e.to_string())?;
        let x = (screen.width as i32 - win.width as i32) / 2 + monitor.position().x;
        let y = monitor.position().y + screen.height as i32 - win.height as i32 - 40;
        window
            .set_position(tauri::PhysicalPosition::new(x, y))
            .map_err(|e| e.to_string())?;
    }

    window.set_always_on_top(true).map_err(|e| e.to_string())?;
    window.set_cursor_grab(false).map_err(|e| e.to_string())?;

    // On Linux/Wayland the WebKitGTK permission dialog is swallowed by
    // the compositor and getUserMedia() silently fails. Intercept the
    // WebKit permission-request signal and grant it programmatically so
    // microphone access works without any user-visible prompt.
    #[cfg(target_os = "linux")]
    window
        .with_webview(|webview| {
            use webkit2gtk::{PermissionRequestExt, WebViewExt};
            webview.inner().connect_permission_request(|_, request| {
                request.allow();
                true // stop further signal handlers
            });
        })
        .map_err(|e| e.to_string())?;

    Ok(())
}

fn ensure_main_window_for_recording<R: Runtime>(app: &AppHandle<R>) -> Result<bool, String> {
    if let Some(window) = app.get_webview_window("main") {
        configure_main_window(&window)?;

        let is_visible = window.is_visible().map_err(|e| e.to_string())?;
        if !is_visible {
            window.show().map_err(|e| e.to_string())?;
            window.minimize().map_err(|e| e.to_string())?;
        }

        return Ok(false);
    }

    let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("/".into()))
        .title("sttapp")
        .inner_size(400.0, 120.0)
        .decorations(false)
        .resizable(false)
        .transparent(true)
        .always_on_top(true)
        .build()
        .map_err(|e| e.to_string())?;

    configure_main_window(&window)?;
    window.show().map_err(|e| e.to_string())?;
    window.minimize().map_err(|e| e.to_string())?;
    Ok(true)
}

fn emit_shortcut_event<R: Runtime>(app: &AppHandle<R>, paste_mode: &str) {
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.emit(
            "shortcut-pressed",
            serde_json::json!({ "pasteMode": paste_mode }),
        );
    }
}

fn open_settings_window<R: Runtime>(app: &AppHandle<R>) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("settings") {
        window.unminimize().map_err(|e| e.to_string())?;
        window.show().map_err(|e| e.to_string())?;
        window.set_focus().map_err(|e| e.to_string())?;
        return Ok(());
    }

    let settings_window =
        WebviewWindowBuilder::new(app, "settings", WebviewUrl::App("/settings".into()))
            .title("Settings")
            .inner_size(480.0, 320.0)
            .resizable(true)
            .build()
            .map_err(|e| e.to_string())?;

    settings_window.set_focus().map_err(|e| e.to_string())?;
    Ok(())
}

/// Returns the OpenAI-compatible API configuration read from environment variables.
///
/// OPENAI_API_KEY   — required
/// OPENAI_BASE_URL  — optional, defaults to https://api.openai.com/v1
/// OPENAI_MODEL     — optional, defaults to whisper-1
#[tauri::command]
fn get_config() -> serde_json::Value {
    serde_json::json!({
        "apiKey":  std::env::var("OPENAI_API_KEY").unwrap_or_default(),
        "baseUrl": std::env::var("OPENAI_BASE_URL")
                     .unwrap_or_else(|_| "https://api.openai.com/v1".into()),
        "model":   std::env::var("OPENAI_MODEL")
                     .unwrap_or_else(|_| "whisper-1".into()),
    })
}

/// Prints the transcription result to the terminal (stdout) where the app was launched.
#[tauri::command]
fn print_to_stdout(text: String) {
    println!("{}", text);
}

fn get_enigo_settings() -> Settings {
    // Linux and mac only
    let mut settings = Settings::default();

    #[cfg(not(target_os = "windows"))]
    {
        if let Ok(display) = std::env::var("WAYLAND_DISPLAY") {
            println!("Using wayland");
            settings.wayland_display = Some(display);
        } else if let Ok(display) = std::env::var("DISPLAY") {
            println!("Using x11");
            settings.x11_display = Some(display);
        }
    }

    return settings;
}

#[tauri::command]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn paste_active_window(mode: Option<String>) -> Result<(), String> {
    let paste_mode = mode.unwrap_or_else(|| "normal".to_string());

    let enigo_settings = get_enigo_settings();
    let mut enigo = Enigo::new(&enigo_settings).map_err(|e| e.to_string())?;

    match paste_mode.as_str() {
        "plain" => {
            enigo
                .key(Key::Control, Direction::Press)
                .map_err(|e| e.to_string())?;
            enigo
                .key(Key::Shift, Direction::Press)
                .map_err(|e| e.to_string())?;
            enigo
                .key(Key::Unicode('v'), Direction::Click)
                .map_err(|e| e.to_string())?;
        }
        _ => {
            enigo
                .key(Key::Control, Direction::Press)
                .map_err(|e| e.to_string())?;
            enigo
                .key(Key::Unicode('v'), Direction::Click)
                .map_err(|e| e.to_string())?;
        }
    }

    std::thread::sleep(Duration::from_millis(200));

    Ok(())
}

#[tauri::command]
#[cfg(any(target_os = "android", target_os = "ios"))]
fn paste_active_window(_mode: Option<String>) -> Result<(), String> {
    Err("Pasting into active window is only supported on desktop".into())
}

#[tauri::command]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn set_recording_state(app: tauri::AppHandle, recording: bool) -> Result<(), String> {
    set_tray_icon_state(&app, recording)
}

#[tauri::command]
#[cfg(any(target_os = "android", target_os = "ios"))]
fn set_recording_state(_app: tauri::AppHandle, _recording: bool) -> Result<(), String> {
    Ok(())
}

#[tauri::command]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn maybe_close_main_window(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        let minimized = window.is_minimized().map_err(|e| e.to_string())?;
        let focused = window.is_focused().map_err(|e| e.to_string())?;
        if minimized || !focused {
            window.hide().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
#[cfg(any(target_os = "android", target_os = "ios"))]
fn maybe_close_main_window(_app: tauri::AppHandle) -> Result<(), String> {
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder = tauri::Builder::default();

    // Global shortcut plugin — desktop only.
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        builder = builder.plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    if event.state() == ShortcutState::Pressed
                        && shortcut == &Shortcut::new(None, Code::F8)
                    {
                        let created = ensure_main_window_for_recording(app).unwrap_or(false);
                        if created {
                            let app_handle = app.clone();
                            thread::spawn(move || {
                                thread::sleep(Duration::from_millis(450));
                                emit_shortcut_event(&app_handle, "normal");
                            });
                        } else {
                            emit_shortcut_event(app, "normal");
                        }
                    }

                    if event.state() == ShortcutState::Pressed
                        && shortcut == &Shortcut::new(Some(Modifiers::SHIFT), Code::F8)
                    {
                        let created = ensure_main_window_for_recording(app).unwrap_or(false);
                        if created {
                            let app_handle = app.clone();
                            thread::spawn(move || {
                                thread::sleep(Duration::from_millis(450));
                                emit_shortcut_event(&app_handle, "plain");
                            });
                        } else {
                            emit_shortcut_event(app, "plain");
                        }
                    }
                })
                .build(),
        );
    }

    builder
        .plugin(tauri_plugin_stronghold::Builder::new(|_pass| todo!()).build())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            {
                let start_item =
                    MenuItemBuilder::with_id("start_recording", "Start Recording").build(app)?;
                let stop_item =
                    MenuItemBuilder::with_id("stop_recording", "Stop Recording").build(app)?;
                let settings_item = MenuItemBuilder::with_id("settings", "Settings").build(app)?;

                let tray_menu = MenuBuilder::new(app)
                    .item(&start_item)
                    .item(&stop_item)
                    .item(&settings_item)
                    .build()?;

                tauri::tray::TrayIconBuilder::with_id(TRAY_ID)
                    .icon(tray_state_icon(false))
                    .menu(&tray_menu)
                    .show_menu_on_left_click(true)
                    .on_menu_event(|app, event| match event.id().as_ref() {
                        "start_recording" => {
                            let created = ensure_main_window_for_recording(app).unwrap_or(false);
                            if created {
                                let app_handle = app.clone();
                                thread::spawn(move || {
                                    thread::sleep(Duration::from_millis(450));
                                    if let Some(win) = app_handle.get_webview_window("main") {
                                        let _ = win.emit("tray-start-recording", ());
                                    }
                                });
                            } else if let Some(win) = app.get_webview_window("main") {
                                let _ = win.emit("tray-start-recording", ());
                            }
                        }
                        "stop_recording" => {
                            if let Some(win) = app.get_webview_window("main") {
                                let _ = win.emit("tray-stop-recording", ());
                            }
                        }
                        "settings" => {
                            let _ = open_settings_window(app);
                        }
                        _ => {}
                    })
                    .build(app)?;
            }

            let window = app.get_webview_window("main").expect("no main window");

            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            configure_main_window(&window).map_err(std::io::Error::other)?;

            // Register F8 as a system-wide global shortcut.
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            app.global_shortcut()
                .register(Shortcut::new(None, Code::F8))?;

            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            app.global_shortcut()
                .register(Shortcut::new(Some(Modifiers::SHIFT), Code::F8))?;

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            print_to_stdout,
            paste_active_window,
            set_recording_state,
            maybe_close_main_window
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
