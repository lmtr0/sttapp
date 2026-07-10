import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sttapp/main.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/notification_service.dart';
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

  testWidgets('notification settings are visible and reflect storage', (
    tester,
  ) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore({
            'openai_api_key': 'key',
            'openai_base_url': defaultOpenAiBaseUrl,
            'openai_model': 'gpt-4o-transcribe',
            'notifications_enabled': 'false',
          }),
          environment: const {},
        ),
        transcriptionService: TranscriptionService(
          client: _ModelsClient(['gpt-4o-transcribe']),
        ),
        supportsShortcutSettings: true,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('System notifications'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isFalse);
  });

  testWidgets('notification setting can be toggled and saved', (tester) async {
    final store = MemoryConfigStore({
      'openai_api_key': 'key',
      'openai_base_url': defaultOpenAiBaseUrl,
      'openai_model': 'gpt-4o-transcribe',
      'notifications_enabled': 'false',
    });

    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(store: store, environment: const {}),
        transcriptionService: TranscriptionService(
          client: _ModelsClient(['gpt-4o-transcribe']),
        ),
        supportsShortcutSettings: true,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('System notifications'));
    await tester.tap(find.text('System notifications'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(await store.read('notifications_enabled'), 'true');
  });

  testWidgets('injected notification service is initialized', (tester) async {
    final notificationService = _FakeNotificationService();

    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore(),
          environment: const {},
        ),
        notificationService: notificationService,
        supportsShortcutSettings: true,
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(notificationService.initialized, isTrue);
    expect(notificationService.shown, 0);
  });
}

final class _FakeNotificationService implements NotificationService {
  var initialized = false;
  var shown = 0;
  var disposed = false;

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<void> showRecordingFinishedTranscribing() async {
    shown += 1;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
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
