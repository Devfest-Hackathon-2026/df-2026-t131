import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 読み上げの声。デモでは端末の日本語音声から2つを選べる。
/// 正式版で増やすときは値を足し、[VoiceCatalog] の割り当てを変えるだけでよい。
enum VoicePreset {
  voice1('声1'),
  voice2('声2');

  const VoicePreset(this.label);
  final String label;

  static VoicePreset fromName(Object? name) => VoicePreset.values.firstWhere(
    (v) => v.name == name,
    orElse: () => voice1,
  );
}

/// 利用者が変えられる設定。値は変えずに作り直す（copyWith）。
class AppSettings {
  const AppSettings({
    this.visualSearchEnabled = true,
    this.voice = VoicePreset.voice1,
    this.developerMode = false,
  });

  /// B（視界の定期検索：撮影して画像で調べる）を使うか。
  /// false のときはカメラ画像を端末の外に一切出さない。
  final bool visualSearchEnabled;
  final VoicePreset voice;

  /// 開発者モード（フェイク GPS など）を設定画面に出すか。
  final bool developerMode;

  AppSettings copyWith({
    bool? visualSearchEnabled,
    VoicePreset? voice,
    bool? developerMode,
  }) => AppSettings(
    visualSearchEnabled: visualSearchEnabled ?? this.visualSearchEnabled,
    voice: voice ?? this.voice,
    developerMode: developerMode ?? this.developerMode,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'visual_search_enabled': visualSearchEnabled,
    'voice': voice.name,
    'developer_mode': developerMode,
  };

  /// 壊れた値・知らない値は既定値に戻す（古い設定ファイルでも起動できるように）。
  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    visualSearchEnabled: json['visual_search_enabled'] is bool
        ? json['visual_search_enabled']! as bool
        : true,
    voice: VoicePreset.fromName(json['voice']),
    developerMode: json['developer_mode'] == true,
  );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.visualSearchEnabled == visualSearchEnabled &&
      other.voice == voice &&
      other.developerMode == developerMode;

  @override
  int get hashCode => Object.hash(visualSearchEnabled, voice, developerMode);
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
