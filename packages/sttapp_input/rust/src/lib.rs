use std::ffi::{c_char, CString};
use std::sync::Mutex;

use enigo::{
    Direction::{Click, Press, Release},
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

    match mode {
        PasteMode::Normal => chord(&mut enigo, normal_paste_modifiers(), 'v'),
        PasteMode::Plain => chord(&mut enigo, plain_paste_modifiers(), 'v'),
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

fn chord(enigo: &mut Enigo, modifiers: &[Key], key: char) -> Result<(), String> {
    for modifier in modifiers {
        enigo
            .key(*modifier, Press)
            .map_err(|error| format!("failed to press paste modifier: {error}"))?;
    }

    let click_result = enigo
        .key(Key::Unicode(key), Click)
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
}
