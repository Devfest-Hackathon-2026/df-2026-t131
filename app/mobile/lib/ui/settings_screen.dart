import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/app_settings.dart';
import '../config.dart';
import '../dev/dev_settings_section.dart';
import '../executors/voicevox_tts.dart';
import '../logging/walk_log_store.dart';
import '../info/info_kind.dart';
import '../net/api_client.dart';
import 'caption.dart';
import 'licenses.dart';
import 'style.dart';

/// 設定画面。開始前でも記録中でも開ける（記録は裏で続き、変えた設定はすぐ効く）。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: Stack(
        children: [
          _body(),
          // 試し聞きの字幕
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: Center(
              child: CaptionBar(
                subtitle: services.speaker.subtitle,
                spoken: services.speaker.spokenChars,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: services.settings,
      builder: (context, s, _) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 96),
        children: [
          const _Header('画像検索（B：視界の定期検索）'),
          SwitchListTile(
            value: s.visualSearchEnabled,
            onChanged: (v) =>
                services.updateSettings(s.copyWith(visualSearchEnabled: v)),
            title: const Text('見ている景色を画像で調べる'),
            subtitle: Text(
              s.visualSearchEnabled
                  ? '約20秒ごとに1枚、顔をぼかしてから送ります。画像は保存しません。'
                  : 'オフ：カメラ画像を端末の外に送りません。地図に登録した場所の案内（A）だけ話します。',
            ),
            secondary: Icon(
              s.visualSearchEnabled ? Icons.image_search : Icons.hide_image,
            ),
          ),
          const Divider(),
          const _Header('声'),
          for (final v in VoicePreset.values)
            ListTile(
              leading: Icon(
                s.voice == v
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: s.voice == v ? AppColors.accent : null,
              ),
              title: Text(v.label),
              // 声の利用規約で、クレジットの表示が必要
              subtitle: Text(
                VoicevoxTtsEngine.styleFor(v) == null
                    ? '端末の日本語音声（通信なし）'
                    : '端末の中で作る声（通信なし）・${VoicevoxTtsEngine.credit}',
              ),
              onTap: () => services.updateSettings(s.copyWith(voice: v)),
              trailing: OutlinedButton.icon(
                onPressed: () => services.previewVoice(v),
                icon: const Icon(Icons.play_arrow),
                label: const Text('試し聞き'),
              ),
            ),
          const Divider(),
          const _Header('案内する情報（優先度の高い順）'),
          for (final k in InfoKind.values)
            _InfoKindTile(services: services, kind: k),
          const Divider(),
          const _Header('記録した歩行ログ'),
          _WalkLogsSection(store: services.walkLogs),
          const Divider(),
          const _Header('サーバー（Cloud Run の API）'),
          _ServerSection(services: services),
          const Divider(),
          const _Header('このアプリについて'),
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('API'),
            subtitle: Text(
              AppConfig.useRealApi ? '本番（Cloud Run）' : '見本データ（fake）',
            ),
          ),
          const ListTile(
            leading: Icon(Icons.privacy_tip_outlined),
            title: Text('プライバシー'),
            subtitle: Text(
              '正確な位置は端末の外に出しません（送るのは地図タイル番号だけ）。'
              '歩行ログは「計測開始」から「終了」までだけ、この端末に保存します。',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.copyright_outlined),
            title: const Text('出典'),
            subtitle: Text(dataAttributions.join('\n')),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('ライセンス'),
            subtitle: const Text('使っているライブラリ・声・データのライセンスの一覧'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showAppLicenses(context),
          ),
          // 7回押すと開発者モードが出る（Android の「ビルド番号」と同じ）
          _UnlockTile(
            unlocked: s.developerMode || AppConfig.devTools,
            onUnlock: () =>
                services.updateSettings(s.copyWith(developerMode: true)),
          ),
          if (s.developerMode || AppConfig.devTools) ...[
            const Divider(),
            const _Header('開発者モード'),
            DevSettingsSection(services: services),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      text,
      style: const TextStyle(color: AppColors.info, fontSize: 15),
    ),
  );
}

/// 保存した歩行ログの一覧と削除。位置を含むので、いつでも消せるようにする。
class _WalkLogsSection extends StatefulWidget {
  const _WalkLogsSection({required this.store});

  final WalkLogStore store;

  @override
  State<_WalkLogsSection> createState() => _WalkLogsSectionState();
}

class _WalkLogsSectionState extends State<_WalkLogsSection> {
  late Future<List<WalkLogInfo>> _logs = widget.store.list();

  void _reload() => setState(() => _logs = widget.store.list());

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('やめる'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('削除する'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _deleteOne(WalkLogInfo log) async {
    if (!await _confirm('このログを削除しますか？', '${log.name} を削除します。元に戻せません。')) return;
    await widget.store.delete(log);
    _reload();
  }

  Future<void> _deleteAll(int count) async {
    const body = '歩行ログを削除します（記録中のものは残します）。元に戻せません。';
    if (!await _confirm('すべて削除しますか？', body)) return;
    final n = await widget.store.deleteAll();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('歩行ログを $n 件削除しました')));
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<WalkLogInfo>>(
      future: _logs,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const ListTile(title: Text('読み込んでいます…'));
        }
        final logs = snap.data!;
        if (logs.isEmpty) {
          return const ListTile(
            leading: Icon(Icons.check_circle_outline, color: AppColors.ok),
            title: Text('保存されている歩行ログはありません'),
          );
        }
        final total = logs.fold<int>(0, (a, l) => a + l.bytes);
        return Column(
          children: [
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text('${logs.length} 件・${formatBytes(total)}'),
              subtitle: const Text('位置を含みます。不要になったら削除してください。'),
              trailing: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                ),
                onPressed: () => _deleteAll(logs.length),
                icon: const Icon(Icons.delete_outline),
                label: const Text('すべて削除'),
              ),
            ),
            for (final l in logs.take(5))
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 72, right: 8),
                title: Text(l.name),
                subtitle: Text(formatBytes(l.bytes)),
                trailing: widget.store.isInUse(l)
                    ? const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: Text(
                          '記録中',
                          style: TextStyle(color: AppColors.danger),
                        ),
                      )
                    : IconButton(
                        tooltip: '削除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteOne(l),
                      ),
              ),
            if (logs.length > 5)
              Padding(
                padding: const EdgeInsets.only(left: 72, bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'ほか ${logs.length - 5} 件',
                    style: const TextStyle(color: AppColors.subtext),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 「バージョン」の行。7回押すと開発者モードを出す。
class _UnlockTile extends StatefulWidget {
  const _UnlockTile({required this.unlocked, required this.onUnlock});

  final bool unlocked;
  final VoidCallback onUnlock;

  @override
  State<_UnlockTile> createState() => _UnlockTileState();
}

class _UnlockTileState extends State<_UnlockTile> {
  static const _needed = 7;
  int _taps = 0;

  void _tap() {
    final messenger = ScaffoldMessenger.of(context);
    if (widget.unlocked) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('開発者モードは表示されています')));
      return;
    }
    _taps++;
    final left = _needed - _taps;
    messenger.hideCurrentSnackBar();
    if (left <= 0) {
      _taps = 0;
      widget.onUnlock();
      messenger.showSnackBar(const SnackBar(content: Text('開発者モードを表示しました')));
    } else if (left <= 3) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('あと $left 回で開発者モードです'),
          duration: const Duration(milliseconds: 700),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.info_outline),
    title: const Text('バージョン'),
    subtitle: Text('デモ版・API ${AppConfig.apiModeLabel}'),
    onTap: _tap,
  );
}

/// 案内する情報の種類1つ：優先度・いつ話すか・今使えるか。
class _InfoKindTile extends StatelessWidget {
  const _InfoKindTile({required this.services, required this.kind});

  final AppServices services;
  final InfoKind kind;

  @override
  Widget build(BuildContext context) {
    // A・B は engine と画像検索が担う。engine をつなぐまでは準備中
    final readiness = switch (kind) {
      InfoKind.landmark || InfoKind.visual => InfoReadiness.planned,
      _ => services.info.readinessOf(kind),
    };
    final ready = readiness == InfoReadiness.ready;
    return ListTile(
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: (ready ? AppColors.ok : AppColors.subtext).withValues(
          alpha: 0.14,
        ),
        child: Text(
          '${kind.priority}',
          style: TextStyle(
            fontSize: 13,
            color: ready ? AppColors.ok : AppColors.subtext,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Text(kind.label),
      subtitle: Text(
        '${kind.timing}${kind.priority == 1 ? '・レベル4以上は割り込み' : ''}'
        '・音楽は${kind.pauseMusic ? '一時停止' : '音量を下げる'}',
      ),
      trailing: Chip(
        label: Text(readiness.label),
        visualDensity: VisualDensity.compact,
        side: BorderSide(color: ready ? AppColors.ok : AppColors.divider),
      ),
    );
  }
}

/// サーバーとのつながり：接続先・トークンの有無（値は出さない）・確認結果・確かめるボタン。
class _ServerSection extends StatelessWidget {
  const _ServerSection({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final api = services.api;
    return ValueListenableBuilder<ServerStatus?>(
      valueListenable: services.serverStatus,
      builder: (context, st, _) => Column(
        children: [
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(api.host),
            subtitle: Text(
              'モード ${AppConfig.apiModeLabel}・トークン ${api.hasToken ? '設定済み' : '未設定'}',
            ),
            trailing: FilledButton.tonalIcon(
              onPressed: api.hasUrl ? services.checkServer : null,
              icon: const Icon(Icons.sync),
              label: const Text('接続を確かめる'),
            ),
          ),
          if (!api.hasUrl)
            const ListTile(
              contentPadding: EdgeInsets.only(left: 72, right: 16),
              title: Text('URL が未設定です（--dart-define=API_BASE_URL=… でビルド）'),
            ),
          if (st != null) ...[
            _CheckRow(name: '生存確認（/health）', check: st.health),
            _CheckRow(name: 'トークンの確認（タイル1枚）', check: st.auth),
          ],
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.name, required this.check});

  final String name;
  final ApiCheck check;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.only(left: 72, right: 16),
    leading: Icon(
      check.ok ? Icons.check_circle : Icons.error_outline,
      color: check.ok ? AppColors.ok : AppColors.warn,
    ),
    title: Text(name),
    trailing: Text(check.label),
  );
}
