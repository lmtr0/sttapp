import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/hosted_backend_client.dart';
import 'package:sttapp/services/transcription_coordinator.dart';
import 'package:sttapp/services/transcription_service.dart';

void main() {
  test('manual mode routes only to the configured manual provider', () async {
    final manualHttp = _TranscriptionClient(text: 'manual transcript');
    final hostedHttp = _TranscriptionClient(text: 'hosted transcript');
    final hosted = HostedBackendClient(
      baseUrl: Uri.parse('https://hosted.example.test/v1'),
      client: hostedHttp,
    );
    final credentials = HostedCredentialRepository(MemoryConfigStore());
    final coordinator = TranscriptionCoordinator(
      manual: TranscriptionService(client: manualHttp),
      hosted: hosted,
      hostedSession: HostedSessionManager(
        client: hosted,
        credentials: credentials,
      ),
    );

    final result = await coordinator.transcribeFlacBytes(
      flacBytes: Uint8List.fromList([1, 2, 3]),
      setup: const ProviderSetupState(
        providerMode: TranscriptionProviderMode.manual,
        draftStep: SetupDraftStep.ready,
        hostedModel: 'hosted-model',
        completedVersion: ProviderSetupState.currentVersion,
      ),
      manualConfig: TranscriptionConfig(
        apiKey: 'manual-secret',
        baseUrl: 'https://manual.example.test/v1',
        model: 'manual-model',
      ),
    );

    expect(result, 'manual transcript');
    expect(manualHttp.calls, 1);
    expect(hostedHttp.calls, 0);
  });

  test('hosted failure never falls back to the manual provider', () async {
    final manualHttp = _TranscriptionClient(text: 'manual transcript');
    final hostedHttp = _TranscriptionClient(
      statusCode: 503,
      errorCode: 'hosted_unavailable',
    );
    final hosted = HostedBackendClient(
      baseUrl: Uri.parse('https://hosted.example.test/v1'),
      client: hostedHttp,
    );
    final credentials = HostedCredentialRepository(MemoryConfigStore());
    await credentials.save(
      HostedCredentials(
        accessToken: 'hosted-access',
        accessTokenExpiresAt: DateTime.utc(2100),
        refreshToken: 'hosted-refresh',
        sessionId: 'hosted-session',
      ),
    );
    final sessions = HostedSessionManager(
      client: hosted,
      credentials: credentials,
    );
    await sessions.initialize();
    final coordinator = TranscriptionCoordinator(
      manual: TranscriptionService(client: manualHttp),
      hosted: hosted,
      hostedSession: sessions,
    );

    await expectLater(
      coordinator.transcribeFlacBytes(
        flacBytes: Uint8List.fromList([1, 2, 3]),
        setup: const ProviderSetupState(
          providerMode: TranscriptionProviderMode.hosted,
          draftStep: SetupDraftStep.ready,
          hostedModel: 'hosted-model',
          completedVersion: ProviderSetupState.currentVersion,
        ),
        manualConfig: TranscriptionConfig(
          apiKey: 'manual-secret',
          baseUrl: 'https://manual.example.test/v1',
          model: 'manual-model',
        ),
      ),
      throwsA(
        isA<HostedApiException>().having(
          (error) => error.code,
          'code',
          'hosted_unavailable',
        ),
      ),
    );
    expect(hostedHttp.calls, 1);
    expect(manualHttp.calls, 0);
  });
}

final class _TranscriptionClient extends http.BaseClient {
  _TranscriptionClient({
    this.text,
    this.statusCode = 200,
    this.errorCode = 'test_error',
  });

  final String? text;
  final int statusCode;
  final String errorCode;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls += 1;
    final body = statusCode >= 200 && statusCode < 300
        ? jsonEncode({'text': text})
        : jsonEncode({
            'error': {'code': errorCode, 'message': 'Hosted request failed.'},
          });
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  }
}
