import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/hosted_backend_client.dart';

typedef BrowserLauncher = Future<bool> Function(Uri uri);

abstract interface class DesktopAuthenticator {
  Future<HostedCredentials> signIn({String? deviceLabel});

  Future<void> cancel();
}

final class DesktopAuthException implements Exception {
  const DesktopAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class DesktopAuthService implements DesktopAuthenticator {
  DesktopAuthService({
    required this.client,
    required this.launchBrowser,
    this.timeout = const Duration(minutes: 5),
  });

  final HostedBackendClient client;
  final BrowserLauncher launchBrowser;
  final Duration timeout;
  HttpServer? _activeServer;

  @override
  Future<HostedCredentials> signIn({String? deviceLabel}) async {
    if (_activeServer != null) {
      throw const DesktopAuthException('A sign-in is already in progress.');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _activeServer = server;
    final callbackUri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: server.port,
      path: '/callback',
    );
    final verifier = _randomBase64Url(32);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomBase64Url(32);
    try {
      final start = await client.startDesktopAuth(
        challenge: challenge,
        state: state,
        callbackUri: callbackUri,
        deviceLabel: deviceLabel,
      );
      if (!await launchBrowser(start.authorizationUrl)) {
        throw const DesktopAuthException(
          'The system browser could not be opened.',
        );
      }
      final callback = await _waitForCallback(
        server: server,
        callbackUri: callbackUri,
        expectedState: state,
        expectedTransactionId: start.transactionId,
        waitFor: timeout < start.expiresIn ? timeout : start.expiresIn,
      );
      final uri = callback.uri;
      final code = uri.queryParameters['code'];
      final transactionId = uri.queryParameters['transaction_id'];
      callback.response
        ..headers.contentType = ContentType.html
        ..headers.set('cache-control', 'no-store')
        ..headers.set(
          'content-security-policy',
          "default-src 'none'; frame-ancestors 'none'",
        )
        ..write(_callbackPage(true));
      await callback.response.close();
      return await client.exchange(
        transactionId: transactionId!,
        code: code!,
        verifier: verifier,
        state: state,
        callbackUri: callbackUri,
      );
    } on TimeoutException {
      throw const DesktopAuthException('Sign-in timed out. Please try again.');
    } finally {
      await server.close(force: true);
      if (identical(_activeServer, server)) _activeServer = null;
    }
  }

  @override
  Future<void> cancel() async {
    final server = _activeServer;
    _activeServer = null;
    await server?.close(force: true);
  }

  Future<HttpRequest> _waitForCallback({
    required HttpServer server,
    required Uri callbackUri,
    required String expectedState,
    required String expectedTransactionId,
    required Duration waitFor,
  }) async {
    final completer = Completer<HttpRequest>();
    late final StreamSubscription<HttpRequest> subscription;
    final timer = Timer(
      waitFor,
      () => completer.completeError(
        TimeoutException('Desktop sign-in callback timed out.'),
      ),
    );
    subscription = server.listen(
      (callback) async {
        if (completer.isCompleted) {
          callback.response.statusCode = HttpStatus.gone;
          await callback.response.close();
          return;
        }
        final uri = callback.uri;
        if (callback.method != 'GET' || uri.path != callbackUri.path) {
          callback.response.statusCode = HttpStatus.notFound;
          await callback.response.close();
          return;
        }
        final code = uri.queryParameters['code'];
        final containsToken = uri.queryParameters.keys.any(
          (key) => key.toLowerCase().contains('token'),
        );
        if (containsToken ||
            uri.queryParameters['state'] != expectedState ||
            uri.queryParameters['transaction_id'] != expectedTransactionId ||
            code == null ||
            code.isEmpty) {
          callback.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.html
            ..headers.set('cache-control', 'no-store')
            ..write(_callbackPage(false));
          await callback.response.close();
          completer.completeError(
            const DesktopAuthException(
              'The sign-in callback was invalid. Please try again.',
            ),
          );
          return;
        }
        completer.complete(callback);
      },
      onError: (Object error, StackTrace stack) {
        if (!completer.isCompleted) completer.completeError(error, stack);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            const DesktopAuthException('Sign-in was canceled.'),
          );
        }
      },
      cancelOnError: false,
    );
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  static String _randomBase64Url(int length) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(length, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static String _callbackPage(bool success) => success
      ? '<!doctype html><meta charset="utf-8"><title>Signed in</title>'
            '<h1>Signed in</h1><p>You can close this tab and return to sttapp.</p>'
      : '<!doctype html><meta charset="utf-8"><title>Sign-in rejected</title>'
            '<h1>Sign-in rejected</h1><p>Return to sttapp and try again.</p>';
}
