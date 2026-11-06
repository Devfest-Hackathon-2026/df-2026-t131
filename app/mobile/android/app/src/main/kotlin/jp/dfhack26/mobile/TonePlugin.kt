package jp.dfhack26.mobile

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sin

/**
 * 話し始めの合図音と、音声認識の起動音を消す係。音声ファイルもライブラリも使わない。
 *
 * MethodChannel "mobile/tone"
 * - play()：やわらかい2音のチャイム（ド→ミのような上がる音、約0.35秒）を鳴らし、鳴り終わってから結果を返す
 * - muteBeeps(on)：音声認識（「検索して」の聞き取り）を起動し直すたびに Android が鳴らす「ポン」を消す。
 *   通知・システムの音を、聞き取っている間だけ消す（止めたら元に戻す）
 * - muteMusicBriefly(ms)：認識を起動し直す瞬間だけ、メディアの音も消す（起動音がメディアで鳴る端末向け）
 */
class TonePlugin(context: Context, messenger: BinaryMessenger) {
    private val handler = Handler(Looper.getMainLooper())
    private val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val chime: ShortArray = makeChime()
    private var beepsMuted = false
    private var musicMutedUntil = 0L

    // 消した音を戻す前にアプリが落ちたときのための印（次の起動で戻す）
    private val prefs = context.getSharedPreferences("tone", Context.MODE_PRIVATE)

    init {
        if (prefs.getBoolean(KEY_MUTED, false)) {
            beepsMuted = true
            setBeepsMuted(false)
        }
        MethodChannel(messenger, "mobile/tone").setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> play(result)
                "muteBeeps" -> {
                    setBeepsMuted(call.argument<Boolean>("on") ?: false)
                    result.success(null)
                }
                "muteMusicBriefly" -> {
                    muteMusicBriefly((call.argument<Int>("ms") ?: 600).coerceIn(100, 2000))
                    result.success(null)
                }
                "unmuteMusic" -> {
                    unmuteMusic()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun play(result: MethodChannel.Result) {
        // 合図音は必ず聞こえるように、メディアの消音を先に戻す
        unmuteMusic()
        try {
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(RATE)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(chime.size * 2)
                .build()
            track.write(chime, 0, chime.size)
            track.play()
            val ms = chime.size * 1000L / RATE
            handler.postDelayed({
                track.release()
                result.success(true)
            }, ms + 40L)
        } catch (e: RuntimeException) {
            // 鳴らせない端末でも読み上げは続ける
            result.success(false)
        }
    }

    private fun setBeepsMuted(on: Boolean) {
        if (on == beepsMuted) return
        beepsMuted = on
        prefs.edit().putBoolean(KEY_MUTED, on).apply()
        val dir = if (on) AudioManager.ADJUST_MUTE else AudioManager.ADJUST_UNMUTE
        for (s in BEEP_STREAMS) {
            try {
                audio.adjustStreamVolume(s, dir, 0)
            } catch (_: SecurityException) {
                // おやすみモードなどで変えられないときはそのまま
            }
        }
    }

    private fun muteMusicBriefly(ms: Int) {
        val until = System.currentTimeMillis() + ms
        val wasMuted = musicMutedUntil > System.currentTimeMillis()
        musicMutedUntil = until
        if (!wasMuted) {
            try {
                audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
            } catch (_: SecurityException) {
            }
        }
        handler.postDelayed({
            if (System.currentTimeMillis() >= musicMutedUntil) unmuteMusic()
        }, ms.toLong() + 20)
    }

    private fun unmuteMusic() {
        if (musicMutedUntil == 0L) return
        musicMutedUntil = 0L
        try {
            audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
        } catch (_: SecurityException) {
        }
    }

    /** アプリを閉じるとき、消した音を必ず戻す。 */
    fun dispose() {
        setBeepsMuted(false)
        unmuteMusic()
    }

    companion object {
        private const val RATE = 24000
        private const val KEY_MUTED = "beeps_muted"
        private val BEEP_STREAMS = intArrayOf(
            AudioManager.STREAM_NOTIFICATION,
            AudioManager.STREAM_SYSTEM,
        )

        /** やわらかい2音のチャイム。鐘のように倍音を少し足し、なめらかに消える。 */
        private fun makeChime(): ShortArray {
            val notes = listOf(0.0 to 1046.5, 0.12 to 1318.5) // ド（C6）→ ミ（E6）
            val total = 0.36
            val n = (RATE * total).toInt()
            val out = DoubleArray(n)
            for ((start, f) in notes) {
                val s0 = (RATE * start).toInt()
                for (i in s0 until n) {
                    val t = (i - s0).toDouble() / RATE
                    val attack = min(1.0, t / 0.006) // 立ち上がりのプツッを消す
                    val env = attack * exp(-t * 9.0)
                    val v = sin(2 * PI * f * t) + 0.25 * sin(2 * PI * f * 2 * t) +
                        0.08 * sin(2 * PI * f * 3 * t)
                    out[i] += 0.32 * env * v
                }
            }
            // 終わりを少し丸めて切る
            val fade = (RATE * 0.03).toInt()
            for (i in 0 until fade) out[n - 1 - i] *= i.toDouble() / fade
            return ShortArray(n) { i ->
                (out[i].coerceIn(-1.0, 1.0) * Short.MAX_VALUE).toInt().toShort()
            }
        }
    }
}
