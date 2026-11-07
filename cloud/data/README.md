# cloud/data — データの準備

| 場所 | 中身 | 担当 |
| :---- | :---- | :---- |
| `manual/` | 確認済みのデータ。ランドマークは1件1ファイル（`landmarks/lm_0001.json`…）、ほかに `events.json`・`timetable.json`（交通は余裕があれば）。Git 管理 | メンバー4（確認はメンバー1） |
| `drafts/` | Gemini が作った原稿の下書き（確認前）。Git 管理 | メンバー4 |
| `osm/` | OpenStreetMap から取り出した横断歩道・信号（`crossings.json`）。範囲は `--bbox 36.6610,137.1685,36.7130,137.2195`（11/6。南はファボーレ富山、西は呉羽山の山頂が入るところまで、北と東は環水公園・デモの範囲。できるように広げた） | メンバー1（スクリプト） |
| `scripts/` | 変換・生成のスクリプト | メンバー1 |
| `raw/` | 元データ。Git 管理外 | — |
| `build/` | 生成した SQLite。Git 管理外 | — |

形は `schema/`（`landmark_entry`・`timetable_file`・`events_file`・`crossings_file`）。ランドマークのひな形は `schema/templates/`、見本は `schema/examples/`。

## 最初に1回だけ

```sh
pip install -r cloud/data/requirements.txt
```

## 原稿の下書きを作る（メンバー4）

`manual/landmarks/<ID>.json` に `status: "draft"` で登録したランドマークの原稿の下書きを、Gemini が作ります。

**スクリプトが、登録ファイルの `sources` にある公式のページの本文を取ってきて Gemini に渡し、「この本文に書いてある事実だけで書く」よう頼みます。**Google 検索のグラウンディングは使いません（Google Cloud の利用条件で、グラウンディングの結果を保存したりデータベース作りに使ったりできないため。11/6 に変更）。なので、先に `sources` に公式のページの URL を入れておいてください（OpenStreetMap の URL は位置の出典なので読みません）。

```sh
# 1. お試し（お金はかからない。仮の文が出るだけ）
python cloud/data/scripts/draft_scripts.py --fake

# 2. 本番の前に1回だけ（ブラウザでログイン）
gcloud auth application-default login

# 3. 本番（Gemini を呼ぶ。1件あたり数円程度）
GOOGLE_CLOUD_PROJECT=<プロジェクトID> python cloud/data/scripts/draft_scripts.py
#   1件だけ：--only lm_0003　／　作り直し：--force
```

* ウイルス対策ソフトが HTTPS を検査している PC（Norton など）で「証明書」のエラーが出たら、そのソフトの証明書を含む束のファイルを `SSL_CERT_FILE` と `REQUESTS_CA_BUNDLE` に指定して動かす（分からなければメンバー1に聞く）
* 出てくる場所：`cloud/data/drafts/lm_0003.json` のように1件1ファイル
* `manual/landmarks/` は**書き換えません**。下書きが既にあるものは作りません（お金の無駄を防ぐ）
* `--fake` で作った下書きは仮の文なので、本番の前に消すか `--force` で作り直してください

### 下書きの確かめ方

下書きのファイルの中で見るところ：

| 項目 | 見ること |
| :---- | :---- |
| `script_short` / `script_long` | 原稿。声に出して読んで自然か。短い版は60字、長い版は150字が目安 |
| `warnings` | 長すぎる、方向の言葉が入っている、など。**全部直す** |
| `numbers_to_check` | 原稿に出てくる数字・年号。**出典と一字一句合っているか確かめる**。合わない・確かめられないなら消す |
| `facts` | 原稿に使った事実と、その根拠の URL。URL を開いて本当に書いてあるか確かめる |
| `uncertain` | Gemini が確かめられなかったこと（原稿には入っていない） |
| `source_pages` | 本文を読んだ出典のページと文字数（0 なら読めなかった。そのページの事実は使われていない） |

確かめて直したら、`landmarks/<ID>.json` に `script_short`・`script_long` を写し、`status` を `"reviewed"` にして、`python schema/validate.py` を動かします。**確かでない内容は入れない**（数が足りないほうが、間違った情報を話すよりよい）。

## SQLite を作る（API 用）

```sh
python cloud/data/scripts/build_sqlite.py            # manual/ と osm/ から
python cloud/data/scripts/build_sqlite.py --examples # 見本から（お試し）
```

`reviewed` のランドマークだけが入ります。データが schema に合わないと、どのファイルの何件目のどこが違うかを表示して止まります。Cloud Run のコンテナを作るときにも自動で動きます。

## ランドマークの形（11/7。メンバー1）

円（中心＋`radius_m`）だけだと、環水公園の外を歩いてもエリアに入るなど、実際の場所とずれるため、
ランドマークに実際の形 `shape` を足した（形は `schema/common.schema.json` の `landmark_shape`）。

* 公園（エリア）：OpenStreetMap の公園の輪郭。輪郭の中だけが範囲（`margin_m` 0）
* 建物・橋：建物の輪郭から `margin_m`（駅舎 30m、美術館・オーバード・ホール・YKK AP ARENA 25m、桜橋 15m）以内
* 通り・川：線から `margin_m`（ブールバール 25m、松川べり 30m）以内。ブールバールは富山駅北線の北緯36.7085まで、松川べりは中心から350m 以内の川筋
* ラバーズ像は像1点なので形を付けない（中心から25m の円のまま）
* 形の出どころ（way の番号）は各ファイルの `shape.source`。`radius_m` は形を読めない古いアプリのために残す
* 形を直したら、viewer の地図（`app/viewer/assets/map.json`）も作り直す（`dart run tool/build_map.dart`）

## カメラで調べない区域（11/7。メンバー1）

建物の中など、B（画像での案内）で撮らない場所。`cloud/data/manual/zones/<ID>.json` に1件1ファイル（形は `schema/zone_entry.schema.json`）。

* 円（中心 `lat`・`lon` と `radius_m`）。入るのは半径以内、出るのは半径＋15m より外（engine の `zoneExitMarginM`。`build_sqlite.py` の `ZONE_EXIT_MARGIN_M` と同じ値）
* `build_sqlite.py` が、円＋15m がかかるタイルすべてに入れる（エリアと同じ）。`note`・`source`・`schema_version` はタイルに入れない
* API は環境変数 `TILE_ZONES=on` のときだけ応答に `zones` を付ける
* 今は2件（どちらも半径20m、`reason: demo`＝仮に指定。実際に撮影が禁止されているわけではない）
  * `zn_0001` 環水公園の南側（36.707472, 137.214222。サンフォルテの北東 約40m。デモ動画で使う）
  * どちらも 11/7 にメンバー1が位置を指定（最初のあいの島・バードサンクチュアリは取りやめ）

## 住所（町丁目）を作る（11/6 夜、メンバー3の提案。メンバー1）

国土交通省「位置参照情報」から、横断歩道と同じ範囲の**町丁目の代表点**だけを取り出して `address/towns.json` を作ります。
位置から町丁目を引くときは、いちばん近い代表点で決め、**800m より遠ければ「わからない」**にします（`scripts/town_lookup.py`）。番地・街区は持ちません。

1. **人が行う**：位置参照情報ダウンロードサービス（https://nlftp.mlit.go.jp/isj/ ）で、富山県 → 富山市（16201）の**大字・町丁目レベル**と**街区レベル**の最新の年度を選び、利用規約に同意してダウンロードする
2. zip を展開して、中の CSV（Shift_JIS のまま）を `cloud/data/raw/address/` に置く（Git 管理外。フォルダの中は下までたどるので、展開したフォルダごとでよい）
3. 作る：

```sh
python cloud/data/scripts/build_address.py     # → cloud/data/address/towns.json（Git 管理）
python cloud/data/scripts/build_sqlite.py      # SQLite の towns・landmark_towns の表に入る
```

* 街区レベルは、近い代表点で決める方法がどれくらい当たるかを表示するのに使うだけ（出力には入れない）
* **今はタイルの応答に町丁目を入れていない**（`schema/api/tile.response.schema.json` を変えるまで API の応答は変えない）。ランドマークの町丁目はビルドのときに SQLite の `landmark_towns` に入る（ランドマークのファイルは書き換えない）
* 出典の表示：「位置参照情報」（国土交通省）を加工して作成（`docs/attribution.md`）
