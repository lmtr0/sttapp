// Native bindings for the Rust library bundled by hook/build.dart.
// ignore_for_file: type=lint
import 'dart:ffi' as ffi;

const _assetId = 'package:sttapp_input/sttapp_input_bindings_generated.dart';

@ffi.Native<ffi.Int32 Function()>(assetId: _assetId)
external int sttapp_input_api_version();

@ffi.Native<ffi.Bool Function(ffi.Int32)>(assetId: _assetId)
external bool sttapp_input_paste(int mode);

@ffi.Native<ffi.Bool Function(ffi.Pointer<ffi.Char>)>(assetId: _assetId)
external bool sttapp_input_set_clipboard_text(ffi.Pointer<ffi.Char> text);

@ffi.Native<ffi.Pointer<ffi.Char> Function()>(assetId: _assetId)
external ffi.Pointer<ffi.Char> sttapp_input_last_error_message();

@ffi.Native<ffi.Void Function(ffi.Pointer<ffi.Char>)>(assetId: _assetId)
external void sttapp_input_string_free(ffi.Pointer<ffi.Char> message);
