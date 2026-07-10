import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp_audio/sttapp_audio.dart';

final class TranscriptionService {
  TranscriptionService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<String> transcribe(AudioClip clip, TranscriptionConfig config) async {
    final bytes = config.isGroqEndpoint
        ? await clip.toGroqOptimizedFlacBytes()
        : await clip.toFlacBytes();
    return transcribeFlacBytes(bytes, config);
  }

  Future<String> transcribeFlacBytes(
    Uint8List flacBytes,
    TranscriptionConfig config,
  ) async {
    config.validate();

    final request = http.MultipartRequest('POST', config.transcriptionsUri)
      ..headers['Authorization'] = 'Bearer ${config.apiKey}'
      ..fields['model'] = config.model
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          flacBytes,
          filename: 'audio.flac',
          contentType: MediaType('audio', 'flac'),
        ),
      );

    final streamedResponse = await _client.send(request);
    final response = await http.Response.fromStream(streamedResponse);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TranscriptionException(response.statusCode, response.body);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Transcription response was not a JSON object.',
      );
    }

    final text = decoded['text'] ?? decoded['transcript'];
    if (text is! String) {
      throw const FormatException(
        'Transcription response did not include text or transcript.',
      );
    }

    return text.trim();
  }

  Future<List<String>> listModels(TranscriptionConfig config) async {
    config.validateEndpoint();

    final response = await _client.get(
      config.modelsUri,
      headers: {'Authorization': 'Bearer ${config.apiKey}'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw TranscriptionException(response.statusCode, response.body);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Models response was not a JSON object.');
    }

    final data = decoded['data'];
    if (data is! List) {
      throw const FormatException('Models response did not include data.');
    }

    final models = <String>{};
    for (final item in data) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final id = item['id'];
      if (id is String && id.trim().isNotEmpty) {
        models.add(id.trim());
      }
    }

    return models.toList()..sort();
  }

  Future<void> testConnection(TranscriptionConfig config) async {
    await listModels(config);
  }

  void close() {
    _client.close();
  }
}

final class TranscriptionException implements Exception {
  const TranscriptionException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'Transcription failed ($statusCode): $body';
}
