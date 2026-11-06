# app/viewer — 判断画面の Web 版（担当：メンバー2）

歩行ログ（engine への入力イベントの記録。`schema/eventlog.schema.json`）を、アプリと同じ `app/engine` に流し直し、
地図の上の位置・いまの状態（`engine.view`）・判断ログと理由コードを時系列で見せる。審査員がデプロイURLで体験する画面。

* 判断はすべて engine が行う。viewer は見せるだけ（判断を作り直さない）。同じログなら実機と同じ判断になる
* 画面の上に「記録を判断エンジンに流し直していること」「スマホでスマートグラスを代用していること」を必ず出す（CLAUDE.md 1章）

## 画面

| 場所 | 中身 |
| :-- | :-- |
| 上 | 再生・一時停止、時刻、シーク、再生の速さ、タイル取得を隠す、ログの名前 |
| 左 | 地図（地理院タイル）：独自マップ（ランドマーク・エリア・横断歩道・信号・イベント会場）、歩いた道、いまの位置と視線、話し始めた場所、B で撮った場所。地図／航空写真の切り替え、いまの位置を追う、歩いた範囲を表示 |
| 中 | いまの状態：いまの判断と理由、読み上げ中の文、行動・速さ・向き・音声、エリア、B の次の計測まで・見送りの理由・残り回数、近くのランドマーク（方向・距離・話したか） |
| 右 | 判断ログ（新しい順）。押すとその時刻に移る |

## 地図（独自マップ）

元データは API の SQLite（`cloud/data/scripts/build_sqlite.py` が作る `tiles.sqlite`）と同じ `cloud/data/manual/landmarks/`（reviewed だけ）・`cloud/data/osm/crossings.json`・`cloud/data/manual/events.json`。
SQLite は Git 管理外で Web では読めないので、描くのに要る項目だけを `assets/map.json` に書き出して同梱する。

```sh
cd app/viewer
dart run tool/build_map.dart   # cloud/data を直したら作り直してコミットする（古いとテストが落ちる）
```

地図の描き方はチームの確認用の地図（`cloud/data/scripts/preview_map.py` が作る map.html）に合わせた：
背景は**地理院タイル**（標準地図・航空写真を切り替え。API キー不要）、`flutter_map` で描く。色も map.html と同じ（ランドマーク＝赤、イベント＝紫、信号＝青、横断歩道＝緑）。
出典「地理院タイル（国土地理院）」「© OpenStreetMap contributors」は地図の右下に常に出す。

## 歩行ログ

* 最初から入れておくログは `assets/walks/`。一覧は `assets/walks/index.json`（先頭のものを起動時に開く）
* 今は schema の見本ログ（作った記録）だけ。**実機の記録が届いたら差し替える**（`note` に「実機で記録」と書く）
* 「ログを開く」で手元の `.jsonl` も開ける（ブラウザの中で読むだけで、どこにも送らない）
* 同梱したログは公開の URL から誰でも取れる。正確な位置が入るので、デモのルートの記録だけを入れる

## 動かす

```sh
cd app/viewer
flutter pub get
flutter test
flutter run -d chrome
flutter build web          # build/web ができる
```

## Firebase Hosting に出す（人が行う）

設定は `firebase.json`（公開するのは `build/web`）と `.firebaserc`（プロジェクト `ambient-guide-toyama-2026`）。

```sh
cd app/viewer
flutter build web
firebase login             # Hosting の権限があるアカウントで。済んでいれば不要
firebase deploy --only hosting
```

出てきた URL（`https://ambient-guide-toyama-2026.web.app` の形）をメンバー1に伝える。審査用のデプロイ URL として 11/14 まで動かし続ける。

## ファイル

* `lib/src/replay.dart`：ログの読み込みと再生（Flutter に依存しない。テストは `test/replay_test.dart`）
* `lib/src/demo_map.dart`・`tool/build_map.dart`：独自マップ
* `lib/src/map_view.dart`：地図の描画
* `lib/src/viewer_page.dart`：画面
* `assets/reason_codes.json`：理由コードの説明（`schema/reason_codes.json` の写し。違うとテストが落ちる）
