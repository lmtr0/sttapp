import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sttapp/services/config_repository.dart';

void main() {
  test('secure config store can be constructed without touching native storage', () {
    expect(SecureConfigStore(), isA<SecureConfigStore>());
  });

  test('normalizes base URL and validates required fields', () {
    final config = TranscriptionConfig(
      apiKey: ' key ',
      baseUrl: ' https://example.test/v1/// ',
      model: ' whisper-1 ',
    );

    expect(config.apiKey, 'key');
    expect(config.baseUrl, 'https://example.test/v1');
    expect(config.model, 'whisper-1');
    expect(
      config.transcriptionsUri.toString(),
      'https://example.test/v1/audio/transcriptions',
    );
    expect(config.modelsUri.toString(), 'https://example.test/v1/models');
    expect(config.validate, returnsNormally);
  });

  test('endpoint validation does not require a model', () {
    final config = TranscriptionConfig(
      apiKey: 'key',
      baseUrl: 'https://example.test/v1',
      model: '',
    );

    expect(config.validateEndpoint, returnsNormally);
    expect(config.validate, throwsA(isA<ConfigException>()));
  });

  test('loads environment fallback when secure storage is empty', () async {
    final repository = ConfigRepository(
      store: MemoryConfigStore(),
      environment: const {
        'OPENAI_API_KEY': 'env-key',
        'OPENAI_BASE_URL': 'https://env.example/v1/',
        'OPENAI_MODEL': 'env-model',
      },
    );

    final config = await repository.load();

    expect(config.apiKey, 'env-key');
    expect(config.baseUrl, 'https://env.example/v1');
    expect(config.model, 'env-model');
  });

  test('uses base URL default and empty model when model is unset', () async {
    final repository = ConfigRepository(
      store: MemoryConfigStore(),
      environment: const {'OPENAI_API_KEY': 'env-key'},
    );

    final config = await repository.load();

    expect(config.baseUrl, defaultOpenAiBaseUrl);
    expect(config.model, '');
  });

  test('stored values override environment fallback', () async {
    final store = MemoryConfigStore({
      'openai_api_key': 'stored-key',
      'openai_base_url': 'https://stored.example/v1',
      'openai_model': 'stored-model',
    });
    final repository = ConfigRepository(
      store: store,
      environment: const {
        'OPENAI_API_KEY': 'env-key',
        'OPENAI_BASE_URL': 'https://env.example/v1',
        'OPENAI_MODEL': 'env-model',
      },
    );

    final config = await repository.load();

    expect(config.apiKey, 'stored-key');
    expect(config.baseUrl, 'https://stored.example/v1');
    expect(config.model, 'stored-model');
  });

  test('loads default shortcut when storage is empty', () async {
    final repository = ConfigRepository(
      store: MemoryConfigStore(),
      environment: const {},
    );

    final config = await repository.loadShortcutConfig();

    expect(config.keyId, defaultShortcutKeyId);
    expect(config.normalLabel, 'F8');
    expect(config.plainLabel, 'Shift+F8');
  });

  test('loads stored shortcut and falls back from unknown keys', () async {
    final repository = ConfigRepository(
      store: MemoryConfigStore({'shortcut_key_id': 'f6'}),
      environment: const {},
    );
    final invalidRepository = ConfigRepository(
      store: MemoryConfigStore({'shortcut_key_id': 'space'}),
      environment: const {},
    );

    expect((await repository.loadShortcutConfig()).keyId, 'f6');
    expect(
      (await invalidRepository.loadShortcutConfig()).keyId,
      defaultShortcutKeyId,
    );
  });

  test('saves shortcut config', () async {
    final store = MemoryConfigStore();
    final repository = ConfigRepository(store: store, environment: const {});

    await repository.saveShortcutConfig(ShortcutConfig(keyId: 'f10'));

    expect(await store.read('shortcut_key_id'), 'f10');
  });

  test('migrates legacy Tauri config when Flutter config is empty', () async {
    final directory = await Directory.systemTemp.createTemp('sttapp-test-');
    addTearDown(() => directory.delete(recursive: true));
    final legacyFile = File('${directory.path}/settings.json');
    await legacyFile.writeAsString(
      '{"apiKey":"legacy-key","baseUrl":"https://legacy.example/v1/","model":"legacy-model"}',
    );
    final store = MemoryConfigStore();
    final repository = ConfigRepository(
      store: store,
      environment: const {},
      legacySettingsFiles: [legacyFile],
    );

    final config = await repository.load();

    expect(config.apiKey, 'legacy-key');
    expect(config.baseUrl, 'https://legacy.example/v1');
    expect(config.model, 'legacy-model');
    expect(await store.read('openai_api_key'), 'legacy-key');
  });

  test('does not migrate legacy Tauri config over Flutter config', () async {
    final directory = await Directory.systemTemp.createTemp('sttapp-test-');
    addTearDown(() => directory.delete(recursive: true));
    final legacyFile = File('${directory.path}/settings.json');
    await legacyFile.writeAsString(
      '{"apiKey":"legacy-key","baseUrl":"https://legacy.example/v1","model":"legacy-model"}',
    );
    final repository = ConfigRepository(
      store: MemoryConfigStore({
        'openai_api_key': 'stored-key',
        'openai_base_url': 'https://stored.example/v1',
        'openai_model': 'stored-model',
      }),
      environment: const {},
      legacySettingsFiles: [legacyFile],
    );

    final config = await repository.load();

    expect(config.apiKey, 'stored-key');
    expect(config.baseUrl, 'https://stored.example/v1');
    expect(config.model, 'stored-model');
  });
}
