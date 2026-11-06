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
| 方向の一言 | 原稿の前に「{方向}に{名前}があります。」を付ける（テンプレート）。方向は話し始める時点で、歩いているときは進行方向、止まっているときは視線から見た角度で、正面・右前方・右手・右後方・後方（左も同じ）。エリアの定型文には付けない。長さの見積もりは付けたあとの文で行う | — |
| エリア | 範囲に入ったら定型文（`script_short`）を一度だけ。いるエリアは `engine.currentArea`（B の送信の `area` 用） | `speak:area_entered` |
| 文脈ゲート | 音声出力なし → 通話中 → 乗り物 → 早歩き → 横断歩道の手前15m → 読み上げ中 → 話題の間隔20秒、の順に確かめる。待たせた候補が条件から外れたら期限切れ | `skip:no_audio_output` など、`skip:expired` |
| 話した履歴 | 話した対象は二度と話さない（A・B 共有、`engine.toldIds`） | `skip:already_told` |
| 警報 | 同じ `alert_id` は1回だけ。レベル4以上は読み上げ中でも割り込み（`interrupt: true`）、止めた話は話していない扱いに戻す。それ以外は今の話が終わってから。どちらも音楽は一時停止 | `speak:alert_interrupt`、`speak:alert` |

- 「話さなかった理由」は、同じ対象・同じ理由につき1回だけ記録する（毎秒同じ行が並ばないように）
- 読み上げ中かどうかは、エンジンが出した `Speak` に対する `TtsFinished` と、センサーの `tts_speaking` の両方で見る。`TtsFinished` が届かなくても、見積もった読み上げ時間＋30秒で終わったとみなす
- 割り込みで止めた話の `TtsFinished` は受け取って無視する（mobile は返す想定）

### B（視界の定期検索）の判断

センサーごとに「撮るか」を決めて `CaptureAndSearch` を出し、`VisualResult`・`VisualError` を受けて「話すか」を決める。
発火タイミングは11/5にメンバー2が決めた（伝言「B_発火タイミングの論点」。番号はその論点の番号）。数字はすべて `EngineConfig`。

| 段階 | やっていること | 理由コード |
| :-- | :-- | :-- |
| 計測の間隔（1・2） | 最後に撮った時刻から20秒（11/6 に60秒から短くした）。最初の1枚は位置と向きが初めて取れてから20秒（タイルが未着でも撮る。候補は空）。止められて撮れなかったときは数え直さず、次の秒にまた試す | `search:interval_elapsed` |
| 立ち止まり（6） | Activity が `still` になって5秒たち、前に撮ってから30秒以上なら前倒し。30秒たっていなければ待つ | `search:stopped_early`、`search_skip:interval_not_elapsed` |
| 1件ずつ（5） | 結果か失敗が来るまで次を出さない。撮ってから15秒たっても来なければ諦め（`answer:error`）、あとから届いた結果は期限切れ | `answer:error`、`answer:expired` |
| 「調べて」（共有/visual-search-spec.md 2章） | アプリが `SearchRequested`（歩行ログでは `search_request`）を送ると、計測間隔と同じ場所を見ずに、その場で一度だけ撮る。ほかの見送りの条件は自動と同じ。撮れなければ理由を毎回記録して終わり、あとで勝手に撮らない。結果待ちの間も見送る | `search:user_requested`、`search_skip:*` |
| 上限 | 既定ではなし（`maxSearchesPerWalk` に値を入れたときだけ、その回数まで） | `search_skip:limit_reached` |
| 文脈ゲート（3・4・11） | 音声出力なし・通話中・乗り物・早歩き・横断歩道の手前・読み上げ中・警報やBの答えが待っている・**前の話の終わり＋話題の間隔20秒−答えの見込み5秒より前**・**15秒以内にAが話し始めそう**、のどれかなら撮らない | `search_skip:gate_blocked` |
| 画質（7） | `image_quality` が null、blur が0.5未満、brightness が0.2未満なら撮らない | `search_skip:low_quality` |
| 同じ場所 | 前に撮った位置から20m以内かつ視線の差30°以内なら撮らない | `search_skip:same_place` |
| 送るもの | 平滑化した位置のタイル、10°単位に丸めた視線、候補 ID（150m以内・視線の左右30°以内・近い順に10件・エリアは除く・**話したものも入れる**（8））、エリアの中なら `area` | — |
| 答えの採否 | 鮮度期限15秒を過ぎた → `unknown` → 自信が足りない（候補と一致は0.6、候補外は0.7未満） → 送った候補にない ID → 話した対象、の順に確かめる。候補外の重複（9）は、固有名（`named: true`）ならエリアごと（外は全体）に名前で、一般名なら前に話した撮影場所から100m以内で同じ名前のときだけ | `answer:expired`、`answer:unknown`、`answer:low_confidence`、`answer:already_told` |
| 話す（10・11） | 優先度6。警報・A が先で、同じ文脈ゲートを通ったら話す。「さっき{方向}に見えたのは{名前}です。{原稿の短い版／説明}」。方向は撮ったときの視線と、話し始めるときの進行方向（止まっていれば視線）の差。DB のランドマークなら A で話した扱いにする | `answer:matched_landmark`、`answer:unlisted_object`、`answer:named_object` |
| どの部分か（part） | 応答の `part`（whole・window・entrance など。呼び方は `visualPartLabels`）。`matched`＋`whole` は今までどおり（自信0.6、A の原稿、ID で A・B 共有）。`matched`＋部分は登録したランドマークの特徴：自信0.7以上で「さっき{方向}に見えたのは{名前}の{部分}です。{説明}」、A で話した扱いにはしない。重複は（場所, part）で見る。場所はランドマーク ID、なければ固有名はエリア＋名前、一般名は名前＋撮影場所100m。`other` は同じ場所で何か話していれば話さない | `answer:landmark_feature`、`answer:already_told` |
| A に譲る（共有/visual-search-spec.md 5章） | B を読み終えて話題の間隔20秒を空けると、その間に A が話したいはずのランドマーク（エリア）を、出る前に話し終えられなくなるなら B を捨てる | `answer:yield_to_narrative` |

- 判断ログの kind は、撮る＝`search`、撮らない＝`search_skip`（理由が変わったときだけ記録。撮るたびに消す）、答え＝`answer`
- 答えの判断ログには、応答の `sources` が空でなければそのまま付ける（schema 0.3 の任意項目）
- `answer:*` の `target_id` は、ランドマークと一致したときはランドマークの ID、それ以外は検索の ID（`s_000001`）

### 画面に出す値（`engine.view`）

`EngineView`（読み取り専用。判断ログには入れない）：`tMs`、いまいるエリア `currentArea`（外なら null）、近くのランドマーク `nearby`（ID・名前・種類・距離・視線から見た方位 `relativeBearingDeg`（右が正）・話したか。近い順に10件）、B の次の計測までのミリ秒 `nextSearchInMs`（結果待ち・上限・センサー未着は null）、B を止めている理由 `searchSkipReason`（判断ログの reason と同じ値。止められていなければ null）、`searching`、`searchesLeft`（上限なしなら null）、最後の判断 `lastDecision`。
mobile のグラス視点の画面と viewer の再生画面の両方で、`handle()` のあとに読む。

**まだ入っていないもの**：交通（`speak:transit_next`）・イベント（`speak:event_nearby`）の読み上げ。
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

再生CLIは入力を記録順に流し、`LogDecision` だけを標準出力する。
変換後の見本は `.dart_tool/contract-fixtures/` に生成され、Gitへは含めない。
`timetable_sample.json`・`events_sample.json`・`fcm_alert_data.json`・`crossings_sample.json` はengineがモデルを持たない見本なので、往復の対象外にしている（`tool/fixture_models.dart` の `examplesOutsideEngine`）。
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

- 次は交通・イベントの読み上げと、viewer（判断画面の Web 版）。
- 原稿には方向の言葉を書かない決まり（`cloud/data/scripts/draft_scripts.py`）なので、方向はengineが付ける。`schema/examples` の見本の原稿には「右手の」と入っているが、見本の石碑は道の東（南へ歩くと左）にあるので、engineは「左前方に」と言う（見本だけの食い違い）。
- TODO(質問): 読み上げの速さ（6字/秒）は仮の値。実機の `flutter_tts` の速さで測って直す（member3）。
- TODO(質問): 画質のしきい値（blur 0.5）で、屋外を歩いている最中に B が撮れるか。実機の値を member3 に確かめる。
- TODO(質問): `CaptureAndSearch` を出した時刻と、mobile が実際にコマを取る時刻の差（最新の1コマなので同じとみなしている）。

SDKと検証ライブラリは作業環境の外部ツールとして管理し、このパッケージには含めない。
