import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/ui/licenses.dart';

void main() {
  test('pub.dev 以外のライセンスと出典がライセンスの一覧に1回だけ入る', () async {
    registerExtraLicenses();
    registerExtraLicenses(); // 2回呼んでも増えない
    final names = <String>[];
    await for (final e in LicenseRegistry.licenses) {
      names.addAll(e.packages);
    }
    for (final (name, _) in extraLicenses) {
      expect(names.where((n) => n == name), hasLength(1), reason: name);
    }
  });

  test('出典の表示が求められているデータを出典の文に入れている', () {
    final text = dataAttributions.join('\n');
    expect(text, contains('© OpenStreetMap contributors'));
    expect(text, contains('位置参照情報'));
    expect(text, contains('気象庁'));
    expect(text, contains('富山市オープンデータ'));
  });
}
