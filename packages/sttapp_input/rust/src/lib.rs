use std::ffi::{c_char, CStr, CString};
use std::sync::Mutex;

use enigo::{
    Direction::{Press, Release},
    Enigo, Key, Keyboard, Settings,
};

const PASTE_MODE_NORMAL: i32 = 0;
const PASTE_MODE_PLAIN: i32 = 1;

static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);

#[no_mangle]
pub extern "C" fn sttapp_input_api_version() -> i32 {
    1
}

#[no_mangle]
pub extern "C" fn sttapp_input_paste(mode: i32) -> bool {
    match paste_mode_from_int(mode).and_then(paste) {
        Ok(()) => {
            clear_last_error();
            true
        }
        Err(error) => {
            set_last_error(error);
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_input_set_clipboard_text(text: *const c_char) -> bool {
    match set_clipboard_text(text) {
        Ok(()) => {
            clear_last_error();
            true
        }
        Err(error) => {
            set_last_error(error);
            false
        }
    }
}

#[no_mangle]
pub extern "C" fn sttapp_input_last_error_message() -> *mut c_char {
    let message = LAST_ERROR
        .lock()
        .ok()
        .and_then(|error| error.clone())
        .unwrap_or_else(|| "unknown sttapp_input error".to_string());

    CString::new(message)
        .unwrap_or_else(|_| CString::new("sttapp_input error contained an interior nul").unwrap())
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_input_string_free(message: *mut c_char) {
    if !message.is_null() {
        drop(CString::from_raw(message));
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PasteMode {
    Normal,
    Plain,
}

fn paste_mode_from_int(mode: i32) -> Result<PasteMode, String> {
    match mode {
        PASTE_MODE_NORMAL => Ok(PasteMode::Normal),
        PASTE_MODE_PLAIN => Ok(PasteMode::Plain),
        _ => Err(format!("invalid paste mode: {mode}")),
    }
}

fn paste(mode: PasteMode) -> Result<(), String> {
    let mut enigo = Enigo::new(&Settings::default())
        .map_err(|error| format!("failed to initialize desktop input: {error}"))?;
    let shortcut = paste_shortcut(mode);
    chord(&mut enigo, shortcut.modifiers, shortcut.key)
}

unsafe fn set_clipboard_text(text: *const c_char) -> Result<(), String> {
    if text.is_null() {
        return Err("clipboard text pointer was null".to_string());
    }

    let text = CStr::from_ptr(text)
        .to_str()
        .map_err(|error| format!("clipboard text was not valid UTF-8: {error}"))?;
    let mut clipboard = arboard::Clipboard::new()
        .map_err(|error| format!("failed to initialize clipboard: {error}"))?;
    clipboard
        .set_text(text.to_owned())
        .map_err(|error| format!("failed to set clipboard text: {error}"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PasteShortcut {
    modifiers: &'static [Key],
    key: Key,
}

fn paste_shortcut(mode: PasteMode) -> PasteShortcut {
    match mode {
        PasteMode::Normal => PasteShortcut {
            modifiers: normal_paste_modifiers(),
            key: Key::Unicode('v'),
        },
        PasteMode::Plain => PasteShortcut {
            modifiers: plain_paste_modifiers(),
            key: Key::Unicode('v'),
        },
    }
}

#[cfg(target_os = "macos")]
fn normal_paste_modifiers() -> &'static [Key] {
    &[Key::Meta]
}

#[cfg(not(target_os = "macos"))]
fn normal_paste_modifiers() -> &'static [Key] {
    &[Key::Control]
}

#[cfg(target_os = "macos")]
fn plain_paste_modifiers() -> &'static [Key] {
    &[Key::Meta, Key::Option, Key::Shift]
}

#[cfg(not(target_os = "macos"))]
fn plain_paste_modifiers() -> &'static [Key] {
    &[Key::Control, Key::Shift]
}

fn chord(enigo: &mut Enigo, modifiers: &[Key], key: Key) -> Result<(), String> {
    for modifier in modifiers {
        enigo
            .key(*modifier, Press)
            .map_err(|error| format!("failed to press paste modifier: {error}"))?;
    }

    let click_result = enigo
        .key(key, enigo::Direction::Click)
        .map_err(|error| format!("failed to send paste key: {error}"));

    let mut release_error = None;
    for modifier in modifiers.iter().rev() {
        if let Err(error) = enigo.key(*modifier, Release) {
            release_error = Some(format!("failed to release paste modifier: {error}"));
        }
    }

    click_result?;
    if let Some(error) = release_error {
        return Err(error);
    }
    Ok(())
}

fn set_last_error(message: impl Into<String>) {
    if let Ok(mut error) = LAST_ERROR.lock() {
        *error = Some(message.into());
    }
}

fn clear_last_error() {
    if let Ok(mut error) = LAST_ERROR.lock() {
        *error = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_paste_modes_fail_cleanly() {
        assert_eq!(
            paste_mode_from_int(99).unwrap_err(),
            "invalid paste mode: 99"
        );
    }

    #[test]
    fn valid_paste_modes_parse() {
        assert_eq!(paste_mode_from_int(0), Ok(PasteMode::Normal));
        assert_eq!(paste_mode_from_int(1), Ok(PasteMode::Plain));
    }

    #[test]
    fn paste_modes_map_to_expected_shortcuts() {
        assert_eq!(
            paste_shortcut(PasteMode::Normal),
            PasteShortcut {
                modifiers: normal_paste_modifiers(),
                key: Key::Unicode('v'),
            }
        );
        assert_eq!(
            paste_shortcut(PasteMode::Plain),
            PasteShortcut {
                modifiers: plain_paste_modifiers(),
                key: Key::Unicode('v'),
            }
        );
    }

    #[test]
    fn null_clipboard_text_fails_cleanly() {
        assert_eq!(
            unsafe { set_clipboard_text(std::ptr::null()) }.unwrap_err(),
            "clipboard text pointer was null"
        );
    }
}
