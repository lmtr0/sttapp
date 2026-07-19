import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sttapp/services/config_repository.dart';

void main() {
  test(
    'secure config store can be constructed without touching native storage',
    () {
      expect(SecureConfigStore(), isA<SecureConfigStore>());
    },
  );

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

  test(
    'manual config save is atomic when legacy compatibility writes fail',
    () async {
      final store = _SelectiveFailureStore({
        'openai_api_key',
        'openai_base_url',
        'openai_model',
      });
      final repository = ConfigRepository(store: store, environment: const {});
      final expected = TranscriptionConfig(
        apiKey: 'atomic-key',
        baseUrl: 'https://atomic.example/v1',
        model: 'atomic-model',
      );

      await repository.save(expected);
      final loaded = await repository.load();

      expect(loaded.apiKey, expected.apiKey);
      expect(loaded.baseUrl, expected.baseUrl);
      expect(loaded.model, expected.model);
    },
  );

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

  test(
    'valid legacy manual config migrates to completed manual mode',
    () async {
      final store = MemoryConfigStore();
      final setup = ProviderSetupRepository(store);
      final state = await setup.load(
        manual: TranscriptionConfig(
          apiKey: 'key',
          baseUrl: 'https://manual.example/v1',
          model: 'whisper',
        ),
      );

      expect(state.providerMode, TranscriptionProviderMode.manual);
      expect(state.isComplete, isTrue);
      expect(await store.read('provider_mode'), 'manual');
    },
  );

  test(
    'fresh setup defaults to incomplete hosted and completion requires a model',
    () async {
      final store = MemoryConfigStore();
      final setup = ProviderSetupRepository(store);
      final state = await setup.load(
        manual: TranscriptionConfig(
          apiKey: '',
          baseUrl: defaultOpenAiBaseUrl,
          model: '',
        ),
      );

      expect(state.providerMode, TranscriptionProviderMode.hosted);
      expect(state.draftStep, SetupDraftStep.hosted);
      expect(state.isComplete, isFalse);
      expect(await store.read('provider_mode'), 'hosted');
      await expectLater(
        setup.complete(mode: TranscriptionProviderMode.hosted),
        throwsA(isA<ConfigException>()),
      );
      await expectLater(
        setup.complete(
          mode: TranscriptionProviderMode.hosted,
          hostedModel: 'enabled-model',
        ),
        throwsA(isA<ConfigException>()),
      );
      await expectLater(
        setup.complete(
          mode: TranscriptionProviderMode.hosted,
          hostedModel: 'disabled-model',
          hostedAuthenticated: true,
          enabledHostedModels: const ['enabled-model'],
        ),
        throwsA(isA<ConfigException>()),
      );
      await expectLater(
        setup.complete(mode: TranscriptionProviderMode.manual),
        throwsA(isA<ConfigException>()),
      );
    },
  );

  test(
    'incomplete legacy manual fields do not override the hosted default',
    () async {
      final store = MemoryConfigStore({'openai_api_key': 'partial-key'});
      final state = await ProviderSetupRepository(store).load(
        manual: TranscriptionConfig(
          apiKey: 'partial-key',
          baseUrl: defaultOpenAiBaseUrl,
          model: '',
        ),
      );

      expect(state.providerMode, TranscriptionProviderMode.hosted);
      expect(state.isComplete, isFalse);
    },
  );

  test(
    'an existing incomplete manual selection is never flipped to hosted',
    () async {
      final store = MemoryConfigStore({
        'provider_mode': 'manual',
        'setup_draft_step': 'manual',
        'setup_version_completed': '',
      });
      final state = await ProviderSetupRepository(store).load(
        manual: TranscriptionConfig(
          apiKey: '',
          baseUrl: defaultOpenAiBaseUrl,
          model: '',
        ),
      );

      expect(state.providerMode, TranscriptionProviderMode.manual);
      expect(state.isComplete, isFalse);
    },
  );

  test('provider setup save is atomic when legacy mirrors fail', () async {
    final store = _SelectiveFailureStore({
      'provider_mode',
      'setup_draft_step',
      'setup_version_completed',
      'hosted_model',
    });
    final repository = ProviderSetupRepository(store);
    await repository.complete(
      mode: TranscriptionProviderMode.manual,
      manualConfig: TranscriptionConfig(
        apiKey: 'key',
        baseUrl: 'https://manual.example/v1',
        model: 'model',
      ),
    );

    final loaded = await repository.load(
      manual: TranscriptionConfig(
        apiKey: 'key',
        baseUrl: 'https://manual.example/v1',
        model: 'model',
      ),
    );
    expect(loaded.providerMode, TranscriptionProviderMode.manual);
    expect(loaded.isComplete, isTrue);
  });

  test('hosted credentials use distinct keys and clear atomically', () async {
    final store = MemoryConfigStore({'openai_api_key': 'manual-secret'});
    final repository = HostedCredentialRepository(store);
    final credentials = HostedCredentials(
      accessToken: 'access',
      accessTokenExpiresAt: DateTime.utc(2030),
      refreshToken: 'refresh',
      sessionId: 'session',
    );

    await repository.save(credentials);
    expect((await repository.load())?.refreshToken, 'refresh');
    await repository.clear();
    expect(await repository.load(), isNull);
    expect(await store.read('openai_api_key'), 'manual-secret');
  });
}

final class _SelectiveFailureStore implements ConfigStore {
  _SelectiveFailureStore(this.failingKeys);

  final Set<String> failingKeys;
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (failingKeys.contains(key)) throw StateError('write failed for $key');
    values[key] = value;
  }
}
