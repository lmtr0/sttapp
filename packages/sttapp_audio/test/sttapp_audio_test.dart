import 'package:test/test.dart';

import 'package:sttapp_audio/sttapp_audio.dart';

void main() {
  test('loads the bundled Rust library', () {
    expect(SttappAudio.nativeApiVersion, 4);
  });
}
