import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sttapp_input/sttapp_input.dart';

const defaultPasteTriggerDelay = Duration(milliseconds: 120);

abstract interface class DesktopInputClient {
  Future<void> preparePaste();

  Future<void> setClipboardText(String text);

  Future<void> paste(PasteMode mode);
}

final class NativeDesktopInputClient implements DesktopInputClient {
  const NativeDesktopInputClient();

  @override
  Future<void> preparePaste() {
    return DesktopInput.prepare();
  }

  @override
  Future<void> setClipboardText(String text) {
    return DesktopInput.setClipboardText(text);
  }

  @override
  Future<void> paste(PasteMode mode) {
    return DesktopInput.paste(mode);
  }
}

abstract interface class ClipboardClient {
  Future<void> setText(String text);
}

final class FlutterClipboardClient implements ClipboardClient {
  const FlutterClipboardClient();

  @override
  Future<void> setText(String text) {
    return Clipboard.setData(ClipboardData(text: text));
  }
}

final class TranscriptDeliveryService {
  const TranscriptDeliveryService({
    this.input = const NativeDesktopInputClient(),
    this.clipboard = const FlutterClipboardClient(),
    this.pasteTriggerDelay = defaultPasteTriggerDelay,
  });

  final DesktopInputClient input;
  final ClipboardClient clipboard;
  final Duration pasteTriggerDelay;

  Future<void> deliver(String transcript, PasteMode pasteMode) async {
    await preparePaste();
    await copyToClipboard(transcript);

    if (pasteTriggerDelay > Duration.zero) {
      await Future<void>.delayed(pasteTriggerDelay);
    }

    await paste(pasteMode);
  }

  Future<void> preparePaste() {
    return input.preparePaste();
  }

  Future<void> copyToClipboard(String transcript) async {
    Object? nativeClipboardError;
    try {
      await input.setClipboardText(transcript);
      return;
    } catch (error) {
      nativeClipboardError = error;
      if (kDebugMode) {
        debugPrint(
          'Native clipboard set failed; trying Flutter clipboard: $error',
        );
      }
    }

    try {
      await clipboard.setText(transcript);
      return;
    } catch (error) {
      throw StateError(
        'Failed to set transcript clipboard: native clipboard failed '
        '($nativeClipboardError), Flutter clipboard failed ($error).',
      );
    }
  }

  Future<void> paste(PasteMode pasteMode) async {
    final stopwatch = Stopwatch()..start();
    if (kDebugMode) {
      debugPrint('Desktop input paste started.');
    }

    try {
      await input.paste(pasteMode);
      stopwatch.stop();
      if (kDebugMode) {
        debugPrint(
          'Desktop input paste succeeded in ${stopwatch.elapsedMilliseconds}ms.',
        );
      }
    } catch (error) {
      stopwatch.stop();
      if (kDebugMode) {
        debugPrint(
          'Desktop input paste failed in '
          '${stopwatch.elapsedMilliseconds}ms: $error',
        );
      }
      rethrow;
    }
  }
}
