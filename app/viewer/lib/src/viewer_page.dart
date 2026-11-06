import 'dart:async';
import 'dart:convert';

import 'package:engine/engine.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'demo_map.dart';
import 'map_view.dart';
import 'replay.dart';

/// 最初から入れておく歩行ログ（assets/walks/index.json）の1件。
final class BundledWalk {
  final String file, title, note;
  const BundledWalk(this.file, this.title, this.note);
  factory BundledWalk.fromJson(Map<String, dynamic> j) => BundledWalk(
    j['file'] as String,
    j['title'] as String,
    j['note'] as String? ?? '',
  );
}

/// 判断画面：歩行ログを engine に流し直し、位置・判断・理由コードを時系列で見せる。
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, this.showMapTiles = true});
  final bool showMapTiles;
  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  static const config = EngineConfig();
  static const _tick = Duration(milliseconds: 100);
  static const speeds = [1, 2, 5, 10, 30];

  List<BundledWalk> _walks = const [];
  Map<String, String> _reasonLabels = const {};
  DemoMap _map = DemoMap.empty;
  String? _title, _note, _error;
  Replay? _replay;
  int _nowMs = 0;
  int _speed = 5;
  bool _hideFetch = true;
  Timer? _timer;
  final _listController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _listController.dispose();
    super.dispose();
  }

  Future<void> _loadAssets() async {
    try {
      final codes = jsonDecode(
        await rootBundle.loadString('assets/reason_codes.json'),
      ) as Map<String, dynamic>;
      final index = jsonDecode(
        await rootBundle.loadString('assets/walks/index.json'),
      ) as List<dynamic>;
      final map = DemoMap.fromJson(
        jsonDecode(await rootBundle.loadString('assets/map.json'))
            as Map<String, dynamic>,
      );
      final walks = [
        for (final w in index) BundledWalk.fromJson(w as Map<String, dynamic>),
      ];
      setState(() {
        _reasonLabels = (codes['codes'] as Map<String, dynamic>).cast();
        _walks = walks;
        _map = map;
      });
      if (walks.isNotEmpty) await _openBundled(walks.first);
    } on Object catch (e) {
      setState(() => _error = '最初の歩行ログを読めませんでした：$e');
    }
  }

  Future<void> _openBundled(BundledWalk w) async {
    final text = await rootBundle.loadString('assets/walks/${w.file}');
    _load(text, w.title, w.note);
  }

  Future<void> _openFile() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '歩行ログ', extensions: ['jsonl']),
      ],
    );
    if (file == null) return;
    _load(await file.readAsString(), file.name, '手元のファイル');
  }

  void _load(String text, String title, String note) {
    _pause();
    try {
      final replay = Replay.run(parseWalkLog(text), config: config);
      setState(() {
        _replay = replay;
        _title = title;
        _note = note;
        _error = null;
        _nowMs = replay.startMs;
      });
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  void _play() {
    final r = _replay;
    if (r == null) return;
    if (_nowMs >= r.endMs) _nowMs = r.startMs;
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) {
      setState(() {
        _nowMs += _tick.inMilliseconds * _speed;
        if (_nowMs >= r.endMs) {
          _nowMs = r.endMs;
          _pause();
        }
      });
    });
    setState(() {});
  }

  void _pause() {
    _timer?.cancel();
    _timer = null;
    if (mounted) setState(() {});
  }

  void _seek(int tMs) => setState(() => _nowMs = tMs);

  String _clock(int tMs) {
    final r = _replay!;
    final s = (tMs - r.startMs) ~/ 1000;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final r = _replay;
    return Scaffold(
      appBar: AppBar(
        title: const Text('判断画面（歩行ログの再生）'),
        actions: [
          if (_walks.length > 1)
            PopupMenuButton<BundledWalk>(
              tooltip: '入っている歩行ログ',
              icon: const Icon(Icons.list),
              onSelected: _openBundled,
              itemBuilder: (_) => [
                for (final w in _walks)
                  PopupMenuItem(value: w, child: Text(w.title)),
              ],
            ),
          TextButton.icon(
            onPressed: _openFile,
            icon: const Icon(Icons.folder_open),
            label: const Text('ログを開く'),
          ),
        ],
      ),
      body: Column(
        children: [
          const _Notice(),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('閉じる'),
                ),
              ],
            ),
          if (r == null)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(child: _body(context, r)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, Replay r) {
    final frameIndex = r.frameIndexAt(_nowMs);
    final frame = r.frames[frameIndex];
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final map = Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          MapView(
            replay: r,
            frameIndex: frameIndex,
            map: _map,
            showTiles: widget.showMapTiles,
          ),
          const Positioned(left: 8, top: 8, child: _MapLegend()),
        ],
      ),
    );
    final state = _StatePanel(
      frame: frame,
      config: config,
      reasonLabels: _reasonLabels,
    );
    final log = _DecisionList(
      replay: r,
      frameIndex: frameIndex,
      hideFetch: _hideFetch,
      reasonLabels: _reasonLabels,
      clock: _clock,
      onTap: _seek,
      controller: _listController,
    );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          _controls(r),
          const SizedBox(height: 8),
          Expanded(
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 5, child: map),
                      SizedBox(width: 340, child: state),
                      SizedBox(width: 380, child: log),
                    ],
                  )
                : ListView(
                    children: [
                      SizedBox(height: 360, child: map),
                      state,
                      SizedBox(height: 420, child: log),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _controls(Replay r) {
    final playing = _timer != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            IconButton.filled(
              tooltip: playing ? '一時停止' : '再生',
              onPressed: playing ? _pause : _play,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            const SizedBox(width: 8),
            Text('${_clock(_nowMs)} / ${_clock(r.endMs)}'),
            Expanded(
              child: Slider(
                min: r.startMs.toDouble(),
                max: r.endMs.toDouble() == r.startMs.toDouble()
                    ? r.startMs + 1.0
                    : r.endMs.toDouble(),
                value: _nowMs.toDouble(),
                onChanged: (v) => _seek(v.round()),
              ),
            ),
            DropdownButton<int>(
              value: _speed,
              underline: const SizedBox(),
              items: [
                for (final s in speeds)
                  DropdownMenuItem(value: s, child: Text('×$s')),
              ],
              onChanged: (v) => setState(() => _speed = v ?? _speed),
            ),
            const SizedBox(width: 12),
            FilterChip(
              label: const Text('タイル取得を隠す'),
              selected: _hideFetch,
              onSelected: (v) => setState(() => _hideFetch = v),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Tooltip(
                message: _note ?? '',
                child: Text(
                  _title ?? '',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 審査で必ず示すこと（CLAUDE.md 1章・9章）。
class _Notice extends StatelessWidget {
  const _Notice();
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: c.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(
        '歩行ログ（位置・向き・行動など、判断エンジンへの入力の記録）を、アプリと同じ判断エンジンに流し直して表示しています。'
        '実機の記録は、スマートグラスの代わりにスマホで行っています。',
        style: TextStyle(color: c.onSecondaryContainer),
      ),
    );
  }
}

class _MapLegend extends StatelessWidget {
  const _MapLegend();
  @override
  Widget build(BuildContext context) {
    Widget item(Widget mark, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          mark,
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
    Widget dot(int c, [double size = 10]) =>
        Icon(Icons.circle, size: size, color: Color(c));
    return Card(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            item(dot(0xFFD62728), 'ランドマーク・エリア（円＝範囲）'),
            item(dot(0xFF9467BD), 'イベント'),
            item(dot(0xFF1F77B4, 7), '信号'),
            item(dot(0xFF2CA02C, 7), '横断歩道'),
            item(
              const Icon(Icons.navigation, size: 12, color: Color(0xFF3949AB)),
              'いまの位置と向き・歩いた道',
            ),
            item(dot(0xFFFF7F0E), '話し始めた場所'),
            item(
              const Icon(Icons.crop_square, size: 12, color: Color(0xFFE377C2)),
              'B で撮った場所',
            ),
            const SizedBox(height: 2),
            const Text(
              '灰色＝もう話したもの',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

/// いまの状態（engine.view とセンサー）。
class _StatePanel extends StatelessWidget {
  final ReplayFrame frame;
  final EngineConfig config;
  final Map<String, String> reasonLabels;
  const _StatePanel({
    required this.frame,
    required this.config,
    required this.reasonLabels,
  });

  @override
  Widget build(BuildContext context) {
    final v = frame.view;
    final s = frame.sensor;
    final text = Theme.of(context).textTheme;
    Widget section(String title, List<Widget> children) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleSmall),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
    final last = v.lastDecision;
    final next = v.nextSearchInMs;
    return Card(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          section('いまの判断', [
            if (last == null)
              const Text('まだありません')
            else ...[
              Text(_kindLabel(last.kind), style: text.titleMedium),
              Text(
                last.reason,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              if (reasonLabels[last.reason] case final label?) Text(label),
            ],
          ]),
          section('読み上げ中', [Text(frame.speaking?.text ?? '（なし）')]),
          section('歩いている様子', [
            if (s == null)
              const Text('センサーがまだ届いていません')
            else ...[
              Text(
                '行動：${_activityLabel(s.activity)}　速さ：${s.speedMps?.toStringAsFixed(1) ?? '—'} m/s',
              ),
              Text(
                '向き：${s.gazeAzDeg.round()}°　音声：${_audioLabel(s.audioOut)}${s.inCall ? '（通話中）' : ''}',
              ),
            ],
            Text('エリア：${v.currentArea?.name ?? '（エリアの外）'}'),
          ]),
          section('B（景色を調べる）', [
            Text(
              v.searching
                  ? '結果を待っています'
                  : next == null
                  ? '次の計測：—'
                  : next == 0
                  ? '次の計測：条件がそろうのを待っています'
                  : '次の計測まで：${(next / 1000).ceil()} 秒',
            ),
            if (v.searchSkipReason case final reason?)
              Text('見送り：${reasonLabels[reason] ?? reason}'),
            if (v.searchesLeft case final left?)
              Text('この歩行であと $left 回'),
          ]),
          section('近くのランドマーク', [
            if (v.nearby.isEmpty) const Text('（150 m 以内にありません）'),
            for (final n in v.nearby)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      n.told ? Icons.check_circle : Icons.place,
                      size: 16,
                      color: n.told ? Colors.grey : Colors.orange,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(n.name, overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      '${relativeLabel(n.relativeBearingDeg, config)}　${n.distanceM.round()} m',
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
          ]),
        ],
      ),
    );
  }
}

/// 判断ログの一覧。いまの時点までに出たものを新しい順に並べる。押すとその時刻へ移る。
class _DecisionList extends StatelessWidget {
  final Replay replay;
  final int frameIndex;
  final bool hideFetch;
  final Map<String, String> reasonLabels;
  final String Function(int tMs) clock;
  final void Function(int tMs) onTap;
  final ScrollController controller;
  const _DecisionList({
    required this.replay,
    required this.frameIndex,
    required this.hideFetch,
    required this.reasonLabels,
    required this.clock,
    required this.onTap,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final count = replay.decisionCountAt(frameIndex);
    final items = [
      for (var i = count - 1; i >= 0; i--)
        if (!hideFetch || replay.decisions[i].decision.kind != 'fetch')
          replay.decisions[i].decision,
    ];
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text(
              '判断ログ（新しい順）',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: items.length,
              itemBuilder: (context, i) {
                final d = items[i];
                return ListTile(
                  dense: true,
                  leading: _KindBadge(kind: d.kind),
                  title: Text(reasonLabels[d.reason] ?? d.reason),
                  subtitle: Text(
                    [
                      clock(d.tMs),
                      d.reason,
                      if (d.targetId != null) d.targetId!,
                      if (d.text != null) '「${d.text}」',
                    ].join('　'),
                  ),
                  onTap: () => onTap(d.tMs),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _KindBadge extends StatelessWidget {
  final String kind;
  const _KindBadge({required this.kind});
  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      'speak' => Colors.blue,
      'skip' => Colors.grey,
      'search' => Colors.purple,
      'search_skip' => Colors.blueGrey,
      'answer' => Colors.teal,
      _ => Colors.black26,
    };
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        _kindLabel(kind),
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: color),
      ),
    );
  }
}

String _kindLabel(String kind) => switch (kind) {
  'speak' => '話す',
  'skip' => '黙る',
  'search' => '撮る',
  'search_skip' => '撮らない',
  'answer' => 'B の答え',
  'fetch' => '先読み',
  _ => kind,
};

String _activityLabel(Activity a) => switch (a) {
  Activity.walking => '歩行',
  Activity.still => '停止',
  Activity.inVehicle => '乗り物',
  Activity.unknown => '不明',
};

String _audioLabel(AudioOut a) => switch (a) {
  AudioOut.earphone => 'イヤホン',
  AudioOut.speaker => 'スピーカー',
  AudioOut.none => '出力なし',
};
