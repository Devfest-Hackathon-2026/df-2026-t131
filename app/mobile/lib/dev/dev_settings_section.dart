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
            title: const Text('模擬の警報を鳴らす'),
            subtitle: const Text(
              '本物の FCM と同じ形の警報を、アプリの中で流します。'
              'レベル4は今の読み上げに割り込み、音楽を一時停止します。記録中なら歩行ログに alert 行が残ります。',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => widget.services.alerts.sendMock(level: 4),
                  child: const Text('レベル4（割り込み）'),
                ),
                OutlinedButton(
                  onPressed: () => widget.services.alerts.sendMock(level: 3),
                  child: const Text('レベル3'),
                ),
              ],
            ),
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
