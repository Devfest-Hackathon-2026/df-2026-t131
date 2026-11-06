#!/usr/bin/env bash
# ずんだもんの声（VOICEVOX CORE）をアプリに組み込むためのファイルを取ってきて並べる。
#
#   bash tool/fetch_voicevox.sh      （app/mobile で実行）
#
# - 取ってくるもの（合わせて約110MB。どれも Git には入れない：app/mobile/vendor/ は .gitignore）
#   1. VOICEVOX CORE の Android 版（java_packages.zip の中の Maven リポジトリ）
#   2. VOICEVOX ONNX Runtime（Android arm64）
#   3. 音声モデル 0.vvm（ずんだもんが入っている）と、その利用規約 TERMS.txt
#   4. Open JTalk の辞書
# - 取ってくる前に、音声モデルと ONNX Runtime の利用規約（TERMS.txt）を読んで同意すること。
#   声を使うときは「VOICEVOX:ずんだもん」のクレジットが必要（アプリの設定画面に出している）。
# - このフォルダが無いままビルドすると、ずんだもんは入らず、端末の声（Google）で話す。
set -euo pipefail

CORE=0.17.1
ORT=1.23.2
VVM=0.17.1
DICT=open_jtalk_dic_utf_8-1.11

cd "$(dirname "$0")/.."
V=vendor/voicevox
mkdir -p "$V/dl"

get() { # URL 保存先
  if [ ! -s "$2" ]; then
    echo "取得: $1"
    curl -fSL -o "$2" "$1"
  fi
}

get "https://github.com/VOICEVOX/voicevox_core/releases/download/$CORE/java_packages.zip" "$V/dl/java_packages.zip"
get "https://github.com/VOICEVOX/onnxruntime-builder/releases/download/voicevox_onnxruntime-$ORT/voicevox_onnxruntime-android-arm64-$ORT.tgz" "$V/dl/ort.tgz"
get "https://github.com/VOICEVOX/voicevox_vvm/releases/download/$VVM/0.vvm" "$V/dl/0.vvm"
get "https://github.com/VOICEVOX/voicevox_vvm/releases/download/$VVM/TERMS.txt" "$V/dl/TERMS.txt"
get "https://github.com/r9y9/open_jtalk/releases/download/v1.11.1/$DICT.tar.gz" "$V/dl/dict.tar.gz"

# 1. Maven リポジトリ（Gradle が読む）
rm -rf "$V/maven" && mkdir -p "$V/maven"
unzip -qo "$V/dl/java_packages.zip" -d "$V/maven"

# 2. ONNX Runtime（jniLibs として APK に入る）
rm -rf "$V/jniLibs" "$V/ort" && mkdir -p "$V/jniLibs/arm64-v8a" "$V/ort"
tar xzf "$V/dl/ort.tgz" -C "$V/ort"
cp "$V/ort/voicevox_onnxruntime-android-arm64-$ORT/lib/libvoicevox_onnxruntime.so" "$V/jniLibs/arm64-v8a/"

# 3・4. 音声モデルと辞書（assets として APK に入り、初回起動時に端末の中へ写す）
rm -rf "$V/assets" && mkdir -p "$V/assets/voicevox"
cp "$V/dl/0.vvm" "$V/assets/voicevox/0.vvm"
tar xzf "$V/dl/dict.tar.gz" -C "$V/assets/voicevox"
# 写したかどうかの目印（版が変わったら写し直す）
echo "core=$CORE ort=$ORT vvm=$VVM dict=$DICT" > "$V/assets/voicevox/VERSION"

echo "完了: $V（ビルドすると、ずんだもんの声が入ります）"
