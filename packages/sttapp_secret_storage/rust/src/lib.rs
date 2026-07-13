use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::sync::{Mutex, OnceLock};

use keyring_core::{Entry, Error};

const API_VERSION: i32 = 1;
const DEFAULT_SERVICE: &str = "com.taresz.sttapp";
const STATUS_SUCCESS: i32 = 0;
const STATUS_NOT_FOUND: i32 = 1;
const STATUS_ERROR: i32 = -1;

static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);
static STORE_INITIALIZED: OnceLock<()> = OnceLock::new();
static STORE_INITIALIZATION_LOCK: Mutex<()> = Mutex::new(());

#[no_mangle]
pub extern "C" fn sttapp_secret_storage_api_version() -> i32 {
    API_VERSION
}

#[no_mangle]
pub extern "C" fn sttapp_secret_storage_prepare() -> bool {
    match ensure_store() {
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
pub unsafe extern "C" fn sttapp_secret_storage_read(
    key: *const c_char,
    out_value: *mut *mut c_char,
) -> i32 {
    match read_secret(key, out_value) {
        Ok(ReadResult::Found(value)) => match string_to_raw(&value) {
            Ok(raw) => {
                *out_value = raw;
                clear_last_error();
                STATUS_SUCCESS
            }
            Err(error) => {
                *out_value = ptr::null_mut();
                set_last_error(error);
                STATUS_ERROR
            }
        },
        Ok(ReadResult::NotFound) => {
            *out_value = ptr::null_mut();
            clear_last_error();
            STATUS_NOT_FOUND
        }
        Err(error) => {
            if !out_value.is_null() {
                *out_value = ptr::null_mut();
            }
            set_last_error(error);
            STATUS_ERROR
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_secret_storage_write(
    key: *const c_char,
    value: *const c_char,
) -> bool {
    match write_secret(key, value) {
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
pub unsafe extern "C" fn sttapp_secret_storage_delete(key: *const c_char) -> i32 {
    match delete_secret(key) {
        Ok(DeleteResult::Deleted) => {
            clear_last_error();
            STATUS_SUCCESS
        }
        Ok(DeleteResult::NotFound) => {
            clear_last_error();
            STATUS_NOT_FOUND
        }
        Err(error) => {
            set_last_error(error);
            STATUS_ERROR
        }
    }
}

#[no_mangle]
pub extern "C" fn sttapp_secret_storage_last_error_message() -> *mut c_char {
    let message = LAST_ERROR
        .lock()
        .ok()
        .and_then(|error| error.clone())
        .unwrap_or_else(|| "unknown sttapp_secret_storage error".to_string());

    CString::new(message)
        .unwrap_or_else(|_| {
            CString::new("sttapp_secret_storage error contained an interior nul").unwrap()
        })
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_secret_storage_string_free(message: *mut c_char) {
    if !message.is_null() {
        drop(CString::from_raw(message));
    }
}

#[derive(Debug)]
enum ReadResult {
    Found(String),
    NotFound,
}

#[derive(Debug)]
enum DeleteResult {
    Deleted,
    NotFound,
}

unsafe fn read_secret(
    key: *const c_char,
    out_value: *mut *mut c_char,
) -> Result<ReadResult, String> {
    if out_value.is_null() {
        return Err("secret storage output pointer was null".to_string());
    }
    *out_value = ptr::null_mut();

    let key = validate_key(key)?;
    ensure_store()?;

    match entry(&key)?.get_password() {
        Ok(value) => Ok(ReadResult::Found(value)),
        Err(Error::NoEntry) => Ok(ReadResult::NotFound),
        Err(error) => Err(format!("failed to read secret '{key}': {error}")),
    }
}

unsafe fn write_secret(key: *const c_char, value: *const c_char) -> Result<(), String> {
    let key = validate_key(key)?;
    let value = c_string(value, "secret storage value")?;
    ensure_store()?;

    entry(&key)?
        .set_password(&value)
        .map_err(|error| format!("failed to write secret '{key}': {error}"))
}

unsafe fn delete_secret(key: *const c_char) -> Result<DeleteResult, String> {
    let key = validate_key(key)?;
    ensure_store()?;

    match entry(&key)?.delete_credential() {
        Ok(()) => Ok(DeleteResult::Deleted),
        Err(Error::NoEntry) => Ok(DeleteResult::NotFound),
        Err(error) => Err(format!("failed to delete secret '{key}': {error}")),
    }
}

fn entry(key: &str) -> Result<Entry, String> {
    Entry::new(DEFAULT_SERVICE, key)
        .map_err(|error| format!("failed to create secret entry '{key}': {error}"))
}

unsafe fn validate_key(key: *const c_char) -> Result<String, String> {
    let key = c_string(key, "secret storage key")?;
    if key.trim().is_empty() {
        return Err("secret storage key was empty".to_string());
    }
    Ok(key)
}

unsafe fn c_string(pointer: *const c_char, name: &str) -> Result<String, String> {
    if pointer.is_null() {
        return Err(format!("{name} pointer was null"));
    }

    CStr::from_ptr(pointer)
        .to_str()
        .map(str::to_owned)
        .map_err(|error| format!("{name} was not valid UTF-8: {error}"))
}

fn string_to_raw(value: &str) -> Result<*mut c_char, String> {
    CString::new(value)
        .map(CString::into_raw)
        .map_err(|_| "secret value contained an interior nul byte".to_string())
}

fn ensure_store() -> Result<(), String> {
    if STORE_INITIALIZED.get().is_some() {
        return Ok(());
    }

    let _guard = STORE_INITIALIZATION_LOCK
        .lock()
        .map_err(|_| "secret storage initialization lock was poisoned".to_string())?;
    if STORE_INITIALIZED.get().is_some() {
        return Ok(());
    }

    initialize_platform_store()
        .map_err(|error| format!("failed to initialize secret storage: {error}"))?;
    let _ = STORE_INITIALIZED.set(());
    Ok(())
}

#[cfg(target_os = "windows")]
fn initialize_platform_store() -> keyring_core::Result<()> {
    keyring_core::set_default_store(windows_native_keyring_store::Store::new()?);
    Ok(())
}

#[cfg(target_os = "macos")]
fn initialize_platform_store() -> keyring_core::Result<()> {
    keyring_core::set_default_store(apple_native_keyring_store::keychain::Store::new()?);
    Ok(())
}

#[cfg(target_os = "linux")]
fn initialize_platform_store() -> keyring_core::Result<()> {
    keyring_core::set_default_store(zbus_secret_service_keyring_store::Store::new()?);
    Ok(())
}

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
fn initialize_platform_store() -> keyring_core::Result<()> {
    Err(Error::NotSupportedByStore(
        "sttapp_secret_storage only supports Windows, macOS, and Linux".to_string(),
    ))
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
mod ffi_contract_tests {
    use super::*;

    #[test]
    fn api_version_matches_dart_contract() {
        assert_eq!(sttapp_secret_storage_api_version(), 1);
    }

    #[test]
    fn validate_key_accepts_non_blank_utf8() {
        let key = CString::new("api-key-é").unwrap();

        assert_eq!(unsafe { validate_key(key.as_ptr()) }.unwrap(), "api-key-é");
    }

    #[test]
    fn c_string_rejects_invalid_utf8() {
        let invalid_utf8 = [0xff_u8, 0];

        let error = unsafe {
            c_string(
                invalid_utf8.as_ptr().cast::<c_char>(),
                "secret storage value",
            )
        }
        .unwrap_err();

        assert!(error.starts_with("secret storage value was not valid UTF-8:"));
    }

    #[test]
    fn string_to_raw_round_trips_utf8() {
        let raw = string_to_raw("secret-é").unwrap();

        let value = unsafe { CStr::from_ptr(raw) }.to_str().unwrap().to_owned();
        unsafe { sttapp_secret_storage_string_free(raw) };

        assert_eq!(value, "secret-é");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_key_pointer_fails_before_store_initialization() {
        let error = unsafe { validate_key(ptr::null()) }.unwrap_err();

        assert_eq!(error, "secret storage key pointer was null");
    }

    #[test]
    fn invalid_utf8_key_fails() {
        let bytes = [0xff_u8, 0x00];
        let error = unsafe { validate_key(bytes.as_ptr().cast::<c_char>()) }.unwrap_err();

        assert!(error.starts_with("secret storage key was not valid UTF-8:"));
    }

    #[test]
    fn empty_key_fails() {
        let key = CString::new("   ").unwrap();
        let error = unsafe { validate_key(key.as_ptr()) }.unwrap_err();

        assert_eq!(error, "secret storage key was empty");
    }

    #[test]
    fn write_rejects_null_value_before_store_initialization() {
        let key = CString::new("openai_api_key").unwrap();
        let error = unsafe { write_secret(key.as_ptr(), ptr::null()) }.unwrap_err();

        assert_eq!(error, "secret storage value pointer was null");
    }

    #[test]
    fn read_rejects_null_output_pointer_before_store_initialization() {
        let key = CString::new("openai_api_key").unwrap();
        let error = unsafe { read_secret(key.as_ptr(), ptr::null_mut()) }.unwrap_err();

        assert_eq!(error, "secret storage output pointer was null");
    }

    #[test]
    fn read_status_for_no_entry_is_not_found() {
        let status = match Error::NoEntry {
            Error::NoEntry => STATUS_NOT_FOUND,
            _ => STATUS_ERROR,
        };

        assert_eq!(status, STATUS_NOT_FOUND);
    }

    #[test]
    fn non_no_entry_errors_map_to_error_status() {
        let status = match Error::NoDefaultStore {
            Error::NoEntry => STATUS_NOT_FOUND,
            _ => STATUS_ERROR,
        };

        assert_eq!(status, STATUS_ERROR);
    }

    #[test]
    fn successful_read_value_allocates_and_frees_c_string() {
        let raw = string_to_raw("stored-key").unwrap();

        assert!(!raw.is_null());
        unsafe {
            sttapp_secret_storage_string_free(raw);
        }
    }

    #[test]
    fn interior_nul_values_do_not_allocate_c_strings() {
        let error = string_to_raw("bad\0value").unwrap_err();

        assert_eq!(error, "secret value contained an interior nul byte");
    }
}
