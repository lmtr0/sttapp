import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/hosted_backend_client.dart';

void main() {
  test(
    'parses stable backend errors without exposing provider bodies',
    () async {
      final client = HostedBackendClient(
        baseUrl: Uri.parse('https://api.example.test/v1'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'message': 'Subscription required.',
                'code': 'subscription_required',
                'request_id': 'req_test',
              },
            }),
            403,
          ),
        ),
      );

      expect(
        () => client.models('access'),
        throwsA(
          isA<HostedApiException>()
              .having((error) => error.code, 'code', 'subscription_required')
              .having((error) => error.requestId, 'requestId', 'req_test'),
        ),
      );
    },
  );

  test('rejects sign-in and billing URLs outside allowlists', () async {
    final client = HostedBackendClient(
      baseUrl: Uri.parse('https://api.example.test/v1'),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/desktop/start')) {
          return http.Response(
            jsonEncode({
              'transaction_id': 'tx',
              'authorization_url': 'https://attacker.test/sign-in',
              'expires_in': 300,
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'url': 'https://attacker.test'}), 200);
      }),
    );

    expect(
      () => client.startDesktopAuth(
        challenge: List.filled(43, 'c').join(),
        state: List.filled(43, 's').join(),
        callbackUri: Uri.parse('http://127.0.0.1:4000/callback'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(() => client.portal('token'), throwsA(isA<FormatException>()));
  });

  test(
    'serializes concurrent refresh and persists the rotated token',
    () async {
      final responseGate = Completer<void>();
      var refreshCalls = 0;
      final client = HostedBackendClient(
        baseUrl: Uri.parse('https://api.example.test/v1'),
        client: MockClient((request) async {
          refreshCalls++;
          await responseGate.future;
          return http.Response(
            jsonEncode({
              'access_token': 'next-access',
              'refresh_token': 'next-refresh',
              'session_id': 'session',
              'expires_in': 600,
            }),
            200,
          );
        }),
      );
      final repository = HostedCredentialRepository(MemoryConfigStore());
      await repository.save(
        HostedCredentials(
          accessToken: 'expired',
          accessTokenExpiresAt: DateTime.utc(2020),
          refreshToken: 'refresh',
          sessionId: 'session',
        ),
      );
      final sessions = HostedSessionManager(
        client: client,
        credentials: repository,
        now: () => DateTime.utc(2026),
      );
      await sessions.initialize();

      final first = sessions.authorized((token) async => token);
      final second = sessions.authorized((token) async => token);
      await Future<void>.delayed(Duration.zero);
      responseGate.complete();

      expect(await Future.wait([first, second]), [
        'next-access',
        'next-access',
      ]);
      expect(refreshCalls, 1);
      expect((await repository.load())?.refreshToken, 'next-refresh');
    },
  );
}
