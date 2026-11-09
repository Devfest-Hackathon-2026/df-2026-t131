"""開発開始（2026-11-05 10:00 JST）より前の日時のコミットが入っていないか確かめる（CI で実行）。

使い方（リポジトリの一番上で。CI では履歴を全部取ってから動かす）:
    python .github/scripts/check_commit_dates.py

見るもの:
  1. 作者の日時（author date）と、コミットした日時（committer date）のどちらかが開始より前 → 赤（終了コード1）
  2. 1つのコミットで app/ や cloud/ に大量の行を足している → 警告だけ（赤にはしない）
     まとめて作ったコードを一度に入れていないか、レビューで人が確かめるための目印

コミットの日時は手元で書き換えられるので、これだけで「開始前に書いていない」ことの証明にはならない。
小さくこまめにコミットする運用（docs/design.md 16章）と、レビューでの確認とあわせて使う。
"""
import subprocess
import sys
from datetime import datetime, timedelta, timezone

START = datetime(2026, 11, 5, 10, 0, tzinfo=timezone(timedelta(hours=9)))
BIG_COMMIT_LINES = 1500
WATCH_PREFIXES = ("app/", "cloud/")
GENERATED_SUFFIXES = (".lock", "pubspec.lock", ".g.dart", ".freezed.dart")  # 自動で作られるファイルは数えない


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, check=True, text=True, encoding="utf-8").stdout


def main() -> int:
    if git("rev-parse", "--is-shallow-repository").strip() == "true":
        print("履歴が浅い（shallow）ため確かめられません。CI では actions/checkout に fetch-depth: 0 を付ける")
        return 1
    bad = []
    merges = set(git("rev-list", "--merges", "HEAD").split())
    for line in git("log", "--format=%H%x09%aI%x09%cI%x09%an%x09%s", "HEAD").splitlines():
        h, a, c, who, subject = line.split("\t", 4)
        ad, cd = datetime.fromisoformat(a), datetime.fromisoformat(c)
        if ad < START or cd < START:
            bad.append(f"{h[:8]} 作者の日時 {a} / コミットの日時 {c}（{who}）{subject}")
            continue
        if h in merges:
            continue  # マージのコミットは、すでにあるコミットをまとめただけなので大きさは見ない
        added = 0
        for row in git("show", "--numstat", "--format=", h).splitlines():
            parts = row.split("\t")
            if len(parts) == 3 and parts[0].isdigit() and parts[2].startswith(WATCH_PREFIXES) \
                    and not parts[2].endswith(GENERATED_SUFFIXES):
                added += int(parts[0])
        if added >= BIG_COMMIT_LINES:
            # GitHub Actions の警告として PR の画面に出る
            print(f"::warning::{h[:8]}（{who}）が1回で {added} 行を足しています。開始後に少しずつ書いたものか、レビューで確かめてください：{subject}")

    if bad:
        print(f"開発開始（{START.isoformat()}）より前の日時のコミットがあります。これらは main に入れられません:")
        for b in bad:
            print(f"  NG {b}")
        return 1
    print("開始前の日時のコミットはありません")
    return 0


if __name__ == "__main__":
    sys.exit(main())
