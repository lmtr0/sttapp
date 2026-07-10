import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

import 'sttapp_secret_storage_bindings_generated.dart' as bindings;

const _statusSuccess = 0;
const _statusNotFound = 1;
const _statusError = -1;

final class SttappSecretStorage {
  const SttappSecretStorage();

  static int get nativeApiVersion =>
      bindings.sttapp_secret_storage_api_version();

  Future<void> prepare() async {
    final ok = bindings.sttapp_secret_storage_prepare();
    if (!ok) {
      throw SttappSecretStorageException(_lastNativeError());
    }
  }

  Future<String?> read({required String key}) async {
    final nativeKey = key.toNativeUtf8();
    final outValue = calloc<ffi.Pointer<ffi.Char>>();
    try {
      final status = bindings.sttapp_secret_storage_read(
        nativeKey.cast<ffi.Char>(),
        outValue,
      );
      return switch (status) {
        _statusSuccess => _takeNativeString(outValue.value),
        _statusNotFound => null,
        _statusError => throw SttappSecretStorageException(_lastNativeError()),
        _ => throw SttappSecretStorageException(
          'unknown sttapp_secret_storage read status: $status',
        ),
      };
    } finally {
      calloc.free(outValue);
      calloc.free(nativeKey);
    }
  }

  Future<void> write({required String key, required String value}) async {
    final nativeKey = key.toNativeUtf8();
    final nativeValue = value.toNativeUtf8();
    try {
      final ok = bindings.sttapp_secret_storage_write(
        nativeKey.cast<ffi.Char>(),
        nativeValue.cast<ffi.Char>(),
      );
      if (!ok) {
        throw SttappSecretStorageException(_lastNativeError());
      }
    } finally {
      calloc.free(nativeValue);
      calloc.free(nativeKey);
    }
  }

  Future<void> delete({required String key}) async {
    final nativeKey = key.toNativeUtf8();
    try {
      final status = bindings.sttapp_secret_storage_delete(
        nativeKey.cast<ffi.Char>(),
      );
      switch (status) {
        case _statusSuccess:
        case _statusNotFound:
          return;
        case _statusError:
          throw SttappSecretStorageException(_lastNativeError());
        default:
          throw SttappSecretStorageException(
            'unknown sttapp_secret_storage delete status: $status',
          );
      }
    } finally {
      calloc.free(nativeKey);
    }
  }
}

final class SttappSecretStorageException implements Exception {
  const SttappSecretStorageException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _takeNativeString(ffi.Pointer<ffi.Char> pointer) {
  if (pointer == ffi.nullptr) {
    throw const SttappSecretStorageException(
      'sttapp_secret_storage returned a null value pointer',
    );
  }

  try {
    return _readNullTerminatedString(pointer);
  } finally {
    bindings.sttapp_secret_storage_string_free(pointer);
  }
}

String _lastNativeError() {
  final message = bindings.sttapp_secret_storage_last_error_message();
  if (message == ffi.nullptr) {
    return 'unknown sttapp_secret_storage error';
  }

  return _takeNativeString(message);
}

String _readNullTerminatedString(ffi.Pointer<ffi.Char> pointer) {
  final bytes = pointer.cast<ffi.Uint8>();
  var length = 0;
  while ((bytes + length).value != 0) {
    length += 1;
  }
  return String.fromCharCodes(bytes.asTypedList(length));
}
