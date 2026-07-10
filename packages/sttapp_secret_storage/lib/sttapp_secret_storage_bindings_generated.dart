// Native bindings for the Rust library bundled by hook/build.dart.
// ignore_for_file: type=lint
import 'dart:ffi' as ffi;

const _assetId =
    'package:sttapp_secret_storage/sttapp_secret_storage_bindings_generated.dart';

@ffi.Native<ffi.Int32 Function()>(assetId: _assetId)
external int sttapp_secret_storage_api_version();

@ffi.Native<ffi.Bool Function()>(assetId: _assetId)
external bool sttapp_secret_storage_prepare();

@ffi.Native<
  ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Pointer<ffi.Char>>)
>(assetId: _assetId)
external int sttapp_secret_storage_read(
  ffi.Pointer<ffi.Char> key,
  ffi.Pointer<ffi.Pointer<ffi.Char>> outValue,
);

@ffi.Native<ffi.Bool Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)>(
  assetId: _assetId,
)
external bool sttapp_secret_storage_write(
  ffi.Pointer<ffi.Char> key,
  ffi.Pointer<ffi.Char> value,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<ffi.Char>)>(assetId: _assetId)
external int sttapp_secret_storage_delete(ffi.Pointer<ffi.Char> key);

@ffi.Native<ffi.Pointer<ffi.Char> Function()>(assetId: _assetId)
external ffi.Pointer<ffi.Char> sttapp_secret_storage_last_error_message();

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Char>)>(assetId: _assetId)
external void sttapp_secret_storage_string_free(ffi.Pointer<ffi.Char> message);
