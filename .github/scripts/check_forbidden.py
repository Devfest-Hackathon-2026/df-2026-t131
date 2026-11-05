"""リポジトリに入れてはいけないものが無いか確かめる（CI で実行）。

使い方（リポジトリの一番上で）:
    python .github/scripts/check_forbidden.py

見るもの:
  1. 画像・動画ファイル（アイコン等の置き場所を除く）
  2. 秘密情報のファイル（.env、鍵、google-services.json など）
  3. ファイルの中身にある秘密情報らしき文字列（Google API キー、秘密鍵、サービスアカウント鍵）
  4. app/engine の決定論を壊すもの（package:flutter、DateTime.now、Random）

見つかったら終了コード1で止まる。
"""
import re
import subprocess
import sys
from fnmatch import fnmatch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

IMAGE_EXT = {".jpg", ".jpeg", ".png", ".heic", ".webp", ".gif", ".bmp", ".mp4", ".mov"}
# 画像を置いてよい場所（アプリのアイコン・Web の静的素材・説明資料の図）
IMAGE_ALLOWED = [
    "app/mobile/android/app/src/main/res/*",
    "app/mobile/assets/icons/*",
    "app/viewer/web/*",
    "app/viewer/assets/icons/*",
    "docs/images/*",
]

SECRET_FILES = [
    ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.jks", "*.keystore", "key.properties",
    "google-services.json", "GoogleService-Info.plist", "firebase_options.dart",
    "service-account*.json", "*-sa.json", "*credentials*.json",
]
SECRET_FILES_ALLOWED = [".env.example"]

SECRET_PATTERNS = [
    (re.compile(r"AIza[0-9A-Za-z_\-]{35}"), "Google API キーらしき文字列"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "秘密鍵"),
    (re.compile(r'"type"\s*:\s*"service_account"'), "サービスアカウント鍵"),
]

ENGINE_FORBIDDEN = [
    (re.compile(r"package:flutter"), "engine は Flutter に依存しない"),
    (re.compile(r"\bDateTime\.now\b"), "engine は時計を読まない（時間はイベントの tMs だけで進める）"),
    (re.compile(r"\bRandom\b"), "engine は乱数を使わない（決定論）"),
]

TEXT_EXT = {".py", ".dart", ".json", ".jsonl", ".yaml", ".yml", ".md", ".txt", ".toml",
            ".gradle", ".kts", ".xml", ".properties", ".sh", ".js", ".ts", ".html", ".cfg", ".ini"}


def tracked_files() -> list[str]:
    """Git 管理下のファイル（コミットされるもの）。Git が無ければ全ファイル。"""
    try:
        out = subprocess.run(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=ROOT, capture_output=True, check=True,
        ).stdout.decode("utf-8")
        return [p for p in out.split("\0") if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        skip = {".git", ".dart_tool", "build", "node_modules", ".venv", "__pycache__"}
        return [
            p.relative_to(ROOT).as_posix()
            for p in ROOT.rglob("*")
            if p.is_file() and not (set(p.relative_to(ROOT).parts) & skip)
        ]


def matches(path: str, patterns: list[str]) -> bool:
    name = path.rsplit("/", 1)[-1]
    return any(fnmatch(path, pat) or fnmatch(name, pat) for pat in patterns)


def main() -> int:
    problems: list[str] = []
    for rel in tracked_files():
        p = ROOT / rel
        if not p.is_file():
            continue
        ext = p.suffix.lower()

        if ext in IMAGE_EXT and not matches(rel, IMAGE_ALLOWED):
            problems.append(f"{rel}: 画像・動画ファイルはコミットしない（カメラ画像を保存しない決まり）")

        if matches(rel, SECRET_FILES) and not matches(rel, SECRET_FILES_ALLOWED):
            problems.append(f"{rel}: 秘密情報のファイルはコミットしない")

        # このスクリプト自身はパターンを書いているので中身の検査から外す
        if ext in TEXT_EXT and rel != ".github/scripts/check_forbidden.py":
            try:
                text = p.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for pat, what in SECRET_PATTERNS:
                if pat.search(text):
                    problems.append(f"{rel}: {what}が含まれている")
            if rel.startswith("app/engine/") and ext == ".dart":
                for i, line in enumerate(text.splitlines(), 1):
                    code = line.split("//", 1)[0]  # コメントは見ない
                    for pat, why in ENGINE_FORBIDDEN:
                        if pat.search(code):
                            problems.append(f"{rel}:{i}: {pat.pattern} は使えない（{why}）")

    if problems:
        print("禁止事項が見つかりました:")
        for msg in problems:
            print(f"  NG {msg}")
        print(f"\n{len(problems)} 件")
        return 1
    print("禁止事項はありません")
    return 0


if __name__ == "__main__":
    sys.exit(main())
