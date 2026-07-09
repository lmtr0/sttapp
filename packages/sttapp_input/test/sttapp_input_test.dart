import 'package:sttapp_input/sttapp_input.dart';
import 'package:test/test.dart';

void main() {
  test('loads the bundled Rust library', () {
    expect(DesktopInput.nativeApiVersion, 2);
  });
}
