import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/dev/fake_gps.dart';
import 'package:mobile/dev/fake_gps_panel.dart';
import 'package:mobile/sources/gaze_source.dart';
import 'package:mobile/sources/location_source.dart';

class _Loc implements LocationSource {
  @override
  Stream<LocationFix> get fixes => const Stream.empty();
}

class _Gaze implements GazeSource {
  @override
  Stream<GazeReading> get readings => const Stream.empty();
  @override
  Future<void> updateLocation(double lat, double lon, double? altM) async {}
}

void main() {
  for (final size in const [Size(640, 360), Size(915, 412)]) {
    testWidgets('フェイク GPS の操作盤はミニプレイヤーのように動き、四隅へ吸い付く（$size）', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final gps = FakeGpsController(
        realLocation: _Loc(),
        realGaze: _Gaze(),
        tick: const Duration(hours: 1),
      )..setEnabled(true);
      addTearDown(gps.dispose);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MovableFakeGpsPanel(
              controller: gps,
              margin: 12,
              initialTop: 150,
            ),
          ),
        ),
      );
      await t.pump();
      final panel = find.byType(FakeGpsPanel);
      final r0 = t.getRect(panel);
      // 最初から画面の中に収まっている
      expect(r0.left >= 12 && r0.right <= size.width - 12, isTrue);
      expect(r0.top >= 12 && r0.bottom <= size.height - 12, isTrue);

      // 札の所を引くと付いてきて、離すと近い四隅（左上）へ吸い付く
      final g = await t.startGesture(t.getCenter(find.text('フェイクGPS')));
      for (var i = 0; i < 12; i++) {
        await g.moveBy(const Offset(-40, -8));
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(t.getRect(panel).left, lessThan(r0.left));
      await g.up();
      await t.pumpAndSettle();
      final r1 = t.getRect(panel);
      expect(r1.left, closeTo(12, 0.5));
      expect(r1.top, closeTo(12, 0.5));

      // 大きく投げても画面の外には出ず、右下の隅に収まる
      await t.fling(find.text('フェイクGPS'), const Offset(3000, 3000), 3000);
      await t.pumpAndSettle();
      final r2 = t.getRect(panel);
      expect(r2.right, closeTo(size.width - 12, 0.5));
      expect(r2.bottom, closeTo(size.height - 12, 0.5));

      // 再生ボタンは引く操作と別に押せる
      await t.tap(find.byTooltip('歩く'));
      await t.pump();
      expect(gps.playing, isTrue);

      // たたむと札の行だけになる
      await t.tap(find.byTooltip('たたむ'));
      await t.pumpAndSettle();
      expect(t.getRect(panel).height, lessThan(r2.height));
      expect(find.byTooltip('止める'), findsNothing);

      // 後片付け（フェイク GPS のタイマーとツールチップのタイマーを止める）
      gps.setEnabled(false);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 5));
    });
  }
}
