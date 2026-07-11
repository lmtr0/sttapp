import 'package:flutter_test/flutter_test.dart';
import 'package:sttapp/services/desktop_permission_service.dart';

void main() {
  test('parses authorized native permission status', () async {
    final service = MacOSDesktopPermissionService(
      invokeMethod: (_, _) async => <String, Object>{
        'microphone': 'authorized',
        'accessibility': true,
      },
    );

    final status = await service.getStatus();

    expect(status.isAuthorized, isTrue);
  });

  test('maps unknown and malformed native status to unavailable', () async {
    final values = <Object?>[
      null,
      const <Object>[],
      <String, Object>{'microphone': 'future-value'},
    ];

    for (final value in values) {
      final service = MacOSDesktopPermissionService(
        invokeMethod: (_, _) async => value,
      );
      final status = await service.getStatus();
      expect(status.microphone, DesktopPermissionState.unavailable);
      expect(status.accessibility, DesktopPermissionState.unavailable);
    }
  });

  test('opens settings for the selected permission', () async {
    String? method;
    Object? arguments;
    final service = MacOSDesktopPermissionService(
      invokeMethod: (calledMethod, calledArguments) async {
        method = calledMethod;
        arguments = calledArguments;
        return null;
      },
    );

    await service.openSettings(DesktopPermission.accessibility);

    expect(method, 'openPermissionSettings');
    expect(arguments, <String, String>{'permission': 'accessibility'});
  });

  test('non-macOS permission service is always authorized', () async {
    const service = PermissiveDesktopPermissionService();

    expect(service.requiresAuthorization, isFalse);
    expect((await service.getStatus()).isAuthorized, isTrue);
  });
}
