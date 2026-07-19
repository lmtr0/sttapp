import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sttapp/main.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/desktop_auth_service.dart';
import 'package:sttapp/services/desktop_permission_service.dart';
import 'package:sttapp/services/hosted_backend_client.dart';
import 'package:sttapp/services/transcription_service.dart';
import 'package:sttapp/services/update_service.dart';

void main() {
  test('app widget is available', () {
    expect(const SttApp(), isA<Widget>());
  });

  testWidgets('shortcut registration failure is actionable', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShortcutRegistrationNotice(
            checking: false,
            message: 'Could not register F8. Shortcut is already in use.',
            onRetry: () => retries += 1,
          ),
        ),
      ),
    );

    expect(find.text('Global shortcuts unavailable'), findsOneWidget);
    expect(find.textContaining('Could not register F8'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Retry registration'));
    expect(retries, 1);
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

  testWidgets('fresh install defaults to signed-out sttapp Hosted', (
    tester,
  ) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore(),
          environment: const {},
        ),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Transcription provider'), findsOneWidget);
    expect(find.text('sttapp Hosted'), findsOneWidget);
    expect(find.text('Sign in securely'), findsOneWidget);
    expect(find.text('Use API key instead'), findsOneWidget);
    expect(find.text('Base URL'), findsNothing);
    expect(_closeButton(tester).onPressed, isNull);
  });

  testWidgets('hosted setup remains usable at the 420px minimum width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore(),
          environment: const {},
        ),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in securely'), findsOneWidget);
    expect(find.text('Use API key instead'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy manual configuration remains the active provider', (
    tester,
  ) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: _validConfigRepository(),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Use sttapp Hosted instead'), findsOneWidget);
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('Sign in securely'), findsNothing);
    expect(_closeButton(tester).onPressed, isNotNull);
  });

  testWidgets('hosted sign-in loads an enabled model and becomes ready', (
    tester,
  ) async {
    final store = MemoryConfigStore();
    final authenticator = _FakeDesktopAuthenticator.succeeding();
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(store: store, environment: const {}),
        hostedBackendClient: _hostedClient(),
        desktopAuthenticator: authenticator,
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign in securely'));
    await tester.pumpAndSettle();

    expect(authenticator.signInCalls, 1);
    expect(find.text('Active subscription'), findsOneWidget);
    expect(find.text('whisper-large-v3-turbo'), findsOneWidget);
    expect(find.text('sttapp Hosted is ready.'), findsOneWidget);
    expect(await store.read('provider_mode'), 'hosted');
    expect(await store.read('setup_version_completed'), '1');
    expect(_closeButton(tester).onPressed, isNotNull);
  });

  testWidgets(
    'an injected hosted session supplies its client and credential store',
    (tester) async {
      final appStore = MemoryConfigStore({
        'provider_mode': 'hosted',
        'setup_draft_step': 'hosted',
        'hosted_model': 'whisper-large-v3-turbo',
        'setup_version_completed': '',
      });
      final sessionStore = MemoryConfigStore();
      final credentials = HostedCredentialRepository(sessionStore);
      await credentials.save(_hostedCredentials());
      final client = _hostedClient();
      final session = HostedSessionManager(
        client: client,
        credentials: credentials,
      );
      await tester.pumpWidget(
        SttApp(
          configRepository: ConfigRepository(
            store: appStore,
            environment: const {},
          ),
          hostedSessionManager: session,
          desktopPermissionService: const PermissiveDesktopPermissionService(),
          initializePlatformServices: false,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Active subscription'), findsOneWidget);
      expect(find.text('whisper-large-v3-turbo'), findsOneWidget);
      expect(_closeButton(tester).onPressed, isNotNull);
    },
  );

  testWidgets('hosted sign-in error is actionable without exposing fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore(),
          environment: const {},
        ),
        desktopAuthenticator: _FakeDesktopAuthenticator.failing(
          const DesktopAuthException('Sign-in was canceled by the browser.'),
        ),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in securely'));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in was canceled by the browser.'), findsOneWidget);
    expect(find.text('Sign in securely'), findsOneWidget);
    expect(find.text('Base URL'), findsNothing);
  });

  testWidgets('in-progress hosted sign-in can be canceled', (tester) async {
    final authenticator = _FakeDesktopAuthenticator.pending();
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore(),
          environment: const {},
        ),
        desktopAuthenticator: authenticator,
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in securely'));
    await tester.pump();
    expect(find.text('Cancel sign-in'), findsOneWidget);

    await tester.tap(find.text('Cancel sign-in'));
    await tester.pumpAndSettle();
    expect(authenticator.cancelCalls, 1);
    expect(find.textContaining('Sign-in canceled'), findsOneWidget);
  });

  testWidgets('switching to API key cancels an in-progress hosted sign-in', (
    tester,
  ) async {
    final authenticator = _FakeDesktopAuthenticator.pending();
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(
          store: MemoryConfigStore(),
          environment: const {},
        ),
        desktopAuthenticator: authenticator,
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in securely'));
    await tester.pump();

    await tester.tap(find.text('Use API key instead'));
    await tester.pumpAndSettle();

    expect(authenticator.cancelCalls, 1);
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('Cancel sign-in'), findsNothing);
  });

  testWidgets('provider switching preserves manual and hosted setup', (
    tester,
  ) async {
    final store = MemoryConfigStore({
      'openai_api_key': 'manual-secret',
      'openai_base_url': 'https://manual.example/v1',
      'openai_model': 'manual-model',
      'provider_mode': 'manual',
      'setup_draft_step': 'ready',
      'setup_version_completed': '1',
    });
    await HostedCredentialRepository(store).save(_hostedCredentials());
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(store: store, environment: const {}),
        hostedBackendClient: _hostedClient(),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    final useHosted = find.widgetWithText(
      TextButton,
      'Use sttapp Hosted instead',
    );
    await tester.ensureVisible(useHosted);
    await tester.pumpAndSettle();
    await tester.tap(useHosted);
    await tester.pumpAndSettle();
    expect(find.text('whisper-large-v3-turbo'), findsOneWidget);
    expect(find.text('Sign in securely'), findsNothing);

    final useManual = find.widgetWithText(TextButton, 'Use API key instead');
    await tester.ensureVisible(useManual);
    await tester.pumpAndSettle();
    await tester.tap(useManual);
    await tester.pumpAndSettle();
    final apiKey = tester.widget<TextField>(
      find.widgetWithText(TextField, 'API key'),
    );
    expect(apiKey.controller?.text, 'manual-secret');
    expect(await HostedCredentialRepository(store).load(), isNotNull);

    await tester.ensureVisible(useHosted);
    await tester.pumpAndSettle();
    await tester.tap(useHosted);
    await tester.pumpAndSettle();
    expect(find.text('whisper-large-v3-turbo'), findsOneWidget);
  });

  testWidgets('the selected provider and both configurations survive restart', (
    tester,
  ) async {
    final store = MemoryConfigStore({
      'openai_api_key': 'manual-secret',
      'openai_base_url': 'https://manual.example/v1',
      'openai_model': 'manual-model',
      'provider_mode': 'manual',
      'setup_draft_step': 'ready',
      'setup_version_completed': '1',
    });
    await HostedCredentialRepository(store).save(_hostedCredentials());

    Future<void> pumpApp() => tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(store: store, environment: const {}),
        hostedBackendClient: _hostedClient(),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );

    await pumpApp();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    final useHosted = find.text('Use sttapp Hosted instead');
    await tester.ensureVisible(useHosted);
    await tester.pumpAndSettle();
    await tester.tap(useHosted);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Active subscription'), findsOneWidget);
    expect(find.text('Base URL'), findsNothing);

    final useManual = find.text('Use API key instead');
    await tester.ensureVisible(useManual);
    await tester.pumpAndSettle();
    await tester.tap(useManual);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await pumpApp();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Base URL'), findsOneWidget);
    expect(find.text('Sign in securely'), findsNothing);
    expect(await HostedCredentialRepository(store).load(), isNotNull);
  });

  testWidgets('revoked hosted refresh returns to sign-in and disables close', (
    tester,
  ) async {
    final store = MemoryConfigStore({
      'provider_mode': 'hosted',
      'setup_draft_step': 'ready',
      'hosted_model': 'whisper-large-v3-turbo',
      'setup_version_completed': '1',
    });
    await HostedCredentialRepository(store).save(
      HostedCredentials(
        accessToken: 'expired-access',
        accessTokenExpiresAt: DateTime.utc(2000),
        refreshToken: 'revoked-refresh',
        sessionId: 'revoked-session',
      ),
    );
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(store: store, environment: const {}),
        hostedBackendClient: HostedBackendClient(
          baseUrl: Uri.parse('https://api.example.test/v1'),
          client: _RevokedRefreshClient(),
        ),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sign in securely'), findsOneWidget);
    expect(find.textContaining('session ended'), findsOneWidget);
    expect(_closeButton(tester).onPressed, isNull);
    expect(await HostedCredentialRepository(store).load(), isNull);
  });

  testWidgets('sign out clears hosted credentials but keeps manual config', (
    tester,
  ) async {
    final store = MemoryConfigStore({
      'openai_api_key': 'manual-secret',
      'openai_base_url': 'https://manual.example/v1',
      'openai_model': 'manual-model',
      'provider_mode': 'hosted',
      'setup_draft_step': 'ready',
      'hosted_model': 'whisper-large-v3-turbo',
      'setup_version_completed': '1',
    });
    await HostedCredentialRepository(store).save(_hostedCredentials());
    await tester.pumpWidget(
      SttApp(
        configRepository: ConfigRepository(store: store, environment: const {}),
        hostedBackendClient: _hostedClient(),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in securely'), findsOneWidget);
    expect(await HostedCredentialRepository(store).load(), isNull);
    expect(await store.read('openai_api_key'), 'manual-secret');
    expect(_closeButton(tester).onPressed, isNull);
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

    await tester.scrollUntilVisible(
      find.text('macOS permissions'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
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

    await tester.scrollUntilVisible(
      find.text('macOS permissions'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
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

  testWidgets('newer release opens settings and shows update card', (
    tester,
  ) async {
    Uri? openedRelease;
    await tester.pumpWidget(
      SttApp(
        configRepository: _validConfigRepository(),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        updateService: UpdateService(client: _UnexpectedUpdateClient()),
        releaseTag: 'v2026.1.0713.1783900800',
        fakeLatestTag: 'v2026.1.0713.1783904400',
        releaseLauncher: (uri) async {
          openedRelease = uri;
          return true;
        },
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Updates and version'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Update needed'), findsOneWidget);
    expect(find.text('A new version is available'), findsOneWidget);
    expect(
      find.text('v2026.1.0713.1783900800 → v2026.1.0713.1783904400'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'View release'));
    await tester.pump();
    expect(openedRelease, Uri.parse(githubReleasesUri));
  });

  testWidgets('equal release shows latest status without an update card', (
    tester,
  ) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: _validConfigRepository(),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        updateService: UpdateService(client: _UnexpectedUpdateClient()),
        releaseTag: 'v2026.1.0713.1783900800',
        fakeLatestTag: 'v2026.1.0713.1783900800',
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ready'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Updates and version'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.textContaining('You are on the latest version'),
      findsOneWidget,
    );
    expect(find.text('A new version is available'), findsNothing);
  });

  testWidgets('failed update check is non-fatal', (tester) async {
    await tester.pumpWidget(
      SttApp(
        configRepository: _validConfigRepository(),
        desktopPermissionService: const PermissiveDesktopPermissionService(),
        updateService: UpdateService(client: _UnexpectedUpdateClient()),
        releaseTag: 'not-a-release-tag',
        fakeLatestTag: 'v2026.1.0713.1783900800',
        initializePlatformServices: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ready'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Updates and version'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('Unable to check for updates'), findsOneWidget);
    expect(find.text('A new version is available'), findsNothing);
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

IconButton _closeButton(WidgetTester tester) {
  return tester.widget<IconButton>(
    find.ancestor(
      of: find.byIcon(Icons.close),
      matching: find.byType(IconButton),
    ),
  );
}

HostedCredentials _hostedCredentials() {
  return HostedCredentials(
    accessToken: 'hosted-access',
    accessTokenExpiresAt: DateTime.utc(2100),
    refreshToken: 'hosted-refresh',
    sessionId: 'hosted-session',
  );
}

HostedBackendClient _hostedClient() {
  return HostedBackendClient(
    baseUrl: Uri.parse('https://api.example.test/v1'),
    client: _HostedApiClient(),
  );
}

final class _FakeDesktopAuthenticator implements DesktopAuthenticator {
  _FakeDesktopAuthenticator._(this._signIn, this._cancel);

  factory _FakeDesktopAuthenticator.succeeding() {
    return _FakeDesktopAuthenticator._(
      () async => _hostedCredentials(),
      () async {},
    );
  }

  factory _FakeDesktopAuthenticator.failing(Object error) {
    return _FakeDesktopAuthenticator._(() async => throw error, () async {});
  }

  factory _FakeDesktopAuthenticator.pending() {
    final completer = Completer<HostedCredentials>();
    return _FakeDesktopAuthenticator._(() => completer.future, () async {
      if (!completer.isCompleted) {
        completer.completeError(
          const DesktopAuthException('Sign-in was canceled.'),
        );
      }
    });
  }

  final Future<HostedCredentials> Function() _signIn;
  final Future<void> Function() _cancel;
  int signInCalls = 0;
  int cancelCalls = 0;

  @override
  Future<void> cancel() {
    cancelCalls += 1;
    return _cancel();
  }

  @override
  Future<HostedCredentials> signIn({String? deviceLabel}) {
    signInCalls += 1;
    return _signIn();
  }
}

final class _HostedApiClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    late final int status;
    late final String body;
    if (request.url.path.endsWith('/account')) {
      status = 200;
      body = jsonEncode({
        'id': 'account-test',
        'subscription': {'state': 'active'},
        'hosted_available': true,
        'billing': {'checkout_available': false, 'portal_available': true},
        'usage': {'retail_micros': '250000', 'as_of': '2026-07-18T12:00:00Z'},
      });
    } else if (request.url.path.endsWith('/models')) {
      status = 200;
      body = jsonEncode({
        'data': [
          {'id': 'whisper-large-v3-turbo'},
        ],
      });
    } else if (request.url.path.endsWith('/auth/logout')) {
      status = 204;
      body = '';
    } else if (request.url.path.endsWith('/billing/portal')) {
      status = 200;
      body = jsonEncode({'url': 'https://app.dodopayments.com/customer'});
    } else {
      status = 500;
      body = jsonEncode({
        'error': {
          'code': 'unexpected_request',
          'message': 'Unexpected request',
        },
      });
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );
  }
}

final class _RevokedRefreshClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonEncode({
      'error': {'code': 'invalid_refresh_token', 'message': 'Sign in again.'},
    });
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      401,
      headers: {'content-type': 'application/json'},
    );
  }
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

final class _UnexpectedUpdateClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('The fake latest tag should bypass HTTP.');
  }
}
