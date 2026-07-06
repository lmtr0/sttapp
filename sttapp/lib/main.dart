import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sttapp_audio/sttapp_audio.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  await windowManager.setSkipTaskbar(true);

  const windowOptions = WindowOptions(
    size: Size(420, 300),
    minimumSize: Size(360, 260),
    center: true,
    title: 'sttapp',
    skipTaskbar: true,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.hide();
  });

  runApp(const SttApp());
}

class SttApp extends StatelessWidget {
  const SttApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'sttapp',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1967D2)),
        useMaterial3: true,
      ),
      home: const RecorderHome(),
    );
  }
}

class RecorderHome extends StatefulWidget {
  const RecorderHome({super.key});

  @override
  State<RecorderHome> createState() => _RecorderHomeState();
}

class _RecorderHomeState extends State<RecorderHome>
    with TrayListener, WindowListener {
  late final AudioRecorder _recorder;

  AudioRecording? _recording;
  String _status = 'Ready';
  String? _lastOutputPath;
  String? _lastError;
  bool _isWriting = false;
  bool _isQuitting = false;

  bool get _isRecording => _recording != null;

  @override
  void initState() {
    super.initState();
    _recorder = AudioRecorder();
    trayManager.addListener(this);
    windowManager.addListener(this);
    _initTray();
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _initTray() async {
    await trayManager.setIcon(
      Platform.isWindows
          ? 'windows/runner/resources/app_icon.ico'
          : 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png',
    );
    await trayManager.setToolTip('sttapp audio capture');
    await _refreshTrayMenu();
  }

  Future<void> _refreshTrayMenu() async {
    final menu = Menu(
      items: [
        MenuItem(
          key: 'start_capture',
          label: _isRecording ? 'Recording' : 'Start capture',
        ),
        MenuItem(key: 'stop_capture', label: 'Stop capture'),
        MenuItem.separator(),
        MenuItem(key: 'show_window', label: 'Show'),
        MenuItem(key: 'quit_app', label: 'Quit'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  Future<void> _startCapture() async {
    if (_isRecording || _isWriting) {
      return;
    }

    setState(() {
      _status = 'Starting capture';
      _lastError = null;
    });
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
        _status = 'Recording';
      });
      await _showWindow();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Ready';
        _lastError = error.toString();
      });
    } finally {
      await _refreshTrayMenu();
    }
  }

  Future<void> _stopCapture() async {
    final recording = _recording;
    if (recording == null || _isWriting) {
      return;
    }

    setState(() {
      _recording = null;
      _isWriting = true;
      _status = 'Writing audio.wav';
      _lastError = null;
    });
    await _refreshTrayMenu();

    AudioClip? clip;
    try {
      clip = await recording.stop();
      final output = File(
        '${Directory.current.path}${Platform.pathSeparator}audio.wav',
      );
      await clip.writeWav(output);
      if (!mounted) {
        return;
      }
      setState(() {
        _lastOutputPath = output.path;
        _status = 'Saved audio.wav';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'Ready';
        _lastError = error.toString();
      });
    } finally {
      clip?.dispose();
      if (mounted) {
        setState(() {
          _isWriting = false;
        });
      }
      await _refreshTrayMenu();
    }
  }

  Future<void> _showWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    if (_isQuitting) {
      return;
    }
    _isQuitting = true;
    await _stopCapture();
    await trayManager.destroy();
    exit(0);
  }

  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'start_capture':
        _startCapture();
      case 'stop_capture':
        _stopCapture();
      case 'show_window':
        _showWindow();
      case 'quit_app':
        _quit();
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
    final isBusy = _isRecording || _isWriting;

    return Scaffold(
      appBar: AppBar(title: const Text('sttapp')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  _isRecording ? Icons.mic : Icons.mic_none,
                  color: _isRecording
                      ? colorScheme.primary
                      : colorScheme.outline,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _status,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Native audio API v${SttappAudio.nativeApiVersion}'),
            const SizedBox(height: 8),
            Text('Output: ${_lastOutputPath ?? 'No recording saved yet'}'),
            if (_lastError != null) ...[
              const SizedBox(height: 16),
              Text(_lastError!, style: TextStyle(color: colorScheme.error)),
            ],
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: isBusy ? null : _startCapture,
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRecording && !_isWriting
                        ? _stopCapture
                        : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
