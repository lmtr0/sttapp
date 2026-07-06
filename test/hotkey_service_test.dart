import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/hotkey_service.dart';
import 'package:sttapp_input/sttapp_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('portal backend maps shortcut events to paste modes', () async {
    final events = StreamController<dynamic>();
    final calls = <String>[];
    final modes = <PasteMode>[];

    final backend = PortalHotkeyBackend(
      eventStream: events.stream,
      invokeMethod: (method, arguments) async {
        calls.add(method);
      },
    );

    await backend.initialize(
      shortcutConfig: ShortcutConfig(),
      onToggle: modes.add,
    );
    events
      ..add(<String, Object>{'id': 'toggle-normal'})
      ..add(<String, Object>{'id': 'toggle-plain'})
      ..add(<String, Object>{'id': 'unknown'});
    await events.close();

    await pumpEventQueue();

    expect(calls, <String>['dispose', 'initialize']);
    expect(modes, <PasteMode>[PasteMode.normal, PasteMode.plain]);
  });

  test('portal backend forwards stream errors', () async {
    final events = StreamController<dynamic>();
    final errors = <Object>[];
    final backend = PortalHotkeyBackend(
      eventStream: events.stream,
      invokeMethod: (_, _) async {},
    );

    await backend.initialize(
      shortcutConfig: ShortcutConfig(),
      onToggle: (_) {},
      onError: errors.add,
    );
    events.addError(PlatformException(code: 'closed'));
    await events.close();

    await pumpEventQueue();

    expect(errors, hasLength(1));
    expect(errors.single, isA<PlatformException>());
  });

  test(
    'portal backend dispose cancels events and calls native dispose',
    () async {
      final events = StreamController<dynamic>();
      final calls = <String>[];
      final modes = <PasteMode>[];
      final backend = PortalHotkeyBackend(
        eventStream: events.stream,
        invokeMethod: (method, arguments) async {
          calls.add(method);
        },
      );

      await backend.initialize(
        shortcutConfig: ShortcutConfig(),
        onToggle: modes.add,
      );
      await backend.dispose();

      events.add(<String, Object>{'id': 'toggle-normal'});
      await events.close();
      await pumpEventQueue();

      expect(calls, <String>['dispose', 'initialize', 'dispose']);
      expect(modes, isEmpty);
    },
  );

  test('hotkey manager backend registers configured key pair', () async {
    final registrar = _FakeHotkeyRegistrar();
    final backend = HotkeyManagerBackend(registrar: registrar);
    final modes = <PasteMode>[];

    await backend.initialize(
      shortcutConfig: ShortcutConfig(keyId: 'f6'),
      onToggle: modes.add,
    );

    expect(registrar.registered, hasLength(2));
    expect(registrar.registered[0].logicalKey, LogicalKeyboardKey.f6);
    expect(registrar.registered[0].modifiers, isNull);
    expect(registrar.registered[1].logicalKey, LogicalKeyboardKey.f6);
    expect(registrar.registered[1].modifiers, [HotKeyModifier.shift]);

    registrar.handlers[0](registrar.registered[0]);
    registrar.handlers[1](registrar.registered[1]);
    expect(modes, [PasteMode.normal, PasteMode.plain]);
  });

  test(
    'hotkey manager backend unregisters old keys before reinitialize',
    () async {
      final registrar = _FakeHotkeyRegistrar();
      final backend = HotkeyManagerBackend(registrar: registrar);

      await backend.initialize(
        shortcutConfig: ShortcutConfig(keyId: 'f5'),
        onToggle: (_) {},
      );
      final oldKeys = List<HotKey>.of(registrar.registered);
      await backend.initialize(
        shortcutConfig: ShortcutConfig(keyId: 'f7'),
        onToggle: (_) {},
      );

      expect(registrar.unregistered, oldKeys);
      expect(registrar.registered.last.logicalKey, LogicalKeyboardKey.f7);
    },
  );
}

final class _FakeHotkeyRegistrar implements HotkeyRegistrar {
  final registered = <HotKey>[];
  final unregistered = <HotKey>[];
  final handlers = <HotKeyHandler>[];

  @override
  Future<void> register(HotKey hotKey, {HotKeyHandler? keyDownHandler}) async {
    registered.add(hotKey);
    if (keyDownHandler != null) {
      handlers.add(keyDownHandler);
    }
  }

  @override
  Future<void> unregister(HotKey hotKey) async {
    unregistered.add(hotKey);
    registered.removeWhere((registered) => registered == hotKey);
  }
}
