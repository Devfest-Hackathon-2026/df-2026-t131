# アンビエント・ナラティブガイド

スマートグラスをかけて歩くと、通り道のランドマークの話を数秒〜15秒で耳元に語る音声ガイド。
**観光地に行かなくても、いつもの道が観光になる。**

DevFest GDGoC Japan Hackathon 2026（カテゴリ：観光）の提出作品。デモでは**スマートグラスの代わりに Android スマホ**を首の高さで構えて使う。

> このリポジトリの設計・ルールは [`CLAUDE.md`](CLAUDE.md)、4人のつなぎ方は [`tasks/README.md`](tasks/README.md) にある。

## 構成

| ディレクトリ | 中身 | 担当 |
| :---- | :---- | :---- |
| `schema/` | API と歩行ログの JSON Schema・見本データ・検証スクリプト | メンバー1 |
| `cloud/api/` | Cloud Run：タイル API（A）と視界の検索 API（B、Vertex AI Gemini） | メンバー1 |
| `cloud/alert-job/` | Cloud Run：気象警報の取得 → FCM 配信 | メンバー1 |
| `cloud/data/` | データ準備（スクリプトはメンバー1、データはメンバー4） | メンバー1・4 |
| `app/engine/` | 判断エンジン（純粋な Dart） | メンバー2 |
| `app/viewer/` | 判断画面の Web 版（Flutter Web） | メンバー2 |
| `app/mobile/` | Android アプリ（Flutter） | メンバー3 |
| `docs/` | 出典・ライセンス（`attribution.md`）など | メンバー4 |

## はじめに（全員）

```sh
pip install -r schema/requirements.txt
python schema/validate.py                    # 形式の検証
python .github/scripts/check_forbidden.py    # 禁止事項の検出
```

* PR は使わず `main` に直接 push する。作業前と push 前に `git pull --rebase origin main`
* push の前に上の2つと自分のテストを通す。CI が赤くなったら push した人がすぐ直す（`tasks/README.md` 5章）
* コミットしないもの：`.env`、鍵、`google-services.json`、`cloud/data/raw/`、`cloud/data/build/`、カメラ画像
* AI エージェントには、会話の最初に [`tasks/START_PROMPTS.md`](tasks/START_PROMPTS.md) の自分の欄を貼る

## 版

[`tasks/README.md`](tasks/README.md) 10章を参照。
