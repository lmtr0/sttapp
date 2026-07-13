import 'package:sttapp_secret_storage/sttapp_secret_storage.dart';
import 'package:test/test.dart';

void main() {
  test('loads the bundled Rust library', () {
    expect(SttappSecretStorage.nativeApiVersion, 1);
  });

  test('exception string is the message', () {
    const exception = SttappSecretStorageException('storage failed');

    expect(exception.toString(), 'storage failed');
  });

  test(
    'storage object can be constructed without initializing native store',
    () {
      const storage = SttappSecretStorage();

      expect(storage, isA<SttappSecretStorage>());
    },
  );
}
