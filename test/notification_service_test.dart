import 'package:flutter_test/flutter_test.dart';
import 'package:sttapp/services/notification_service.dart';

void main() {
  test('noop notification service methods do not throw', () async {
    const service = NoopNotificationService();

    await expectLater(service.initialize(), completes);
    await expectLater(service.showRecordingFinishedTranscribing(), completes);
    await expectLater(service.dispose(), completes);
  });
}
