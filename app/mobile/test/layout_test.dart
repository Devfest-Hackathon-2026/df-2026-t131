import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/app/app_mode.dart';
import 'package:mobile/app/app_services.dart';
import 'package:mobile/app/app_settings.dart';
import 'package:mobile/core/sensor_ticker.dart';
import 'package:mobile/executors/voice_catalog.dart';
import 'package:mobile/info/alert_message.dart';
import 'package:mobile/sources/activity_source.dart';
import 'package:mobile/sources/audio_state_source.dart';
import 'package:mobile/sources/camera_source.dart';
import 'package:mobile/sources/gaze_source.dart';
import 'package:mobile/sources/location_source.dart';
import 'package:mobile/ui/collapsible_sheet.dart';
import 'package:mobile/ui/glass_overlay.dart';
import 'package:mobile/ui/glass_view_screen.dart';
import 'package:mobile/ui/layout.dart';
import 'package:mobile/ui/start_screen.dart';
import 'package:mobile/ui/style.dart';

import 'support/alert_fixture.dart';

class _Cam implements CameraSource {
  @override
  CameraController? get controller => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  CameraFrame? latestFrame() => null;
  @override
  Future<CameraFrame?> captureFrame() async => null;
}

class _Loc implements LocationSource {
  final c = StreamController<LocationFix>.broadcast(sync: true);
  @override
  Stream<LocationFix> get fixes => c.stream;
}

class _Gaze implements GazeSource {
  final c = StreamController<GazeReading>.broadcast(sync: true);
  @override
  Stream<GazeReading> get readings => c.stream;
  @override
  Future<void> updateLocation(double lat, double lon, double? altM) async {}
}

class _Act implements ActivitySource {
  @override
  Stream<ActivityKind> get changes => const Stream.empty();
}

class _Audio implements AudioStateSource {
  @override
  Stream<AudioState> get states => const Stream.empty();
}

/// 横持ちの代表的な画面の大きさ（論理ピクセル）。小さいスマホ・今の実機・大きめのスマホ・タブレット。
const sizes = <String, Size>{
  '小さいスマホ 640x360': Size(640, 360),
  'Zenfone 10 相当 915x412': Size(915, 412),
  '大きめのスマホ 960x432': Size(960, 432),
  'タブレット 1280x800': Size(1280, 800),
};

AppServices _services() {
  final loc = _Loc();
  final gaze = _Gaze();
  final ticker = SensorTicker(
    locationSource: loc,
    gazeSource: gaze,
    activitySource: _Act(),
    audioStateSource: _Audio(),
    interval: const Duration(days: 1),
  )..start();
  final s = AppServices(
    camera: _Cam(),
    ticker: ticker,
    settingsStore: MemorySettingsStore(),
    voices: VoiceCatalog(),
    policy: const DemoSessionPolicy(),
    mode: AppMode.demo,
  );
  loc.c.add(
    const LocationFix(
      lat: 36.7,
      lon: 137.2,
      accM: 54,
      speedMps: 1.3,
      courseDeg: 0,
      altM: null,
    ),
  );
  gaze.c.add(const GazeReading(azDeg: 350, pitchDeg: 0));
  // いちばん長い表示内容で試す
  s.overlay.value = const GlassOverlay(
    decision: 'speak:closest_approach',
    reason: 'ランドマークの最接近の直前',
    subtitle: '右手の石碑は、見本のために置いた架空の石碑です。明治時代に建てられました。',
    areaName: '富岩運河環水公園',
    nextSearchIn: Duration(seconds: 23),
    lastSearch: 'skip 画質が低い',
    candidates: [
      CandidateMark(name: '見本の石碑', bearingDeg: 10, distanceM: 32),
      CandidateMark(name: '見本の橋', bearingDeg: 200, distanceM: 180),
    ],
  );
  return s;
}

Future<AppServices> _pump(
  WidgetTester tester,
  Size size,
  Widget Function(AppServices) screen,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final s = _services();
  await tester.pumpWidget(
    MaterialApp(theme: buildTheme(), builder: clampTextScale, home: screen(s)),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return s;
}

void main() {
  for (final e in sizes.entries) {
    testWidgets('開始画面が ${e.key} に収まる', (tester) async {
      final s = await _pump(tester, e.value, (s) => StartScreen(services: s));
      expect(tester.takeException(), isNull);
      // 「計測開始」は必ず画面の中に見えている
      final r = tester.getRect(find.text('計測開始').hitTestable());
      expect(r.bottom, lessThanOrEqualTo(e.value.height));
      s.ticker.stop(); // 1秒タイマーはその場で止まる（終わりは待たない）
    });

    testWidgets('記録中の画面が ${e.key} に収まる', (tester) async {
      final s = await _pump(
        tester,
        e.value,
        (s) => GlassViewScreen(services: s),
      );
      expect(tester.takeException(), isNull);
      final r = tester.getRect(find.text('終了'));
      expect(r.right, lessThanOrEqualTo(e.value.width));
      expect(r.bottom, lessThanOrEqualTo(e.value.height));
      // 左上のカードと右上の札が重ならない
      final banner = tester.getRect(find.textContaining('スマートグラスの代わりに'));
      final now = tester.getRect(find.textContaining('右手の石碑は'));
      expect(banner.overlaps(now), isFalse);
      s.ticker.stop(); // 1秒タイマーはその場で止まる（終わりは待たない）
    });

    testWidgets('警報の帯が ${e.key} で画面に収まり、ほかと重ならない', (tester) async {
      for (final glass in [false, true]) {
        final s = await _pump(
          tester,
          e.value,
          (s) =>
              glass ? GlassViewScreen(services: s) : StartScreen(services: s),
        );
        s.activeAlert.value = parseAlertData(
          mockAlertData(level: 4, nowMs: 1),
          receivedMs: 1,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        final a = tester.getRect(find.textContaining('レベル4  '));
        expect(a.right, lessThanOrEqualTo(e.value.width));
        expect(a.bottom, lessThanOrEqualTo(e.value.height));
        final other = glass
            ? find.textContaining('右手の石碑は')
            : find.text('計測開始').hitTestable();
        expect(a.overlaps(tester.getRect(other)), isFalse);
        await tester.tap(find.byTooltip('警報の表示を閉じる'));
        expect(s.activeAlert.value, isNull);
        s.ticker.stop();
      }
    });
  }

  final handle = find.byKey(sheetHandleKey);

  testWidgets('開始画面：右中央のバーを左へ引くとたたまれ、「計測開始」の札が出る', (tester) async {
    final s = await _pump(
      tester,
      sizes.values.first,
      (s) => StartScreen(services: s),
    );
    expect(find.text('計測開始').hitTestable(), findsOneWidget);
    // 少しだけ引いて離すと元に戻る
    await tester.timedDrag(
      handle,
      const Offset(-40, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.expand_less).hitTestable(), findsNothing);
    // しっかり引くとたたまれる
    await tester.drag(handle, const Offset(-400, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.expand_less).hitTestable(), findsOneWidget);
    // 札を押すと戻る
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.expand_less).hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    s.ticker.stop();
  });

  testWidgets('記録中：上中央のバーを下へはらうとたたまれ、終了ボタンが残る', (tester) async {
    final s = await _pump(
      tester,
      sizes.values.first,
      (s) => GlassViewScreen(services: s),
    );
    expect(find.byTooltip('終了').hitTestable(), findsNothing);
    await tester.fling(handle, const Offset(0, 120), 1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byTooltip('終了').hitTestable(), findsOneWidget);
    // 代用の明示はたたんでも消さない
    expect(find.textContaining('スマートグラスの代わりに'), findsOneWidget);
    // バーを押すと戻る
    await tester.tap(handle);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byTooltip('終了').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
    s.ticker.stop();
  });

  for (final e in sizes.entries) {
    testWidgets('カメラで調べない区域の札が ${e.key} に収まり、B の行が止めている表示になる', (tester) async {
      // 画面は親の通知で描き直すので、描く前に値を入れる
      tester.view.physicalSize = e.value;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = _services();
      final o = s.overlay.value;
      s.overlay.value = GlassOverlay(
        decision: o.decision,
        reason: o.reason,
        areaName: o.areaName,
        nextSearchIn: o.nextSearchIn,
        noCameraZoneName: 'あいの島・バードサンクチュアリ',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          builder: clampTextScale,
          home: GlassViewScreen(services: s),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('カメラで調べない区域（デモのため仮に指定）'), findsOneWidget);
      expect(find.text('あいの島・バードサンクチュアリ'), findsOneWidget);
      expect(find.text('画像での案内は止めています'), findsWidgets);
      expect(find.textContaining('次の画像検索まで'), findsNothing);
      expect(tester.takeException(), isNull);
      s.ticker.stop();
    });
  }

  testWidgets('区域に入った・出たのポップアップを出す', (tester) async {
    final s = await _pump(
      tester,
      sizes.values.first,
      (s) => GlassViewScreen(services: s),
    );
    s.zoneNotice.value = const ZoneNotice(zoneName: 'あいの島', entered: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('カメラで調べない区域に入りました'), findsOneWidget);
    expect(find.text('あいの島・画像での案内を止めます'), findsOneWidget);
    s.zoneNotice.value = const ZoneNotice(zoneName: 'あいの島', entered: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('カメラで調べない区域を出ました'), findsOneWidget);
    expect(tester.takeException(), isNull);
    s.ticker.stop();
  });
}
