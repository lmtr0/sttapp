import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/hotkey_service.dart';
import 'package:sttapp_input/sttapp_input.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native backend confirms both shortcuts and maps events', () async {
    final events = StreamController<dynamic>();
    final calls = <String>[];
    final modes = <PasteMode>[];
    Object? initializeArguments;
    final backend = NativeHotkeyBackend(
      eventStream: events.stream,
      invokeMethod: (method, arguments) async {
        calls.add(method);
        if (method == 'initialize') {
          initializeArguments = arguments;
          return _completeRegistration;
        }
        return null;
      },
    );

    final registration = await backend.initialize(
      shortcutConfig: ShortcutConfig(keyId: 'f6'),
      onToggle: modes.add,
    );
    events
      ..add(<String, Object>{'id': 'toggle-normal'})
      ..add(<String, Object>{'id': 'toggle-plain'})
      ..add(<String, Object>{'id': 'unknown'});
    await events.close();
    await pumpEventQueue();

    expect(calls, <String>['dispose', 'initialize']);
    expect(registration.shortcutIds, <String>{'toggle-normal', 'toggle-plain'});
    expect(modes, <PasteMode>[PasteMode.normal, PasteMode.plain]);

    final arguments = initializeArguments! as Map<String, Object>;
    final shortcuts = arguments['shortcuts']! as List<Map<String, Object>>;
    expect(shortcuts[0]['keyId'], 'f6');
    expect(shortcuts[0]['preferredTrigger'], 'F6');
    expect(shortcuts[0]['modifiers'], isEmpty);
    expect(shortcuts[1]['preferredTrigger'], 'SHIFT+F6');
    expect(shortcuts[1]['modifiers'], <String>['shift']);
  });

  test('native backend forwards event stream errors', () async {
    final events = StreamController<dynamic>();
    final errors = <Object>[];
    final backend = NativeHotkeyBackend(
      eventStream: events.stream,
      invokeMethod: (method, _) async {
        return method == 'initialize' ? _completeRegistration : null;
      },
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
    'native backend dispose cancels events and calls native dispose',
    () async {
      final events = StreamController<dynamic>();
      final calls = <String>[];
      final modes = <PasteMode>[];
      final backend = NativeHotkeyBackend(
        eventStream: events.stream,
        invokeMethod: (method, _) async {
          calls.add(method);
          return method == 'initialize' ? _completeRegistration : null;
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

  test(
    'native backend rejects incomplete registration and cleans up',
    () async {
      final calls = <String>[];
      final backend = NativeHotkeyBackend(
        eventStream: const Stream<dynamic>.empty(),
        invokeMethod: (method, _) async {
          calls.add(method);
          if (method == 'initialize') {
            return <String, Object>{
              'registeredShortcutIds': <String>['toggle-normal'],
            };
          }
          return null;
        },
      );

      await expectLater(
        backend.initialize(shortcutConfig: ShortcutConfig(), onToggle: (_) {}),
        throwsA(
          isA<HotkeyRegistrationException>()
              .having((error) => error.code, 'code', 'incomplete_registration')
              .having(
                (error) => error.shortcutId,
                'shortcutId',
                'toggle-plain',
              ),
        ),
      );
      expect(calls, <String>['dispose', 'initialize', 'dispose']);
    },
  );

  test('native registration error retains the failed shortcut id', () async {
    final calls = <String>[];
    final backend = NativeHotkeyBackend(
      eventStream: const Stream<dynamic>.empty(),
      invokeMethod: (method, _) async {
        calls.add(method);
        if (method == 'initialize') {
          throw PlatformException(
            code: 'registration_failed',
            message: 'Shortcut is already in use.',
            details: <String, Object>{
              'shortcutId': 'toggle-plain',
              'nativeErrorCode': 1409,
            },
          );
        }
        return null;
      },
    );

    await expectLater(
      backend.initialize(shortcutConfig: ShortcutConfig(), onToggle: (_) {}),
      throwsA(
        isA<HotkeyRegistrationException>()
            .having((error) => error.code, 'code', 'registration_failed')
            .having((error) => error.shortcutId, 'shortcutId', 'toggle-plain'),
      ),
    );
    expect(calls, <String>['dispose', 'initialize', 'dispose']);
  });

  test(
    'native registration times out and disposes the native session',
    () async {
      final calls = <String>[];
      final pending = Completer<dynamic>();
      final backend = NativeHotkeyBackend(
        eventStream: const Stream<dynamic>.empty(),
        registrationTimeout: const Duration(milliseconds: 1),
        invokeMethod: (method, _) async {
          calls.add(method);
          if (method == 'initialize') {
            return pending.future;
          }
          return null;
        },
      );

      await expectLater(
        backend.initialize(shortcutConfig: ShortcutConfig(), onToggle: (_) {}),
        throwsA(
          isA<HotkeyRegistrationException>().having(
            (error) => error.code,
            'code',
            'timeout',
          ),
        ),
      );
      expect(calls, <String>['dispose', 'initialize', 'dispose']);
    },
  );
}

const _completeRegistration = <String, Object>{
  'registeredShortcutIds': <String>['toggle-normal', 'toggle-plain'],
};
