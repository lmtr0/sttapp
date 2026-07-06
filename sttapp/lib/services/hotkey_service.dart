import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp_input/sttapp_input.dart';

typedef PasteModeCallback = void Function(PasteMode mode);
typedef HotkeyErrorCallback = void Function(Object error);

abstract interface class HotkeyBackend {
  Future<void> initialize({
    required ShortcutConfig shortcutConfig,
    required PasteModeCallback onToggle,
    HotkeyErrorCallback? onError,
  });

  Future<void> dispose();
}

final class HotkeyService {
  HotkeyService({HotkeyBackend? backend})
    : _backend = backend ?? _defaultBackend();

  final HotkeyBackend _backend;

  Future<void> initialize({
    ShortcutConfig? shortcutConfig,
    required PasteModeCallback onToggle,
    HotkeyErrorCallback? onError,
  }) {
    return _backend.initialize(
      shortcutConfig: shortcutConfig ?? ShortcutConfig(),
      onToggle: onToggle,
      onError: onError,
    );
  }

  Future<void> dispose() => _backend.dispose();
}

HotkeyBackend _defaultBackend() {
  if (Platform.isLinux) {
    return PortalHotkeyBackend();
  }
  return HotkeyManagerBackend();
}

abstract interface class HotkeyRegistrar {
  Future<void> register(HotKey hotKey, {HotKeyHandler? keyDownHandler});

  Future<void> unregister(HotKey hotKey);
}

final class DefaultHotkeyRegistrar implements HotkeyRegistrar {
  const DefaultHotkeyRegistrar();

  @override
  Future<void> register(HotKey hotKey, {HotKeyHandler? keyDownHandler}) {
    return hotKeyManager.register(hotKey, keyDownHandler: keyDownHandler);
  }

  @override
  Future<void> unregister(HotKey hotKey) => hotKeyManager.unregister(hotKey);
}

final class HotkeyManagerBackend implements HotkeyBackend {
  HotkeyManagerBackend({this.registrar = const DefaultHotkeyRegistrar()});

  final HotkeyRegistrar registrar;
  final List<HotKey> _registeredHotKeys = [];

  @override
  Future<void> initialize({
    required ShortcutConfig shortcutConfig,
    required PasteModeCallback onToggle,
    HotkeyErrorCallback? onError,
  }) async {
    await dispose();

    final normalHotKey = HotKey(
      key: shortcutConfig.logicalKey,
      scope: HotKeyScope.system,
    );
    final plainHotKey = HotKey(
      key: shortcutConfig.logicalKey,
      modifiers: [HotKeyModifier.shift],
      scope: HotKeyScope.system,
    );

    await registrar.register(
      normalHotKey,
      keyDownHandler: (_) => onToggle(PasteMode.normal),
    );
    await registrar.register(
      plainHotKey,
      keyDownHandler: (_) => onToggle(PasteMode.plain),
    );

    _registeredHotKeys
      ..add(normalHotKey)
      ..add(plainHotKey);
  }

  @override
  Future<void> dispose() async {
    for (final hotKey in List<HotKey>.of(_registeredHotKeys)) {
      await registrar.unregister(hotKey);
    }
    _registeredHotKeys.clear();
  }
}

typedef PortalInvokeMethod =
    Future<dynamic> Function(String method, Object? arguments);

final class PortalHotkeyBackend implements HotkeyBackend {
  PortalHotkeyBackend({
    MethodChannel methodChannel = _defaultMethodChannel,
    this.eventChannel = _defaultEventChannel,
    this.eventStream,
    PortalInvokeMethod? invokeMethod,
  }) : _invokeMethod =
           invokeMethod ??
           ((method, arguments) {
             return methodChannel.invokeMethod<void>(method, arguments);
           });

  static const _defaultMethodChannel = MethodChannel(
    'com.taresz.sttapp/global_shortcuts',
  );
  static const _defaultEventChannel = EventChannel(
    'com.taresz.sttapp/global_shortcuts/events',
  );

  final EventChannel eventChannel;
  final Stream<dynamic>? eventStream;
  final PortalInvokeMethod _invokeMethod;
  StreamSubscription<dynamic>? _eventsSubscription;

  @override
  Future<void> initialize({
    required ShortcutConfig shortcutConfig,
    required PasteModeCallback onToggle,
    HotkeyErrorCallback? onError,
  }) async {
    await dispose();

    final stream = eventStream ?? eventChannel.receiveBroadcastStream();
    _eventsSubscription = stream.listen(
      (event) {
        final mode = _pasteModeFromEvent(event);
        if (mode != null) {
          onToggle(mode);
        }
      },
      onError: (Object error) {
        onError?.call(error);
      },
    );

    try {
      await _invokeMethod('initialize', <String, Object>{
        'shortcuts': const <Map<String, String>>[
          <String, String>{
            'id': 'toggle-normal',
            'description': 'Start or stop capture and paste normally',
            'preferredTrigger': 'F8',
          },
          <String, String>{
            'id': 'toggle-plain',
            'description': 'Start or stop capture and paste as plain text',
            'preferredTrigger': 'SHIFT+F8',
          },
        ],
      });
    } catch (_) {
      await _eventsSubscription?.cancel();
      _eventsSubscription = null;
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    await _invokeMethod('dispose', null);
  }
}

PasteMode? _pasteModeFromEvent(Object? event) {
  if (event is! Map) {
    return null;
  }

  final id = event['id'];
  return switch (id) {
    'toggle-normal' => PasteMode.normal,
    'toggle-plain' => PasteMode.plain,
    _ => null,
  };
}
