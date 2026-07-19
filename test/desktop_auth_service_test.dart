import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sttapp/services/desktop_auth_service.dart';
import 'package:sttapp/services/hosted_backend_client.dart';

void main() {
  test(
    'desktop auth completes the loopback exchange without browser tokens',
    () async {
      final api = _DesktopAuthApiClient();
      final browser = HttpClient();
      addTearDown(browser.close);
      final service = DesktopAuthService(
        client: HostedBackendClient(
          baseUrl: Uri.parse('https://api.example.test/v1'),
          client: api,
        ),
        launchBrowser: (_) async {
          final callback = api.callbackUri!.replace(
            queryParameters: {
              'code': 'one-time-code',
              'state': api.state,
              'transaction_id': 'transaction-1',
            },
          );
          unawaited(_openLoopback(browser, callback));
          return true;
        },
        timeout: const Duration(seconds: 5),
      );

      final credentials = await service.signIn(deviceLabel: 'test desktop');

      expect(credentials.accessToken, 'backend-access');
      expect(api.exchangeBody?['code'], 'one-time-code');
      expect(api.exchangeBody?['code_verifier'], isNotEmpty);
      expect(api.exchangeBody?.containsKey('access_token'), isFalse);
    },
  );

  test(
    'desktop auth rejects overlapping attempts and cancellation is reusable',
    () async {
      final api = _DesktopAuthApiClient();
      final service = DesktopAuthService(
        client: HostedBackendClient(
          baseUrl: Uri.parse('https://api.example.test/v1'),
          client: api,
        ),
        launchBrowser: (_) async => true,
        timeout: const Duration(seconds: 5),
      );

      final first = service.signIn();
      await _waitUntil(() => api.callbackUri != null);
      await expectLater(
        service.signIn(),
        throwsA(
          isA<DesktopAuthException>().having(
            (error) => error.message,
            'message',
            contains('already in progress'),
          ),
        ),
      );
      await service.cancel();
      await expectLater(
        first,
        throwsA(
          isA<DesktopAuthException>().having(
            (error) => error.message,
            'message',
            contains('canceled'),
          ),
        ),
      );

      api.callbackUri = null;
      final next = service.signIn();
      await _waitUntil(() => api.callbackUri != null);
      await service.cancel();
      await expectLater(next, throwsA(isA<DesktopAuthException>()));
    },
  );

  test(
    'desktop auth reports a browser launch failure and releases its port',
    () async {
      final api = _DesktopAuthApiClient();
      final service = DesktopAuthService(
        client: HostedBackendClient(
          baseUrl: Uri.parse('https://api.example.test/v1'),
          client: api,
        ),
        launchBrowser: (_) async => false,
      );

      await expectLater(
        service.signIn(),
        throwsA(
          isA<DesktopAuthException>().having(
            (error) => error.message,
            'message',
            contains('could not be opened'),
          ),
        ),
      );
      await expectLater(service.signIn(), throwsA(isA<DesktopAuthException>()));
    },
  );
}

Future<void> _openLoopback(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  await response.drain<void>();
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for the desktop auth test state.');
}

final class _DesktopAuthApiClient extends http.BaseClient {
  Uri? callbackUri;
  String? state;
  Map<String, dynamic>? exchangeBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = request is http.Request && request.body.isNotEmpty
        ? jsonDecode(request.body) as Map<String, dynamic>
        : <String, dynamic>{};
    Object response;
    if (request.url.path.endsWith('/auth/desktop/start')) {
      callbackUri = Uri.parse(body['callback_uri'] as String);
      state = body['state'] as String;
      response = {
        'transaction_id': 'transaction-1',
        'authorization_url':
            'https://api.example.test/authorize/desktop?transaction_id=transaction-1',
        'expires_in': 60,
      };
    } else if (request.url.path.endsWith('/auth/desktop/exchange')) {
      exchangeBody = body;
      response = {
        'access_token': 'backend-access',
        'refresh_token': 'backend-refresh',
        'session_id': 'session-1',
        'expires_in': 300,
      };
    } else {
      return http.StreamedResponse(Stream.value(const <int>[]), 404);
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(response))),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
