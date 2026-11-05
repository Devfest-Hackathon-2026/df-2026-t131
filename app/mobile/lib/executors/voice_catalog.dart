import 'package:flutter_tts/flutter_tts.dart';

import '../app/app_settings.dart';

/// 端末の TTS の声1つ。
class TtsVoice {
  const TtsVoice({required this.name, required this.locale});

  final String name;
  final String locale;

  Map<String, String> toMap() => {'name': name, 'locale': locale};
}

/// 端末にある日本語の声から、[VoicePreset] に割り当てる声を決める。
/// 名前順に並べて先頭から割り当てるので、同じ端末なら毎回同じ声になる。
/// 端末内（ネットワーク不要）の声を優先する。
List<TtsVoice> pickJapaneseVoices(List<Object?> raw) {
  final voices = <TtsVoice>[];
  for (final v in raw) {
    if (v is! Map) continue;
    final name = v['name']?.toString();
    final locale = v['locale']?.toString();
    if (name == null || locale == null) continue;
    if (!locale.toLowerCase().replaceAll('_', '-').startsWith('ja')) continue;
    voices.add(TtsVoice(name: name, locale: locale));
  }
  int rank(TtsVoice v) => v.name.contains('local') ? 0 : 1;
  voices.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : a.name.compareTo(b.name);
  });
  return voices;
}

/// 声の選択と試し聞き。本番の読み上げ（SpeakExecutor）も同じ割り当てを使う。
class VoiceCatalog {
  VoiceCatalog([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  List<TtsVoice>? _voices;

  Future<List<TtsVoice>> voices() async {
    final cached = _voices;
    if (cached != null) return cached;
    final raw = await _tts.getVoices;
    final picked = pickJapaneseVoices(raw is List ? raw : const []);
    _voices = picked;
    return picked;
  }

  /// プリセットに当たる声。声が1つしかない端末では、声2は話す速さと高さで区別する。
  Future<TtsVoice?> voiceFor(VoicePreset preset) async {
    final list = await voices();
    if (list.isEmpty) return null;
    return list[preset.index.clamp(0, list.length - 1)];
  }

  Future<void> apply(VoicePreset preset) async {
    await _tts.setLanguage('ja-JP');
    final v = await voiceFor(preset);
    if (v != null) await _tts.setVoice(v.toMap());
    final sameVoice = (await voices()).length < 2;
    await _tts.setPitch(preset == VoicePreset.voice2 && sameVoice ? 0.85 : 1.0);
    await _tts.setSpeechRate(0.5);
  }

  Future<void> preview(VoicePreset preset) async {
    await _tts.stop();
    await apply(preset);
    await _tts.speak('${preset.label}で案内します。右手に見えるのは、富山駅です。');
  }

  Future<void> stop() => _tts.stop();
}
