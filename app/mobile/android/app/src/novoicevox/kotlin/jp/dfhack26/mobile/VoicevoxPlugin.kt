package jp.dfhack26.mobile

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * ずんだもんの声のファイル（app/mobile/vendor/voicevox。tool/fetch_voicevox.sh で取る）が
 * 無いままビルドしたときの代わり。init は false を返し、アプリは端末の声（Google）で話す。
 */
class VoicevoxPlugin(@Suppress("UNUSED_PARAMETER") context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "mobile/voicevox")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "init", "speak" -> result.success(false)
                "stop", "prepare" -> result.success(null)
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
