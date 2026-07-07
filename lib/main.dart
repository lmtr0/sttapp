import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sttapp/services/config_repository.dart';
import 'package:sttapp/services/hotkey_service.dart';
import 'package:sttapp/services/transcript_delivery_service.dart';
import 'package:sttapp/services/transcription_service.dart';
import 'package:sttapp_audio/sttapp_audio.dart';
import 'package:sttapp_input/sttapp_input.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const _recorderWindowSize = Size(400, 120);
const _settingsWindowSize = Size(460, 560);
const _trayDefaultPng = 'assets/tray/tray_default.png';
const _trayRecordingPng = 'assets/tray/tray_recording.png';
const _trayDefaultIco = 'assets/tray/tray_default.ico';
const _trayRecordingIco = 'assets/tray/tray_recording.ico';
const _customModelValue = '__custom__';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.setSkipTaskbar(true);

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
    this.transcriptDeliveryService,
    this.hotkeyService,
    this.supportsShortcutSettings,
    this.initializePlatformServices = true,
  });

  final ConfigRepository? configRepository;
  final TranscriptionService? transcriptionService;
  final TranscriptDeliveryService? transcriptDeliveryService;
  final HotkeyService? hotkeyService;
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
      home: RecorderHome(
        configRepository: configRepository,
        transcriptionService: transcriptionService,
        transcriptDeliveryService: transcriptDeliveryService,
        hotkeyService: hotkeyService,
        supportsShortcutSettings: supportsShortcutSettings,
        initializePlatformServices: initializePlatformServices,
      ),
    );
  }
}

class RecorderHome extends StatefulWidget {
  const RecorderHome({
    super.key,
    this.configRepository,
    this.transcriptionService,
    this.transcriptDeliveryService,
    this.hotkeyService,
    this.supportsShortcutSettings,
    this.initializePlatformServices = true,
  });

  final ConfigRepository? configRepository;
  final TranscriptionService? transcriptionService;
  final TranscriptDeliveryService? transcriptDeliveryService;
  final HotkeyService? hotkeyService;
  final bool? supportsShortcutSettings;
  final bool initializePlatformServices;

  @override
  State<RecorderHome> createState() => _RecorderHomeState();
}

enum RecorderState { ready, needsConfig, recording, transcribing, done, error }

class _RecorderHomeState extends State<RecorderHome>
    with TrayListener, WindowListener {
  late final AudioRecorder _recorder;
  late final ConfigRepository _configRepository;
  late final TranscriptionService _transcriptionService;
  late final TranscriptDeliveryService _transcriptDeliveryService;
  late final HotkeyService _hotkeyService;
  late final bool _ownsTranscriptionService;
  late final bool _supportsShortcutSettings;
  late final bool _initializePlatformServices;

  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController(text: defaultOpenAiBaseUrl);
  final _modelController = TextEditingController(text: defaultOpenAiModel);

  AudioRecording? _recording;
  TranscriptionConfig? _config;
  ShortcutConfig _shortcutConfig = ShortcutConfig();
  RecorderState _state = RecorderState.ready;
  PasteMode _recordingPasteMode = PasteMode.normal;
  String? _lastTranscript;
  String? _lastError;
  String? _settingsStatus;
  String _selectedModelValue = _customModelValue;
  List<String> _availableModels = const [];
  String? _modelsLoadedForEndpoint;
  bool _showSettings = false;
  bool _showApiKey = false;
  bool _isTestingConnection = false;
  bool _isLoadingModels = false;
  bool _isQuitting = false;

  bool get _isRecording => _recording != null;

  bool get _isTranscribing => _state == RecorderState.transcribing;

  bool get _canStart => !_isRecording && !_isTranscribing;

  @override
  void initState() {
    super.initState();
    _recorder = AudioRecorder();
    _configRepository = widget.configRepository ?? ConfigRepository();
    _transcriptionService =
        widget.transcriptionService ?? TranscriptionService();
    _transcriptDeliveryService =
        widget.transcriptDeliveryService ?? const TranscriptDeliveryService();
    _hotkeyService = widget.hotkeyService ?? HotkeyService();
    _ownsTranscriptionService = widget.transcriptionService == null;
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
    if (_initializePlatformServices) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    unawaited(_hotkeyService.dispose());
    if (_ownsTranscriptionService) {
      _transcriptionService.close();
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
    if (!_initializePlatformServices) {
      return;
    }
    await _registerHotkeys();
  }

  Future<void> _registerHotkeys() async {
    try {
      await _hotkeyService.initialize(
        shortcutConfig: _shortcutConfig,
        onToggle: (mode) => unawaited(_toggleCapture(mode)),
        onError: (error) => _setError('Shortcut service error: $error'),
      );
    } catch (error) {
      _setError('Failed to register hotkeys: $error');
    }
  }

  Future<void> _loadConfig() async {
    try {
      final config = await _configRepository.load();
      final shortcutConfig = await _configRepository.loadShortcutConfig();
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
      setState(() {
        _config = config;
        _shortcutConfig = shortcutConfig;
        _showSettings = !configIsValid;
        _state = configIsValid
            ? RecorderState.ready
            : RecorderState.needsConfig;
        _lastError = configError;
      });
      if (!configIsValid) {
        _refreshModelsIfPossible();
        await _showSettingsWindow();
      }
    } catch (error) {
      _setError(error.toString());
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
        MenuItem(
          key: 'start_capture',
          label: _isRecording ? 'Recording' : 'Start capture',
        ),
        MenuItem(key: 'stop_capture', label: 'Stop and paste'),
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

    final config = _config;
    if (config == null || !config.isComplete) {
      setState(() {
        _state = RecorderState.needsConfig;
        _showSettings = true;
        _lastError = 'OpenAI API key is required.';
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
      final transcript = await _transcriptionService.transcribe(clip, config);
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

      await _transcriptDeliveryService.deliver(transcript, resolvedPasteMode);

      if (!mounted) {
        return;
      }
      setState(() {
        _state = RecorderState.done;
        _lastTranscript = transcript;
      });
    } catch (error) {
      _setError(error.toString());
    } finally {
      clip?.dispose();
      await _refreshTrayMenu();
      await _hideWindowAfterCapture();
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
      if (_supportsShortcutSettings) {
        await _configRepository.saveShortcutConfig(_shortcutConfig);
        if (_initializePlatformServices) {
          await _registerHotkeys();
        }
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _config = config;
        _state = RecorderState.ready;
        _showSettings = false;
        _lastError = null;
        _settingsStatus = null;
      });
      await _hideWindowAfterCapture();
    } catch (error) {
      setState(() {
        _state = RecorderState.needsConfig;
        _lastError = error.toString();
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
    if (!_initializePlatformServices || _showSettings) {
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
        _state = RecorderState.needsConfig;
      }
    });
    _refreshModelsIfPossible();
    unawaited(_showSettingsWindow());
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
      case 'quit_app':
        unawaited(_quit());
    }
  }

  @override
  void onWindowClose() {
    if (_isQuitting) {
      return;
    }
    windowManager.hide();
    unawaited(windowManager.setSkipTaskbar(true));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: _showSettings ? null : Colors.transparent,
      appBar: _showSettings
          ? AppBar(
              title: const Text('Settings'),
              actions: [
                IconButton(
                  tooltip: 'Close',
                  onPressed: _config?.isComplete == true
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
        padding: EdgeInsets.all(_showSettings ? 24 : 0),
        child: _showSettings
            ? _buildSettings(context)
            : _buildRecorder(context),
      ),
      bottomNavigationBar: !_showSettings || _lastError == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
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
    final modelDropdownValue = _availableModels.contains(_selectedModelValue)
        ? _selectedModelValue
        : _customModelValue;

    return ListView(
      children: [
        Text(
          'Audio API v${SttappAudio.nativeApiVersion} · Input API v${DesktopInput.nativeApiVersion}',
        ),
        const SizedBox(height: 20),
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
            if (value != null) {
              _selectModel(value);
            }
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
        if (_supportsShortcutSettings) ...[
          const SizedBox(height: 20),
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
        if (_settingsStatus != null) ...[
          const SizedBox(height: 16),
          Text(
            _settingsStatus!,
            style: TextStyle(
              color: _settingsStatus!.startsWith('Connection successful')
                  ? colorScheme.primary
                  : colorScheme.error,
            ),
          ),
        ],
        if (_isLoadingModels) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isTestingConnection ? null : _testConnection,
                child: _isTestingConnection
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Test Connection'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _saveSettings,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
