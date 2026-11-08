# 出典とライセンス（著作物利用シート用）

使ったデータ・文章・ライブラリの出典を記録する。原稿は出典の事実をもとに自分たちの言葉で書き、写真・他人の文章はそのまま使わない。
提出する著作物利用シートと同じ内容にそろえる（11/8 に照合。URL・題名・権利表記・ライセンスを一次情報で確認）。

## 地図データ

| データ | 出典 | ライセンス | 使い方 |
| :-- | :-- | :-- | :-- |
| ランドマークの位置（緯度・経度） | OpenStreetMap（© OpenStreetMap contributors） https://www.openstreetmap.org/copyright | ODbL 1.0 | 各ランドマークの中心の位置を確かめて登録 |
| ランドマークの形（各ランドマークの `shape`。11/7） | OpenStreetMap（© OpenStreetMap contributors）を Overpass API で取り出した https://www.openstreetmap.org/copyright | ODbL 1.0 | 公園・建物・橋の輪郭、通り・川の線。範囲の判定と判断画面の地図に使う。way の番号は各ファイルの `shape.source` |
| 横断歩道・信号（`cloud/data/osm/crossings.json`、1,167件） | OpenStreetMap（© OpenStreetMap contributors）を Overpass API で取り出した https://www.openstreetmap.org/copyright | ODbL 1.0 | 文脈ゲート（横断歩道の手前では話さない）。タイル API で配る。抽出データとタイルのデータも ODbL |
| カメラで調べない区域（`cloud/data/manual/zones/`。11/7） | 場所はチーム（メンバー1）が決めた。周りの目印の確認に OpenStreetMap を使った | ODbL 1.0（目印の参照） | デモのために仮に指定した2か所 |
| 町丁目の代表点（`cloud/data/address/towns.json`、296件） | 「位置参照情報」（国土交通省）を加工して作成 https://nlftp.mlit.go.jp/isj/ | 国土交通省 位置参照情報の利用規約（出典を明記） | 位置から町丁目を引く（いちばん近い代表点）。番地・街区は使わない。11/6 夜に追加（メンバー3の提案） |
| 判断画面（viewer）の地図の背景（地理院タイル：標準地図・シームレス空中写真） | 出典：国土地理院（地理院タイル） https://maps.gsi.go.jp/development/ichiran.html | 国土地理院コンテンツ利用規約。地理院サーバーから読み込んで表示するだけなので申請不要で、出典の明示と地理院タイル一覧へのリンクが要る（国土地理院「測量成果の利用手続」Q&A Q1-12） | 背景として表示するだけ（保存・加工しない）。地図の下に出典とリンクを常に出す。写真はズーム14未満で衛星画像（別の出典が要る）に切り替わるので、14より小さくは縮めない |

## 気象データ

| データ | 出典 | ライセンス・条件 | 使い方 |
| :-- | :-- | :-- | :-- |
| 気象警報（防災情報XML 随時フィード） | 出典：気象庁ホームページ https://www.data.jma.go.jp/developer/xml/feed/extra.xml | 気象庁ホームページのコンテンツ利用条件（公共データ利用規約 第1.0版） https://www.jma.go.jp/jma/kishou/info/coment.html | 富山市の警報の種類とレベルを取り出し、テンプレートの文（「気象庁は、富山市に〜を発表しました。」）に**加工して作成**。FCM で配り、今出ている警報の一覧を公開の Cloud Storage に置く。元の電文は非公開のバケットに30日だけ残す。予想や独自の警報はしない（気象業務法 第17条・第23条） |

## ランドマーク

### lm_0001 富岩運河環水公園

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山県「運河のまちを愛する会へようこそ！」 | https://www.pref.toyama.jp/1504/kendodukuri/dourokouwan/kouwan/kj00005433/kj00005433-001-01.html | 富山県ホームページの利用条件に従う（事実の参照のみ） |
| 富山県富岩運河環水公園 公式「公園案内とマップ」 | https://www.kansui-park.jp/how-to-enjoy-the-park/map/ | 施設公式サイトの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置） | https://www.openstreetmap.org/way/338875394 | ODbL 1.0 |

### lm_0002 富山駅

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山市「富山駅路面電車南北接続開業記念事業」 | https://www.city.toyama.lg.jp/shisei/machizukuri/1010796/1006464.html | 富山市ホームページの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置） | https://www.openstreetmap.org/node/5591348357 | ODbL 1.0 |

### lm_0004 富山県美術館

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山県美術館「ごあいさつ」 | https://tad-toyama.jp/about/greeting | 施設公式サイトの利用条件に従う（事実の参照のみ） |
| 富山県美術館「建築・デザインについて」（見た目の説明 `visual_hint` に使用） | https://tad-toyama.jp/about/design | 施設公式サイトの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置） | https://www.openstreetmap.org/way/522869869 | ODbL 1.0 |

### lm_0003 ブールバール

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山県「とやま都市MIRAI計画」 | https://www.pref.toyama.jp/1506/kendodukuri/toshikeikaku/keikaku-tochi/kj00019152.html | 富山県ホームページの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置：富山駅北線の上の点） | https://www.openstreetmap.org/way/118519870 | ODbL 1.0 |

### lm_0005 オーバード・ホール

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| オーバード・ホール「オーバード・ホールについて」（富山市芸術文化ホール。指定管理者 公益財団法人富山市民文化事業団） | https://www.aubade.or.jp/about/ | 施設公式サイトの利用条件に従う（事実の参照のみ） |
| 富山県「とやま都市MIRAI計画」 | https://www.pref.toyama.jp/1506/kendodukuri/toshikeikaku/keikaku-tochi/kj00019152.html | 富山県ホームページの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置） | https://www.openstreetmap.org/way/198741385 | ODbL 1.0 |

### lm_0006 ラバーズ像

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 吉野美奈子 公式 YouTube「『ラバーズ』富山駅設置インタビュー｜吉野美奈子」の説明文（2023年4月公開） | https://www.youtube.com/watch?v=nwnyyqxFMk4 | 制作者本人の発信（事実の参照のみ。映像・作品の写真は使わない）。市・県のサイトに載っていないため、制作者本人の発信を出典にする（メンバー1が了承） |
| OpenStreetMap（位置：駅北口の彫刻） | https://www.openstreetmap.org/node/13758880422 | ODbL 1.0 |

### lm_0007 YKK AP ARENA

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山市「富山市まちなかアリーナ（YKK APアリーナ）」 | https://www.city.toyama.lg.jp/shisei/shisetsu/1011061/1011062/1019453.html | 富山市ホームページの利用条件に従う（事実の参照のみ） |
| 富山市「富山市総合体育館のネーミングライツ・パートナーと愛称について」 | https://www.city.toyama.lg.jp/bunka/sports/1010564/1016385.html | 富山市ホームページの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置：富山市総合体育館） | https://www.openstreetmap.org/way/198741387 | ODbL 1.0 |

### lm_0008 富山城址公園

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山市オープンデータ「インフォマップとやま＿観光情報マップ＿文化財情報」 | https://opdt.city.toyama.lg.jp/dataset/infomap-toyama12 | CC BY（富山市） |
| 富山県「松川」 | https://www.pref.toyama.jp/1706/kurashi/kankyoushizen/kankyou/mizuhozen/1shirou/meisui/02/61.html | 富山県ホームページの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置・範囲：公園の形の中心、半径160m） | https://www.openstreetmap.org/way/338862862 | ODbL 1.0 |

### lm_0009 松川べり

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山県「松川」 | https://www.pref.toyama.jp/1706/kurashi/kankyoushizen/kankyou/mizuhozen/1shirou/meisui/02/61.html | 富山県ホームページの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置：城址公園の北の松川） | https://www.openstreetmap.org/way/593382662 | ODbL 1.0 |

### lm_0010 桜橋

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 文化庁「国指定文化財等データベース」桜橋 | https://kunishitei.bunka.go.jp/heritage/detail/101/00001410 | 国指定文化財等データベースの利用規約に従う（事実の参照のみ） |
| OpenStreetMap（位置） | https://www.openstreetmap.org/way/1369530727 | ODbL 1.0 |

## 原稿の下書き

| ツール | 使い方 |
| :-- | :-- |
| Vertex AI Gemini（`gemini-3.6-flash`） | A の原稿の下書き（`cloud/data/drafts/`）。人が出典と照らして確かめてから登録ファイルに写した |
| Claude（Anthropic） | lm_0003・0005〜0010 の原稿の下書きと、OpenStreetMap からの位置の取り出し（11/6）。出典のページを読んで、書いてある事実だけで書いた。人が確かめてから `reviewed` にする |

## 実行中の AI

| ツール | 使い方 |
| :-- | :-- |
| Vertex AI Gemini（`gemini-3.6-flash`、Cloud Run の API から呼ぶ） | B（視界の定期検索）で、画像に何が写っているかと短い説明を答えさせる。話すかどうかは端末の判断エンジン（AI を使わない決まった計算）が決める。Google マップ・Google 検索でのグラウンディングは使わない |

## 判断画面で公開する画像（11/8）

| もの | 出典・条件 | 使い方 |
| :-- | :-- | :-- |
| デモの歩き（`walk_20261108T044257Z`）で AI に送った画像23枚と、同じ歩きのアプリの画面の録画（音声なし） | チームが撮影したもの。画像の顔はアプリ（ML Kit）でぼかし、取りこぼしの2枚は手でぼかしを足した。動画の通行人の顔はチームがぼかした | 判断画面で、撮った判断と並べて見せる（CLAUDE.md 3章6の例外）。リポジトリには入れず Cloud Storage の公開バケット `ambient-guide-toyama-2026-viewer-images` に置き、11/14 のあとに消す |

## 声・音

| もの | 出典・条件 | 使い方 |
| :-- | :-- | :-- |
| 読み上げの声（端末の日本語音声） | Android の音声合成（Google の音声サービス）を flutter_tts から使う | 声1・声2 |
| 「調べて」の聞き取り | Android の音声認識（Google の音声サービス）を speech_to_text から使う | 音声も認識結果も保存・送信しない |
| 合図音 | Android の標準の音（ToneGenerator。Apache-2.0）。音のファイルは使っていない | 話し始めの合図 |
| VOICEVOX（ずんだもん） | VOICEVOX:ずんだもん。VOICEVOX 音声モデル利用規約・ずんだもんの利用規約（https://zunko.jp/con_ongen_kiyaku.html ）に従う https://voicevox.hiroshiba.jp/ | 声のファイルを入れてビルドしたときだけ使う（入っていなければ端末の声）。使うときはアプリの画面にクレジットを出す。デモ動画で使った場合は、動画にも「VOICEVOX:ずんだもん」を入れる |
| VOICEVOX CORE 0.17.1 | MIT License（Copyright (c) 2021 Hiroshiba Kazuyuki） https://github.com/VOICEVOX/voicevox_core | ずんだもんの声を作る |
| VOICEVOX ONNX Runtime 1.23.2 | VOICEVOX ONNX Runtime 利用規約（VOICEVOX のクレジットが必要。元の ONNX Runtime は MIT License、Microsoft Corporation） https://github.com/VOICEVOX/onnxruntime-builder | 同上 |
| Open JTalk 辞書（open_jtalk_dic_utf_8-1.11） | 修正 BSD ライセンス（奈良先端科学技術大学院大学、The UniDic Consortium、名古屋工業大学） https://github.com/r9y9/open_jtalk | 同上 |

## ライブラリ・実行環境

ライセンスと公開者は pub.dev・PyPI の公開情報で確かめた（11/8）。

| 使う所 | ライブラリ | ライセンス |
| :-- | :-- | :-- |
| アプリ・判断画面・判断エンジン | Flutter・Dart（The Flutter Authors） | BSD-3-Clause |
| アプリ | camera、path_provider、http、firebase_core、firebase_messaging（Google）、wakelock_plus（Flutter Community）、speech_to_text（csdcorp） | BSD-3-Clause |
| アプリ | geolocator、permission_handler、permission_handler_android（Baseflow）、flutter_tts（dlutton）、audio_session（Ryan Heise）、image（Brendan Duncan）、flutter_activity_recognition（Dev-hwang）、google_mlkit_face_detection（flutter-ml） | MIT（ML Kit 本体は ML Kit の利用規約） |
| アプリ | Kotlin 標準ライブラリ（JetBrains） | Apache-2.0 |
| 判断画面 | flutter_map（fleaflet）、file_selector（Google） | BSD-3-Clause |
| 判断画面 | latlong2（ThexXTURBOXx。元は Mike Mitterer の latlong） | Apache-2.0 |
| 判断画面 | Roboto・Noto Sans JP（Google Fonts から読み込む）、Material Icons | SIL Open Font License 1.1（Material Icons は Apache-2.0） |
| API・警報ジョブ・データ | fastapi（Sebastián Ramírez）、jsonschema（Julian Berman）、pytest | MIT |
| API・警報ジョブ | uvicorn、httpx（Encode OSS） | BSD-3-Clause |
| API・警報ジョブ・データ | google-genai、google-cloud-firestore、google-cloud-storage、firebase-admin（Google） | Apache-2.0 |
| API・警報ジョブのコンテナ | Python 3.12（python:3.12-slim） | PSF License |
| 判断画面のコンテナ | nginx 1.27（nginx:1.27-alpine） | BSD-2-Clause |
| データ確認用の地図ページ（アプリには入っていない） | Leaflet 1.9.4 | BSD-2-Clause |

## Google のサービス

Vertex AI（Gemini）、Cloud Run、Cloud Scheduler、Firestore、Cloud Storage、Firebase Cloud Messaging、Secret Manager、Cloud Build、Artifact Registry、ML Kit Face Detection、Google Play 開発者サービス（位置・行動）。それぞれの利用規約に従って使う。

