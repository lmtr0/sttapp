import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:sttapp/services/config_repository.dart';

const defaultHostedBaseUrl = String.fromEnvironment(
  'STTAPP_HOSTED_BASE_URL',
  defaultValue: 'https://api.sttapp.app/v1',
);

final class HostedApiException implements Exception {
  const HostedApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
  });

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  bool get requiresSignIn =>
      const {'invalid_refresh_token', 'refresh_token_reused'}.contains(code);

  @override
  String toString() =>
      requestId == null ? message : '$message (Request ID: $requestId)';
}

final class DesktopAuthStart {
  const DesktopAuthStart({
    required this.transactionId,
    required this.authorizationUrl,
    required this.expiresIn,
  });
  final String transactionId;
  final Uri authorizationUrl;
  final Duration expiresIn;
}

final class HostedAccount {
  const HostedAccount({
    required this.id,
    required this.subscriptionState,
    required this.hostedAvailable,
    required this.checkoutAvailable,
    required this.portalAvailable,
    required this.usageMicros,
    required this.usageAsOf,
  });
  final String id;
  final String subscriptionState;
  final bool hostedAvailable;
  final bool checkoutAvailable;
  final bool portalAvailable;
  final int usageMicros;
  final DateTime usageAsOf;
}

final class HostedBackendClient {
  HostedBackendClient({Uri? baseUrl, http.Client? client})
    : baseUrl = _validateBaseUrl(baseUrl ?? Uri.parse(defaultHostedBaseUrl)),
      _client = client ?? http.Client(),
      _ownsClient = client == null;

  final Uri baseUrl;
  final http.Client _client;
  final bool _ownsClient;

  Future<DesktopAuthStart> startDesktopAuth({
    required String challenge,
    required String state,
    required Uri callbackUri,
    String? deviceLabel,
  }) async {
    final value = await _json(
      'POST',
      'auth/desktop/start',
      body: {
        'code_challenge': challenge,
        'state': state,
        'callback_uri': callbackUri.toString(),
        ...deviceLabel == null ? const {} : {'device_label': deviceLabel},
      },
    );
    final authorizationUrl = Uri.parse(_string(value, 'authorization_url'));
    if (authorizationUrl.scheme != 'https' ||
        authorizationUrl.origin != baseUrl.origin ||
        !authorizationUrl.path.endsWith('/authorize/desktop') ||
        authorizationUrl.userInfo.isNotEmpty) {
      throw const FormatException('Backend returned an unsafe sign-in URL.');
    }
    return DesktopAuthStart(
      transactionId: _string(value, 'transaction_id'),
      authorizationUrl: authorizationUrl,
      expiresIn: Duration(seconds: _integer(value, 'expires_in')),
    );
  }

  Future<HostedCredentials> exchange({
    required String transactionId,
    required String code,
    required String verifier,
    required String state,
    required Uri callbackUri,
  }) async => _credentials(
    await _json(
      'POST',
      'auth/desktop/exchange',
      body: {
        'transaction_id': transactionId,
        'code': code,
        'code_verifier': verifier,
        'state': state,
        'callback_uri': callbackUri.toString(),
      },
    ),
  );

  Future<HostedCredentials> refresh(String refreshToken) async => _credentials(
    await _json('POST', 'auth/refresh', body: {'refresh_token': refreshToken}),
  );

  Future<void> logout(String refreshToken) async {
    await _json(
      'POST',
      'auth/logout',
      body: {'refresh_token': refreshToken},
      allowEmpty: true,
    );
  }

  Future<HostedAccount> account(String accessToken) async {
    final value = await _json('GET', 'account', accessToken: accessToken);
    final subscription = _map(value, 'subscription');
    final billing = _map(value, 'billing');
    final usage = _map(value, 'usage');
    return HostedAccount(
      id: _string(value, 'id'),
      subscriptionState: _string(subscription, 'state'),
      hostedAvailable: value['hosted_available'] == true,
      checkoutAvailable: billing['checkout_available'] == true,
      portalAvailable: billing['portal_available'] == true,
      usageMicros: int.parse(_string(usage, 'retail_micros')),
      usageAsOf: DateTime.parse(_string(usage, 'as_of')).toUtc(),
    );
  }

  Future<List<String>> models(String accessToken) async {
    final value = await _json('GET', 'models', accessToken: accessToken);
    final data = value['data'];
    if (data is! List) {
      throw const FormatException('Models response is invalid.');
    }
    return data
        .whereType<Map<String, dynamic>>()
        .map((item) => item['id'])
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
  }

  Future<Uri> checkout(String accessToken) =>
      _browserUrl('billing/checkout', accessToken);

  Future<Uri> portal(String accessToken) =>
      _browserUrl('billing/portal', accessToken);

  Future<String> transcribe(
    String accessToken,
    Uint8List flacBytes,
    String model,
  ) async {
    final request =
        http.MultipartRequest('POST', _endpoint('audio/transcriptions'))
          ..headers['authorization'] = 'Bearer $accessToken'
          ..fields['model'] = model
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              flacBytes,
              filename: 'audio.flac',
              contentType: MediaType('audio', 'flac'),
            ),
          );
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(minutes: 2)),
    );
    final value = _decodeResponse(response);
    return _string(value, 'text').trim();
  }

  Future<Uri> _browserUrl(String path, String accessToken) async {
    final value = await _json('POST', path, accessToken: accessToken);
    final uri = Uri.parse(_string(value, 'url'));
    if (uri.scheme != 'https' ||
        !(uri.host == 'dodopayments.com' ||
            uri.host.endsWith('.dodopayments.com'))) {
      throw const FormatException('Backend returned an unsafe billing URL.');
    }
    return uri;
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    String? accessToken,
    Map<String, Object?>? body,
    bool allowEmpty = false,
  }) async {
    final request = http.Request(method, _endpoint(path));
    request.headers['accept'] = 'application/json';
    if (accessToken != null) {
      request.headers['authorization'] = 'Bearer $accessToken';
    }
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 30)),
    );
    if (allowEmpty && response.bodyBytes.isEmpty && response.statusCode < 300) {
      return const {};
    }
    return _decodeResponse(response);
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    Object? decoded;
    try {
      decoded = response.bodyBytes.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw HostedApiException(
        statusCode: response.statusCode,
        code: 'invalid_response',
        message: 'The hosted service returned an invalid response.',
        requestId: response.headers['x-request-id'],
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final envelope = decoded is Map<String, dynamic>
          ? decoded['error']
          : null;
      final error = envelope is Map<String, dynamic> ? envelope : const {};
      throw HostedApiException(
        statusCode: response.statusCode,
        code: error['code'] is String ? error['code'] as String : 'api_error',
        message: error['message'] is String
            ? error['message'] as String
            : 'The hosted request failed.',
        requestId: error['request_id'] is String
            ? error['request_id'] as String
            : response.headers['x-request-id'],
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Hosted response was not a JSON object.');
    }
    return decoded;
  }

  Uri _endpoint(String path) => baseUrl.replace(
    path: '${baseUrl.path.replaceFirst(RegExp(r'/$'), '')}/$path',
    query: null,
    fragment: null,
  );

  void close() {
    if (_ownsClient) _client.close();
  }

  static Uri _validateBaseUrl(Uri value) {
    if (value.scheme != 'https' ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty) {
      throw ArgumentError.value(value, 'baseUrl', 'Must be a safe HTTPS URL.');
    }
    return value;
  }

  static HostedCredentials _credentials(Map<String, dynamic> value) {
    final expiresIn = _integer(value, 'expires_in');
    return HostedCredentials(
      accessToken: _string(value, 'access_token'),
      accessTokenExpiresAt: DateTime.now().toUtc().add(
        Duration(seconds: expiresIn),
      ),
      refreshToken: _string(value, 'refresh_token'),
      sessionId: _string(value, 'session_id'),
    );
  }

  static String _string(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! String || field.isEmpty) {
      throw FormatException('Hosted response is missing $key.');
    }
    return field;
  }

  static int _integer(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! int) {
      throw FormatException('Hosted response is missing $key.');
    }
    return field;
  }

  static Map<String, dynamic> _map(Map<String, dynamic> value, String key) {
    final field = value[key];
    if (field is! Map<String, dynamic>) {
      throw FormatException('Hosted response is missing $key.');
    }
    return field;
  }
}

final class HostedSessionManager {
  HostedSessionManager({
    required this.client,
    required this.credentials,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final HostedBackendClient client;
  final HostedCredentialRepository credentials;
  final DateTime Function() _now;
  HostedCredentials? _credentials;
  Future<HostedCredentials>? _refreshing;

  Future<void> initialize() async {
    _credentials = await credentials.load();
  }

  Future<void> accept(HostedCredentials value) async {
    _credentials = value;
    await credentials.save(value);
  }

  Future<T> authorized<T>(
    Future<T> Function(String accessToken) operation,
  ) async {
    var current = _credentials ?? await credentials.load();
    if (current == null) {
      throw const HostedApiException(
        statusCode: 401,
        code: 'sign_in_required',
        message: 'Sign in to sttapp Hosted.',
      );
    }
    _credentials = current;
    if (current.expiresSoon(_now().toUtc())) current = await _refresh();
    try {
      return await operation(current.accessToken);
    } on HostedApiException catch (error) {
      if (error.code != 'invalid_access_token') rethrow;
      final refreshed = await _refresh();
      return operation(refreshed.accessToken);
    }
  }

  Future<HostedCredentials> _refresh() {
    final active = _refreshing;
    if (active != null) return active;
    final future = _performRefresh();
    _refreshing = future;
    return future.whenComplete(() => _refreshing = null);
  }

  Future<HostedCredentials> _performRefresh() async {
    final current = _credentials;
    if (current == null) {
      throw const HostedApiException(
        statusCode: 401,
        code: 'sign_in_required',
        message: 'Sign in to sttapp Hosted.',
      );
    }
    try {
      final next = await client.refresh(current.refreshToken);
      await accept(next);
      return next;
    } on HostedApiException catch (error) {
      if (error.requiresSignIn) {
        _credentials = null;
        await credentials.clear();
      }
      rethrow;
    }
  }

  Future<void> signOut() async {
    final current = _credentials ?? await credentials.load();
    try {
      if (current != null) await client.logout(current.refreshToken);
    } finally {
      _credentials = null;
      await credentials.clear();
    }
  }
}
