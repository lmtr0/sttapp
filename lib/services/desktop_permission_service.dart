import 'dart:io';

import 'package:flutter/services.dart';

enum DesktopPermission { microphone, accessibility }

enum DesktopPermissionState {
  notDetermined,
  denied,
  restricted,
  authorized,
  unavailable,
}

final class DesktopPermissionSnapshot {
  const DesktopPermissionSnapshot({
    required this.microphone,
    required this.accessibility,
  });

  const DesktopPermissionSnapshot.authorized()
    : microphone = DesktopPermissionState.authorized,
      accessibility = DesktopPermissionState.authorized;

  const DesktopPermissionSnapshot.unavailable()
    : microphone = DesktopPermissionState.unavailable,
      accessibility = DesktopPermissionState.unavailable;

  final DesktopPermissionState microphone;
  final DesktopPermissionState accessibility;

  bool get isAuthorized =>
      microphone == DesktopPermissionState.authorized &&
      accessibility == DesktopPermissionState.authorized;
}

abstract interface class DesktopPermissionService {
  bool get requiresAuthorization;

  Future<DesktopPermissionSnapshot> getStatus();

  Future<DesktopPermissionSnapshot> requestMicrophone();

  Future<DesktopPermissionSnapshot> requestAccessibility();

  Future<void> openSettings(DesktopPermission permission);
}

typedef PermissionMethodInvoker =
    Future<Object?> Function(String method, Object? arguments);

final class MacOSDesktopPermissionService implements DesktopPermissionService {
  MacOSDesktopPermissionService({
    MethodChannel methodChannel = _channel,
    PermissionMethodInvoker? invokeMethod,
  }) : _invokeMethod =
           invokeMethod ??
           ((method, arguments) =>
               methodChannel.invokeMethod<Object?>(method, arguments));

  static const _channel = MethodChannel('com.taresz.sttapp/permissions');

  final PermissionMethodInvoker _invokeMethod;

  @override
  bool get requiresAuthorization => true;

  @override
  Future<DesktopPermissionSnapshot> getStatus() async {
    return _parseSnapshot(await _invokeMethod('getStatus', null));
  }

  @override
  Future<DesktopPermissionSnapshot> requestMicrophone() async {
    return _parseSnapshot(await _invokeMethod('requestMicrophone', null));
  }

  @override
  Future<DesktopPermissionSnapshot> requestAccessibility() async {
    return _parseSnapshot(await _invokeMethod('requestAccessibility', null));
  }

  @override
  Future<void> openSettings(DesktopPermission permission) async {
    await _invokeMethod('openPermissionSettings', <String, String>{
      'permission': permission.name,
    });
  }
}

final class PermissiveDesktopPermissionService
    implements DesktopPermissionService {
  const PermissiveDesktopPermissionService();

  @override
  bool get requiresAuthorization => false;

  @override
  Future<DesktopPermissionSnapshot> getStatus() async {
    return const DesktopPermissionSnapshot.authorized();
  }

  @override
  Future<DesktopPermissionSnapshot> requestMicrophone() => getStatus();

  @override
  Future<DesktopPermissionSnapshot> requestAccessibility() => getStatus();

  @override
  Future<void> openSettings(DesktopPermission permission) async {}
}

DesktopPermissionService defaultDesktopPermissionService() {
  if (Platform.isMacOS) {
    return MacOSDesktopPermissionService();
  }
  return const PermissiveDesktopPermissionService();
}

DesktopPermissionSnapshot _parseSnapshot(Object? value) {
  if (value is! Map) {
    return const DesktopPermissionSnapshot.unavailable();
  }

  final microphone = _parseState(value['microphone']);
  final accessibility = switch (value['accessibility']) {
    true => DesktopPermissionState.authorized,
    false => DesktopPermissionState.denied,
    _ => DesktopPermissionState.unavailable,
  };
  return DesktopPermissionSnapshot(
    microphone: microphone,
    accessibility: accessibility,
  );
}

DesktopPermissionState _parseState(Object? value) {
  return switch (value) {
    'notDetermined' => DesktopPermissionState.notDetermined,
    'denied' => DesktopPermissionState.denied,
    'restricted' => DesktopPermissionState.restricted,
    'authorized' => DesktopPermissionState.authorized,
    _ => DesktopPermissionState.unavailable,
  };
}
