import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sttapp/services/update_service.dart';

void main() {
  group('ReleaseVersion', () {
    test('parses the release tag format', () {
      final version = ReleaseVersion.tryParse('v2026.4.0713.1783900800');

      expect(version, isNotNull);
      expect(version!.year, 2026);
      expect(version.major, 4);
      expect(version.monthDay, '0713');
      expect(version.timestamp, 1783900800);
    });

    test('supports existing three-part release tags', () {
      expect(ReleaseVersion.tryParse('v2026.8.0711'), isNotNull);
      expect(ReleaseVersion.tryParse('v2026.07.1'), isNotNull);
      expect(ReleaseVersion.tryParse('v1.0.2'), isNotNull);
    });

    test('rejects malformed tags and invalid timestamped dates', () {
      expect(ReleaseVersion.tryParse('2026.4.0713.1783900800'), isNull);
      expect(ReleaseVersion.tryParse('v2026.4.0230.1783900800'), isNull);
    });
  });

  group('UpdateService', () {
    test('requests the latest release and returns a newer update', () async {
      late http.BaseRequest capturedRequest;
      final client = _HandlerClient((request) async {
        capturedRequest = request;
        return _jsonResponse(200, [
          {
            'tag_name': 'v2026.9.0712',
            'html_url':
                'https://github.com/lmtr0/sttapp/releases/tag/v2026.9.0712',
            'draft': false,
            'prerelease': true,
          },
          {
            'tag_name': 'v2026.8.0711',
            'html_url':
                'https://github.com/lmtr0/sttapp/releases/tag/v2026.8.0711',
            'draft': false,
            'prerelease': false,
          },
          {
            'tag_name': 'v1.0.2',
            'html_url': 'https://github.com/lmtr0/sttapp/releases/tag/v1.0.2',
            'draft': false,
            'prerelease': false,
          },
        ]);
      });
      final service = UpdateService(client: client);

      final update = await service.checkForUpdate(currentTag: 'v2026.7.0710');

      expect(capturedRequest.url.toString(), githubReleasesApiUri);
      expect(capturedRequest.headers['Accept'], 'application/vnd.github+json');
      expect(capturedRequest.headers['User-Agent'], 'sttapp-update-checker');
      expect(update, isNotNull);
      expect(update!.latestVersion.tag, 'v2026.8.0711');
      expect(update.releaseUri.host, 'github.com');
    });

    test('returns no update for equal or older timestamps', () async {
      final service = UpdateService(
        client: _HandlerClient((_) async => throw StateError('not called')),
      );

      expect(
        await service.checkForUpdate(
          currentTag: 'v2026.1.0713.1783900800',
          fakeLatestTag: 'v2026.1.0713.1783900800',
        ),
        isNull,
      );
      expect(
        await service.checkForUpdate(
          currentTag: 'v2026.1.0713.1783900800',
          fakeLatestTag: 'v2026.1.0713.1783890000',
        ),
        isNull,
      );
    });

    test('fails safely on non-success responses', () async {
      final service = UpdateService(
        client: _HandlerClient(
          (_) async => _jsonResponse(403, {'error': true}),
        ),
      );

      await expectLater(
        service.checkForUpdate(currentTag: 'v2026.1.0713.1783900800'),
        throwsA(isA<UpdateCheckException>()),
      );
    });

    test('rejects malformed GitHub responses', () async {
      final service = UpdateService(
        client: _HandlerClient((_) async => _jsonResponse(200, {'name': 'x'})),
      );

      await expectLater(
        service.checkForUpdate(currentTag: 'v2026.1.0713.1783900800'),
        throwsFormatException,
      );
    });
  });
}

final class _HandlerClient extends http.BaseClient {
  _HandlerClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest request)
  handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return handler(request);
  }
}

http.StreamedResponse _jsonResponse(int statusCode, Object body) {
  return http.StreamedResponse(
    Stream.value(utf8.encode(jsonEncode(body))),
    statusCode,
    headers: {'content-type': 'application/json'},
  );
}
