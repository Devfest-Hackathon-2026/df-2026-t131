import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/logging/walk_log_store.dart';

void main() {
  test('歩行ログだけを新しい順に並べ、すべて削除しても他のファイルは残す', () async {
    final dir = await Directory.systemTemp.createTemp('walklogs');
    final a = File('${dir.path}/walk_20261105T010000Z.jsonl')
      ..writeAsStringSync('{}\n');
    final b = File('${dir.path}/walk_20261105T020000Z.jsonl')
      ..writeAsStringSync('{}\n{}\n');
    a.setLastModifiedSync(DateTime(2026, 11, 5, 10));
    b.setLastModifiedSync(DateTime(2026, 11, 5, 11));
    final other = File('${dir.path}/settings.json')..writeAsStringSync('{}');
    final store = WalkLogStore(() async => dir);

    final logs = await store.list();
    expect(logs.map((l) => l.name), [
      'walk_20261105T020000Z.jsonl',
      'walk_20261105T010000Z.jsonl',
    ]);

    await store.delete(logs.last);
    expect((await store.list()).length, 1);

    expect(await store.deleteAll(), 1);
    expect(await store.list(), isEmpty);
    expect(other.existsSync(), isTrue);
    await dir.delete(recursive: true);
  });

  test('フォルダが無くても空で返す', () async {
    final store = WalkLogStore(
      () async => Directory('${Directory.systemTemp.path}/no_such_dir_x'),
    );
    expect(await store.list(), isEmpty);
  });

  test('大きさの表示', () {
    expect(formatBytes(500), '500 B');
    expect(formatBytes(2048), '2 KB');
    expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
  });

  test('記録中のファイルは消さない', () async {
    final dir = await Directory.systemTemp.createTemp('walklogs');
    File('${dir.path}/walk_20261105T010000Z.jsonl').writeAsStringSync('{}');
    final live = File('${dir.path}/walk_20261105T020000Z.jsonl')
      ..writeAsStringSync('{}');
    final store = WalkLogStore(
      () async => dir,
      inUse: () => 'walk_20261105T020000Z.jsonl',
    );
    final logs = await store.list();
    expect(logs.where(store.isInUse).map((l) => l.name), [
      'walk_20261105T020000Z.jsonl',
    ]);
    expect(await store.deleteAll(), 1);
    expect(live.existsSync(), isTrue);
    expect(await store.delete(logs.firstWhere(store.isInUse)), isFalse);
    await dir.delete(recursive: true);
  });

  test('歩行ログを消すと、隣の送った画像のフォルダ（walk_〇〇_images）も消える', () async {
    final dir = await Directory.systemTemp.createTemp('walklogs');
    final log = File('${dir.path}/walk_20261107T010000Z.jsonl')
      ..writeAsStringSync('{}\n');
    final images = sentImagesDir(log);
    expect(images.path, '${dir.path}/walk_20261107T010000Z_images');
    images.createSync();
    File('${images.path}/s_000001.jpg').writeAsBytesSync([1, 2, 3]);
    final store = WalkLogStore(() async => dir);
    expect((await store.list()).map((l) => l.name), [
      'walk_20261107T010000Z.jsonl',
    ]); // 画像のフォルダは歩行ログとして数えない
    await store.delete((await store.list()).single);
    expect(images.existsSync(), isFalse);
    await dir.delete(recursive: true);
  });
}
