import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const defaultOpenAiBaseUrl = 'https://api.openai.com/v1';
const defaultOpenAiModel = '';

const defaultShortcutKeyId = 'f8';

final List<ShortcutKeyOption> shortcutKeyOptions = [
  ShortcutKeyOption('f1', 'F1', LogicalKeyboardKey.f1),
  ShortcutKeyOption('f2', 'F2', LogicalKeyboardKey.f2),
  ShortcutKeyOption('f3', 'F3', LogicalKeyboardKey.f3),
  ShortcutKeyOption('f4', 'F4', LogicalKeyboardKey.f4),
  ShortcutKeyOption('f5', 'F5', LogicalKeyboardKey.f5),
  ShortcutKeyOption('f6', 'F6', LogicalKeyboardKey.f6),
  ShortcutKeyOption('f7', 'F7', LogicalKeyboardKey.f7),
  ShortcutKeyOption('f8', 'F8', LogicalKeyboardKey.f8),
  ShortcutKeyOption('f9', 'F9', LogicalKeyboardKey.f9),
  ShortcutKeyOption('f10', 'F10', LogicalKeyboardKey.f10),
  ShortcutKeyOption('f11', 'F11', LogicalKeyboardKey.f11),
  ShortcutKeyOption('f12', 'F12', LogicalKeyboardKey.f12),
];

final class ShortcutKeyOption {
  const ShortcutKeyOption(this.id, this.label, this.logicalKey);

  final String id;
  final String label;
  final LogicalKeyboardKey logicalKey;
}

final class ShortcutConfig {
  ShortcutConfig({String keyId = defaultShortcutKeyId})
    : keyId = _normalizeKeyId(keyId);

  final String keyId;

  ShortcutKeyOption get keyOption {
    return shortcutKeyOptions.firstWhere(
      (option) => option.id == keyId,
      orElse: () => shortcutKeyOptions.firstWhere(
        (option) => option.id == defaultShortcutKeyId,
      ),
    );
  }

  LogicalKeyboardKey get logicalKey => keyOption.logicalKey;

  String get normalLabel => keyOption.label;

  String get plainLabel => 'Shift+${keyOption.label}';

  static String _normalizeKeyId(String value) {
    final normalized = value.trim().toLowerCase();
    if (shortcutKeyOptions.any((option) => option.id == normalized)) {
      return normalized;
    }
    return defaultShortcutKeyId;
  }
}

final class TranscriptionConfig {
  TranscriptionConfig({
    required String apiKey,
    required String baseUrl,
    required String model,
  }) : apiKey = apiKey.trim(),
       baseUrl = _normalizeBaseUrl(baseUrl),
       model = model.trim();

  final String apiKey;
  final String baseUrl;
  final String model;

  bool get isComplete =>
      apiKey.isNotEmpty && baseUrl.isNotEmpty && model.isNotEmpty;

  Uri get transcriptionsUri => Uri.parse('$baseUrl/audio/transcriptions');

  Uri get modelsUri => Uri.parse('$baseUrl/models');

  void validateEndpoint() {
    if (apiKey.isEmpty) {
      throw const ConfigException('OpenAI API key is required.');
    }
    if (baseUrl.isEmpty) {
      throw const ConfigException('OpenAI base URL is required.');
    }
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ConfigException('OpenAI base URL is invalid: $baseUrl');
    }
  }

  void validate() {
    validateEndpoint();
    if (model.isEmpty) {
      throw const ConfigException('OpenAI model is required.');
    }
  }

  TranscriptionConfig copyWith({
    String? apiKey,
    String? baseUrl,
    String? model,
  }) {
    return TranscriptionConfig(
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      model: model ?? this.model,
    );
  }

  static String _normalizeBaseUrl(String value) {
    var normalized = value.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}

final class ConfigException implements Exception {
  const ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class ConfigStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);
}

final class SecureConfigStore implements ConfigStore {
  SecureConfigStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value);
  }
}

final class ConfigRepository {
  ConfigRepository({
    ConfigStore? store,
    Map<String, String>? environment,
    this.legacySettingsFiles,
  }) : _store = store ?? SecureConfigStore(),
       _environment = environment ?? Platform.environment;

  static const _apiKeyKey = 'openai_api_key';
  static const _baseUrlKey = 'openai_base_url';
  static const _modelKey = 'openai_model';
  static const _shortcutKeyIdKey = 'shortcut_key_id';

  final ConfigStore _store;
  final Map<String, String> _environment;
  final List<File>? legacySettingsFiles;

  Future<TranscriptionConfig> load() async {
    await migrateLegacyTauriConfigIfNeeded();

    final storedApiKey = await _store.read(_apiKeyKey);
    final storedBaseUrl = await _store.read(_baseUrlKey);
    final storedModel = await _store.read(_modelKey);

    return TranscriptionConfig(
      apiKey: _firstNonEmpty(storedApiKey, _environment['OPENAI_API_KEY']),
      baseUrl: _firstNonEmpty(
        storedBaseUrl,
        _environment['OPENAI_BASE_URL'],
        defaultOpenAiBaseUrl,
      ),
      model: _firstNonEmpty(
        storedModel,
        _environment['OPENAI_MODEL'],
        defaultOpenAiModel,
      ),
    );
  }

  Future<void> save(TranscriptionConfig config) async {
    await _store.write(_apiKeyKey, config.apiKey);
    await _store.write(_baseUrlKey, config.baseUrl);
    await _store.write(_modelKey, config.model);
  }

  Future<ShortcutConfig> loadShortcutConfig() async {
    return ShortcutConfig(
      keyId: _firstNonEmpty(
        await _store.read(_shortcutKeyIdKey),
        defaultShortcutKeyId,
      ),
    );
  }

  Future<void> saveShortcutConfig(ShortcutConfig config) {
    return _store.write(_shortcutKeyIdKey, config.keyId);
  }

  Future<void> migrateLegacyTauriConfigIfNeeded() async {
    if (!await _flutterConfigIsEmpty()) {
      return;
    }

    final legacy = await _readLegacyConfig();
    if (legacy == null || !legacy.isComplete) {
      return;
    }

    await save(legacy);
  }

  Future<bool> _flutterConfigIsEmpty() async {
    final storedApiKey = await _store.read(_apiKeyKey);
    final storedBaseUrl = await _store.read(_baseUrlKey);
    final storedModel = await _store.read(_modelKey);
    return _firstNonEmpty(storedApiKey, storedBaseUrl, storedModel).isEmpty;
  }

  Future<TranscriptionConfig?> _readLegacyConfig() async {
    for (final file in legacySettingsFiles ?? _defaultLegacySettingsFiles()) {
      if (!await file.exists()) {
        continue;
      }

      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) {
          continue;
        }

        return TranscriptionConfig(
          apiKey: _legacyString(decoded['apiKey']),
          baseUrl: _firstNonEmpty(
            _legacyString(decoded['baseUrl']),
            defaultOpenAiBaseUrl,
          ),
          model: _firstNonEmpty(
            _legacyString(decoded['model']),
            defaultOpenAiModel,
          ),
        );
      } catch (_) {
        continue;
      }
    }

    return null;
  }

  List<File> _defaultLegacySettingsFiles() {
    final explicitPath = _environment['STTAPP_LEGACY_SETTINGS_PATH'];
    final home = _environment['HOME'];
    final appData = _environment['APPDATA'];
    final xdgConfigHome = _environment['XDG_CONFIG_HOME'];
    final xdgDataHome = _environment['XDG_DATA_HOME'];

    final paths = <String>[
      if (explicitPath != null && explicitPath.trim().isNotEmpty) explicitPath,
      if (xdgConfigHome != null) '$xdgConfigHome/sttapp/settings.json',
      if (xdgConfigHome != null)
        '$xdgConfigHome/com.taresz.sttapp/settings.json',
      if (xdgDataHome != null) '$xdgDataHome/sttapp/settings.json',
      if (xdgDataHome != null) '$xdgDataHome/com.taresz.sttapp/settings.json',
      if (home != null) '$home/.config/sttapp/settings.json',
      if (home != null) '$home/.config/com.taresz.sttapp/settings.json',
      if (home != null) '$home/.local/share/sttapp/settings.json',
      if (home != null) '$home/.local/share/com.taresz.sttapp/settings.json',
      if (home != null)
        '$home/Library/Application Support/sttapp/settings.json',
      if (home != null)
        '$home/Library/Application Support/com.taresz.sttapp/settings.json',
      if (appData != null) '$appData/sttapp/settings.json',
      if (appData != null) '$appData/com.taresz.sttapp/settings.json',
    ];

    return paths.map(File.new).toList();
  }

  static String _firstNonEmpty(String? first, [String? second, String? third]) {
    for (final value in [first, second, third]) {
      final normalized = value?.trim();
      if (normalized != null && normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  static String _legacyString(Object? value) {
    return value is String ? value.trim() : '';
  }
}

final class MemoryConfigStore implements ConfigStore {
  MemoryConfigStore([Map<String, String>? values]) : _values = values ?? {};

  final Map<String, String> _values;

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}
