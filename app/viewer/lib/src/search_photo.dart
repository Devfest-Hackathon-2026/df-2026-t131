import 'package:flutter/material.dart';

import 'replay.dart';

// B で AI に送った画像を、撮った判断と並べて見せる（11/8 決定。CLAUDE.md 3章6の例外）。
// 画像はリポジトリにも viewer のイメージにも入れず、Cloud Storage から読む。
// 顔はアプリ（ML Kit）でぼかしたもの。公開の前に人が確かめ、取りこぼしは手でぼかした。

/// 歩行ログ1本ぶんの、AI に送った画像の置き場所。
final class WalkImages {
  /// 画像のフォルダの URL（末尾の `/` なし）。画像は `<baseUrl>/<撮影の番号>.jpg`。
  final String baseUrl;

  /// 公開の前に手でぼかしを足した画像（撮影の番号）。画面でそう断る。
  final Set<String> manualBlur;

  const WalkImages(this.baseUrl, {this.manualBlur = const {}});

  /// index.json の `images`（無ければ null）。
  static WalkImages? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final base = j['base_url'] as String?;
    if (base == null || base.isEmpty) return null;
    return WalkImages(
      base.endsWith('/') ? base.substring(0, base.length - 1) : base,
      manualBlur: {
        for (final id in (j['manual_blur'] as List<dynamic>? ?? const []))
          id as String,
      },
    );
  }

  String urlFor(String searchId) => '$baseUrl/$searchId.jpg';
}

/// 画面に出す断り書き。
const searchPhotoNotice = 'デモの説明のため、AI に送った画像（顔はアプリでぼかし済み）を公開しています。';

/// 答えを短い言葉にする。
String outcomeLabel(SearchOutcome? o) {
  if (o == null) return '答えを待っています';
  final conf = o.confidence == null ? '' : '（自信 ${o.confidence!.toStringAsFixed(2)}）';
  return switch (o.result) {
    'matched' => '登録した場所の一部$conf',
    'unlisted' => '${o.objectName ?? '登録外のもの'}$conf',
    'unknown' => '話すものなし（わからない）$conf',
    'error' => 'エラー（${o.error}）',
    _ => o.result,
  };
}

/// 送った画像1枚。読めないときは理由を出す（画像が無くても画面は動く）。
class SearchImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  const SearchImage({super.key, required this.url, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) => Image.network(
    url,
    fit: fit,
    // CORS が無くても表示できるよう、ブラウザの <img> に任せられるときは任せる
    webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
    errorBuilder: (context, error, stack) => Container(
      color: Colors.black12,
      alignment: Alignment.center,
      child: const Text('画像を読めませんでした', style: TextStyle(fontSize: 12)),
    ),
    loadingBuilder: (context, child, progress) => progress == null
        ? child
        : Container(
            color: Colors.black12,
            alignment: Alignment.center,
            child: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
  );
}

/// いまの時点までに撮った最後の1枚と、その答え。押すと大きく出す。
class LastSearchPhoto extends StatelessWidget {
  final Replay replay;
  final int frameIndex;
  final WalkImages images;
  final String Function(int tMs) clock;
  const LastSearchPhoto({
    super.key,
    required this.replay,
    required this.frameIndex,
    required this.images,
    required this.clock,
  });

  @override
  Widget build(BuildContext context) {
    final s = replay.lastSearchAt(frameIndex);
    if (s == null) return const Text('まだ撮っていません');
    final id = s.search.searchId;
    final outcome = replay.outcomeAt(id, frameIndex);
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => showSearchPhoto(context, images, id, s.tMs, outcome, clock),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: SearchImage(url: images.urlFor(id)),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('${clock(s.tMs)} に撮影（$id）→ ${outcomeLabel(outcome)}'),
        if (images.manualBlur.contains(id))
          Text('この画像は、公開の前に顔のぼかしを手で足しています', style: small),
        Text(searchPhotoNotice, style: small),
      ],
    );
  }
}

/// 送った画像を大きく出す。
void showSearchPhoto(
  BuildContext context,
  WalkImages images,
  String searchId,
  int tMs,
  SearchOutcome? outcome,
  String Function(int tMs) clock,
) {
  showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${clock(tMs)} に撮影（$searchId）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: SearchImage(
                  url: images.urlFor(searchId),
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 8),
              Text('AI の答え：${outcomeLabel(outcome)}'),
              if (outcome?.description case final d?) Text('説明：$d'),
              const SizedBox(height: 4),
              if (images.manualBlur.contains(searchId))
                const Text('この画像は、公開の前に顔のぼかしを手で足しています'),
              const Text(searchPhotoNotice),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('閉じる'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
