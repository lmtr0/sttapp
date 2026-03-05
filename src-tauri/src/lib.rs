use tauri::{Emitter, Manager};

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};

#[cfg(not(any(target_os = "android", target_os = "ios")))]
use enigo::{Direction, Enigo, Key, Keyboard, Settings};

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

#[tauri::command]
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn paste_active_window(mode: Option<String>) -> Result<(), String> {
    use std::thread;
    use std::time::Duration;

    let paste_mode = mode.unwrap_or_else(|| "normal".to_string());

    thread::sleep(Duration::from_millis(200));

    let mut enigo = Enigo::new(&Settings::default()).map_err(|e| e.to_string())?;

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
            enigo
                .key(Key::Shift, Direction::Release)
                .map_err(|e| e.to_string())?;
            enigo
                .key(Key::Control, Direction::Release)
                .map_err(|e| e.to_string())?;
        }
        _ => {
            enigo
                .key(Key::Control, Direction::Press)
                .map_err(|e| e.to_string())?;
            enigo
                .key(Key::Unicode('v'), Direction::Click)
                .map_err(|e| e.to_string())?;
            enigo
                .key(Key::Control, Direction::Release)
                .map_err(|e| e.to_string())?;
        }
    }

    Ok(())
}

#[tauri::command]
#[cfg(any(target_os = "android", target_os = "ios"))]
fn paste_active_window(_mode: Option<String>) -> Result<(), String> {
    Err("Pasting into active window is only supported on desktop".into())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut builder =
        tauri::Builder::default().plugin(tauri_plugin_global_shortcut::Builder::new().build());

    // Global shortcut plugin — desktop only.
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        builder = builder.plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    if event.state() == ShortcutState::Pressed
                        && shortcut == &Shortcut::new(None, Code::F8)
                    {
                        if let Some(win) = app.get_webview_window("main") {
                            let _ = win.emit(
                                "shortcut-pressed",
                                serde_json::json!({ "pasteMode": "normal" }),
                            );
                        }
                    }

                    if event.state() == ShortcutState::Pressed
                        && shortcut == &Shortcut::new(Some(Modifiers::SHIFT), Code::F8)
                    {
                        if let Some(win) = app.get_webview_window("main") {
                            let _ = win.emit(
                                "shortcut-pressed",
                                serde_json::json!({ "pasteMode": "plain" }),
                            );
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
            let window = app.get_webview_window("main").expect("no main window");

            // Position the window at bottom-center of the primary monitor,
            // 40 px above the bottom edge.
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            {
                if let Some(monitor) = window.current_monitor()? {
                    let screen = monitor.size();
                    let win = window.outer_size()?;
                    let x = (screen.width as i32 - win.width as i32) / 2 + monitor.position().x;
                    let y = monitor.position().y + screen.height as i32 - win.height as i32 - 40;
                    window.set_position(tauri::PhysicalPosition::new(x, y))?;
                }
            }

            // Register F8 as a system-wide global shortcut.
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            app.global_shortcut()
                .register(Shortcut::new(None, Code::F8))?;

            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            app.global_shortcut()
                .register(Shortcut::new(Some(Modifiers::SHIFT), Code::F8))?;

            window.set_always_on_top(true)?;
            window.set_cursor_grab(false)?;
            // On Linux/Wayland the WebKitGTK permission dialog is swallowed by
            // the compositor and getUserMedia() silently fails.  Intercept the
            // WebKit permission-request signal and grant it programmatically so
            // microphone access works without any user-visible prompt.
            #[cfg(target_os = "linux")]
            window.with_webview(|webview| {
                use webkit2gtk::{PermissionRequestExt, WebViewExt};
                webview.inner().connect_permission_request(|_, request| {
                    request.allow();
                    true // stop further signal handlers
                });
            })?;

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_config,
            print_to_stdout,
            paste_active_window
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
