import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

typedef AsyncAppEntry = Future<void> Function();

final class StartupErrorTracker {
  const StartupErrorTracker._();

  static File? _logFile;

  static Future<void> runGuarded(AsyncAppEntry appEntry) {
    _installFlutterErrorHandler();
    _installPlatformErrorHandler();
    _write('Dart startup begin');

    final result = runZonedGuarded<Future<void>?>(appEntry, (
      error,
      stackTrace,
    ) {
      recordError('Uncaught zone error', error, stackTrace);
    });
    return result ?? Future<void>.value();
  }

  static void recordError(
    String label,
    Object error, [
    StackTrace? stackTrace,
  ]) {
    final buffer = StringBuffer()
      ..writeln(label)
      ..writeln(error);
    if (stackTrace != null) {
      buffer.writeln(stackTrace);
    }
    _write(buffer.toString().trimRight());
  }

  static void _installFlutterErrorHandler() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      recordError('Flutter framework error', details.exception, details.stack);
      previous?.call(details);
    };
  }

  static void _installPlatformErrorHandler() {
    final previous = ui.PlatformDispatcher.instance.onError;
    ui.PlatformDispatcher.instance.onError = (error, stackTrace) {
      recordError('Uncaught platform error', error, stackTrace);
      return previous?.call(error, stackTrace) ?? true;
    };
  }

  static void _write(String message) {
    try {
      final file = _logFile ??= _createLogFile();
      final timestamp = DateTime.now().toIso8601String();
      file.writeAsStringSync(
        '[$timestamp] $message${Platform.lineTerminator}',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Last-chance logging must never become the startup failure.
    }

    if (kDebugMode) {
      debugPrint(message);
    }
  }

  static File _createLogFile() {
    final directory = Directory(_logDirectoryPath());
    directory.createSync(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}startup.log');
  }

  static String _logDirectoryPath() {
    if (Platform.isWindows) {
      final basePath =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          Directory.systemTemp.path;
      return '$basePath${Platform.pathSeparator}sttapp';
    }
    return '${Directory.systemTemp.path}${Platform.pathSeparator}sttapp';
  }
}
