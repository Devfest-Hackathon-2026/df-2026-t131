# 出典とライセンス（著作物利用シート用）

使ったデータ・文章の出典を、ランドマークごとに記録する。原稿は出典の事実をもとに自分たちの言葉で書き、写真・他人の文章はそのまま使わない。

## 地図データ

| データ | 出典 | ライセンス | 使い方 |
| :-- | :-- | :-- | :-- |
| ランドマークの位置（緯度・経度） | OpenStreetMap（© OpenStreetMap contributors） https://www.openstreetmap.org/copyright | ODbL 1.0 | 各ランドマークの中心の位置を確かめて登録 |
| 横断歩道・信号（`cloud/data/osm/crossings.json`、1,167件） | OpenStreetMap（© OpenStreetMap contributors）を Overpass API で取り出した https://www.openstreetmap.org/copyright | ODbL 1.0 | 文脈ゲート（横断歩道の手前では話さない）。タイル API で配る。抽出データとタイルのデータも ODbL。11/6 に範囲を南はファボーレ富山・西は呉羽山まで広げた（365件→1,167件） |
| ランドマークの形（各ランドマークの `shape`。11/7） | OpenStreetMap（© OpenStreetMap contributors）を Overpass API で取り出した https://www.openstreetmap.org/copyright | ODbL 1.0 | 公園・建物・橋の輪郭、通り・川の線。範囲の判定（中にいるか）と、判断画面の地図に使う。way の番号は下の「ランドマークの形」と各ファイルの `shape.source` |
| カメラで調べない区域（`cloud/data/manual/zones/`。11/7） | 場所はチーム（メンバー1）が決めた。周りの目印の確認に OpenStreetMap（© OpenStreetMap contributors）を使った | ODbL 1.0（目印の参照） | デモのために仮に指定した2か所。Google マップの座標は保存していない |
| 判断画面（viewer）の地図の背景（地理院タイル：標準地図・写真） | 出典：国土地理院（地理院タイル） https://maps.gsi.go.jp/development/ichiran.html | 国土地理院コンテンツ利用規約（出典を明記） https://www.gsi.go.jp/kikakuchousei/kikakuchousei40182.html | 背景として表示するだけ（保存・加工しない）。画面の地図の下に出典を常に出す |
| 町丁目の代表点（`cloud/data/address/towns.json`） | 「位置参照情報」（国土交通省）を加工して作成 https://nlftp.mlit.go.jp/isj/ | 国土交通省 位置参照情報の利用規約（出典を明記） | 位置から町丁目を引く（いちばん近い代表点）。番地・街区は使わない。11/6 夜に追加（メンバー3の提案） |

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
| 富山県美術館「建築・デザイン」（見た目の説明 `visual_hint` に使用） | https://tad-toyama.jp/about/design | 施設公式サイトの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置） | https://www.openstreetmap.org/way/522869869 | ODbL 1.0 |

### lm_0003 ブールバール

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山県「とやま都市MIRAI計画」 | https://www.pref.toyama.jp/1506/kendodukuri/toshikeikaku/keikaku-tochi/kj00019152.html | 富山県ホームページの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置：富山駅北線の上の点） | https://www.openstreetmap.org/way/118519870 | ODbL 1.0 |

### lm_0005 オーバード・ホール

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| オーバード・ホール「オーバード・ホールについて」 | https://www.aubade.or.jp/about/ | 施設公式サイトの利用条件に従う（事実の参照のみ） |
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
| OpenStreetMap（位置・範囲：公園の形の中心。11/7 から範囲は公園の輪郭そのもの） | https://www.openstreetmap.org/way/338862862 | ODbL 1.0 |

### lm_0009 松川べり

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 富山県「松川」 | https://www.pref.toyama.jp/1706/kurashi/kankyoushizen/kankyou/mizuhozen/1shirou/meisui/02/61.html | 富山県ホームページの利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置：城址公園の北の松川） | https://www.openstreetmap.org/way/593382662 | ODbL 1.0 |

### lm_0010 桜橋

| 出典 | URL | ライセンス・条件 |
| :-- | :-- | :-- |
| 文化遺産オンライン「桜橋」 | https://kunishitei.bunka.go.jp/heritage/detail/101/00001410 | 文化庁の利用条件に従う（事実の参照のみ） |
| OpenStreetMap（位置） | https://www.openstreetmap.org/way/1369530727 | ODbL 1.0 |

### ランドマークの形（11/7）

範囲を円から実際の形に変えたときに使った OpenStreetMap の way（© OpenStreetMap contributors、ODbL 1.0）。各ファイルの `shape.source` にも書いてある。

| ランドマーク | 形 | OpenStreetMap |
| :-- | :-- | :-- |
| lm_0001 富岩運河環水公園 | 公園の輪郭 | https://www.openstreetmap.org/way/338875394 |
| lm_0002 富山駅 | 駅舎（building=train_station）の輪郭 | https://www.openstreetmap.org/way/544923364 |
| lm_0003 ブールバール | 富山駅北線の線（北緯36.7085まで） | https://www.openstreetmap.org/way/497939826 ・ https://www.openstreetmap.org/way/118519067 ・ https://www.openstreetmap.org/way/118519870 |
| lm_0004 富山県美術館 | 建物の輪郭 | https://www.openstreetmap.org/way/522869869 |
| lm_0005 オーバード・ホール | 大ホール・中ホールの建物の輪郭 | https://www.openstreetmap.org/way/198741385 ・ https://www.openstreetmap.org/way/1503381094 |
| lm_0007 YKK AP ARENA | 建物（富山市総合体育館）の輪郭 | https://www.openstreetmap.org/way/198741387 |
| lm_0008 富山城址公園 | 公園の輪郭 | https://www.openstreetmap.org/way/338862862 |
| lm_0009 松川べり | 松川の線（中心から350m 以内） | https://www.openstreetmap.org/way/806356440 |
| lm_0010 桜橋 | 橋の輪郭 | https://www.openstreetmap.org/way/1369530727 |

ラバーズ像（lm_0006）は像1点なので形を使わない。別名（`aliases`。例：YKK AP ARENA の「富山市総合体育館」）は、各ランドマークの出典ページに書いてある名前だけを入れた。

## 原稿の下書き

| ツール | 使い方 |
| :-- | :-- |
| Vertex AI Gemini（`gemini-3.6-flash`） | A の原稿の下書き（`cloud/data/drafts/`）。人が出典と照らして確かめてから登録ファイルに写した |
| Claude（Anthropic） | lm_0003・0005〜0010 の原稿の下書きと、OpenStreetMap からの位置の取り出し（11/6）。出典のページを読んで、書いてある事実だけで書いた。人が確かめてから `reviewed` にする |

## 実行中の AI

| ツール | 使い方 |
| :-- | :-- |
| Vertex AI Gemini（`gemini-3.6-flash`、Cloud Run の API から呼ぶ） | B（視界の定期検索）で、画像に何が写っているかと短い説明を答えさせる。話すかどうかは端末の判断エンジン（AI を使わない決まった計算）が決める。数字・年号を含む文は読み上げない。Google マップ・Google 検索でのグラウンディングは使わない |

## 開発に使ったツール

| ツール | 使い方 |
| :-- | :-- |
| Claude Code（Anthropic） | プログラム・テスト・設定ファイルの作成の補助。人が内容を確かめてから main に入れた |

## 声・音

| もの | 出典・条件 | 使い方 |
| :-- | :-- | :-- |
| 読み上げの声（端末の日本語音声） | Android の音声合成（Google の音声サービス）を flutter_tts から使う | 声1・声2 |
| 合図音 | Android の標準の音（ToneGenerator）。音のファイルは使っていない | 話し始めの合図 |
| VOICEVOX（ずんだもん） | VOICEVOX:ずんだもん。VOICEVOX CORE と音声モデルの利用規約に従う https://voicevox.hiroshiba.jp/ | **声のファイルを入れてビルドしたときだけ**使う（入っていなければ端末の声）。使うときはアプリの画面にクレジットを出す。デモ動画で使った場合は、動画にも「VOICEVOX:ずんだもん」を入れる |

## ライブラリ

ライセンスは pub.dev・PyPI の公開情報で確かめた（11/7）。

| 使う所 | ライブラリ | ライセンス |
| :-- | :-- | :-- |
| アプリ・判断画面・判断エンジン | Flutter・Dart | BSD-3-Clause |
| アプリ | camera、path_provider、http、wakelock_plus、firebase_core、firebase_messaging、speech_to_text | BSD-3-Clause |
| アプリ | geolocator、permission_handler、flutter_tts、audio_session、image、flutter_activity_recognition、google_mlkit_face_detection | MIT（ML Kit 本体は Google の ML Kit の利用規約） |
| 判断画面 | flutter_map、file_selector | BSD-3-Clause |
| 判断画面 | latlong2 | Apache-2.0 |
| API・警報ジョブ・データ | fastapi、jsonschema、pytest | MIT |
| API・警報ジョブ | uvicorn、httpx | BSD-3-Clause |
| API・警報ジョブ・データ | google-genai、google-cloud-firestore、google-cloud-storage、firebase-admin | Apache-2.0 |
