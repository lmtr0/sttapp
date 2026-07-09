import 'package:flutter_test/flutter_test.dart';
import 'package:sttapp/services/transcript_delivery_service.dart';
import 'package:sttapp_input/sttapp_input.dart';

void main() {
  test('deliver copies transcript before pasting', () async {
    final input = _FakeDesktopInput();
    final clipboard = _FakeClipboard();
    final service = _service(input: input, clipboard: clipboard);

    await service.deliver('hello', PasteMode.normal);

    expect(input.calls, [
      'prepare paste',
      'native clipboard: hello',
      'paste: normal',
    ]);
    expect(clipboard.text, 'hello');
  });

  test('deliver warms input before clipboard copy', () async {
    final input = _FakeDesktopInput();
    final service = _service(input: input, clipboard: _FakeClipboard());

    await service.deliver('warm', PasteMode.normal);

    expect(input.calls.first, 'prepare paste');
    expect(input.calls[1], 'native clipboard: warm');
  });

  test('deliver stops when input warm-up fails', () async {
    final input = _FakeDesktopInput(failPrepare: true);
    final clipboard = _FakeClipboard();
    final service = _service(input: input, clipboard: clipboard);

    await expectLater(
      service.deliver('blocked', PasteMode.normal),
      throwsA(isA<StateError>()),
    );

    expect(input.calls, ['prepare paste']);
    expect(clipboard.text, isNull);
  });

  test('copyToClipboard trusts native success without readback', () async {
    final input = _FakeDesktopInput(updateSystemClipboard: false);
    final clipboard = _FakeClipboard();
    final service = _service(input: input, clipboard: clipboard);

    await service.copyToClipboard('native-only');

    expect(input.calls, ['native clipboard: native-only']);
    expect(clipboard.text, isNull);
  });

  test(
    'copyToClipboard falls back to Flutter clipboard when native fails',
    () async {
      final input = _FakeDesktopInput(failNativeClipboard: true);
      final clipboard = _FakeClipboard();
      final service = _service(input: input, clipboard: clipboard);

      await service.copyToClipboard('fallback');

      expect(input.calls, ['native clipboard: fallback']);
      expect(clipboard.text, 'fallback');
    },
  );

  test('paste failure is reported', () async {
    final input = _FakeDesktopInput(failPaste: true);
    final service = _service(input: input, clipboard: _FakeClipboard());

    await expectLater(
      service.paste(PasteMode.plain),
      throwsA(isA<StateError>()),
    );
  });
}

TranscriptDeliveryService _service({
  required _FakeDesktopInput input,
  required _FakeClipboard clipboard,
}) {
  input.clipboard = clipboard;
  return TranscriptDeliveryService(
    input: input,
    clipboard: clipboard,
    pasteTriggerDelay: Duration.zero,
  );
}

final class _FakeDesktopInput implements DesktopInputClient {
  _FakeDesktopInput({
    this.failPrepare = false,
    this.failNativeClipboard = false,
    this.updateSystemClipboard = true,
    this.failPaste = false,
  });

  final bool failPrepare;
  final bool failNativeClipboard;
  final bool updateSystemClipboard;
  final bool failPaste;
  final List<String> calls = [];
  _FakeClipboard? clipboard;

  @override
  Future<void> preparePaste() async {
    calls.add('prepare paste');
    if (failPrepare) {
      throw StateError('prepare failed');
    }
  }

  @override
  Future<void> setClipboardText(String text) async {
    calls.add('native clipboard: $text');
    if (failNativeClipboard) {
      throw StateError('native failed');
    }
    if (updateSystemClipboard) {
      clipboard?.text = text;
    }
  }

  @override
  Future<void> paste(PasteMode mode) async {
    calls.add('paste: ${mode.name}');
    if (failPaste) {
      throw StateError('paste failed');
    }
  }
}

final class _FakeClipboard implements ClipboardClient {
  String? text;

  @override
  Future<void> setText(String text) async {
    this.text = text;
  }
}
