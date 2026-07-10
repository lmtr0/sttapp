// Native bindings for the Rust library bundled by hook/build.dart.
// ignore_for_file: type=lint
import 'dart:ffi' as ffi;

const _assetId = 'package:sttapp_audio/sttapp_audio_bindings_generated.dart';

@ffi.Native<ffi.Int32 Function()>(assetId: _assetId)
external int sttapp_audio_api_version();

@ffi.Native<ffi.Pointer<ffi.Void> Function()>(assetId: _assetId)
external ffi.Pointer<ffi.Void> sttapp_audio_recorder_new();

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(assetId: _assetId)
external void sttapp_audio_recorder_free(ffi.Pointer<ffi.Void> recorder);

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>(
  assetId: _assetId,
)
external ffi.Pointer<ffi.Void> sttapp_audio_recorder_start(
  ffi.Pointer<ffi.Void> recorder,
);

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>(
  assetId: _assetId,
)
external ffi.Pointer<ffi.Void> sttapp_audio_recording_stop(
  ffi.Pointer<ffi.Void> recording,
);

@ffi.Native<ffi.Uint32 Function(ffi.Pointer<ffi.Void>)>(assetId: _assetId)
external int sttapp_audio_clip_sample_rate(ffi.Pointer<ffi.Void> clip);

@ffi.Native<ffi.Uint16 Function(ffi.Pointer<ffi.Void>)>(assetId: _assetId)
external int sttapp_audio_clip_channels(ffi.Pointer<ffi.Void> clip);

@ffi.Native<ffi.Uint64 Function(ffi.Pointer<ffi.Void>)>(assetId: _assetId)
external int sttapp_audio_clip_sample_count(ffi.Pointer<ffi.Void> clip);

@ffi.Native<ffi.Uint64 Function(ffi.Pointer<ffi.Void>)>(assetId: _assetId)
external int sttapp_audio_clip_frame_count(ffi.Pointer<ffi.Void> clip);

@ffi.Native<ffi.Pointer<ffi.Int16> Function(ffi.Pointer<ffi.Void>)>(
  assetId: _assetId,
)
external ffi.Pointer<ffi.Int16> sttapp_audio_clip_data(
  ffi.Pointer<ffi.Void> clip,
);

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>(
  assetId: _assetId,
)
external ffi.Pointer<ffi.Void> sttapp_audio_clip_to_flac(
  ffi.Pointer<ffi.Void> clip,
);

@ffi.Native<ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)>(
  assetId: _assetId,
)
external ffi.Pointer<ffi.Void> sttapp_audio_clip_to_flac_16khz_mono(
  ffi.Pointer<ffi.Void> clip,
);

@ffi.Native<ffi.Uint64 Function(ffi.Pointer<ffi.Void>)>(assetId: _assetId)
external int sttapp_audio_encoded_audio_len(ffi.Pointer<ffi.Void> encoded);

@ffi.Native<ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Void>)>(
  assetId: _assetId,
)
external ffi.Pointer<ffi.Uint8> sttapp_audio_encoded_audio_data(
  ffi.Pointer<ffi.Void> encoded,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(assetId: _assetId)
external void sttapp_audio_encoded_audio_free(ffi.Pointer<ffi.Void> encoded);

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Void>)>(assetId: _assetId)
external void sttapp_audio_clip_free(ffi.Pointer<ffi.Void> clip);

@ffi.Native<ffi.Pointer<ffi.Char> Function()>(assetId: _assetId)
external ffi.Pointer<ffi.Char> sttapp_audio_last_error_message();

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Char>)>(assetId: _assetId)
external void sttapp_audio_string_free(ffi.Pointer<ffi.Char> message);
