use tauri::Manager;

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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            let window = app.get_webview_window("main").expect("no main window");

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
        .invoke_handler(tauri::generate_handler![get_config, print_to_stdout])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
