use std::ffi::{c_char, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rodio::microphone::MicrophoneBuilder;

static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);

#[no_mangle]
pub extern "C" fn sttapp_audio_api_version() -> i32 {
    2
}

#[no_mangle]
pub extern "C" fn sttapp_audio_recorder_new() -> *mut AudioRecorder {
    Box::into_raw(Box::new(AudioRecorder))
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_audio_recorder_free(recorder: *mut AudioRecorder) {
    if !recorder.is_null() {
        drop(Box::from_raw(recorder));
    }
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_audio_recorder_start(
    recorder: *mut AudioRecorder,
) -> *mut ActiveRecording {
    if recorder.is_null() {
        set_last_error("recorder handle is null");
        return ptr::null_mut();
    }

    match ActiveRecording::start() {
        Ok(recording) => {
            clear_last_error();
            Box::into_raw(Box::new(recording))
        }
        Err(error) => {
            set_last_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_audio_recording_stop(
    recording: *mut ActiveRecording,
) -> *mut AudioClip {
    if recording.is_null() {
        set_last_error("recording handle is null");
        return ptr::null_mut();
    }

    let recording = Box::from_raw(recording);
    let clip = recording.stop();
    clear_last_error();
    Box::into_raw(Box::new(clip))
}

#[no_mangle]
pub extern "C" fn sttapp_audio_clip_sample_rate(clip: *const AudioClip) -> u32 {
    unsafe {
        clip.as_ref()
            .map(|clip| clip.sample_rate)
            .unwrap_or_default()
    }
}

#[no_mangle]
pub extern "C" fn sttapp_audio_clip_channels(clip: *const AudioClip) -> u16 {
    unsafe { clip.as_ref().map(|clip| clip.channels).unwrap_or_default() }
}

#[no_mangle]
pub extern "C" fn sttapp_audio_clip_sample_count(clip: *const AudioClip) -> u64 {
    unsafe {
        clip.as_ref()
            .map(|clip| clip.samples.len() as u64)
            .unwrap_or_default()
    }
}

#[no_mangle]
pub extern "C" fn sttapp_audio_clip_frame_count(clip: *const AudioClip) -> u64 {
    unsafe {
        clip.as_ref()
            .and_then(|clip| {
                if clip.channels == 0 {
                    None
                } else {
                    Some((clip.samples.len() / clip.channels as usize) as u64)
                }
            })
            .unwrap_or_default()
    }
}

#[no_mangle]
pub extern "C" fn sttapp_audio_clip_data(clip: *const AudioClip) -> *const i16 {
    unsafe {
        clip.as_ref()
            .map(|clip| clip.samples.as_ptr())
            .unwrap_or(ptr::null())
    }
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_audio_clip_free(clip: *mut AudioClip) {
    if !clip.is_null() {
        drop(Box::from_raw(clip));
    }
}

#[no_mangle]
pub extern "C" fn sttapp_audio_last_error_message() -> *mut c_char {
    let message = LAST_ERROR
        .lock()
        .ok()
        .and_then(|error| error.clone())
        .unwrap_or_else(|| "unknown sttapp_audio error".to_string());

    CString::new(message)
        .unwrap_or_else(|_| CString::new("sttapp_audio error contained an interior nul").unwrap())
        .into_raw()
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_audio_string_free(message: *mut c_char) {
    if !message.is_null() {
        drop(CString::from_raw(message));
    }
}

pub struct AudioRecorder;

pub struct ActiveRecording {
    stop_requested: Arc<AtomicBool>,
    worker: Option<JoinHandle<()>>,
    samples: Arc<Mutex<Vec<i16>>>,
    sample_rate: u32,
    channels: u16,
}

impl ActiveRecording {
    fn start() -> Result<Self, String> {
        let mut mic = MicrophoneBuilder::new()
            .default_device()
            .map_err(|error| format!("failed to select default input device: {error}"))?
            .default_config()
            .map_err(|error| format!("failed to read default input config: {error}"))?
            .open_stream()
            .map_err(|error| format!("failed to open microphone stream: {error}"))?;

        let sample_rate = mic.config().sample_rate.get();
        let channels = mic.config().channel_count.get();
        let samples = Arc::new(Mutex::new(Vec::new()));
        let stop_requested = Arc::new(AtomicBool::new(false));
        let worker_samples = Arc::clone(&samples);
        let worker_stop = Arc::clone(&stop_requested);

        let worker = thread::spawn(move || {
            while let Some(sample) = mic.next() {
                if worker_stop.load(Ordering::Acquire) {
                    break;
                }

                if let Ok(mut output) = worker_samples.lock() {
                    output.push(convert_sample(sample));
                }
            }
        });

        Ok(Self {
            stop_requested,
            worker: Some(worker),
            samples,
            sample_rate,
            channels,
        })
    }

    fn stop(mut self) -> AudioClip {
        self.stop_requested.store(true, Ordering::Release);

        if let Some(worker) = self.worker.take() {
            join_promptly(worker, Duration::from_millis(250));
        }

        let samples = self
            .samples
            .lock()
            .map(|mut samples| std::mem::take(&mut *samples))
            .unwrap_or_default();

        AudioClip {
            samples,
            sample_rate: self.sample_rate,
            channels: self.channels,
        }
    }
}

pub struct AudioClip {
    samples: Vec<i16>,
    sample_rate: u32,
    channels: u16,
}

fn join_promptly(worker: JoinHandle<()>, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    while !worker.is_finished() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }

    if worker.is_finished() {
        let _ = worker.join();
    }
}

fn convert_sample(sample: rodio::Sample) -> i16 {
    (sample.clamp(-1.0, 1.0) * i16::MAX as rodio::Sample) as i16
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
    fn float_samples_are_clamped() {
        assert_eq!(convert_sample(-2.0), i16::MIN + 1);
        assert_eq!(convert_sample(0.0), 0);
        assert_eq!(convert_sample(2.0), i16::MAX);
    }

    #[test]
    fn frame_count_uses_channel_count() {
        let clip = AudioClip {
            samples: vec![0; 8],
            sample_rate: 48_000,
            channels: 2,
        };

        assert_eq!(sttapp_audio_clip_frame_count(&clip), 4);
    }
}
