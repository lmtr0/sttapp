import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sttapp_secret_storage/sttapp_secret_storage.dart';

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
  SecureConfigStore([SttappSecretStorage? storage])
    : _storage = storage ?? const SttappSecretStorage();

  final SttappSecretStorage _storage;

  @override
  Future<String?> read(String key) {
    return _storage.read(key: key);
  }

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
  static const _configKey = 'manual_transcription_config_v1';
  static const _shortcutKeyIdKey = 'shortcut_key_id';

  final ConfigStore _store;
  final Map<String, String> _environment;
  final List<File>? legacySettingsFiles;

  ConfigStore get store => _store;

  Future<TranscriptionConfig> load() async {
    await migrateLegacyTauriConfigIfNeeded();

    final atomicConfig = await _loadAtomicConfig();
    if (atomicConfig != null) {
      return atomicConfig;
    }

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
    await _store.write(
      _configKey,
      jsonEncode({
        'api_key': config.apiKey,
        'base_url': config.baseUrl,
        'model': config.model,
      }),
    );
    // Keep the pre-v1 keys synchronized for downgrade compatibility. The
    // single item above is authoritative, so a failed compatibility write
    // cannot leave a partially updated configuration active.
    for (final entry in {
      _apiKeyKey: config.apiKey,
      _baseUrlKey: config.baseUrl,
      _modelKey: config.model,
    }.entries) {
      try {
        await _store.write(entry.key, entry.value);
      } catch (_) {
        // The atomic record has already been saved successfully.
      }
    }
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
    if (await _loadAtomicConfig() != null) {
      return false;
    }
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

  Future<TranscriptionConfig?> _loadAtomicConfig() async {
    final encoded = (await _store.read(_configKey))?.trim() ?? '';
    if (encoded.isEmpty) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic>) return null;
      final apiKey = value['api_key'];
      final baseUrl = value['base_url'];
      final model = value['model'];
      if (apiKey is! String || baseUrl is! String || model is! String) {
        return null;
      }
      return TranscriptionConfig(
        apiKey: apiKey,
        baseUrl: baseUrl,
        model: model,
      );
    } catch (_) {
      return null;
    }
  }
}

enum TranscriptionProviderMode { unset, hosted, manual }

enum SetupDraftStep { choose, hosted, manual, permissions, ready }

final class ProviderSetupState {
  const ProviderSetupState({
    required this.providerMode,
    required this.draftStep,
    required this.hostedModel,
    required this.completedVersion,
  });

  static const currentVersion = 1;
  final TranscriptionProviderMode providerMode;
  final SetupDraftStep draftStep;
  final String? hostedModel;
  final int? completedVersion;

  bool get isComplete =>
      completedVersion == currentVersion &&
      providerMode != TranscriptionProviderMode.unset &&
      (providerMode != TranscriptionProviderMode.hosted ||
          (hostedModel != null && hostedModel!.isNotEmpty));

  ProviderSetupState copyWith({
    TranscriptionProviderMode? providerMode,
    SetupDraftStep? draftStep,
    String? hostedModel,
    int? completedVersion,
    bool clearCompletedVersion = false,
  }) => ProviderSetupState(
    providerMode: providerMode ?? this.providerMode,
    draftStep: draftStep ?? this.draftStep,
    hostedModel: hostedModel ?? this.hostedModel,
    completedVersion: clearCompletedVersion
        ? null
        : completedVersion ?? this.completedVersion,
  );
}

final class ProviderSetupRepository {
  ProviderSetupRepository(this._store);

  static const _modeKey = 'provider_mode';
  static const _draftStepKey = 'setup_draft_step';
  static const _completedVersionKey = 'setup_version_completed';
  static const _hostedModelKey = 'hosted_model';
  static const _stateKey = 'provider_setup_state_v1';
  final ConfigStore _store;

  Future<ProviderSetupState> load({required TranscriptionConfig manual}) async {
    final atomicState = await _loadAtomicState();
    final mode =
        atomicState?.providerMode ?? _parseMode(await _store.read(_modeKey));
    final version =
        atomicState?.completedVersion ??
        int.tryParse((await _store.read(_completedVersionKey)) ?? '');
    if (mode == TranscriptionProviderMode.unset && manual.isComplete) {
      final migrated = const ProviderSetupState(
        providerMode: TranscriptionProviderMode.manual,
        draftStep: SetupDraftStep.ready,
        hostedModel: null,
        completedVersion: ProviderSetupState.currentVersion,
      );
      await save(migrated);
      return migrated;
    }
    if (mode == TranscriptionProviderMode.unset) {
      final fresh = const ProviderSetupState(
        providerMode: TranscriptionProviderMode.hosted,
        draftStep: SetupDraftStep.hosted,
        hostedModel: null,
        completedVersion: null,
      );
      await save(fresh);
      return fresh;
    }
    if (atomicState != null) return atomicState;
    return ProviderSetupState(
      providerMode: mode,
      draftStep: _parseStep(await _store.read(_draftStepKey)),
      hostedModel: _nonEmpty(await _store.read(_hostedModelKey)),
      completedVersion: version,
    );
  }

  Future<void> save(ProviderSetupState state) async {
    await _store.write(
      _stateKey,
      jsonEncode({
        'provider_mode': state.providerMode.name,
        'draft_step': state.draftStep.name,
        'hosted_model': state.hostedModel,
        'completed_version': state.completedVersion,
      }),
    );
    // Mirror the previous format for downgrade compatibility. The JSON record
    // is authoritative after the first successful write.
    for (final entry in {
      _modeKey: state.providerMode.name,
      _draftStepKey: state.draftStep.name,
      _hostedModelKey: state.hostedModel ?? '',
      _completedVersionKey: state.completedVersion?.toString() ?? '',
    }.entries) {
      try {
        await _store.write(entry.key, entry.value);
      } catch (_) {
        // The atomic record has already been saved successfully.
      }
    }
  }

  Future<ProviderSetupState> complete({
    required TranscriptionProviderMode mode,
    String? hostedModel,
    bool hostedAuthenticated = false,
    Iterable<String> enabledHostedModels = const [],
    TranscriptionConfig? manualConfig,
  }) async {
    if (mode == TranscriptionProviderMode.unset) {
      throw const ConfigException('A transcription provider is required.');
    }
    if (mode == TranscriptionProviderMode.hosted &&
        (hostedModel == null || hostedModel.trim().isEmpty)) {
      throw const ConfigException('A hosted model is required.');
    }
    if (mode == TranscriptionProviderMode.hosted && !hostedAuthenticated) {
      throw const ConfigException('Hosted sign-in is required.');
    }
    if (mode == TranscriptionProviderMode.hosted &&
        !enabledHostedModels.contains(hostedModel!.trim())) {
      throw const ConfigException('The hosted model is not enabled.');
    }
    if (mode == TranscriptionProviderMode.manual) {
      if (manualConfig == null) {
        throw const ConfigException('Manual provider settings are required.');
      }
      manualConfig.validate();
    }
    final state = ProviderSetupState(
      providerMode: mode,
      draftStep: SetupDraftStep.ready,
      hostedModel: _nonEmpty(hostedModel),
      completedVersion: ProviderSetupState.currentVersion,
    );
    await save(state);
    return state;
  }

  static TranscriptionProviderMode _parseMode(String? value) =>
      TranscriptionProviderMode.values.firstWhere(
        (item) => item.name == value,
        orElse: () => TranscriptionProviderMode.unset,
      );

  static SetupDraftStep _parseStep(String? value) =>
      SetupDraftStep.values.firstWhere(
        (item) => item.name == value,
        orElse: () => SetupDraftStep.choose,
      );

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  Future<ProviderSetupState?> _loadAtomicState() async {
    final encoded = (await _store.read(_stateKey))?.trim() ?? '';
    if (encoded.isEmpty) return null;
    try {
      final value = jsonDecode(encoded);
      if (value is! Map<String, dynamic>) return null;
      final rawMode = value['provider_mode'];
      final rawStep = value['draft_step'];
      final rawModel = value['hosted_model'];
      final rawVersion = value['completed_version'];
      if (rawMode is! String ||
          rawStep is! String ||
          (rawModel != null && rawModel is! String) ||
          (rawVersion != null && rawVersion is! int)) {
        return null;
      }
      final mode = _parseMode(rawMode);
      if (mode == TranscriptionProviderMode.unset &&
          rawMode != TranscriptionProviderMode.unset.name) {
        return null;
      }
      final step = _parseStep(rawStep);
      if (step == SetupDraftStep.choose &&
          rawStep != SetupDraftStep.choose.name) {
        return null;
      }
      return ProviderSetupState(
        providerMode: mode,
        draftStep: step,
        hostedModel: _nonEmpty(rawModel as String?),
        completedVersion: rawVersion as int?,
      );
    } catch (_) {
      return null;
    }
  }
}

final class HostedCredentials {
  const HostedCredentials({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.sessionId,
  });

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final String sessionId;

  bool expiresSoon(DateTime now) =>
      accessTokenExpiresAt.isBefore(now.add(const Duration(seconds: 60)));
}

final class HostedCredentialRepository {
  HostedCredentialRepository(this._store);

  static const _accessKey = 'hosted_access_token';
  static const _accessExpiryKey = 'hosted_access_token_expires_at';
  static const _refreshKey = 'hosted_refresh_token';
  static const _sessionKey = 'hosted_session_id';
  static const _credentialsKey = 'hosted_credentials_v1';
  final ConfigStore _store;

  Future<HostedCredentials?> load() async {
    final encoded = (await _store.read(_credentialsKey))?.trim() ?? '';
    if (encoded.isNotEmpty) {
      try {
        final value = jsonDecode(encoded);
        if (value is Map<String, dynamic>) {
          if (value['cleared'] == true) return null;
          final access = value['access_token'];
          final refresh = value['refresh_token'];
          final session = value['session_id'];
          final expiry = DateTime.tryParse(
            value['access_token_expires_at'] is String
                ? value['access_token_expires_at'] as String
                : '',
          );
          if (access is String &&
              access.isNotEmpty &&
              refresh is String &&
              refresh.isNotEmpty &&
              session is String &&
              session.isNotEmpty &&
              expiry != null) {
            return HostedCredentials(
              accessToken: access,
              accessTokenExpiresAt: expiry.toUtc(),
              refreshToken: refresh,
              sessionId: session,
            );
          }
        }
      } catch (_) {
        // Fall through to the legacy multi-key format for one-time migration.
      }
    }
    final access = (await _store.read(_accessKey))?.trim() ?? '';
    final refresh = (await _store.read(_refreshKey))?.trim() ?? '';
    final session = (await _store.read(_sessionKey))?.trim() ?? '';
    final expiry = DateTime.tryParse(
      (await _store.read(_accessExpiryKey)) ?? '',
    );
    if (access.isEmpty ||
        refresh.isEmpty ||
        session.isEmpty ||
        expiry == null) {
      return null;
    }
    final credentials = HostedCredentials(
      accessToken: access,
      accessTokenExpiresAt: expiry.toUtc(),
      refreshToken: refresh,
      sessionId: session,
    );
    await save(credentials);
    return credentials;
  }

  Future<void> save(HostedCredentials credentials) async {
    await _store.write(
      _credentialsKey,
      jsonEncode({
        'access_token': credentials.accessToken,
        'access_token_expires_at': credentials.accessTokenExpiresAt
            .toUtc()
            .toIso8601String(),
        'refresh_token': credentials.refreshToken,
        'session_id': credentials.sessionId,
      }),
    );
    await _clearLegacyKeys();
  }

  Future<void> clear() async {
    await _store.write(_credentialsKey, jsonEncode({'cleared': true}));
    await _clearLegacyKeys();
  }

  Future<void> _clearLegacyKeys() async {
    for (final key in [
      _accessKey,
      _accessExpiryKey,
      _refreshKey,
      _sessionKey,
    ]) {
      try {
        await _store.write(key, '');
      } catch (_) {
        // The single credentials item is authoritative after migration/clear.
      }
    }
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
