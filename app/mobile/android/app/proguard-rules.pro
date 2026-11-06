# ずんだもんの声（VOICEVOX CORE）。ネイティブ側が Java のクラス・フィールドを名前で読むので、
# リリースビルドの縮小（R8）で消したり名前を変えたりしない。gson で読む型も同じ。
-keep class jp.hiroshiba.voicevoxcore.** { *; }
-dontwarn jp.hiroshiba.voicevoxcore.**
-dontwarn javax.annotation.**
-dontwarn jakarta.**
