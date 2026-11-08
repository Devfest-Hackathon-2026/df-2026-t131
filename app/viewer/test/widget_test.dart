import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewer/main.dart';

void main() {
  testWidgets('起動すると同梱の歩行ログを読み込み、再生の操作と判断ログを出す', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const ViewerApp(showMapTiles: false));
    // 同梱のログは大きい（実機の15分）ので、読み込みは別のスレッドで進む。
    // 本物の時間を少し進めては画面を更新し、読み込み中の表示が消えるまで待つ
    for (
      var i = 0;
      i < 40 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(find.text('判断画面（歩行ログの再生）'), findsOneWidget);
    expect(find.byTooltip('再生'), findsOneWidget);
    expect(find.text('判断ログ（新しい順）'), findsOneWidget);
    expect(find.textContaining('スマートグラスの代わりにスマホ'), findsOneWidget);
    // 地図の出典（地理院タイル・OpenStreetMap）は常に出す
    expect(find.text('地理院タイル（国土地理院）'), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);

    // 終わりまで進めると、判断ログが並ぶ
    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(slider.max);
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsWidgets);
  });
}
