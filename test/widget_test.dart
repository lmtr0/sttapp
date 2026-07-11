import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sttapp/main.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/desktop_permission_service.dart';
import 'package:sttapp/services/transcription_service.dart';

void main() {
  test('app widget is available', () {
    expect(const SttApp(), isA<Widget>());
  });

  testWidgets('shortcut settings are visible when supported', (tester) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore(),
          environment: const {},
        ),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        supportsShortcutSettings: true,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Shortcut key'), findsOneWidget);
    expect(find.textContaining('Plain: Shift+F8'), findsOneWidget);
  });

  testWidgets('shortcut settings are hidden when unsupported', (tester) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore(),
          environment: const {},
        ),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        supportsShortcutSettings: false,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Shortcut key'), findsNothing);
  });

  testWidgets('manual model option is shown for stored unlisted model', (
    tester,
  ) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore({
            'openai_api_key': 'key',
            'openai_base_url': defaultOpenAiBaseUrl,
            'openai_model': 'custom-transcribe',
          }),
          environment: const {},
        ),
        transcriptionService: TranscriptionService(
          client: _ModelsClient(['gpt-4o-transcribe']),
        ),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        supportsShortcutSettings: true,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Manual model'), findsWidgets);
    expect(find.text('custom-transcribe'), findsOneWidget);
  });

  testWidgets('model options are loaded from models endpoint', (tester) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore({
            'openai_api_key': 'key',
            'openai_base_url': defaultOpenAiBaseUrl,
            'openai_model': 'gpt-4o-transcribe',
          }),
          environment: const {},
        ),
        transcriptionService: TranscriptionService(
          client: _ModelsClient([
            'gpt-4o-transcribe',
            'gpt-4o-mini-transcribe',
          ]),
        ),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        supportsShortcutSettings: true,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('gpt-4o-transcribe'));
    await tester.pumpAndSettle();

    expect(find.text('gpt-4o-mini-transcribe'), findsOneWidget);
    expect(find.text('Manual model'), findsOneWidget);
  });

  testWidgets('macOS setup stays open while permissions are missing', (
    tester,
  ) async {
    final permissions = _FakeDesktopPermissionService(
      const DesktopPermissionSnapshot(
        microphone: DesktopPermissionState.notDetermined,
        accessibility: DesktopPermissionState.denied,
      ),
    );
    await tester.pumpWidget(
      SttApp(
        configRepository: _validConfigRepository(),
        desktopPermissionService: permissions,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('macOS permissions'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Accessibility'), findsOneWidget);
    final closeButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.close),
        matching: find.byType(IconButton),
      ),
    );
    expect(closeButton.onPressed, isNull);
  });

  testWidgets('grant actions refresh permission setup state', (tester) async {
    final permissions = _FakeDesktopPermissionService(
      const DesktopPermissionSnapshot(
        microphone: DesktopPermissionState.notDetermined,
        accessibility: DesktopPermissionState.denied,
      ),
    );
    await tester.pumpWidget(
      SttApp(
        configRepository: _validConfigRepository(),
        desktopPermissionService: permissions,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Grant').first);
    await tester.pumpAndSettle();
    expect(permissions.requested, [DesktopPermission.microphone]);

    await tester.tap(find.widgetWithText(FilledButton, 'Grant').first);
    await tester.pumpAndSettle();
    expect(permissions.requested, [
      DesktopPermission.microphone,
      DesktopPermission.accessibility,
    ]);
    final closeButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.close),
        matching: find.byType(IconButton),
      ),
    );
    expect(closeButton.onPressed, isNotNull);
  });
}

ConfigRepository _validConfigRepository() {
  return ConfigRepository(
    store: MemoryConfigStore({
      'openai_api_key': 'key',
      'openai_base_url': defaultOpenAiBaseUrl,
      'openai_model': 'gpt-4o-transcribe',
    }),
    environment: const {},
  );
}

final class _FakeDesktopPermissionService implements DesktopPermissionService {
  _FakeDesktopPermissionService(this.status);

  DesktopPermissionSnapshot status;
  final List<DesktopPermission> requested = [];
  final List<DesktopPermission> openedSettings = [];

  @override
  bool get requiresAuthorization => true;

  @override
  Future<DesktopPermissionSnapshot> getStatus() async => status;

  @override
  Future<void> openSettings(DesktopPermission permission) async {
    openedSettings.add(permission);
  }

  @override
  Future<DesktopPermissionSnapshot> requestAccessibility() async {
    requested.add(DesktopPermission.accessibility);
    status = DesktopPermissionSnapshot(
      microphone: status.microphone,
      accessibility: DesktopPermissionState.authorized,
    );
    return status;
  }

  @override
  Future<DesktopPermissionSnapshot> requestMicrophone() async {
    requested.add(DesktopPermission.microphone);
    status = DesktopPermissionSnapshot(
      microphone: DesktopPermissionState.authorized,
      accessibility: status.accessibility,
    );
    return status;
  }
}

final class _ModelsClient extends http.BaseClient {
  _ModelsClient(this.models);

  final List<String> models;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonEncode({
      'object': 'list',
      'data': [
        for (final model in models) {'id': model, 'object': 'model'},
      ],
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
