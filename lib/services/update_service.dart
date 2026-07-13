import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const githubReleasesApiUri =
    'https://api.github.com/repos/lmtr0/sttapp/releases';
const githubReleasesUri = 'https://github.com/lmtr0/sttapp/releases';

final class ReleaseVersion {
  const ReleaseVersion({
    required this.tag,
    required this.year,
    required this.major,
    required this.monthDay,
    required this.timestamp,
  });

  final String tag;
  final int year;
  final int major;
  final String monthDay;
  final int? timestamp;

  static final RegExp _tagPattern = RegExp(
    r'^v([0-9]+)\.([0-9]+)\.([0-9]+)(?:\.([0-9]+))?$',
  );

  static ReleaseVersion? tryParse(String value) {
    final tag = value.trim();
    final match = _tagPattern.firstMatch(tag);
    if (match == null) {
      return null;
    }

    final year = int.tryParse(match.group(1)!);
    final major = int.tryParse(match.group(2)!);
    final monthDay = match.group(3)!;
    final timestampPart = match.group(4);
    final timestamp = timestampPart == null
        ? null
        : int.tryParse(timestampPart);
    if (year == null ||
        major == null ||
        (timestampPart != null && timestamp == null)) {
      return null;
    }

    if (timestamp != null) {
      if (timestamp <= 0 ||
          match.group(1)!.length != 4 ||
          monthDay.length != 4) {
        return null;
      }
      final month = int.tryParse(monthDay.substring(0, 2));
      final day = int.tryParse(monthDay.substring(2));
      if (month == null ||
          day == null ||
          month < 1 ||
          month > 12 ||
          day < 1 ||
          day > DateTime.utc(year, month + 1, 0).day) {
        return null;
      }
    }

    return ReleaseVersion(
      tag: tag,
      year: year,
      major: major,
      monthDay: monthDay,
      timestamp: timestamp,
    );
  }

  bool isNewerThan(ReleaseVersion other) {
    if (timestamp != null && other.timestamp != null) {
      return timestamp! > other.timestamp!;
    }

    final parts = [year, major, int.parse(monthDay)];
    final otherParts = [other.year, other.major, int.parse(other.monthDay)];
    for (var index = 0; index < parts.length; index++) {
      if (parts[index] != otherParts[index]) {
        return parts[index] > otherParts[index];
      }
    }
    return timestamp != null && other.timestamp == null;
  }
}

final class AvailableUpdate {
  const AvailableUpdate({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUri,
  });

  final ReleaseVersion currentVersion;
  final ReleaseVersion latestVersion;
  final Uri releaseUri;
}

final class UpdateService {
  UpdateService({
    http.Client? client,
    Uri? releasesApiUri,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       releasesApiUri = releasesApiUri ?? Uri.parse(githubReleasesApiUri);

  final http.Client _client;
  final bool _ownsClient;
  final Uri releasesApiUri;
  final Duration requestTimeout;

  Future<AvailableUpdate?> checkForUpdate({
    required String currentTag,
    String? fakeLatestTag,
  }) async {
    final currentVersion = ReleaseVersion.tryParse(currentTag);
    if (currentVersion == null) {
      throw FormatException('Invalid current release tag: $currentTag');
    }

    late final ReleaseVersion latestVersion;
    late final Uri releaseUri;
    if (fakeLatestTag != null && fakeLatestTag.trim().isNotEmpty) {
      final parsedFakeVersion = ReleaseVersion.tryParse(fakeLatestTag);
      if (parsedFakeVersion == null) {
        throw FormatException(
          'Invalid fake latest release tag: $fakeLatestTag',
        );
      }
      latestVersion = parsedFakeVersion;
      releaseUri = Uri.parse(githubReleasesUri);
    } else {
      final release = await _fetchLatestRelease();
      latestVersion = release.version;
      releaseUri = release.uri;
    }

    if (!latestVersion.isNewerThan(currentVersion)) {
      return null;
    }

    return AvailableUpdate(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      releaseUri: releaseUri,
    );
  }

  Future<({ReleaseVersion version, Uri uri})> _fetchLatestRelease() async {
    final response = await _client
        .get(
          releasesApiUri,
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'sttapp-update-checker',
            'X-GitHub-Api-Version': '2026-03-10',
          },
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UpdateCheckException(response.statusCode, response.body);
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      throw const FormatException(
        'GitHub releases response was not a JSON array.',
      );
    }

    for (final item in decoded) {
      if (item is! Map<String, dynamic> ||
          item['draft'] == true ||
          item['prerelease'] == true) {
        continue;
      }
      final tag = item['tag_name'];
      final htmlUrl = item['html_url'];
      if (tag is! String || htmlUrl is! String) {
        continue;
      }
      final version = ReleaseVersion.tryParse(tag);
      final uri = Uri.tryParse(htmlUrl);
      if (version == null ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'github.com') {
        continue;
      }
      return (version: version, uri: uri);
    }

    throw const FormatException(
      'GitHub releases response did not include a compatible published release.',
    );
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

final class UpdateCheckException implements Exception {
  const UpdateCheckException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'Update check failed ($statusCode): $body';
}
