# cloud/data — データの準備

| 場所 | 中身 | 担当 |
| :---- | :---- | :---- |
| `manual/` | 確認済みのデータ。ランドマークは1件1ファイル（`landmarks/lm_0001.json`…）、ほかに `events.json`・`timetable.json`（交通は余裕があれば）。Git 管理 | メンバー4（確認はメンバー1） |
| `drafts/` | Gemini が作った原稿の下書き（確認前）。Git 管理 | メンバー4 |
| `osm/` | OpenStreetMap から取り出した横断歩道・信号（`crossings.json`） | メンバー1（スクリプト） |
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

```sh
# 1. お試し（お金はかからない。仮の文が出るだけ）
python cloud/data/scripts/draft_scripts.py --fake

# 2. 本番の前に1回だけ（ブラウザでログイン）
gcloud auth application-default login

# 3. 本番（Gemini を呼ぶ。1件あたり数円程度）
GOOGLE_CLOUD_PROJECT=<プロジェクトID> python cloud/data/scripts/draft_scripts.py
#   1件だけ：--only lm_0003　／　作り直し：--force
```

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
| `grounding_sources` | Gemini が検索で見たページ |

確かめて直したら、`landmarks/<ID>.json` に `script_short`・`script_long` を写し、`status` を `"reviewed"` にして、`python schema/validate.py` を動かします。**確かでない内容は入れない**（数が足りないほうが、間違った情報を話すよりよい）。

## SQLite を作る（API 用）

```sh
python cloud/data/scripts/build_sqlite.py            # manual/ と osm/ から
python cloud/data/scripts/build_sqlite.py --examples # 見本から（お試し）
```

`reviewed` のランドマークだけが入ります。データが schema に合わないと、どのファイルの何件目のどこが違うかを表示して止まります。Cloud Run のコンテナを作るときにも自動で動きます。
