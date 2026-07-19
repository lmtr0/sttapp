import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/desktop_auth_service.dart';
import 'package:sttapp/services/desktop_permission_service.dart';
import 'package:sttapp/services/hosted_backend_client.dart';
import 'package:sttapp/services/hotkey_service.dart';
import 'package:sttapp/services/startup_error_tracker.dart';
import 'package:sttapp/services/transcript_delivery_service.dart';
import 'package:sttapp/services/transcription_service.dart';
import 'package:sttapp/services/transcription_coordinator.dart';
import 'package:sttapp/services/update_service.dart';
import 'package:sttapp_audio/sttapp_audio.dart';
import 'package:sttapp_input/sttapp_input.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

const _recorderWindowSize = Size(400, 120);
const _settingsWindowSize = Size(520, 720);
const _trayDefaultPng = 'assets/tray/tray_default.png';
const _trayRecordingPng = 'assets/tray/tray_recording.png';
const _trayDefaultIco = 'assets/tray/tray_default.ico';
const _trayRecordingIco = 'assets/tray/tray_recording.ico';
const _customModelValue = '__custom__';
const _compiledReleaseTag = String.fromEnvironment('STTAPP_RELEASE_TAG');
const _compiledFakeLatestTag = String.fromEnvironment('STTAPP_FAKE_LATEST_TAG');

typedef ReleaseLauncher = Future<bool> Function(Uri uri);

Future<bool> _launchRelease(Uri uri) {
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> main() {
  return StartupErrorTracker.runGuarded(_main);
}

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);

  const windowOptions = WindowOptions(
    size: _recorderWindowSize,
    minimumSize: _recorderWindowSize,
    maximumSize: _recorderWindowSize,
    alwaysOnTop: true,
    backgroundColor: Colors.transparent,
    title: 'sttapp',
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.hide();
  });

  runApp(const SttApp());
}

class SttApp extends StatelessWidget {
  const SttApp({
    super.key,
    this.configRepository,
    this.transcriptionService,
    this.hostedBackendClient,
    this.hostedCredentialRepository,
    this.hostedSessionManager,
    this.desktopAuthenticator,
    this.providerSetupRepository,
    this.transcriptionCoordinator,
    this.transcriptDeliveryService,
    this.hotkeyService,
    this.desktopPermissionService,
    this.updateService,
    this.releaseLauncher,
    this.releaseTag,
    this.fakeLatestTag,
    this.supportsShortcutSettings,
    this.initializePlatformServices = true,
  });

  final ConfigRepository? configRepository;
  final TranscriptionService? transcriptionService;
  final HostedBackendClient? hostedBackendClient;
  final HostedCredentialRepository? hostedCredentialRepository;
  final HostedSessionManager? hostedSessionManager;
  final DesktopAuthenticator? desktopAuthenticator;
  final ProviderSetupRepository? providerSetupRepository;
  final TranscriptionCoordinator? transcriptionCoordinator;
  final TranscriptDeliveryService? transcriptDeliveryService;
  final HotkeyService? hotkeyService;
  final DesktopPermissionService? desktopPermissionService;
  final UpdateService? updateService;
  final ReleaseLauncher? releaseLauncher;
  final String? releaseTag;
  final String? fakeLatestTag;
  final bool? supportsShortcutSettings;
  final bool initializePlatformServices;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'sttapp',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1967D2)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1967D2),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: RecorderHome(
        configRepository: configRepository,
        transcriptionService: transcriptionService,
        hostedBackendClient: hostedBackendClient,
        hostedCredentialRepository: hostedCredentialRepository,
        hostedSessionManager: hostedSessionManager,
        desktopAuthenticator: desktopAuthenticator,
        providerSetupRepository: providerSetupRepository,
        transcriptionCoordinator: transcriptionCoordinator,
        transcriptDeliveryService: transcriptDeliveryService,
        hotkeyService: hotkeyService,
        desktopPermissionService: desktopPermissionService,
        updateService: updateService,
        releaseLauncher: releaseLauncher,
        releaseTag: releaseTag,
        fakeLatestTag: fakeLatestTag,
        supportsShortcutSettings: supportsShortcutSettings,
        initializePlatformServices: initializePlatformServices,
      ),
    );
  }
}

class ShortcutRegistrationNotice extends StatelessWidget {
  const ShortcutRegistrationNotice({
    super.key,
    required this.checking,
    required this.message,
    required this.onRetry,
  });

  final bool checking;
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: checking
          ? colorScheme.surfaceContainerHighest
          : colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (checking)
                  const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    Icons.warning_amber,
                    color: colorScheme.onErrorContainer,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    checking
                        ? 'Registering global shortcuts…'
                        : 'Global shortcuts unavailable',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (!checking) ...[
              const SizedBox(height: 8),
              Text(
                message ??
                    'The operating system did not register every shortcut.',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: onRetry,
                  child: const Text('Retry registration'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class RecorderHome extends StatefulWidget {
  const RecorderHome({
    super.key,
    this.configRepository,
    this.transcriptionService,
    this.hostedBackendClient,
    this.hostedCredentialRepository,
    this.hostedSessionManager,
    this.desktopAuthenticator,
    this.providerSetupRepository,
    this.transcriptionCoordinator,
    this.transcriptDeliveryService,
    this.hotkeyService,
    this.desktopPermissionService,
    this.updateService,
    this.releaseLauncher,
    this.releaseTag,
    this.fakeLatestTag,
    this.supportsShortcutSettings,
    this.initializePlatformServices = true,
  });

  final ConfigRepository? configRepository;
  final TranscriptionService? transcriptionService;
  final HostedBackendClient? hostedBackendClient;
  final HostedCredentialRepository? hostedCredentialRepository;
  final HostedSessionManager? hostedSessionManager;
  final DesktopAuthenticator? desktopAuthenticator;
  final ProviderSetupRepository? providerSetupRepository;
  final TranscriptionCoordinator? transcriptionCoordinator;
  final TranscriptDeliveryService? transcriptDeliveryService;
  final HotkeyService? hotkeyService;
  final DesktopPermissionService? desktopPermissionService;
  final UpdateService? updateService;
  final ReleaseLauncher? releaseLauncher;
  final String? releaseTag;
  final String? fakeLatestTag;
  final bool? supportsShortcutSettings;
  final bool initializePlatformServices;

  @override
  State<RecorderHome> createState() => _RecorderHomeState();
}

enum RecorderState { ready, needsConfig, recording, transcribing, done, error }

enum ShortcutRegistrationState { idle, checking, registered, failed }

enum UpdateStatus {
  development,
  checking,
  latest,
  updateAvailable,
  unavailable,
}

class _RecorderHomeState extends State<RecorderHome>
    with TrayListener, WindowListener, WidgetsBindingObserver {
  late final AudioRecorder _recorder;
  late final ConfigRepository _configRepository;
  late final TranscriptionService _transcriptionService;
  late final HostedBackendClient _hostedBackendClient;
  late final HostedCredentialRepository _hostedCredentialRepository;
  late final HostedSessionManager _hostedSessionManager;
  late final DesktopAuthenticator _desktopAuthenticator;
  late final ProviderSetupRepository _providerSetupRepository;
  late final TranscriptionCoordinator _transcriptionCoordinator;
  late final TranscriptDeliveryService _transcriptDeliveryService;
  late final HotkeyService _hotkeyService;
  late final DesktopPermissionService _desktopPermissionService;
  late final UpdateService _updateService;
  late final ReleaseLauncher _releaseLauncher;
  late final bool _ownsTranscriptionService;
  late final bool _ownsHostedBackendClient;
  late final bool _ownsUpdateService;
  late final bool _supportsShortcutSettings;
  late final bool _initializePlatformServices;
  late final String _releaseTag;
  late final String _fakeLatestTag;

  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController(text: defaultOpenAiBaseUrl);
  final _modelController = TextEditingController(text: defaultOpenAiModel);

  AudioRecording? _recording;
  TranscriptionConfig? _config;
  ProviderSetupState _providerSetup = const ProviderSetupState(
    providerMode: TranscriptionProviderMode.hosted,
    draftStep: SetupDraftStep.hosted,
    hostedModel: null,
    completedVersion: null,
  );
  HostedAccount? _hostedAccount;
  List<String> _hostedModels = const [];
  ShortcutConfig _shortcutConfig = ShortcutConfig();
  RecorderState _state = RecorderState.ready;
  PasteMode _recordingPasteMode = PasteMode.normal;
  String? _lastTranscript;
  String? _lastError;
  String? _settingsStatus;
  String? _updateActionError;
  String _selectedModelValue = _customModelValue;
  List<String> _availableModels = const [];
  AvailableUpdate? _availableUpdate;
  UpdateStatus _updateStatus = UpdateStatus.development;
  String? _modelsLoadedForEndpoint;
  bool _showSettings = false;
  bool _showApiKey = false;
  bool _isTestingConnection = false;
  bool _isLoadingModels = false;
  bool _hasHostedCredentials = false;
  bool _isLoadingHosted = false;
  bool _isSigningIn = false;
  bool _isSwitchingProvider = false;
  bool _isOpeningBilling = false;
  String? _hostedStatus;
  bool _isQuitting = false;
  bool _isPermissionActionPending = false;
  bool _isRefreshingPermissions = false;
  bool _permissionStatusLoaded = false;
  bool _inputServicesInitialized = false;
  bool _inputServicesInitializing = false;
  bool _showUpdateWhenIdle = false;
  String? _permissionError;
  ShortcutRegistrationState _shortcutRegistrationState =
      ShortcutRegistrationState.idle;
  String? _shortcutRegistrationError;
  DesktopPermissionSnapshot _permissionStatus =
      const DesktopPermissionSnapshot.authorized();

  bool get _isRecording => _recording != null;

  bool get _isTranscribing => _state == RecorderState.transcribing;

  bool get _canStart => !_isRecording && !_isTranscribing;

  bool get _providerReady {
    switch (_providerSetup.providerMode) {
      case TranscriptionProviderMode.manual:
        return _providerSetup.isComplete && _config?.isComplete == true;
      case TranscriptionProviderMode.hosted:
        final model = _providerSetup.hostedModel;
        return _providerSetup.isComplete &&
            _hasHostedCredentials &&
            _hostedAccount?.hostedAvailable == true &&
            model != null &&
            _hostedModels.contains(model);
      case TranscriptionProviderMode.unset:
        return false;
    }
  }

  bool get _requiresDesktopPermissions =>
      _desktopPermissionService.requiresAuthorization;

  bool get _permissionsAuthorized =>
      !_requiresDesktopPermissions || _permissionStatus.isAuthorized;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _recorder = AudioRecorder();
    _configRepository = widget.configRepository ?? ConfigRepository();
    final injectedCoordinator = widget.transcriptionCoordinator;
    final injectedSession =
        widget.hostedSessionManager ?? injectedCoordinator?.hostedSession;
    _transcriptionService =
        widget.transcriptionService ??
        injectedCoordinator?.manual ??
        TranscriptionService();
    _hostedBackendClient =
        widget.hostedBackendClient ??
        injectedSession?.client ??
        injectedCoordinator?.hosted ??
        HostedBackendClient();
    _hostedCredentialRepository =
        widget.hostedCredentialRepository ??
        injectedSession?.credentials ??
        HostedCredentialRepository(_configRepository.store);
    _hostedSessionManager =
        injectedSession ??
        HostedSessionManager(
          client: _hostedBackendClient,
          credentials: _hostedCredentialRepository,
        );
    _desktopAuthenticator =
        widget.desktopAuthenticator ??
        DesktopAuthService(
          client: _hostedBackendClient,
          launchBrowser: _launchRelease,
        );
    _providerSetupRepository =
        widget.providerSetupRepository ??
        ProviderSetupRepository(_configRepository.store);
    _transcriptionCoordinator =
        injectedCoordinator ??
        TranscriptionCoordinator(
          manual: _transcriptionService,
          hosted: _hostedBackendClient,
          hostedSession: _hostedSessionManager,
        );
    _transcriptDeliveryService =
        widget.transcriptDeliveryService ?? const TranscriptDeliveryService();
    _hotkeyService = widget.hotkeyService ?? HotkeyService();
    _desktopPermissionService =
        widget.desktopPermissionService ??
        (widget.initializePlatformServices
            ? defaultDesktopPermissionService()
            : const PermissiveDesktopPermissionService());
    _updateService = widget.updateService ?? UpdateService();
    _releaseLauncher = widget.releaseLauncher ?? _launchRelease;
    _releaseTag = (widget.releaseTag ?? _compiledReleaseTag).trim();
    _fakeLatestTag = kDebugMode
        ? (widget.fakeLatestTag ?? _compiledFakeLatestTag).trim()
        : '';
    _updateStatus = _releaseTag.isEmpty
        ? UpdateStatus.development
        : UpdateStatus.checking;
    if (_desktopPermissionService.requiresAuthorization) {
      _permissionStatus = const DesktopPermissionSnapshot.unavailable();
    }
    _ownsTranscriptionService =
        widget.transcriptionService == null && injectedCoordinator == null;
    _ownsHostedBackendClient =
        widget.hostedBackendClient == null &&
        injectedSession == null &&
        injectedCoordinator == null;
    _ownsUpdateService = widget.updateService == null;
    _supportsShortcutSettings =
        widget.supportsShortcutSettings ?? !Platform.isLinux;
    _initializePlatformServices = widget.initializePlatformServices;
    if (_initializePlatformServices) {
      trayManager.addListener(this);
      windowManager.addListener(this);
    }
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_initializePlatformServices) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    unawaited(_hotkeyService.dispose());
    if (_ownsTranscriptionService) {
      _transcriptionService.close();
    }
    unawaited(_desktopAuthenticator.cancel());
    if (_ownsHostedBackendClient) {
      _hostedBackendClient.close();
    }
    if (_ownsUpdateService) {
      _updateService.close();
    }
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_initializePlatformServices) {
      await _initTray();
    }
    await _loadConfig();
    unawaited(_checkForUpdates());
    if (_requiresDesktopPermissions) {
      await _refreshPermissionStatus(showWindowWhenMissing: true);
      if (!_permissionsAuthorized) {
        return;
      }
    }
    if (!_initializePlatformServices) {
      return;
    }
    await _initializeInputServices();
  }

  Future<void> _initializeInputServices() async {
    if (_inputServicesInitialized ||
        _inputServicesInitializing ||
        !_permissionsAuthorized) {
      return;
    }
    _inputServicesInitializing = true;
    try {
      await _transcriptDeliveryService.preparePaste();
      await _registerHotkeys();
      _inputServicesInitialized = true;
      await _refreshTrayMenu();
    } catch (error) {
      _inputServicesInitialized = false;
      final message =
          _shortcutRegistrationError ??
          'Failed to initialize desktop input: $error';
      StartupErrorTracker.recordError(
        'Desktop input initialization failed',
        error,
      );
      if (mounted) {
        setState(() {
          _showSettings = true;
          _state = RecorderState.error;
          _lastError = message;
        });
        await _refreshTrayMenu();
        await _showSettingsWindow();
      }
    } finally {
      _inputServicesInitializing = false;
    }
  }

  Future<void> _registerHotkeys() async {
    if (mounted) {
      setState(() {
        _shortcutRegistrationState = ShortcutRegistrationState.checking;
        _shortcutRegistrationError = null;
      });
    }
    StartupErrorTracker.recordEvent(
      'Global shortcut registration begin: '
      '${_shortcutConfig.normalLabel}, ${_shortcutConfig.plainLabel}',
    );

    try {
      final registration = await _hotkeyService.initialize(
        shortcutConfig: _shortcutConfig,
        onToggle: (mode) {
          StartupErrorTracker.recordEvent(
            'Global shortcut activated: ${mode.name}',
          );
          unawaited(_toggleCapture(mode));
        },
        onError: _handleShortcutServiceError,
      );
      StartupErrorTracker.recordEvent(
        'Global shortcut registration succeeded: '
        '${registration.shortcutIds.join(', ')}',
      );
      if (mounted) {
        setState(() {
          _shortcutRegistrationState = ShortcutRegistrationState.registered;
          _shortcutRegistrationError = null;
        });
      }
    } catch (error, stackTrace) {
      final message = _shortcutFailureMessage(error);
      StartupErrorTracker.recordError(
        'Global shortcut registration failed',
        error,
        stackTrace,
      );
      if (mounted) {
        setState(() {
          _shortcutRegistrationState = ShortcutRegistrationState.failed;
          _shortcutRegistrationError = message;
        });
      }
      rethrow;
    }
  }

  void _handleShortcutServiceError(Object error) {
    final message = 'Global shortcut service stopped: $error';
    StartupErrorTracker.recordError('Global shortcut service error', error);
    if (!mounted) {
      return;
    }
    setState(() {
      _inputServicesInitialized = false;
      _shortcutRegistrationState = ShortcutRegistrationState.failed;
      _shortcutRegistrationError = message;
      _showSettings = true;
      _state = RecorderState.error;
      _lastError = message;
    });
    unawaited(_refreshTrayMenu());
    unawaited(_showSettingsWindow());
  }

  String _shortcutFailureMessage(Object error) {
    if (error is HotkeyRegistrationException) {
      final shortcut = switch (error.shortcutId) {
        'toggle-normal' => _shortcutConfig.normalLabel,
        'toggle-plain' => _shortcutConfig.plainLabel,
        _ => null,
      };
      final prefix = shortcut == null
          ? 'Global shortcuts are unavailable.'
          : 'Could not register $shortcut.';
      return '$prefix ${error.message}';
    }
    return 'Global shortcuts are unavailable. $error';
  }

  Future<void> _retryShortcutRegistration() async {
    if (_inputServicesInitializing || !_permissionsAuthorized) {
      return;
    }
    _inputServicesInitialized = false;
    await _initializeInputServices();
    if (!mounted || !_inputServicesInitialized) {
      return;
    }
    setState(() {
      _state = _providerReady ? RecorderState.ready : RecorderState.needsConfig;
      _lastError = null;
      _showSettings = !_providerReady;
    });
    await _hideWindowAfterCapture();
  }

  Future<void> _loadConfig() async {
    try {
      final config = await _configRepository.load();
      final shortcutConfig = await _configRepository.loadShortcutConfig();
      await _hostedSessionManager.initialize();
      var setup = await _providerSetupRepository.load(manual: config);
      var hasHostedCredentials =
          await _hostedCredentialRepository.load() != null;
      HostedAccount? hostedAccount;
      List<String> hostedModels = const [];
      String? hostedStatus;
      if (hasHostedCredentials &&
          setup.providerMode == TranscriptionProviderMode.hosted) {
        try {
          hostedAccount = await _hostedSessionManager.authorized(
            _hostedBackendClient.account,
          );
          if (hostedAccount!.hostedAvailable) {
            hostedModels = await _hostedSessionManager.authorized(
              _hostedBackendClient.models,
            );
            final selected = _enabledHostedModel(
              setup.hostedModel,
              hostedModels,
            );
            if (selected != null) {
              setup = setup.providerMode == TranscriptionProviderMode.hosted
                  ? await _providerSetupRepository.complete(
                      mode: TranscriptionProviderMode.hosted,
                      hostedModel: selected,
                      hostedAuthenticated: hasHostedCredentials,
                      enabledHostedModels: hostedModels,
                    )
                  : setup.copyWith(hostedModel: selected);
              if (setup.providerMode != TranscriptionProviderMode.hosted) {
                await _providerSetupRepository.save(setup);
              }
            }
          }
        } on HostedApiException catch (error) {
          if (error.requiresSignIn || error.code == 'sign_in_required') {
            hasHostedCredentials = false;
          }
          hostedStatus = _hostedErrorMessage(error);
        } catch (_) {
          hostedStatus =
              'Could not reach sttapp Hosted. Check your connection and retry.';
        }
      }
      if (!mounted) {
        return;
      }
      _applyConfigToFields(config);
      String? configError;
      try {
        config.validate();
      } catch (error) {
        configError = error.toString();
      }
      final configIsValid = configError == null;
      final providerIsReady = switch (setup.providerMode) {
        TranscriptionProviderMode.manual => setup.isComplete && configIsValid,
        TranscriptionProviderMode.hosted =>
          setup.isComplete &&
              hasHostedCredentials &&
              hostedAccount?.hostedAvailable == true &&
              hostedModels.contains(setup.hostedModel),
        TranscriptionProviderMode.unset => false,
      };
      setState(() {
        _config = config;
        _providerSetup = setup;
        _hasHostedCredentials = hasHostedCredentials;
        _hostedAccount = hostedAccount;
        _hostedModels = hostedModels;
        _hostedStatus = hostedStatus;
        _shortcutConfig = shortcutConfig;
        _showSettings =
            !providerIsReady ||
            (_permissionStatusLoaded && !_permissionsAuthorized);
        _state = providerIsReady
            ? RecorderState.ready
            : RecorderState.needsConfig;
        _lastError = setup.providerMode == TranscriptionProviderMode.manual
            ? configError
            : null;
      });
      await _refreshTrayMenu();
      if (!providerIsReady ||
          (_permissionStatusLoaded && !_permissionsAuthorized)) {
        if (setup.providerMode == TranscriptionProviderMode.manual) {
          _refreshModelsIfPossible();
        }
        await _showSettingsWindow();
      }
    } catch (error) {
      _setError(error.toString());
    }
  }

  String? _enabledHostedModel(String? stored, List<String> enabled) {
    if (stored != null) {
      return enabled.contains(stored) ? stored : null;
    }
    if (enabled.contains('whisper-large-v3-turbo')) {
      return 'whisper-large-v3-turbo';
    }
    return enabled.firstOrNull;
  }

  String _hostedErrorMessage(Object error) {
    if (error is HostedApiException) {
      if (error.requiresSignIn || error.code == 'sign_in_required') {
        return 'Your session ended. Sign in again to continue.';
      }
      return error.message;
    }
    if (error is DesktopAuthException) {
      return error.message;
    }
    return 'Could not reach sttapp Hosted. Check your connection and retry.';
  }

  Future<void> _switchProvider(TranscriptionProviderMode mode) async {
    if (_isRecording ||
        _isTranscribing ||
        _isSwitchingProvider ||
        mode == _providerSetup.providerMode) {
      return;
    }
    setState(() {
      _isSwitchingProvider = true;
      _settingsStatus = null;
      _hostedStatus = null;
    });
    try {
      if (_isSigningIn) {
        await _desktopAuthenticator.cancel();
        if (!mounted) return;
        setState(() => _isSigningIn = false);
      }
      if (mode == TranscriptionProviderMode.manual) {
        final config = _config;
        var setup = config?.isComplete == true
            ? await _providerSetupRepository.complete(
                mode: TranscriptionProviderMode.manual,
                manualConfig: config,
              )
            : ProviderSetupState(
                providerMode: TranscriptionProviderMode.manual,
                draftStep: SetupDraftStep.manual,
                hostedModel: _providerSetup.hostedModel,
                completedVersion: null,
              );
        setup = setup.copyWith(hostedModel: _providerSetup.hostedModel);
        await _providerSetupRepository.save(setup);
        if (!mounted) return;
        setState(() {
          _providerSetup = setup;
          _state = setup.isComplete
              ? RecorderState.ready
              : RecorderState.needsConfig;
          _lastError = setup.isComplete ? null : 'Complete your API settings.';
        });
        _refreshModelsIfPossible();
      } else {
        var setup = ProviderSetupState(
          providerMode: TranscriptionProviderMode.hosted,
          draftStep: SetupDraftStep.hosted,
          hostedModel: _providerSetup.hostedModel,
          completedVersion: null,
        );
        final model = _enabledHostedModel(setup.hostedModel, _hostedModels);
        if (_hasHostedCredentials &&
            _hostedAccount?.hostedAvailable == true &&
            model != null) {
          setup = await _providerSetupRepository.complete(
            mode: TranscriptionProviderMode.hosted,
            hostedModel: model,
            hostedAuthenticated: _hasHostedCredentials,
            enabledHostedModels: _hostedModels,
          );
        } else {
          await _providerSetupRepository.save(setup);
        }
        if (!mounted) return;
        setState(() {
          _providerSetup = setup;
          _state = setup.isComplete
              ? RecorderState.ready
              : RecorderState.needsConfig;
          _lastError = null;
        });
        if (_hasHostedCredentials) {
          await _refreshHosted();
        }
      }
      await _refreshTrayMenu();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastError = 'Could not switch transcription providers: $error';
      });
    } finally {
      if (mounted) setState(() => _isSwitchingProvider = false);
    }
  }

  Future<void> _signInHosted() async {
    if (_isSigningIn) return;
    setState(() {
      _isSigningIn = true;
      _hostedStatus = 'Waiting for sign-in in your browser…';
      _lastError = null;
    });
    try {
      final credentials = await _desktopAuthenticator.signIn(
        deviceLabel: 'sttapp desktop',
      );
      await _hostedSessionManager.accept(credentials);
      if (!mounted) return;
      setState(() => _hasHostedCredentials = true);
      await _refreshHosted();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _hostedStatus = _hostedErrorMessage(error);
        if (_providerSetup.providerMode == TranscriptionProviderMode.hosted) {
          _state = _providerReady
              ? RecorderState.ready
              : RecorderState.needsConfig;
        }
      });
    } finally {
      if (mounted) {
        setState(() => _isSigningIn = false);
        await _refreshTrayMenu();
      }
    }
  }

  Future<void> _cancelHostedSignIn() async {
    if (!_isSigningIn) return;
    await _desktopAuthenticator.cancel();
    if (!mounted) return;
    setState(() {
      _isSigningIn = false;
      _hostedStatus = 'Sign-in canceled. You can try again when ready.';
    });
  }

  Future<void> _refreshHosted() async {
    if (_isLoadingHosted || !_hasHostedCredentials) return;
    setState(() {
      _isLoadingHosted = true;
      _hostedStatus = 'Refreshing account status…';
    });
    try {
      final account = await _hostedSessionManager.authorized(
        _hostedBackendClient.account,
      );
      final models = account.hostedAvailable
          ? await _hostedSessionManager.authorized(_hostedBackendClient.models)
          : <String>[];
      var setup = _providerSetup;
      final selected = _enabledHostedModel(setup.hostedModel, models);
      if (setup.providerMode == TranscriptionProviderMode.hosted &&
          selected != null) {
        setup = await _providerSetupRepository.complete(
          mode: TranscriptionProviderMode.hosted,
          hostedModel: selected,
          hostedAuthenticated: _hasHostedCredentials,
          enabledHostedModels: models,
        );
      } else if (selected != null && setup.hostedModel != selected) {
        setup = setup.copyWith(hostedModel: selected);
        await _providerSetupRepository.save(setup);
      } else if (setup.providerMode == TranscriptionProviderMode.hosted &&
          setup.isComplete) {
        setup = setup.copyWith(
          clearCompletedVersion: true,
          draftStep: SetupDraftStep.hosted,
        );
        await _providerSetupRepository.save(setup);
      }
      if (!mounted) return;
      setState(() {
        _hostedAccount = account;
        _hostedModels = models;
        _providerSetup = setup;
        _hostedStatus = account.hostedAvailable
            ? models.isEmpty
                  ? 'No hosted transcription models are currently available.'
                  : 'sttapp Hosted is ready.'
            : null;
        _state = _providerReady
            ? RecorderState.ready
            : RecorderState.needsConfig;
        _lastError = null;
      });
      await _refreshTrayMenu();
    } catch (error) {
      final requiresSignIn =
          error is HostedApiException &&
          (error.requiresSignIn || error.code == 'sign_in_required');
      if (!mounted) return;
      setState(() {
        if (requiresSignIn) {
          _hasHostedCredentials = false;
          _hostedAccount = null;
          _hostedModels = const [];
        }
        _hostedStatus = _hostedErrorMessage(error);
        if (_providerSetup.providerMode == TranscriptionProviderMode.hosted) {
          _state = _providerReady
              ? RecorderState.ready
              : RecorderState.needsConfig;
        }
      });
    } finally {
      if (mounted) {
        setState(() => _isLoadingHosted = false);
        await _refreshTrayMenu();
      }
    }
  }

  Future<void> _selectHostedModel(String model) async {
    if (!_hostedModels.contains(model)) return;
    final setup = await _providerSetupRepository.complete(
      mode: TranscriptionProviderMode.hosted,
      hostedModel: model,
      hostedAuthenticated: _hasHostedCredentials,
      enabledHostedModels: _hostedModels,
    );
    if (!mounted) return;
    setState(() {
      _providerSetup = setup;
      _state = RecorderState.ready;
      _hostedStatus = 'sttapp Hosted is ready.';
      _lastError = null;
    });
    await _refreshTrayMenu();
  }

  Future<void> _signOutHosted() async {
    if (_isLoadingHosted || _isSigningIn) return;
    setState(() {
      _isLoadingHosted = true;
      _hostedStatus = 'Signing out…';
    });
    Object? persistenceError;
    try {
      await _hostedSessionManager.signOut();
    } catch (_) {
      // Local credentials are cleared by HostedSessionManager even if logout
      // cannot reach the backend.
    }
    final setup =
        _providerSetup.providerMode == TranscriptionProviderMode.hosted
        ? _providerSetup.copyWith(
            clearCompletedVersion: true,
            draftStep: SetupDraftStep.hosted,
          )
        : _providerSetup;
    try {
      await _providerSetupRepository.save(setup);
    } catch (error) {
      persistenceError = error;
    } finally {
      if (mounted) {
        setState(() {
          _providerSetup = setup;
          _hasHostedCredentials = false;
          _hostedAccount = null;
          _hostedModels = const [];
          _isLoadingHosted = false;
          _hostedStatus = persistenceError == null
              ? 'Signed out of sttapp Hosted.'
              : 'Signed out, but local setup state could not be saved.';
          if (setup.providerMode == TranscriptionProviderMode.hosted) {
            _state = RecorderState.needsConfig;
          }
        });
        await _refreshTrayMenu();
      }
    }
  }

  Future<void> _openHostedBilling({required bool portal}) async {
    if (_isOpeningBilling) return;
    setState(() {
      _isOpeningBilling = true;
      _hostedStatus = portal
          ? 'Opening billing settings…'
          : 'Opening secure checkout…';
    });
    try {
      final uri = await _hostedSessionManager.authorized(
        portal ? _hostedBackendClient.portal : _hostedBackendClient.checkout,
      );
      final opened = await _releaseLauncher(uri);
      if (!opened) throw const DesktopAuthException('Browser could not open.');
      if (!mounted) return;
      setState(() {
        _hostedStatus = portal
            ? 'Billing settings opened in your browser.'
            : 'Checkout opened. After payment, return here and refresh status.';
      });
    } catch (error) {
      if (!mounted) return;
      final requiresSignIn =
          error is HostedApiException &&
          (error.requiresSignIn || error.code == 'sign_in_required');
      if (requiresSignIn) {
        await _markHostedSignInRequired();
      } else if (mounted) {
        setState(() => _hostedStatus = _hostedErrorMessage(error));
      }
    } finally {
      if (mounted) setState(() => _isOpeningBilling = false);
    }
  }

  Future<void> _markHostedSignInRequired() async {
    final setup =
        _providerSetup.providerMode == TranscriptionProviderMode.hosted
        ? _providerSetup.copyWith(
            clearCompletedVersion: true,
            draftStep: SetupDraftStep.hosted,
          )
        : _providerSetup;
    try {
      await _providerSetupRepository.save(setup);
    } catch (_) {
      // The in-memory state still fails closed; the session repository has
      // already removed permanently invalid credentials.
    }
    if (!mounted) return;
    setState(() {
      _providerSetup = setup;
      _hasHostedCredentials = false;
      _hostedAccount = null;
      _hostedModels = const [];
      _hostedStatus = 'Your session ended. Sign in again to continue.';
      if (setup.providerMode == TranscriptionProviderMode.hosted) {
        _state = RecorderState.needsConfig;
        _showSettings = true;
      }
    });
    await _refreshTrayMenu();
  }

  Future<void> _checkForUpdates() async {
    if (_releaseTag.isEmpty) {
      return;
    }

    try {
      final update = await _updateService.checkForUpdate(
        currentTag: _releaseTag,
        fakeLatestTag: _fakeLatestTag.isEmpty ? null : _fakeLatestTag,
      );
      if (!mounted) {
        return;
      }

      final shouldDefer = update != null && (_isRecording || _isTranscribing);
      setState(() {
        _availableUpdate = update;
        _updateActionError = null;
        _updateStatus = update == null
            ? UpdateStatus.latest
            : UpdateStatus.updateAvailable;
        if (shouldDefer) {
          _showUpdateWhenIdle = true;
        } else if (update != null) {
          _showSettings = true;
        }
      });
      if (update != null && !shouldDefer) {
        await _showSettingsWindow();
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _availableUpdate = null;
        _updateStatus = UpdateStatus.unavailable;
      });
    }
  }

  Future<void> _showDeferredUpdateIfNeeded() async {
    if (!_showUpdateWhenIdle || _availableUpdate == null || !mounted) {
      return;
    }
    setState(() {
      _showUpdateWhenIdle = false;
      _showSettings = true;
    });
    await _showSettingsWindow();
  }

  Future<void> _openAvailableUpdate() async {
    final update = _availableUpdate;
    if (update == null) {
      return;
    }
    setState(() => _updateActionError = null);
    try {
      final opened = await _releaseLauncher(update.releaseUri);
      if (!opened && mounted) {
        setState(() {
          _updateActionError = 'Could not open the GitHub release page.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _updateActionError = 'Could not open the GitHub release page.';
        });
      }
    }
  }

  Future<void> _initTray() async {
    await _setTrayRecordingState(false);
    await _refreshTrayMenu();
    if (!Platform.isLinux) {
      await trayManager.setToolTip('sttapp transcription');
    }
  }

  Future<void> _setTrayRecordingState(bool recording) async {
    if (!_initializePlatformServices) {
      return;
    }

    await trayManager.setIcon(
      Platform.isWindows
          ? (recording ? _trayRecordingIco : _trayDefaultIco)
          : (recording ? _trayRecordingPng : _trayDefaultPng),
    );
  }

  Future<void> _refreshTrayMenu() async {
    if (!_initializePlatformServices) {
      return;
    }

    final menu = Menu(
      items: [
        if (_shortcutRegistrationState == ShortcutRegistrationState.failed)
          MenuItem(
            key: 'shortcut_status',
            label: 'Global shortcuts unavailable',
            disabled: true,
          ),
        if (_shortcutRegistrationState == ShortcutRegistrationState.failed)
          MenuItem(key: 'retry_shortcuts', label: 'Retry global shortcuts'),
        if (_shortcutRegistrationState == ShortcutRegistrationState.failed)
          MenuItem.separator(),
        MenuItem(
          key: 'start_capture',
          label: _isRecording ? 'Recording' : 'Start capture',
          disabled: !_permissionsAuthorized || !_providerReady || _isRecording,
        ),
        MenuItem(
          key: 'stop_capture',
          label: 'Stop and paste',
          disabled: !_isRecording,
        ),
        MenuItem.separator(),
        MenuItem(key: 'settings', label: 'Settings'),
        MenuItem(key: 'quit_app', label: 'Quit'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  Future<void> _toggleCapture(PasteMode mode) async {
    if (_isRecording) {
      await _stopCapture(mode);
    } else {
      await _startCapture(mode);
    }
  }

  Future<void> _startCapture([PasteMode pasteMode = PasteMode.normal]) async {
    if (!_canStart) {
      return;
    }

    if (!await _ensurePermissions()) {
      return;
    }

    final config = _config;
    if (!_providerReady || config == null) {
      setState(() {
        _state = RecorderState.needsConfig;
        _showSettings = true;
        _lastError = switch (_providerSetup.providerMode) {
          TranscriptionProviderMode.hosted when !_hasHostedCredentials =>
            'Sign in to sttapp Hosted before recording.',
          TranscriptionProviderMode.hosted =>
            'Finish sttapp Hosted setup before recording.',
          TranscriptionProviderMode.manual =>
            'Complete your API settings before recording.',
          TranscriptionProviderMode.unset =>
            'Choose a transcription provider before recording.',
        };
      });
      await _showSettingsWindow();
      return;
    }

    setState(() {
      _state = RecorderState.ready;
      _showSettings = false;
      _lastTranscript = null;
      _lastError = null;
      _recordingPasteMode = pasteMode;
    });
    await _hideWindowAfterCapture();
    await _refreshTrayMenu();

    try {
      final recording = await _recorder.start();
      if (!mounted) {
        final clip = await recording.stop();
        clip.dispose();
        return;
      }

      setState(() {
        _recording = recording;
        _state = RecorderState.recording;
      });
      await _setTrayRecordingState(true);
    } catch (error) {
      _setError(error.toString());
      await _hideWindowAfterCapture();
    } finally {
      await _refreshTrayMenu();
    }
  }

  Future<void> _stopCapture([PasteMode? pasteMode]) async {
    final recording = _recording;
    final config = _config;
    if (recording == null || _isTranscribing || config == null) {
      return;
    }

    final resolvedPasteMode = pasteMode ?? _recordingPasteMode;
    setState(() {
      _recording = null;
      _state = RecorderState.transcribing;
      _lastError = null;
    });
    await _setTrayRecordingState(false);
    await _refreshTrayMenu();

    AudioClip? clip;
    try {
      clip = await recording.stop();
      final transcript = await _transcriptionCoordinator.transcribe(
        clip: clip,
        setup: _providerSetup,
        manualConfig: config,
      );
      if (!mounted) {
        return;
      }

      if (transcript.isEmpty) {
        setState(() {
          _state = RecorderState.done;
          _lastTranscript = null;
        });
        return;
      }

      if (!await _ensurePermissions()) {
        await _transcriptDeliveryService.copyToClipboard(transcript);
        if (!mounted) {
          return;
        }
        setState(() {
          _state = RecorderState.error;
          _lastTranscript = transcript;
          _lastError =
              'Permissions changed while recording. The transcript was copied '
              'but could not be pasted.';
        });
        return;
      }

      await _transcriptDeliveryService.deliver(transcript, resolvedPasteMode);

      if (!mounted) {
        return;
      }
      setState(() {
        _state = RecorderState.done;
        _lastTranscript = transcript;
      });
    } catch (error) {
      if (error is HostedApiException &&
          (error.requiresSignIn || error.code == 'sign_in_required')) {
        await _markHostedSignInRequired();
        if (mounted) {
          await _showSettingsWindow();
        }
      }
      _setError(
        _providerSetup.providerMode == TranscriptionProviderMode.hosted
            ? _hostedErrorMessage(error)
            : error.toString(),
      );
    } finally {
      clip?.dispose();
      await _refreshTrayMenu();
      await _hideWindowAfterCapture();
      await _showDeferredUpdateIfNeeded();
    }
  }

  Future<void> _discardCapture() async {
    final recording = _recording;
    if (recording == null) {
      return;
    }
    _recording = null;
    final clip = await recording.stop();
    clip.dispose();
    await _setTrayRecordingState(false);
  }

  Future<void> _saveSettings() async {
    final config = TranscriptionConfig(
      apiKey: _apiKeyController.text,
      baseUrl: _baseUrlController.text,
      model: _modelController.text,
    );

    try {
      config.validate();
      await _configRepository.save(config);
      var providerSetup = await _providerSetupRepository.complete(
        mode: TranscriptionProviderMode.manual,
        manualConfig: config,
      );
      providerSetup = providerSetup.copyWith(
        hostedModel: _providerSetup.hostedModel,
      );
      await _providerSetupRepository.save(providerSetup);
      if (_supportsShortcutSettings) {
        await _configRepository.saveShortcutConfig(_shortcutConfig);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _config = config;
        _providerSetup = providerSetup;
        _state = RecorderState.ready;
        _showSettings = !_permissionsAuthorized;
        _lastError = null;
        _settingsStatus = null;
      });
      await _refreshTrayMenu();
      if (_permissionsAuthorized) {
        await _hideWindowAfterCapture();
      } else {
        await _showSettingsWindow();
      }
    } catch (error) {
      setState(() {
        _state = RecorderState.needsConfig;
        _lastError = error is HotkeyRegistrationException
            ? _shortcutFailureMessage(error)
            : error.toString();
      });
    }
  }

  void _applyConfigToFields(TranscriptionConfig config) {
    _apiKeyController.text = config.apiKey;
    _baseUrlController.text = config.baseUrl;
    _modelController.text = config.model;
    _syncModelSelection(config.model);
  }

  Future<void> _showSettingsWindow() async {
    if (!_initializePlatformServices) {
      return;
    }

    await windowManager.setTitleBarStyle(
      TitleBarStyle.normal,
      windowButtonVisibility: true,
    );
    await windowManager.setResizable(true);
    await windowManager.setMinimumSize(const Size(420, 480));
    await windowManager.setMaximumSize(const Size(900, 900));
    await windowManager.setSize(_settingsWindowSize);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setSkipTaskbar(false);
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _hideWindowAfterCapture() async {
    if (!_initializePlatformServices ||
        _showSettings ||
        !_permissionsAuthorized ||
        !_providerReady) {
      return;
    }

    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  Future<void> _testConnection() async {
    await _refreshModels(showSuccess: true);
  }

  Future<void> _refreshModels({bool showSuccess = false}) async {
    final config = TranscriptionConfig(
      apiKey: _apiKeyController.text,
      baseUrl: _baseUrlController.text,
      model: _modelController.text,
    );

    try {
      config.validateEndpoint();
    } catch (error) {
      setState(() {
        _availableModels = const [];
        _modelsLoadedForEndpoint = null;
        _settingsStatus = showSuccess ? 'Connection failed: $error' : null;
      });
      return;
    }

    setState(() {
      _isTestingConnection = true;
      _isLoadingModels = true;
      _settingsStatus = null;
      _lastError = null;
    });

    try {
      final models = await _transcriptionService.listModels(config);
      if (!mounted) {
        return;
      }
      setState(() {
        _availableModels = models;
        _modelsLoadedForEndpoint = _modelEndpointKey(config);
        _syncModelSelection(_modelController.text);
        if (showSuccess) {
          _settingsStatus =
              'Connection successful. Loaded ${models.length} '
              '${models.length == 1 ? 'model' : 'models'}.';
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _availableModels = const [];
        _modelsLoadedForEndpoint = null;
        _syncModelSelection(_modelController.text);
        _settingsStatus = 'Connection failed: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isTestingConnection = false;
          _isLoadingModels = false;
        });
      }
    }
  }

  void _refreshModelsIfPossible() {
    final config = TranscriptionConfig(
      apiKey: _apiKeyController.text,
      baseUrl: _baseUrlController.text,
      model: _modelController.text,
    );
    if (config.apiKey.isEmpty ||
        config.baseUrl.isEmpty ||
        _modelsLoadedForEndpoint == _modelEndpointKey(config) ||
        _isLoadingModels) {
      return;
    }
    unawaited(_refreshModels());
  }

  void _handleModelEndpointChanged() {
    setState(() {
      _settingsStatus = null;
      _availableModels = const [];
      _modelsLoadedForEndpoint = null;
      _syncModelSelection(_modelController.text);
    });
  }

  void _syncModelSelection(String model) {
    final normalized = model.trim();
    _selectedModelValue = _availableModels.contains(normalized)
        ? normalized
        : _customModelValue;
  }

  void _selectModel(String value) {
    setState(() {
      _selectedModelValue = value;
      _settingsStatus = null;
      if (value != _customModelValue) {
        _modelController.text = value;
      }
    });
  }

  String _modelEndpointKey(TranscriptionConfig config) {
    return '${config.apiKey}\n${config.baseUrl}';
  }

  void _selectShortcut(String keyId) {
    setState(() {
      _shortcutConfig = ShortcutConfig(keyId: keyId);
      _settingsStatus = null;
    });
    unawaited(_persistShortcutSettings());
  }

  Future<void> _persistShortcutSettings() async {
    try {
      await _configRepository.saveShortcutConfig(_shortcutConfig);
      if (_initializePlatformServices && _permissionsAuthorized) {
        _inputServicesInitialized = false;
        await _registerHotkeys();
        _inputServicesInitialized = true;
        await _refreshTrayMenu();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lastError = error is HotkeyRegistrationException
            ? _shortcutFailureMessage(error)
            : 'Could not save the shortcut: $error';
      });
    }
  }

  void _resetShortcut() {
    _selectShortcut(defaultShortcutKeyId);
  }

  Future<void> _quit() async {
    if (_isQuitting) {
      return;
    }
    _isQuitting = true;
    await _discardCapture();
    await _hotkeyService.dispose();
    await trayManager.destroy();
    exit(0);
  }

  void _openSettings() {
    setState(() {
      _showSettings = true;
      _settingsStatus = null;
      if (_state != RecorderState.recording &&
          _state != RecorderState.transcribing) {
        _state = _providerReady
            ? RecorderState.ready
            : RecorderState.needsConfig;
      }
    });
    if (_providerSetup.providerMode == TranscriptionProviderMode.hosted) {
      if (_hasHostedCredentials) unawaited(_refreshHosted());
    } else {
      _refreshModelsIfPossible();
    }
    unawaited(_showSettingsWindow());
  }

  Future<bool> _ensurePermissions() async {
    if (!_requiresDesktopPermissions) {
      return true;
    }
    await _refreshPermissionStatus(showWindowWhenMissing: true);
    if (!_permissionsAuthorized) {
      return false;
    }
    await _initializeInputServices();
    return _inputServicesInitialized;
  }

  Future<void> _refreshPermissionStatus({
    required bool showWindowWhenMissing,
  }) async {
    if (!_requiresDesktopPermissions ||
        _isPermissionActionPending ||
        _isRefreshingPermissions) {
      return;
    }
    _isRefreshingPermissions = true;
    try {
      final status = await _desktopPermissionService.getStatus();
      if (!mounted) {
        return;
      }
      final wasAuthorized = _permissionsAuthorized;
      setState(() {
        _permissionStatus = status;
        _permissionStatusLoaded = true;
        _permissionError = null;
        if (!status.isAuthorized) {
          _showSettings = true;
          if (_state != RecorderState.recording &&
              _state != RecorderState.transcribing) {
            _state = RecorderState.needsConfig;
          }
        }
      });

      if (!status.isAuthorized) {
        if (_inputServicesInitialized || wasAuthorized) {
          await _hotkeyService.dispose();
          _inputServicesInitialized = false;
        }
        await _refreshTrayMenu();
        if (showWindowWhenMissing) {
          await _showSettingsWindow();
        }
        return;
      }

      if (_initializePlatformServices) {
        await _initializeInputServices();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _permissionStatusLoaded = true;
        _permissionError = 'Could not read macOS permissions: $error';
        _showSettings = true;
      });
      if (showWindowWhenMissing) {
        await _showSettingsWindow();
      }
    } finally {
      _isRefreshingPermissions = false;
    }
  }

  Future<void> _requestPermission(DesktopPermission permission) async {
    if (_isPermissionActionPending) {
      return;
    }
    setState(() {
      _isPermissionActionPending = true;
      _permissionError = null;
    });
    try {
      final status = switch (permission) {
        DesktopPermission.microphone =>
          await _desktopPermissionService.requestMicrophone(),
        DesktopPermission.accessibility =>
          await _desktopPermissionService.requestAccessibility(),
      };
      if (!mounted) {
        return;
      }
      setState(() {
        _permissionStatus = status;
        _permissionStatusLoaded = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _permissionError = 'Permission request failed: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _isPermissionActionPending = false);
      }
    }
    if (_permissionsAuthorized && _initializePlatformServices) {
      await _initializeInputServices();
    }
  }

  Future<void> _openPermissionSettings(DesktopPermission permission) async {
    try {
      await _desktopPermissionService.openSettings(permission);
    } catch (error) {
      if (mounted) {
        setState(() => _permissionError = 'Could not open settings: $error');
      }
    }
  }

  void _setError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _state = RecorderState.error;
      _lastError = message;
    });
  }

  @override
  void onTrayIconMouseDown() {
    if (!Platform.isLinux) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!Platform.isLinux) {
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'start_capture':
        unawaited(_startCapture());
      case 'stop_capture':
        unawaited(_stopCapture());
      case 'settings':
        _openSettings();
      case 'retry_shortcuts':
        unawaited(_retryShortcutRegistration());
      case 'quit_app':
        unawaited(_quit());
    }
  }

  @override
  void onWindowClose() {
    if (_isQuitting) {
      return;
    }
    if (!_permissionsAuthorized || !_providerReady) {
      unawaited(_showSettingsWindow());
      return;
    }
    if (mounted) setState(() => _showSettings = false);
    windowManager.hide();
    unawaited(windowManager.setSkipTaskbar(true));
  }

  @override
  void onWindowFocus() {
    if (_requiresDesktopPermissions) {
      unawaited(_refreshPermissionStatus(showWindowWhenMissing: false));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _requiresDesktopPermissions) {
      unawaited(_refreshPermissionStatus(showWindowWhenMissing: false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final settingsPadding = MediaQuery.sizeOf(context).width <= 460
        ? 16.0
        : 24.0;

    return Scaffold(
      backgroundColor: _showSettings ? null : Colors.transparent,
      appBar: _showSettings
          ? AppBar(
              title: const Text('Settings'),
              actions: [
                IconButton(
                  tooltip: 'Close',
                  onPressed:
                      _providerReady &&
                          _permissionsAuthorized &&
                          _shortcutRegistrationState !=
                              ShortcutRegistrationState.failed
                      ? () {
                          setState(() => _showSettings = false);
                          unawaited(_hideWindowAfterCapture());
                        }
                      : null,
                  icon: const Icon(Icons.close),
                ),
              ],
            )
          : null,
      body: Padding(
        padding: EdgeInsets.all(_showSettings ? settingsPadding : 0),
        child: _showSettings
            ? _buildSettings(context)
            : _buildRecorder(context),
      ),
      bottomNavigationBar: !_showSettings || _lastError == null
          ? null
          : SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  settingsPadding,
                  0,
                  settingsPadding,
                  16,
                ),
                child: Text(
                  _lastError!,
                  style: TextStyle(color: colorScheme.error),
                ),
              ),
            ),
    );
  }

  Widget _buildRecorder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final status = switch (_state) {
      RecorderState.ready => 'Ready',
      RecorderState.needsConfig => 'Settings required',
      RecorderState.recording => 'Recording',
      RecorderState.transcribing => 'Transcribing',
      RecorderState.done =>
        _lastTranscript == null
            ? 'No speech detected'
            : 'Transcribed and pasted',
      RecorderState.error => 'Error',
    };

    final detail = _lastError ?? (_lastTranscript == null ? '' : 'Copied');

    return Container(
      width: _recorderWindowSize.width,
      height: _recorderWindowSize.height,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            _isRecording ? Icons.mic : Icons.mic_none,
            color: _isRecording ? colorScheme.primary : colorScheme.outline,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  detail.isEmpty
                      ? 'Shortcut: ${_shortcutConfig.normalLabel}'
                      : detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _lastError == null
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.error,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
    );
  }

  Widget _buildSettings(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final updateStatusText = switch (_updateStatus) {
      UpdateStatus.development => 'Development build',
      UpdateStatus.checking => 'Checking for updates…',
      UpdateStatus.latest => 'You are on the latest version',
      UpdateStatus.updateAvailable => 'Update needed',
      UpdateStatus.unavailable => 'Unable to check for updates',
    };
    final updateStatusColor = switch (_updateStatus) {
      UpdateStatus.updateAvailable => colorScheme.error,
      UpdateStatus.latest => colorScheme.primary,
      _ => colorScheme.onSurfaceVariant,
    };

    return ListView(
      children: [
        _buildProviderSection(context),
        if (_requiresDesktopPermissions) ...[
          const SizedBox(height: 20),
          Text(
            'macOS permissions',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          _buildPermissionCard(
            context,
            permission: DesktopPermission.microphone,
            title: 'Microphone',
            description:
                'Required to record audio after you start a transcription.',
            status: _permissionStatus.microphone,
          ),
          const SizedBox(height: 10),
          _buildPermissionCard(
            context,
            permission: DesktopPermission.accessibility,
            title: 'Accessibility',
            description:
                'Required to paste completed transcripts into the active app.',
            status: _permissionStatus.accessibility,
          ),
          if (_permissionError != null) ...[
            const SizedBox(height: 8),
            Text(_permissionError!, style: TextStyle(color: colorScheme.error)),
          ],
        ],
        if (_shortcutRegistrationState == ShortcutRegistrationState.checking ||
            _shortcutRegistrationState == ShortcutRegistrationState.failed) ...[
          const SizedBox(height: 20),
          ShortcutRegistrationNotice(
            checking:
                _shortcutRegistrationState ==
                ShortcutRegistrationState.checking,
            message: _shortcutRegistrationError,
            onRetry: () => unawaited(_retryShortcutRegistration()),
          ),
        ],
        if (_supportsShortcutSettings) ...[
          const SizedBox(height: 20),
          Text(
            'Keyboard shortcut',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey('shortcut-${_shortcutConfig.keyId}'),
            initialValue: _shortcutConfig.keyId,
            items: [
              for (final option in shortcutKeyOptions)
                DropdownMenuItem(value: option.id, child: Text(option.label)),
            ],
            onChanged: (value) {
              if (value != null) {
                _selectShortcut(value);
              }
            },
            decoration: const InputDecoration(
              labelText: 'Shortcut key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Normal: ${_shortcutConfig.normalLabel} · Plain: ${_shortcutConfig.plainLabel}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(onPressed: _resetShortcut, child: const Text('Reset')),
            ],
          ),
        ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 16),
        Text(
          'Updates and version',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text:
                    'Audio API v${SttappAudio.nativeApiVersion} · '
                    'Input API v${DesktopInput.nativeApiVersion} · ',
              ),
              TextSpan(
                text: updateStatusText,
                style: TextStyle(color: updateStatusColor),
              ),
            ],
          ),
        ),
        if (_availableUpdate != null) ...[
          const SizedBox(height: 12),
          _buildUpdateCard(context, _availableUpdate!),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildProviderSection(BuildContext context) {
    final hosted =
        _providerSetup.providerMode == TranscriptionProviderMode.hosted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Transcription provider',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          hosted
              ? 'Audio is sent only to sttapp Hosted.'
              : 'Audio is sent only to your configured API endpoint.',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: hosted
                ? _buildHostedProvider(context)
                : _buildManualProvider(context),
          ),
        ),
      ],
    );
  }

  Widget _buildHostedProvider(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final account = _hostedAccount;
    final selectedModel = _hostedModels.contains(_providerSetup.hostedModel)
        ? _providerSetup.hostedModel
        : null;
    final subscriptionLabel = switch (account?.subscriptionState) {
      'active' => 'Active subscription',
      'trialing' => 'Trial active',
      'on_hold' || 'past_due' => 'Payment action required',
      'canceled' || 'expired' => 'Subscription ended',
      null => 'Signed out',
      _ => 'Subscription required',
    };
    final statusIsError =
        _hostedStatus != null &&
        !(_hostedStatus!.contains('ready') ||
            _hostedStatus!.contains('opened') ||
            _hostedStatus!.contains('Refreshing') ||
            _hostedStatus!.contains('Waiting'));
    final paymentActionRequired =
        account?.subscriptionState == 'on_hold' ||
        account?.subscriptionState == 'past_due';
    final subscriptionEnded =
        account?.subscriptionState == 'canceled' ||
        account?.subscriptionState == 'expired';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.cloud_outlined, color: colors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'sttapp Hosted',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _hasHostedCredentials
                        ? subscriptionLabel
                        : 'Sign in once, then use sttapp normally.',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (_isSigningIn) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
          const SizedBox(height: 10),
          const Text('Complete sign-in in your system browser.'),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _cancelHostedSignIn,
            child: const Text('Cancel sign-in'),
          ),
        ] else if (!_hasHostedCredentials) ...[
          const SizedBox(height: 16),
          const Text(
            'Authentication happens securely in your browser. No hosted token '
            'or backend configuration is shown in the app.',
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _signInHosted,
            icon: const Icon(Icons.open_in_browser),
            label: const Text('Sign in securely'),
          ),
        ] else ...[
          if (_isLoadingHosted) ...[
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
          ],
          if (account?.hostedAvailable == true && _hostedModels.isNotEmpty) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey('hosted-model-$selectedModel'),
              initialValue: selectedModel,
              items: [
                for (final model in _hostedModels)
                  DropdownMenuItem(value: model, child: Text(model)),
              ],
              onChanged: _isLoadingHosted
                  ? null
                  : (value) {
                      if (value != null) unawaited(_selectHostedModel(value));
                    },
              decoration: const InputDecoration(
                labelText: 'Hosted model',
                hintText: 'Choose a hosted model',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Estimated hosted usage: '
              '\$${(account!.usageMicros / 1000000).toStringAsFixed(2)} '
              '(as of ${account.usageAsOf.toIso8601String().substring(0, 10)} UTC).',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (account?.checkoutAvailable == true && !paymentActionRequired)
                FilledButton(
                  onPressed: _isOpeningBilling
                      ? null
                      : () => _openHostedBilling(portal: false),
                  child: Text(subscriptionEnded ? 'Resubscribe' : 'Subscribe'),
                ),
              if (account?.portalAvailable == true && paymentActionRequired)
                FilledButton(
                  onPressed: _isOpeningBilling
                      ? null
                      : () => _openHostedBilling(portal: true),
                  child: const Text('Update payment method'),
                ),
              if (account?.portalAvailable == true && !paymentActionRequired)
                OutlinedButton(
                  onPressed: _isOpeningBilling
                      ? null
                      : () => _openHostedBilling(portal: true),
                  child: const Text('Manage billing'),
                ),
              OutlinedButton(
                onPressed: _isLoadingHosted ? null : _refreshHosted,
                child: const Text('Refresh status'),
              ),
              TextButton(
                onPressed: _isLoadingHosted ? null : _signOutHosted,
                child: const Text('Sign out'),
              ),
            ],
          ),
        ],
        if (_hostedStatus != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              _hostedStatus!,
              style: TextStyle(
                color: statusIsError ? colors.error : colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _isRecording || _isTranscribing || _isSwitchingProvider
              ? null
              : () => _switchProvider(TranscriptionProviderMode.manual),
          icon: const Icon(Icons.key_outlined),
          label: const Text('Use API key instead'),
        ),
      ],
    );
  }

  Widget _buildManualProvider(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final modelDropdownValue = _availableModels.contains(_selectedModelValue)
        ? _selectedModelValue
        : _customModelValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.key_outlined, color: colors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'API key',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Use your own OpenAI-compatible provider.',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _apiKeyController,
          obscureText: !_showApiKey,
          decoration: InputDecoration(
            labelText: 'API key',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _showApiKey ? 'Hide API key' : 'Show API key',
              onPressed: () => setState(() => _showApiKey = !_showApiKey),
              icon: Icon(_showApiKey ? Icons.visibility_off : Icons.visibility),
            ),
          ),
          onChanged: (_) => _handleModelEndpointChanged(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _baseUrlController,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _handleModelEndpointChanged(),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey('model-$modelDropdownValue'),
          initialValue: modelDropdownValue,
          items: [
            for (final model in _availableModels)
              DropdownMenuItem(value: model, child: Text(model)),
            const DropdownMenuItem(
              value: _customModelValue,
              child: Text('Manual model'),
            ),
          ],
          onChanged: (value) {
            if (value != null) _selectModel(value);
          },
          decoration: const InputDecoration(
            labelText: 'Model',
            border: OutlineInputBorder(),
          ),
        ),
        if (modelDropdownValue == _customModelValue) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _modelController,
            decoration: const InputDecoration(
              labelText: 'Manual model',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _settingsStatus = null),
          ),
        ],
        if (_settingsStatus != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              _settingsStatus!,
              style: TextStyle(
                color: _settingsStatus!.startsWith('Connection successful')
                    ? colors.primary
                    : colors.error,
              ),
            ),
          ),
        ],
        if (_isLoadingModels) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _saveSettings,
              child: const Text('Save API settings'),
            ),
            OutlinedButton(
              onPressed: _isTestingConnection ? null : _testConnection,
              child: _isTestingConnection
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Test connection'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _isRecording || _isTranscribing || _isSwitchingProvider
              ? null
              : () => _switchProvider(TranscriptionProviderMode.hosted),
          icon: const Icon(Icons.cloud_outlined),
          label: const Text('Use sttapp Hosted instead'),
        ),
      ],
    );
  }

  Widget _buildUpdateCard(BuildContext context, AvailableUpdate update) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.system_update, color: colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'A new version is available',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: colorScheme.onErrorContainer),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${update.currentVersion.tag} → '
                        '${update.latestVersion.tag}',
                        style: TextStyle(color: colorScheme.onErrorContainer),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _openAvailableUpdate,
                child: const Text('View release'),
              ),
            ),
            if (_updateActionError != null) ...[
              const SizedBox(height: 8),
              Text(
                _updateActionError!,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionCard(
    BuildContext context, {
    required DesktopPermission permission,
    required String title,
    required String description,
    required DesktopPermissionState status,
  }) {
    final authorized = status == DesktopPermissionState.authorized;
    final requiresSettings =
        permission == DesktopPermission.microphone &&
        (status == DesktopPermissionState.denied ||
            status == DesktopPermissionState.restricted);
    final label = switch (status) {
      DesktopPermissionState.notDetermined => 'Not requested',
      DesktopPermissionState.denied => 'Not granted',
      DesktopPermissionState.restricted => 'Restricted',
      DesktopPermissionState.authorized => 'Granted',
      DesktopPermissionState.unavailable => 'Unavailable',
    };

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              authorized ? Icons.check_circle : Icons.warning_amber,
              color: authorized
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 3),
                  Text(description),
                  const SizedBox(height: 3),
                  Text('Status: $label'),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!authorized)
              Column(
                children: [
                  FilledButton.tonal(
                    onPressed: _isPermissionActionPending
                        ? null
                        : requiresSettings
                        ? () => _openPermissionSettings(permission)
                        : () => _requestPermission(permission),
                    child: Text(requiresSettings ? 'Open Settings' : 'Grant'),
                  ),
                  if (permission == DesktopPermission.accessibility)
                    TextButton(
                      onPressed: _isPermissionActionPending
                          ? null
                          : () => _openPermissionSettings(permission),
                      child: const Text('Open Settings'),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
