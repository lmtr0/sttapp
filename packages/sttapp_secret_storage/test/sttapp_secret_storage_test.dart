import 'package:sttapp_secret_storage/sttapp_secret_storage.dart';
import 'package:test/test.dart';

void main() {
  test('exception string is the message', () {
    const exception = SttappSecretStorageException('storage failed');

    expect(exception.toString(), 'storage failed');
  });

  test('storage object can be constructed without touching native store', () {
    const storage = SttappSecretStorage();

    expect(storage, isA<SttappSecretStorage>());
  });
}
