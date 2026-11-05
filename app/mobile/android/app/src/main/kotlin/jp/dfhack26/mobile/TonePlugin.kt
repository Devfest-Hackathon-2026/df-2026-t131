package jp.dfhack26.mobile

import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * 話し始めの合図音。音声ファイルもライブラリも使わず、Android 標準の ToneGenerator で鳴らす。
 * MethodChannel "mobile/tone"：play(durationMs) → 鳴り終わってから結果を返す。
 */
class TonePlugin(messenger: BinaryMessenger) {
    private val handler = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "mobile/tone").setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> {
                    val ms = (call.argument<Int>("durationMs") ?: 150).coerceIn(50, 1000)
                    try {
                        val tone = ToneGenerator(AudioManager.STREAM_MUSIC, VOLUME)
                        tone.startTone(ToneGenerator.TONE_PROP_BEEP, ms)
                        // 鳴り終わってから少し間を置いて片付け、結果を返す
                        handler.postDelayed({
                            tone.release()
                            result.success(true)
                        }, ms + 80L)
                    } catch (e: RuntimeException) {
                        // 鳴らせない端末でも読み上げは続ける
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        private const val VOLUME = 60 // 0〜100
    }
}
