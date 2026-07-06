import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sttapp/main.dart';

void main() {
  test('app widget is available', () {
    expect(const SttApp(), isA<StatelessWidget>());
  });
}
