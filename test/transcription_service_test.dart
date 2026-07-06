import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/transcription_service.dart';

void main() {
  test(
    'multipart request includes auth, model, FLAC filename, and MIME type',
    () async {
      late http.MultipartRequest capturedRequest;
      final client = _CapturingClient((request) {
        capturedRequest = request as http.MultipartRequest;
        return _jsonResponse(200, {'text': ' ok '});
      });
      final service = TranscriptionService(client: client);

      final text = await service.transcribeFlacBytes(
        Uint8List.fromList([0x66, 0x4c, 0x61, 0x43]),
        TranscriptionConfig(
          apiKey: 'test-key',
          baseUrl: 'https://api.example/v1',
          model: 'whisper-1',
        ),
      );

      expect(text, 'ok');
      expect(capturedRequest.method, 'POST');
      expect(
        capturedRequest.url.toString(),
        'https://api.example/v1/audio/transcriptions',
      );
      expect(capturedRequest.headers['Authorization'], 'Bearer test-key');
      expect(capturedRequest.fields['model'], 'whisper-1');
      expect(capturedRequest.files.single.field, 'file');
      expect(capturedRequest.files.single.filename, 'audio.flac');
      expect(capturedRequest.files.single.contentType.toString(), 'audio/flac');
    },
  );

  test('response parsing accepts transcript and trims whitespace', () async {
    final service = TranscriptionService(
      client: _CapturingClient(
        (_) => _jsonResponse(200, {'transcript': ' hi \n'}),
      ),
    );

    final text = await service.transcribeFlacBytes(
      Uint8List.fromList([1, 2, 3]),
      TranscriptionConfig(
        apiKey: 'key',
        baseUrl: 'https://api.example/v1',
        model: 'model',
      ),
    );

    expect(text, 'hi');
  });

  test('non-2xx responses surface status and body', () async {
    final service = TranscriptionService(
      client: _CapturingClient((_) => _textResponse(401, 'bad key')),
    );

    expect(
      () => service.transcribeFlacBytes(
        Uint8List.fromList([1, 2, 3]),
        TranscriptionConfig(
          apiKey: 'key',
          baseUrl: 'https://api.example/v1',
          model: 'model',
        ),
      ),
      throwsA(
        isA<TranscriptionException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.body, 'body', 'bad key'),
      ),
    );
  });

  test('testConnection calls models endpoint with auth header', () async {
    late http.BaseRequest capturedRequest;
    final service = TranscriptionService(
      client: _CapturingClient((request) {
        capturedRequest = request;
        return _jsonResponse(200, {'data': []});
      }),
    );

    await service.testConnection(
      TranscriptionConfig(
        apiKey: 'key',
        baseUrl: 'https://api.example/v1',
        model: 'model',
      ),
    );

    expect(capturedRequest.method, 'GET');
    expect(capturedRequest.url.toString(), 'https://api.example/v1/models');
    expect(capturedRequest.headers['Authorization'], 'Bearer key');
  });

  test('listModels parses sorted unique model ids', () async {
    final service = TranscriptionService(
      client: _CapturingClient(
        (_) => _jsonResponse(200, {
          'object': 'list',
          'data': [
            {'id': 'z-model', 'object': 'model'},
            {'id': 'a-model', 'object': 'model'},
            {'id': 'z-model', 'object': 'model'},
            {'id': ' ', 'object': 'model'},
            {'object': 'model'},
          ],
        }),
      ),
    );

    final models = await service.listModels(
      TranscriptionConfig(
        apiKey: 'key',
        baseUrl: 'https://api.example/v1',
        model: '',
      ),
    );

    expect(models, ['a-model', 'z-model']);
  });

  test('listModels surfaces non-2xx status and body', () async {
    final service = TranscriptionService(
      client: _CapturingClient((_) => _textResponse(403, 'no models')),
    );

    expect(
      () => service.listModels(
        TranscriptionConfig(
          apiKey: 'key',
          baseUrl: 'https://api.example/v1',
          model: '',
        ),
      ),
      throwsA(
        isA<TranscriptionException>()
            .having((error) => error.statusCode, 'statusCode', 403)
            .having((error) => error.body, 'body', 'no models'),
      ),
    );
  });
}

final class _CapturingClient extends http.BaseClient {
  _CapturingClient(this._handler);

  final FutureOr<http.StreamedResponse> Function(http.BaseRequest request)
  _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return _handler(request);
  }
}

http.StreamedResponse _jsonResponse(int statusCode, Object body) {
  return _textResponse(statusCode, jsonEncode(body));
}

http.StreamedResponse _textResponse(int statusCode, String body) {
  return http.StreamedResponse(Stream.value(utf8.encode(body)), statusCode);
}
