import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'sttapp_input_bindings_generated.dart' as bindings;

enum PasteMode {
  normal,
  plain;

  int get nativeValue => switch (this) {
    PasteMode.normal => 0,
    PasteMode.plain => 1,
  };
}

final class DesktopInput {
  const DesktopInput._();

  static int get nativeApiVersion => bindings.sttapp_input_api_version();

  static Future<void> paste(PasteMode mode) async {
    final ok = bindings.sttapp_input_paste(mode.nativeValue);
    if (!ok) {
      throw StateError(_lastNativeError());
    }
  }

  static Future<void> setClipboardText(String text) async {
    final nativeText = text.toNativeUtf8();
    try {
      final ok = bindings.sttapp_input_set_clipboard_text(
        nativeText.cast<ffi.Char>(),
      );
      if (!ok) {
        throw StateError(_lastNativeError());
      }
    } finally {
      calloc.free(nativeText);
    }
  }
}

String _lastNativeError() {
  final message = bindings.sttapp_input_last_error_message();
  if (message == ffi.nullptr) {
    return 'unknown sttapp_input error';
  }

  try {
    return _readNullTerminatedString(message);
  } finally {
    bindings.sttapp_input_string_free(message);
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
