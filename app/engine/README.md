# engine — 判断エンジン

使用SDKは **Dart 3.13.7**。`dart create -t package` で作成した純粋なDartパッケージ。
公開する入口は `lib/engine.dart`、パッケージ名は `engine`。

## 現在できること

- `tasks/README.md` 2.3の入力イベント・出力Commandを受け渡せる。
- イベント、タイル、画像検索の送受信、判断ログ、ランドマーク見本のJSONをモデルと相互変換できる。
- 省略可能な項目は、省略と明示的な `null` を区別してJSONへ戻す。
- 入力の型・範囲・列挙値、定義されていない項目、検索応答の組み合わせ、理由コードを検査する。
- `schema/examples/` の入力ログを順番に `Engine.handle()` へ渡せる。

### A（ランドマーク案内）の判断

`Engine.handle()` は次を判断して `Speak`・`FetchTiles`・`LogDecision` を返す。

| 段階 | やっていること | 理由コード |
| :-- | :-- | :-- |
| 位置の平滑化 | 最初の測位点を原点にした平面（m）で、カルマンフィルタ（状態 [x, y, vx, vy]、等速モデル）。`course_deg` が null のときは速度を観測せず推定に任せる。センサーが30秒以上途切れたら作り直す | — |
| 先読み | 予測軌跡（150秒先まで10秒ごと）の各点の周り150mが入るタイルのうち、持っていないものを要求。届かなければ30秒後にもう一度 | `fetch:prefetch_tiles` |
| 最接近 | 等速で進むとジオフェンスの円の中にいる時間帯を解き、最接近が20秒以内で、円から出るまでに話し終わる（文字数÷6字/秒）ものを話す | `speak:closest_approach`、`skip:pass_before_end` |
| 立ち止まり | 止まっていてジオフェンスの中なら長い版 | `speak:long_version_still` |
| エリア | 範囲に入ったら定型文（`script_short`）を一度だけ。いるエリアは `engine.currentArea`（B の送信の `area` 用） | `speak:area_entered` |
| 文脈ゲート | 音声出力なし → 通話中 → 乗り物 → 早歩き → 横断歩道の手前15m → 読み上げ中 → 話題の間隔20秒、の順に確かめる。待たせた候補が条件から外れたら期限切れ | `skip:no_audio_output` など、`skip:expired` |
| 話した履歴 | 話した対象は二度と話さない（A・B 共有、`engine.toldIds`） | `skip:already_told` |
| 警報 | 同じ `alert_id` は1回だけ。レベル4以上は読み上げ中でも割り込み（`interrupt: true`）、止めた話は話していない扱いに戻す。それ以外は今の話が終わってから。どちらも音楽は一時停止 | `speak:alert_interrupt`、`speak:alert` |

- 「話さなかった理由」は、同じ対象・同じ理由につき1回だけ記録する（毎秒同じ行が並ばないように）
- 読み上げ中かどうかは、エンジンが出した `Speak` に対する `TtsFinished` と、センサーの `tts_speaking` の両方で見る。`TtsFinished` が届かなくても、見積もった読み上げ時間＋30秒で終わったとみなす
- 割り込みで止めた話の `TtsFinished` は受け取って無視する（mobile は返す想定）

**まだ入っていないもの**：B の計測・結果の採否、交通（`speak:transit_next`）・イベント（`speak:event_nearby`）の読み上げ。
設定の初期値は `lib/src/constants.dart` の `EngineConfig` にまとめた（tasks/README.md 2.5 の値と、その下に engine の内部の仮の値）。JSONの形式の基準はschema 0.3（`currentSchemaVersion`）。0.2の見本も読める（版は `^\d+\.\d+$` の形だけを検査する）。

## member3・viewerから参照する

それぞれの `pubspec.yaml` に以下を設定する。変更は各ディレクトリの担当者が行う。

```yaml
dependencies:
  engine:
    path: ../engine
```

```dart
import 'package:engine/engine.dart';

final engine = Engine();
final commands = engine.handle(
  const TtsFinished(tMs: 1000, utteranceId: 'u_000001'),
);
```

APIのJSONは `TileResponse.fromJson` と `VisualSearchResponse.fromJson` で読む。
入力ログには `eventToJson` を使い、再生時は `eventFromJson` を使う。
`TileId`、`AreaContext`、`ImageQuality`、各モデルにも名前付きコンストラクタと `fromJson` / `toJson` がある。

Bの送信JSON（`POST /v1/visual-search`）は `visualSearchRequestToJson(CaptureAndSearch, imageJpegBase64)` で作る。
mobileは自分でMapを組まず、この関数の戻り値をそのまま送る。中の変換は `VisualSearchRequest`（schemaにあるJSONの変換だけを行う値オブジェクト）が行う。
顔ぼかし・画像作成・HTTP送信・画像の破棄はmobile側が担当し、画像を `Engine.handle()` や入力イベントのログへ渡さない。
`name_hints` は既存形式の読取互換用に保持できるが、現方針では構築・送信しない。

## 検証する

`app/engine` で実行する。

```sh
dart --version
dart pub get
dart analyze
dart test
dart run example/engine_example.dart
dart run bin/replay.dart ../../schema/examples/walk_short.jsonl
dart run tool/roundtrip_examples.dart
```

再生CLIは入力を記録順に流し、`LogDecision` だけを標準出力する。初版は指示を生成しないので出力は空になる。
変換後の見本は `.dart_tool/contract-fixtures/` に生成され、Gitへは含めない。
`timetable_sample.json`・`events_sample.json`・`fcm_alert_data.json` はengineがモデルを持たない見本なので、往復の対象外にしている（`tool/fixture_models.dart` の `examplesOutsideEngine`）。
`pubspec.lock` はチームの決まりに従ってコミットする。通常の依存ライブラリはなく、開発用の `test` だけを直接依存にしている。

## 判断ログのfixtures

- `test/fixtures/walks/*.jsonl`：実機の歩行ログ（member3から受け取って置く）
- `test/fixtures/decisions/*.jsonl`：見本の `walk_short.jsonl` と上の歩行ログを、Engineで再生して書き出した判断ログ

Engineの判断を変えたら、次で書き出し直してコミットする。古いままだと `dart test` が失敗する。
CIの `python schema/validate.py` が、どちらのフォルダも形と理由コードを検証する。

```sh
dart run tool/write_decision_fixtures.dart
```

リポジトリ直下でも共通チェックを行う。

```sh
pip install -r schema/requirements.txt
python schema/validate.py
python .github/scripts/check_forbidden.py
```

## 次の実装と連携時に確認すること

- 次はBの計測判定・候補選択・結果の採否を実装する。
- TODO(質問): 原稿の見本は「右手の石碑は…」と方向が原稿に入っている。CLAUDE.md 5章の「方向を添える」をエンジンで足すと二重になるので、今は足していない。原稿に方向を書かない決まりにするなら、エンジンで「右手に」などを前に付ける（member4・member1と確認）。
- TODO(質問): 読み上げの速さ（6字/秒）は仮の値。実機の `flutter_tts` の速さで測って直す（member3）。
- TODO(質問): Bの `sources` を判断ログへ残す項目が `decision.schema.json` にない。member1に形式の追加を依頼する。現段階では検索応答の `sources` を保持する。
- TODO(質問): グラス視点の画面へ渡すA候補一覧の公開方法をmember1・member3と確定する。現在のCommand・判断ログへ独自項目は追加していない。
- TODO(質問): 割り込み後の `TtsFinished`、検索実行中の次回要求は、A/Bの状態管理を実装する段階でmember3と確定する。今回の空のEngineは読み上げ・検索を開始しない。自転車（ON_BICYCLE）はリーダーが `in_vehicle` に決定済み。

SDKと検証ライブラリは作業環境の外部ツールとして管理し、このパッケージには含めない。
