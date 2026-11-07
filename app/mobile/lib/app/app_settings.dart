import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 読み上げの声。声1・声2は端末の日本語音声（Google）、ずんだもんは VOICEVOX（端末の中で作る）。
/// ずんだもんの声のファイルが入っていないビルドでは、ずんだもんを選んでも声1で話す。
/// 増やすときは値を足し、[VoicevoxTtsEngine.styleFor] と [VoiceCatalog] の割り当てを変える。
enum VoicePreset {
  voice1('声1'),
  voice2('声2'),
  zunda('ずんだもん'),
  zundaSweet('ずんだもん（あまあま）');

  const VoicePreset(this.label);
  final String label;

  /// 画面のボタンで順に切り替えるときの次の声。
  VoicePreset get next => values[(index + 1) % values.length];

  static VoicePreset fromName(Object? name) =>
      VoicePreset.values.firstWhere((v) => v.name == name, orElse: () => zunda);
}

/// 利用者が変えられる設定。値は変えずに作り直す（copyWith）。
class AppSettings {
  const AppSettings({
    this.visualSearchEnabled = true,
    this.voice = VoicePreset.zunda,
    this.developerMode = false,
    this.saveSentImages = false,
    this.retellLandmarks = false,
    this.demoAlertNearLovers = false,
  });

  /// B（視界の定期検索：撮影して画像で調べる）を使うか。
  /// false のときはカメラ画像を端末の外に一切出さない。
  final bool visualSearchEnabled;
  final VoicePreset voice;

  /// 開発者モード（フェイク GPS など）を設定画面に出すか。
  final bool developerMode;

  /// 開発者モードのときだけ：AI に送った画像（顔ぼかし後）を、歩行ログの隣に保存する（検証用。11/7）。
  /// 既定はオフ。開発者モードを閉じると保存しない。歩行ログを消すと一緒に消える。
  final bool saveSentImages;

  /// 開発者モードのときだけ：一度話したランドマークも、離れてからもう一度近づいたら話す（検証用。11/7）。
  /// 計測開始のときの値を使う（計測中に変えたら、次の計測開始から効く）。
  final bool retellLandmarks;

  /// 開発者モードのときだけ：ラバーズ像（lm_0006）に近づいたら、デモの警報（レベル4）を流す
  /// （割り込みの確認用。11/7）。1回の計測で1回だけ。
  final bool demoAlertNearLovers;

  bool get demoAlertingNearLovers => developerMode && demoAlertNearLovers;

  /// 実際にもう一度話すか（開発者モードで、かつオンのとき）。
  bool get retellingLandmarks => developerMode && retellLandmarks;

  /// 実際に保存するか（開発者モードで、かつオンのとき）。
  bool get savingSentImages => developerMode && saveSentImages;

  AppSettings copyWith({
    bool? visualSearchEnabled,
    VoicePreset? voice,
    bool? developerMode,
    bool? saveSentImages,
    bool? retellLandmarks,
    bool? demoAlertNearLovers,
  }) => AppSettings(
    visualSearchEnabled: visualSearchEnabled ?? this.visualSearchEnabled,
    voice: voice ?? this.voice,
    developerMode: developerMode ?? this.developerMode,
    saveSentImages: saveSentImages ?? this.saveSentImages,
    retellLandmarks: retellLandmarks ?? this.retellLandmarks,
    demoAlertNearLovers: demoAlertNearLovers ?? this.demoAlertNearLovers,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'visual_search_enabled': visualSearchEnabled,
    'voice': voice.name,
    'developer_mode': developerMode,
    'save_sent_images': saveSentImages,
    'retell_landmarks': retellLandmarks,
    'demo_alert_near_lovers': demoAlertNearLovers,
  };

  /// 壊れた値・知らない値は既定値に戻す（古い設定ファイルでも起動できるように）。
  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    visualSearchEnabled: json['visual_search_enabled'] is bool
        ? json['visual_search_enabled']! as bool
        : true,
    voice: VoicePreset.fromName(json['voice']),
    developerMode: json['developer_mode'] == true,
    saveSentImages: json['save_sent_images'] == true,
    retellLandmarks: json['retell_landmarks'] == true,
    demoAlertNearLovers: json['demo_alert_near_lovers'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.visualSearchEnabled == visualSearchEnabled &&
      other.voice == voice &&
      other.developerMode == developerMode &&
      other.saveSentImages == saveSentImages &&
      other.retellLandmarks == retellLandmarks &&
      other.demoAlertNearLovers == demoAlertNearLovers;

  @override
  int get hashCode => Object.hash(
    visualSearchEnabled,
    voice,
    developerMode,
    saveSentImages,
    retellLandmarks,
    demoAlertNearLovers,
  );
}

/// 設定の保存先。テストではメモリ版、アプリではファイル版を使う。
abstract class SettingsStore {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this._value = const AppSettings()]);
  AppSettings _value;

  @override
  Future<AppSettings> load() async => _value;

  @override
  Future<void> save(AppSettings settings) async => _value = settings;
}

/// アプリ専用フォルダの settings.json に保存する（追加のライブラリを使わない）。
class FileSettingsStore implements SettingsStore {
  FileSettingsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/settings.json');

  @override
  Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return const AppSettings();
      final json = jsonDecode(await f.readAsString());
      if (json is Map<String, Object?>) return AppSettings.fromJson(json);
    } catch (_) {
      // 読めなければ既定値で動かす
    }
    return const AppSettings();
  }

  @override
  Future<void> save(AppSettings settings) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(settings.toJson()), flush: true);
  }
}
