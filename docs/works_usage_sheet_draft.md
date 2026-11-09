# 著作物利用シート（下書き）

作成：メンバー4　／　11/6　／　状態：**下書き**（大会の提出様式が分かったら、その形に写す。確認はメンバー1）

もとにした記録：`docs/attribution.md`（くわしい出典とライセンスはこちら）

## 1. 方針

- 他人の文章・写真・映像・音楽はそのまま使っていない。ランドマークの原稿は、公式ページなどに書かれた**事実だけ**をもとに、自分たちの言葉で書いた
- 年号・数字は出典の表記どおりにした。出典で確かめられない内容は原稿に入れていない
- 地図の位置は OpenStreetMap の座標を使った（Google マップの座標は利用規約で保存が制限されているので使っていない）

## 2. データ

| データ | 出典・権利者 | ライセンス・利用条件 | 使い方 |
| :-- | :-- | :-- | :-- |
| ランドマークの位置、横断歩道・信号 | OpenStreetMap（© OpenStreetMap contributors） | ODbL 1.0 | 位置を登録。横断歩道・信号は文脈ゲートに使う。アプリと判断画面に出典を表示する |
| 気象警報 | 気象庁（防災情報XML） | 公共データ利用規約 第1.0版 | 発表の内容をテンプレートの文に加工して読み上げる。予想はしない |
| 富山城址公園の情報 | 富山市オープンデータ「インフォマップとやま＿観光情報マップ＿文化財情報」 | CC BY | 原稿の事実の確認 |

## 3. 原稿の事実の出典（ウェブページ）

事実を確かめるためだけに参照した（文章・画像は写していない）。ランドマークごとの URL は `docs/attribution.md`。

| 出典の種類 | 権利者 | 使ったランドマーク |
| :-- | :-- | :-- |
| 富山県のウェブページ | 富山県 | 環水公園・ブールバール・オーバード・ホール・松川べり・桜橋・富山城址公園 |
| 富山市のウェブページ | 富山市 | 富山駅・YKK AP ARENA |
| 国土交通省のウェブページ | 国土交通省 | 松川べり・富山城址公園 |
| 文化遺産オンライン | 文化庁 | 桜橋 |
| 施設の公式サイト | 各施設（富岩運河環水公園・富山県美術館・オーバード・ホール・オークスカナルパークホテル富山） | 環水公園・美術館・オーバード・ホール・ブールバール |
| 制作者本人の公式 YouTube（説明文） | 吉野美奈子さん | ラバーズ像（映像・写真は使っていない） |

## 4. AI で作ったもの

| ツール | 作ったもの | 人の確認 |
| :-- | :-- | :-- |
| Vertex AI Gemini（`gemini-3.6-flash`） | ランドマークの原稿の下書き | 人が出典と照らして確かめ、直したものだけを使う（`status: reviewed`） |
| Vertex AI Gemini | 実行中の「何が写っているか」の判定（B の視界の検索） | 自信が低いときは話さない。年号・数字は読み上げない |

## 5. ソフトウェア（ライブラリ）

ライセンスは 11/6 に pub.dev・PyPI で確かめた。

### スマホのアプリ（Flutter / Dart）

| ライブラリ | ライセンス |
| :-- | :-- |
| Flutter SDK・Dart | BSD-3-Clause |
| camera | BSD-3-Clause |
| firebase_core・firebase_messaging | BSD-3-Clause |
| http | BSD-3-Clause |
| path_provider | BSD-3-Clause |
| wakelock_plus | BSD-3-Clause |
| audio_session | MIT |
| flutter_activity_recognition | MIT |
| flutter_tts | MIT |
| geolocator | MIT |
| permission_handler・permission_handler_android | MIT |
| test・flutter_lints（開発用） | BSD-3-Clause |

### クラウド（Python）

| ライブラリ | ライセンス |
| :-- | :-- |
| fastapi | MIT |
| uvicorn | BSD-3-Clause |
| httpx | BSD-3-Clause |
| jsonschema | MIT |
| google-genai | Apache-2.0 |
| google-cloud-firestore・google-cloud-storage | Apache-2.0 |
| firebase-admin | Apache-2.0 |
| pytest（開発用） | MIT |

## 6. Google のサービス

Cloud Run・Cloud Scheduler・Firestore・Cloud Storage・Firebase Cloud Messaging・Firebase Hosting・Vertex AI（Gemini）・Google Maps（判断画面の地図表示）。各サービスの利用規約に従う。

## 7. 画像・音声・フォント

- 写真・イラスト：使っていない
- 読み上げの声：端末の TTS（Android の音声合成。`flutter_tts` 経由）
- 話し始めの合図音：音声ファイルもライブラリも使っていない。Android 標準の `ToneGenerator`（`TONE_PROP_BEEP`）で鳴らす（`app/mobile/android/.../TonePlugin.kt`。11/6 にコードで確認）
- フォント：アプリではフォントを指定していない（`app/mobile/pubspec.yaml` に `fonts:` が無い）。文字は端末の標準フォントで表示する。アイコンは Flutter に付いている Material Icons（`uses-material-design: true`、Apache-2.0）

## 8. デモ動画

- スマートグラスの代わりにスマホで撮影していることを動画の中で明示する
- 通行人の顔が映ったらぼかす
- 映った建物・像・看板：**要確認**（像の作品が大きく映る場合の扱い）
- BGM：**未定**（使うなら利用条件を確かめて、ここに書く）
- 判断画面に OpenStreetMap・Google Maps の地図が映る場合は、出典表示が見えるようにする

## 9. まだ確かめていないこと

- [ ] 大会の著作物利用シートの様式（項目・ファイル形式）。11/6 にウェブで探したが公開のページには見つからなかった → 参加者向けの案内を持っているメンバー1に聞く
- [x] 合図音・フォントの出どころ（11/6 にアプリのコードで確認。上の7章）
- [ ] ML Kit Face Detection を入れたら、そのライセンス（Google の ML Kit の利用規約）を足す
- [ ] 判断画面（app/viewer）で使うライブラリを足す
- [ ] デモ動画の BGM・映り込み
