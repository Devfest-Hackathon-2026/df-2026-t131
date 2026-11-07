import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../logging/walk_log_store.dart';
import '../ui/style.dart';
import 'fake_gps.dart';
import 'fake_track.dart';
import 'track_import.dart';

/// 設定画面の「開発者モード」。フェイク GPS で A（位置による音声ガイド）を机の上で試す。
class DevSettingsSection extends StatefulWidget {
  const DevSettingsSection({super.key, required this.services});

  final AppServices services;

  @override
  State<DevSettingsSection> createState() => _DevSettingsSectionState();
}

class _DevSettingsSectionState extends State<DevSettingsSection> {
  late Future<List<WalkLogInfo>> _logs = widget.services.walkLogs.list();
  final _testStore = TestTrackStore();
  late Future<List<File>> _tests = _testStore.list();
  late final Future<String> _testDir = _testStore.directory().then(
    (d) => d.path,
  );
  String? _loadError;

  void _reload() => setState(() {
    _logs = widget.services.walkLogs.list();
    _tests = _testStore.list();
  });

  Future<void> _useTestFile(File f) async {
    final name = f.uri.pathSegments.last;
    try {
      final track = await const TrackImporter().loadFile(f);
      if (!mounted) return;
      setState(() => _loadError = null);
      _gps!.setTrack(track);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = '$name を読めません：$e');
    }
  }

  FakeGpsController? get _gps => widget.services.fakeGps;

  Future<void> _useLog(WalkLogInfo log) async {
    final track = await LogTrack.load(log.file);
    if (!mounted) return;
    if (track == null) {
      setState(() => _loadError = '${log.name} に位置の行がありません');
      return;
    }
    setState(() => _loadError = null);
    _gps!.setTrack(track);
  }

  Future<void> _close() async {
    _gps?.setEnabled(false);
    final s = widget.services.settings.value;
    await widget.services.updateSettings(s.copyWith(developerMode: false));
  }

  @override
  Widget build(BuildContext context) {
    final gps = _gps;
    if (gps == null) {
      return const ListTile(title: Text('この組み立てではフェイク GPS を使えません'));
    }
    return ListenableBuilder(
      listenable: gps,
      builder: (context, _) => Column(
        children: [
          _DemoTapSection(services: widget.services),
          SwitchListTile(
            value: gps.enabled,
            onChanged: gps.setEnabled,
            secondary: const Icon(Icons.route),
            title: const Text('フェイクGPSを使う'),
            subtitle: const Text(
              '本物の GPS の代わりに、選んだ道のりを歩いている位置を流します。'
              '位置による音声ガイド（A）の確認用です。カメラは本物のままなので、'
              '画像検索（B）の確認には向きません。記録したログの名前には _fake が付きます。',
            ),
          ),
          SwitchListTile(
            value: gps.gazeFollowsRoute,
            onChanged: gps.setGazeFollowsRoute,
            secondary: const Icon(Icons.explore_outlined),
            title: const Text('向きを進行方向に合わせる'),
            subtitle: const Text('オフにすると、端末の向き（本物のセンサー）を使います。'),
          ),
          ValueListenableBuilder(
            valueListenable: widget.services.settings,
            builder: (context, s, _) => SwitchListTile(
              value: s.demoAlertNearLovers,
              onChanged: (v) => widget.services.updateSettings(
                s.copyWith(demoAlertNearLovers: v),
              ),
              secondary: const Icon(Icons.warning_amber_outlined),
              title: const Text('ラバーズ像に近づいたらデモの警報を流す（割り込みの確認用）'),
              subtitle: const Text(
                '計測中にラバーズ像の話が始まるか範囲に入ったら、3秒後に「デモの警報」（レベル4）を'
                '本物の警報と同じ入口から流します。話している途中なら割り込みます。1回の計測で1回だけです。'
                '文の中で「実際の警報ではありません」と言います。',
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: widget.services.settings,
            builder: (context, s, _) => SwitchListTile(
              value: s.retellLandmarks,
              onChanged: (v) => widget.services.updateSettings(
                s.copyWith(retellLandmarks: v),
              ),
              secondary: const Icon(Icons.replay),
              title: const Text('通ったランドマークをもう一度話す（検証用）'),
              subtitle: const Text(
                '一度話したランドマーク・エリアも、範囲から離れてもう一度近づいたら話します。'
                '同じ道を往復して試すとき用です。次の「計測開始」から効きます。開発者モードを閉じると元に戻ります。',
              ),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: widget.services.settings,
            builder: (context, s, _) => SwitchListTile(
              value: s.saveSentImages,
              onChanged: (v) =>
                  widget.services.updateSettings(s.copyWith(saveSentImages: v)),
              secondary: const Icon(Icons.photo_library_outlined),
              title: const Text('AI に送った画像を保存する（検証用）'),
              subtitle: const Text(
                '計測中に画像検索で送った画像（顔をぼかしたあと）を、歩行ログの隣の '
                'walk_〇〇_images/ に「検索 ID.jpg」で保存します。開発者モードを閉じると保存しません。'
                '歩行ログを消すと一緒に消えます。人の写った画像は人に渡さないでください。',
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '歩く道のり',
                style: TextStyle(color: AppColors.subtext, fontSize: 14),
              ),
            ),
          ),
          _TrackTile(
            title: demoRouteToyama.name,
            subtitle:
                '${demoRouteToyama.lengthM.toStringAsFixed(0)} m・'
                '約 ${(demoRouteToyama.durationS / 60).toStringAsFixed(0)} 分（1.3 m/s）',
            selected: identical(gps.track, demoRouteToyama),
            onTap: () => gps.setTrack(demoRouteToyama),
          ),
          FutureBuilder<List<WalkLogInfo>>(
            future: _logs,
            builder: (context, snap) {
              final logs = (snap.data ?? const <WalkLogInfo>[])
                  .where((l) => !widget.services.walkLogs.isInUse(l))
                  .take(5);
              return Column(
                children: [
                  for (final l in logs)
                    _TrackTile(
                      title: '歩行ログ：${l.name}',
                      subtitle: '記録した道を1秒1行で流し直します',
                      selected: gps.track.name == l.name,
                      onTap: () => _useLog(l),
                    ),
                ],
              );
            },
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '検証用データ（GPX・GeoJSON・JSON・CSV・歩行ログ）',
                style: TextStyle(color: AppColors.subtext, fontSize: 14),
              ),
            ),
          ),
          FutureBuilder<List<File>>(
            future: _tests,
            builder: (context, snap) {
              final files = snap.data ?? const <File>[];
              if (snap.hasError) {
                return ListTile(title: Text('フォルダを読めません：${snap.error}'));
              }
              return Column(
                children: [
                  for (final f in files)
                    _TrackTile(
                      title: f.uri.pathSegments.last,
                      subtitle: '時刻付きならその速さで、無ければ 1.3 m/s で歩きます',
                      selected: gps.track.name == f.uri.pathSegments.last,
                      onTap: () => _useTestFile(f),
                    ),
                  FutureBuilder<String>(
                    future: _testDir,
                    builder: (context, dir) => ListTile(
                      leading: const Icon(Icons.folder_open_outlined),
                      title: Text(
                        files.isEmpty ? '置いたファイルはまだありません' : '${files.length} 件',
                      ),
                      subtitle: SelectableText(
                        'PC から置く：adb push ファイル名 ${dir.data ?? '…'}/',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          if (_loadError != null)
            ListTile(
              leading: const Icon(Icons.error_outline, color: AppColors.danger),
              title: Text(_loadError!),
            ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('一覧を読み直す'),
            onTap: _reload,
          ),
          ListTile(
            leading: const Icon(
              Icons.warning_amber_rounded,
              color: AppColors.danger,
            ),
            title: const Text('警報の順番と割り込みを確かめる'),
            subtitle: const Text(
              '警報はサーバーから届いたものだけを読みます（アプリの中で警報は作りません）。'
              '模擬の警報は、サーバーの /mock-alert（メンバー1）から送ってもらいます。'
              '先に「案内を流す」で長めの案内（優先度5）を流しておくと、'
              'レベル4が割り込むか・レベル3が案内の後に話すかを確かめられます。',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: widget.services.speakDevLandmark,
                child: const Text('案内を流す（優先度5）'),
              ),
            ),
          ),
          Builder(
            builder: (context) {
              final t = widget.services.tiles;
              return ListTile(
                leading: const Icon(Icons.grid_view),
                title: const Text('地図タイル（A）'),
                subtitle: Text(
                  '持っている ${t.tiles.length} 枚（うち空 ${t.empty} 枚）・'
                  '取得 ${t.fetched}・端末から ${t.fromCache}・失敗 ${t.failed}\n'
                  '前回：${t.lastResult}\n'
                  'どのタイルを取るかは engine が決めます（計測中だけ）。送るのはタイル番号だけ。'
                  '空のタイル（範囲の外）も覚えて、同じタイルは問い合わせ直しません。押すと数を更新します。',
                ),
                onTap: () => setState(() {}),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.layers_clear_outlined),
            title: const Text('地図のキャッシュを消す'),
            subtitle: const Text(
              'サーバーの地図データは再デプロイのたびに変わります。'
              'デモの撮影の前や、データを直してもらったあとに押してください（次の計測で取り直します）。',
            ),
            onTap: () async {
              await widget.services.tiles.clear();
              if (!context.mounted) return;
              setState(() {});
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('地図のキャッシュを消しました')));
            },
          ),
          ListTile(
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('警報の一覧を取りに行く'),
            subtitle: Text(
              'FCM が届かなかったときの保険（公開の Cloud Storage の alerts/current/'
              '1620100.json と、模擬の警報の mock_1620100.json）。'
              'まだ聞いていない警報があれば読み上げます。'
              '前回：${widget.services.alertList.lastResult}',
            ),
            onTap: () async {
              await widget.services.refreshAlerts(force: true);
              if (mounted) setState(() {});
            },
          ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('開発者モードを閉じる'),
            subtitle: const Text('フェイク GPS もやめて、本物の GPS に戻します。'),
            onTap: _close,
          ),
        ],
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(
      selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      color: selected ? AppColors.accent : null,
    ),
    title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(subtitle),
    onTap: onTap,
  );
}

/// デモ撮影のワンタップ（11/7）。押してから15秒後に、本物と同じ入口から流す
/// （操作している画面を動画から切れるように）。計測中だけ使える。
class _DemoTapSection extends StatelessWidget {
  const _DemoTapSection({required this.services});

  final AppServices services;

  static const _labels = {
    DemoTap.landmark: 'ランドマークの案内',
    DemoTap.alert: 'デモの警報（レベル4）',
    DemoTap.landmarkThenAlert: '案内の途中に警報（割り込み）',
  };

  void _tap(BuildContext context, DemoTap kind) {
    final ok = services.scheduleDemo(kind);
    final sec = AppServices.demoTapDelay.inSeconds;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '${_labels[kind]}を $sec 秒後に流します。グラス視点の画面に戻ってください'
              : '計測を開始してから押してください',
        ),
      ),
    );
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const ListTile(
        leading: Icon(Icons.movie_creation_outlined),
        title: Text('デモ撮影のワンタップ'),
        subtitle: Text(
          '押してから15秒後に流します（操作している画面を動画から切れるように）。'
          '本物の警報・案内と同じ入口を通るので、割り込み・順番待ち・記録も本物と同じです。'
          '歩行ログと判断画面には「デモ」と残ります。案内は、いちばん近いランドマーク（エリアを除く）を'
          '話した履歴に関係なく話します。計測中だけ使えます。',
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 16, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final kind in [
              DemoTap.landmark,
              DemoTap.alert,
              DemoTap.landmarkThenAlert,
            ])
              OutlinedButton(
                onPressed: () => _tap(context, kind),
                child: Text(_labels[kind]!),
              ),
          ],
        ),
      ),
      ValueListenableBuilder(
        valueListenable: services.demoTaps,
        builder: (context, taps, _) => taps.isEmpty
            ? const SizedBox(height: 8)
            : ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(
                  [
                    for (final e in taps.entries)
                      '${_labels[e.key]}：${_clock(e.value)} に流す',
                  ].join('\n'),
                ),
                trailing: TextButton(
                  onPressed: services.cancelDemoTaps,
                  child: const Text('取り消す'),
                ),
              ),
      ),
    ],
  );
}
