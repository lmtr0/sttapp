use std::ffi::{c_char, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use flacenc::component::BitRepr;
use flacenc::error::Verify;
use rodio::microphone::MicrophoneBuilder;
use rubato::audioadapter_buffers::direct::InterleavedSlice;
use rubato::{Fft, FixedSync, Resampler};

static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);
const TRANSCRIPTION_SAMPLE_RATE: usize = 16_000;
const TRANSCRIPTION_CHANNELS: usize = 1;

#[no_mangle]
pub extern "C" fn sttapp_audio_api_version() -> i32 {
    4
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
pub extern "C" fn sttapp_audio_clip_to_flac(clip: *const AudioClip) -> *mut EncodedAudio {
    let Some(clip) = (unsafe { clip.as_ref() }) else {
        set_last_error("audio clip handle is null");
        return ptr::null_mut();
    };

    match clip.to_flac_bytes() {
        Ok(bytes) => {
            clear_last_error();
            Box::into_raw(Box::new(EncodedAudio { bytes }))
        }
        Err(error) => {
            set_last_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn sttapp_audio_clip_to_flac_16khz_mono(
    clip: *const AudioClip,
) -> *mut EncodedAudio {
    let Some(clip) = (unsafe { clip.as_ref() }) else {
        set_last_error("audio clip handle is null");
        return ptr::null_mut();
    };

    match clip.to_flac_16khz_mono_bytes() {
        Ok(bytes) => {
            clear_last_error();
            Box::into_raw(Box::new(EncodedAudio { bytes }))
        }
        Err(error) => {
            set_last_error(error);
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn sttapp_audio_encoded_audio_len(encoded: *const EncodedAudio) -> u64 {
    unsafe {
        encoded
            .as_ref()
            .map(|encoded| encoded.bytes.len() as u64)
            .unwrap_or_default()
    }
}

#[no_mangle]
pub extern "C" fn sttapp_audio_encoded_audio_data(encoded: *const EncodedAudio) -> *const u8 {
    unsafe {
        encoded
            .as_ref()
            .map(|encoded| encoded.bytes.as_ptr())
            .unwrap_or(ptr::null())
    }
}

#[no_mangle]
pub unsafe extern "C" fn sttapp_audio_encoded_audio_free(encoded: *mut EncodedAudio) {
    if !encoded.is_null() {
        drop(Box::from_raw(encoded));
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

pub struct EncodedAudio {
    bytes: Vec<u8>,
}

impl AudioClip {
    fn to_flac_bytes(&self) -> Result<Vec<u8>, String> {
        let metadata = self.validate_for_encoding()?;

        let samples = self
            .samples
            .iter()
            .map(|sample| i32::from(*sample))
            .collect::<Vec<_>>();
        encode_flac_samples(&samples, metadata.channels, metadata.sample_rate)
    }

    fn to_flac_16khz_mono_bytes(&self) -> Result<Vec<u8>, String> {
        let metadata = self.validate_for_encoding()?;
        let mono = downmix_to_mono_f32(&self.samples, metadata.channels);
        let resampled = resample_mono_to_transcription_rate(&mono, metadata.sample_rate)?;
        let samples = resampled
            .into_iter()
            .map(f32_to_i16_sample)
            .map(i32::from)
            .collect::<Vec<_>>();

        encode_flac_samples(&samples, TRANSCRIPTION_CHANNELS, TRANSCRIPTION_SAMPLE_RATE)
    }

    fn validate_for_encoding(&self) -> Result<AudioClipMetadata, String> {
        if self.channels == 0 {
            return Err("audio clip has invalid channel count".to_string());
        }
        if self.sample_rate == 0 {
            return Err("audio clip has invalid sample rate".to_string());
        }
        if self.samples.is_empty() {
            return Err("audio clip has no samples".to_string());
        }

        let channels = self.channels as usize;
        if self.samples.len() % channels != 0 {
            return Err("audio clip samples are not aligned to channel count".to_string());
        }

        Ok(AudioClipMetadata {
            channels,
            sample_rate: self.sample_rate as usize,
        })
    }
}

struct AudioClipMetadata {
    channels: usize,
    sample_rate: usize,
}

fn downmix_to_mono_f32(samples: &[i16], channels: usize) -> Vec<f32> {
    if channels == TRANSCRIPTION_CHANNELS {
        return samples.iter().map(|sample| *sample as f32).collect();
    }

    samples
        .chunks_exact(channels)
        .map(|frame| {
            let sum = frame.iter().map(|sample| *sample as f32).sum::<f32>();
            sum / channels as f32
        })
        .collect()
}

fn resample_mono_to_transcription_rate(
    samples: &[f32],
    sample_rate: usize,
) -> Result<Vec<f32>, String> {
    if sample_rate == TRANSCRIPTION_SAMPLE_RATE {
        return Ok(samples.to_vec());
    }

    let input_frames = samples.len();
    let input = InterleavedSlice::new(samples, TRANSCRIPTION_CHANNELS, input_frames)
        .map_err(|error| format!("failed to prepare resampler input buffer: {error}"))?;
    let mut resampler = Fft::<f32>::new(
        sample_rate,
        TRANSCRIPTION_SAMPLE_RATE,
        1024,
        TRANSCRIPTION_CHANNELS,
        FixedSync::Input,
    )
    .map_err(|error| format!("failed to create 16 kHz mono resampler: {error}"))?;
    let output = resampler
        .process_all(&input, input_frames, None)
        .map_err(|error| format!("failed to resample audio to 16 kHz mono: {error}"))?;

    Ok(output.take_data())
}

fn f32_to_i16_sample(sample: f32) -> i16 {
    sample.round().clamp(i16::MIN as f32, i16::MAX as f32) as i16
}

fn encode_flac_samples(
    samples: &[i32],
    channels: usize,
    sample_rate: usize,
) -> Result<Vec<u8>, String> {
    let config = flacenc::config::Encoder::default()
        .into_verified()
        .map_err(|error| format!("invalid FLAC encoder config: {error:?}"))?;
    let source = flacenc::source::MemSource::from_samples(samples, channels, 16, sample_rate);
    let stream = flacenc::encode_with_fixed_block_size(&config, source, config.block_size)
        .map_err(|error| format!("failed to encode FLAC: {error}"))?;
    let mut sink = flacenc::bitsink::ByteSink::new();
    stream
        .write(&mut sink)
        .map_err(|error| format!("failed to serialize FLAC: {error}"))?;
    Ok(sink.as_slice().to_vec())
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

    #[test]
    fn flac_encoding_starts_with_marker() {
        let clip = AudioClip {
            samples: vec![0; 4096],
            sample_rate: 16_000,
            channels: 1,
        };

        let encoded = clip.to_flac_bytes().expect("FLAC encoding should work");

        assert_eq!(&encoded[0..4], b"fLaC");
    }

    #[test]
    fn flac_encoding_preserves_stream_metadata() {
        let clip = AudioClip {
            samples: vec![0; 8192],
            sample_rate: 48_000,
            channels: 2,
        };

        let encoded = clip.to_flac_bytes().expect("FLAC encoding should work");
        let (sample_rate, channels, bits_per_sample) = read_flac_stream_info(&encoded);

        assert_eq!(sample_rate, 48_000);
        assert_eq!(channels, 2);
        assert_eq!(bits_per_sample, 16);
    }

    #[test]
    fn flac_encoding_rejects_invalid_clips() {
        let empty = AudioClip {
            samples: Vec::new(),
            sample_rate: 16_000,
            channels: 1,
        };
        let bad_channels = AudioClip {
            samples: vec![0; 64],
            sample_rate: 16_000,
            channels: 0,
        };
        let unaligned = AudioClip {
            samples: vec![0; 65],
            sample_rate: 16_000,
            channels: 2,
        };

        assert_eq!(
            empty.to_flac_bytes().unwrap_err(),
            "audio clip has no samples"
        );
        assert_eq!(
            bad_channels.to_flac_bytes().unwrap_err(),
            "audio clip has invalid channel count"
        );
        assert_eq!(
            unaligned.to_flac_bytes().unwrap_err(),
            "audio clip samples are not aligned to channel count"
        );
    }

    #[test]
    fn optimized_flac_encoding_preserves_16khz_mono_stream_metadata() {
        let clip = AudioClip {
            samples: vec![0; 8192],
            sample_rate: 16_000,
            channels: 1,
        };

        let encoded = clip
            .to_flac_16khz_mono_bytes()
            .expect("optimized FLAC encoding should work");
        let (sample_rate, channels, bits_per_sample) = read_flac_stream_info(&encoded);

        assert_eq!(sample_rate, 16_000);
        assert_eq!(channels, 1);
        assert_eq!(bits_per_sample, 16);
    }

    #[test]
    fn optimized_flac_encoding_downmixes_and_resamples_stereo_48khz() {
        let samples = (0..48_000)
            .flat_map(|frame| {
                let left = ((frame % 256) as i16) * 32;
                let right = -left;
                [left, right]
            })
            .collect::<Vec<_>>();
        let clip = AudioClip {
            samples,
            sample_rate: 48_000,
            channels: 2,
        };

        let encoded = clip
            .to_flac_16khz_mono_bytes()
            .expect("optimized FLAC encoding should work");
        let (sample_rate, channels, bits_per_sample) = read_flac_stream_info(&encoded);

        assert_eq!(sample_rate, 16_000);
        assert_eq!(channels, 1);
        assert_eq!(bits_per_sample, 16);
    }

    #[test]
    fn optimized_flac_encoding_rejects_invalid_clips() {
        let empty = AudioClip {
            samples: Vec::new(),
            sample_rate: 16_000,
            channels: 1,
        };
        let bad_channels = AudioClip {
            samples: vec![0; 64],
            sample_rate: 16_000,
            channels: 0,
        };
        let bad_sample_rate = AudioClip {
            samples: vec![0; 64],
            sample_rate: 0,
            channels: 1,
        };
        let unaligned = AudioClip {
            samples: vec![0; 65],
            sample_rate: 16_000,
            channels: 2,
        };

        assert_eq!(
            empty.to_flac_16khz_mono_bytes().unwrap_err(),
            "audio clip has no samples"
        );
        assert_eq!(
            bad_channels.to_flac_16khz_mono_bytes().unwrap_err(),
            "audio clip has invalid channel count"
        );
        assert_eq!(
            bad_sample_rate.to_flac_16khz_mono_bytes().unwrap_err(),
            "audio clip has invalid sample rate"
        );
        assert_eq!(
            unaligned.to_flac_16khz_mono_bytes().unwrap_err(),
            "audio clip samples are not aligned to channel count"
        );
    }

    #[test]
    fn downmix_to_mono_averages_stereo_frames() {
        let samples = [1000, -500, -1000, 500, 100, 300];

        let mono = downmix_to_mono_f32(&samples, 2);

        assert_eq!(mono, vec![250.0, -250.0, 200.0]);
    }

    fn read_flac_stream_info(bytes: &[u8]) -> (u32, u8, u8) {
        assert_eq!(&bytes[0..4], b"fLaC");
        assert_eq!(bytes[4] & 0x7f, 0);
        let stream_info = &bytes[8..42];
        let packed = u64::from_be_bytes([
            stream_info[10],
            stream_info[11],
            stream_info[12],
            stream_info[13],
            stream_info[14],
            stream_info[15],
            stream_info[16],
            stream_info[17],
        ]);
        let sample_rate = ((packed >> 44) & 0x000f_ffff) as u32;
        let channels = (((packed >> 41) & 0x07) + 1) as u8;
        let bits_per_sample = (((packed >> 36) & 0x1f) + 1) as u8;
        (sample_rate, channels, bits_per_sample)
    }
}
