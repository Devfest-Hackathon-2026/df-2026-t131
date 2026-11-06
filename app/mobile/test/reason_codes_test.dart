import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'assets/reason_codes.json は schema/reason_codes.json と同じ（写しがずれていない）',
    () {
      final copy = File('assets/reason_codes.json').readAsStringSync();
      final source = File('../../schema/reason_codes.json').readAsStringSync();
      String norm(String s) => s.replaceAll('\r\n', '\n').trim();
      expect(
        norm(copy),
        norm(source),
        reason: 'schema/reason_codes.json が変わったら app/mobile/assets/ にコピーし直す',
      );
    },
  );
}
