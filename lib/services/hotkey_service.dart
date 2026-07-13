import 'dart:async';

import 'package:flutter/services.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp_input/sttapp_input.dart';

typedef PasteModeCallback = void Function(PasteMode mode);
typedef HotkeyErrorCallback = void Function(Object error);
typedef NativeShortcutInvokeMethod =
    Future<dynamic> Function(String method, Object? arguments);

const _normalShortcutId = 'toggle-normal';
const _plainShortcutId = 'toggle-plain';
const _expectedShortcutIds = <String>{_normalShortcutId, _plainShortcutId};

final class HotkeyRegistrationResult {
  const HotkeyRegistrationResult({required this.shortcutIds});

  final Set<String> shortcutIds;
}

final class HotkeyRegistrationException implements Exception {
  const HotkeyRegistrationException({
    required this.code,
    required this.message,
    this.shortcutId,
    this.details,
  });

  final String code;
  final String message;
  final String? shortcutId;
  final Object? details;

  @override
  String toString() {
    final shortcut = shortcutId == null ? '' : ' ($shortcutId)';
    final nativeDetails = details == null ? '' : ' Details: $details';
    return 'HotkeyRegistrationException[$code]$shortcut: '
        '$message$nativeDetails';
  }
}

abstract interface class HotkeyBackend {
  Future<HotkeyRegistrationResult> initialize({
    required ShortcutConfig shortcutConfig,
    required PasteModeCallback onToggle,
    HotkeyErrorCallback? onError,
  });

  Future<void> dispose();
}

final class HotkeyService {
  HotkeyService({HotkeyBackend? backend})
    : _backend = backend ?? NativeHotkeyBackend();

  final HotkeyBackend _backend;

  Future<HotkeyRegistrationResult> initialize({
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

final class NativeHotkeyBackend implements HotkeyBackend {
  NativeHotkeyBackend({
    MethodChannel methodChannel = _defaultMethodChannel,
    this.eventChannel = _defaultEventChannel,
    this.eventStream,
    NativeShortcutInvokeMethod? invokeMethod,
    this.registrationTimeout = const Duration(seconds: 60),
  }) : _invokeMethod =
           invokeMethod ??
           ((method, arguments) {
             return methodChannel.invokeMethod<dynamic>(method, arguments);
           });

  static const _defaultMethodChannel = MethodChannel(
    'com.taresz.sttapp/global_shortcuts',
  );
  static const _defaultEventChannel = EventChannel(
    'com.taresz.sttapp/global_shortcuts/events',
  );

  final EventChannel eventChannel;
  final Stream<dynamic>? eventStream;
  final NativeShortcutInvokeMethod _invokeMethod;
  final Duration registrationTimeout;
  StreamSubscription<dynamic>? _eventsSubscription;

  @override
  Future<HotkeyRegistrationResult> initialize({
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
      final response = await _invokeMethod(
        'initialize',
        _registrationArguments(shortcutConfig),
      ).timeout(registrationTimeout);
      return _registrationResultFromResponse(response);
    } on TimeoutException catch (error) {
      await _cleanupAfterFailedInitialization();
      throw HotkeyRegistrationException(
        code: 'timeout',
        message: 'Timed out while registering global shortcuts.',
        details: error,
      );
    } on PlatformException catch (error) {
      await _cleanupAfterFailedInitialization();
      throw HotkeyRegistrationException(
        code: error.code,
        message: error.message ?? 'The operating system rejected a shortcut.',
        shortcutId: _shortcutIdFromDetails(error.details),
        details: error.details,
      );
    } on HotkeyRegistrationException {
      await _cleanupAfterFailedInitialization();
      rethrow;
    } catch (_) {
      await _cleanupAfterFailedInitialization();
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    await _invokeMethod('dispose', null);
  }

  Future<void> _cleanupAfterFailedInitialization() async {
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    try {
      await _invokeMethod('dispose', null);
    } catch (_) {
      // Preserve the registration failure, which is the actionable error.
    }
  }
}

Map<String, Object> _registrationArguments(ShortcutConfig config) {
  final keyLabel = config.keyOption.label.toUpperCase();
  return <String, Object>{
    'shortcuts': <Map<String, Object>>[
      <String, Object>{
        'id': _normalShortcutId,
        'description': 'Start or stop capture and paste normally',
        'keyId': config.keyId,
        'modifiers': const <String>[],
        'preferredTrigger': keyLabel,
      },
      <String, Object>{
        'id': _plainShortcutId,
        'description': 'Start or stop capture and paste as plain text',
        'keyId': config.keyId,
        'modifiers': const <String>['shift'],
        'preferredTrigger': 'SHIFT+$keyLabel',
      },
    ],
  };
}

HotkeyRegistrationResult _registrationResultFromResponse(Object? response) {
  if (response is! Map) {
    throw const HotkeyRegistrationException(
      code: 'invalid_response',
      message: 'The shortcut service returned an invalid response.',
    );
  }

  final rawIds = response['registeredShortcutIds'];
  if (rawIds is! List) {
    throw const HotkeyRegistrationException(
      code: 'invalid_response',
      message: 'The shortcut service did not confirm its registrations.',
    );
  }

  final ids = rawIds.whereType<String>().toSet();
  final missingIds = _expectedShortcutIds.difference(ids);
  if (missingIds.isNotEmpty) {
    throw HotkeyRegistrationException(
      code: 'incomplete_registration',
      message: 'The operating system did not register every shortcut.',
      shortcutId: missingIds.first,
      details: <String, Object>{'registeredShortcutIds': ids.toList()},
    );
  }
  return HotkeyRegistrationResult(shortcutIds: Set.unmodifiable(ids));
}

String? _shortcutIdFromDetails(Object? details) {
  if (details is Map) {
    final shortcutId = details['shortcutId'];
    if (shortcutId is String) {
      return shortcutId;
    }
  }
  return null;
}

PasteMode? _pasteModeFromEvent(Object? event) {
  if (event is! Map) {
    return null;
  }

  final id = event['id'];
  return switch (id) {
    _normalShortcutId => PasteMode.normal,
    _plainShortcutId => PasteMode.plain,
    _ => null,
  };
}
