import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const recordingFinishedTranscribingNotificationId = 1001;

abstract interface class NotificationService {
  Future<void> initialize();

  Future<void> showRecordingFinishedTranscribing();

  Future<void> dispose();
}

final class SystemNotificationService implements NotificationService {
  SystemNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    try {
      final initialized = await _plugin.initialize(
        settings: const InitializationSettings(
          macOS: DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          linux: LinuxInitializationSettings(
            defaultActionName: 'Open sttapp',
            defaultSuppressSound: true,
          ),
          windows: WindowsInitializationSettings(
            appName: 'sttapp',
            appUserModelId: 'com.taresz.sttapp',
            guid: 'f58ece71-f12f-4f69-99e2-5d1077037d89',
          ),
        ),
      );
      _initialized = initialized ?? false;
    } catch (error, stackTrace) {
      debugPrint('Notification initialization failed: $error');
      debugPrint('$stackTrace');
    }
  }

  @override
  Future<void> showRecordingFinishedTranscribing() async {
    if (!_initialized) {
      return;
    }

    try {
      await _plugin.show(
        id: recordingFinishedTranscribingNotificationId,
        title: 'sttapp',
        body: 'Recording finished. Transcribing...',
        notificationDetails: NotificationDetails(
          macOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: false,
            presentSound: false,
            presentBanner: true,
            presentList: true,
          ),
          linux: const LinuxNotificationDetails(suppressSound: true),
          windows: WindowsNotificationDetails(
            audio: WindowsNotificationAudio.silent(),
          ),
        ),
      );
    } catch (error, stackTrace) {
      debugPrint('Notification display failed: $error');
      debugPrint('$stackTrace');
    }
  }

  @override
  Future<void> dispose() async {}
}

final class NoopNotificationService implements NotificationService {
  const NoopNotificationService();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> showRecordingFinishedTranscribing() async {}

  @override
  Future<void> dispose() async {}
}
