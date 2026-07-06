import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'sttapp_audio_bindings_generated.dart' as bindings;

final class SttappAudio {
  const SttappAudio._();

  static int get nativeApiVersion => bindings.sttapp_audio_api_version();
}

final class AudioRecorder {
  AudioRecorder() : _handle = bindings.sttapp_audio_recorder_new() {
    if (_handle == ffi.nullptr) {
      throw StateError(_lastNativeError());
    }
  }

  ffi.Pointer<ffi.Void> _handle;
  bool _disposed = false;

  Future<AudioRecording> start() async {
    _checkOpen();
    final recording = bindings.sttapp_audio_recorder_start(_handle);
    if (recording == ffi.nullptr) {
      throw StateError(_lastNativeError());
    }
    return AudioRecording._(recording);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    bindings.sttapp_audio_recorder_free(_handle);
    _handle = ffi.nullptr;
    _disposed = true;
  }

  void _checkOpen() {
    if (_disposed || _handle == ffi.nullptr) {
      throw StateError('AudioRecorder has been disposed.');
    }
  }
}

final class AudioRecording {
  AudioRecording._(this._handle);

  ffi.Pointer<ffi.Void> _handle;
  bool _stopped = false;

  bool get isStopped => _stopped;

  Future<AudioClip> stop() async {
    if (_stopped || _handle == ffi.nullptr) {
      throw StateError('AudioRecording has already been stopped.');
    }

    final recording = _handle;
    _handle = ffi.nullptr;
    _stopped = true;

    final clip = bindings.sttapp_audio_recording_stop(recording);
    if (clip == ffi.nullptr) {
      throw StateError(_lastNativeError());
    }
    return AudioClip._(clip);
  }
}

final class AudioClip {
  AudioClip._(this._handle)
    : sampleRate = bindings.sttapp_audio_clip_sample_rate(_handle),
      channels = bindings.sttapp_audio_clip_channels(_handle),
      sampleCount = bindings.sttapp_audio_clip_sample_count(_handle),
      frameCount = bindings.sttapp_audio_clip_frame_count(_handle);

  ffi.Pointer<ffi.Void> _handle;

  final int sampleRate;
  final int channels;
  final int sampleCount;
  final int frameCount;

  bool _disposed = false;

  Int16List get samples {
    _checkOpen();
    final data = bindings.sttapp_audio_clip_data(_handle);
    if (data == ffi.nullptr && sampleCount > 0) {
      throw StateError('Native audio clip returned a null sample buffer.');
    }
    return data.asTypedList(sampleCount);
  }

  Future<void> writeWav(File file) async {
    _checkOpen();
    if (channels <= 0 || sampleRate <= 0) {
      throw StateError('Audio clip has invalid metadata.');
    }

    final output = BytesBuilder(copy: false);
    output.add(_wavHeader());
    output.add(_pcmBytes());
    await file.writeAsBytes(output.takeBytes(), flush: true);
  }

  Future<Uint8List> toFlacBytes() async {
    _checkOpen();
    final encoded = bindings.sttapp_audio_clip_to_flac(_handle);
    if (encoded == ffi.nullptr) {
      throw StateError(_lastNativeError());
    }

    try {
      final length = bindings.sttapp_audio_encoded_audio_len(encoded);
      final data = bindings.sttapp_audio_encoded_audio_data(encoded);
      if (data == ffi.nullptr && length > 0) {
        throw StateError('Native FLAC encoder returned a null byte buffer.');
      }
      return Uint8List.fromList(data.asTypedList(length));
    } finally {
      bindings.sttapp_audio_encoded_audio_free(encoded);
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    bindings.sttapp_audio_clip_free(_handle);
    _handle = ffi.nullptr;
    _disposed = true;
  }

  Uint8List _wavHeader() {
    final dataSize = sampleCount * 2;
    final header = ByteData(44);
    _writeAscii(header, 0, 'RIFF');
    header.setUint32(4, 36 + dataSize, Endian.little);
    _writeAscii(header, 8, 'WAVE');
    _writeAscii(header, 12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * channels * 2, Endian.little);
    header.setUint16(32, channels * 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    _writeAscii(header, 36, 'data');
    header.setUint32(40, dataSize, Endian.little);
    return header.buffer.asUint8List();
  }

  Uint8List _pcmBytes() {
    final source = samples;
    final output = Uint8List(source.length * 2);
    final data = ByteData.sublistView(output);
    for (var i = 0; i < source.length; i += 1) {
      data.setInt16(i * 2, source[i], Endian.little);
    }
    return output;
  }

  void _checkOpen() {
    if (_disposed || _handle == ffi.nullptr) {
      throw StateError('AudioClip has been disposed.');
    }
  }
}

void _writeAscii(ByteData data, int offset, String value) {
  for (var i = 0; i < value.length; i += 1) {
    data.setUint8(offset + i, value.codeUnitAt(i));
  }
}

String _lastNativeError() {
  final message = bindings.sttapp_audio_last_error_message();
  if (message == ffi.nullptr) {
    return 'unknown sttapp_audio error';
  }

  try {
    return _readNullTerminatedString(message);
  } finally {
    bindings.sttapp_audio_string_free(message);
  }
}

String _readNullTerminatedString(ffi.Pointer<ffi.Char> pointer) {
  final bytes = pointer.cast<ffi.Uint8>();
  var length = 0;
  while ((bytes + length).value != 0) {
    length += 1;
  }
  return String.fromCharCodes(bytes.asTypedList(length));
}
