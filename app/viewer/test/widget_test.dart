import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewer/main.dart';

void main() {
  testWidgets('起動すると同梱の歩行ログを読み込み、再生の操作と判断ログを出す', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ViewerApp(showMapTiles: false));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    expect(find.text('判断画面（歩行ログの再生）'), findsOneWidget);
    expect(find.byTooltip('再生'), findsOneWidget);
    expect(find.text('判断ログ（新しい順）'), findsOneWidget);
    expect(find.textContaining('スマートグラスの代わりにスマホ'), findsOneWidget);

    // 終わりまで進めると、判断ログが並ぶ
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(slider.max);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsWidgets);
  });
}
