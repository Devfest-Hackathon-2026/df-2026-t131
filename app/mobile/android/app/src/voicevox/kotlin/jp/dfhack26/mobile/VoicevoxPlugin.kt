package jp.dfhack26.mobile

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.Future
import jp.hiroshiba.voicevoxcore.blocking.Onnxruntime
import jp.hiroshiba.voicevoxcore.blocking.OpenJtalk
import jp.hiroshiba.voicevoxcore.blocking.Synthesizer
import jp.hiroshiba.voicevoxcore.blocking.VoiceModelFile

/**
 * ずんだもんの声（VOICEVOX CORE）で、端末の中だけで読み上げる。通信はしない。
 * 声を使うときは「VOICEVOX:ずんだもん」のクレジットを出す（設定画面）。
 *
 * MethodChannel "mobile/voicevox"
 * - init() → bool：音声モデルと辞書を端末の中へ写し（初回だけ）、読み込む。使えなければ false
 * - speak(id, text, styleId, speed) → bool：作って話す。話し終えたら true、止められたら false
 *   話し始めに Dart へ started(id, durationMs) を送る
 * - stop()：今の発話を止める
 */
class VoicevoxPlugin(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "mobile/voicevox")
    private val main = Handler(Looper.getMainLooper())

    // 読み込みと音声づくりは1本の裏のスレッドで順に行う
    private val worker = Executors.newSingleThreadExecutor()

    // 作り終わるのを待つ係（worker を待たせないため別のスレッド）
    private val waiter = Executors.newSingleThreadExecutor()

    // 先に作り始めた声（prepare）。キーは「文・スタイル・速さ」。話すときに取り出して使う
    private val prepared = java.util.concurrent.ConcurrentHashMap<String, Future<ByteArray?>>()

    private var synthesizer: Synthesizer? = null
    private var model: VoiceModelFile? = null
    private var initResult: Boolean? = null

    // 止めるたびに増やす。作っている途中で止められた発話を、あとで話し出さないため
    @Volatile private var generation = 0
    private var track: AudioTrack? = null
    private var pending: MethodChannel.Result? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> worker.execute {
                    val ok = ensureLoaded()
                    main.post { result.success(ok) }
                }
                "speak" -> {
                    val id = call.argument<Int>("id") ?: 0
                    val text = call.argument<String>("text") ?: ""
                    val style = call.argument<Int>("styleId") ?: 3
                    val speed = call.argument<Double>("speed") ?: 1.0
                    speak(id, text, style, speed, result)
                }
                "prepare" -> {
                    val text = call.argument<String>("text") ?: ""
                    val style = call.argument<Int>("styleId") ?: 3
                    val speed = call.argument<Double>("speed") ?: 1.0
                    if (text.isNotBlank()) synthFuture(text, style, speed)
                    result.success(null)
                }
                "stop" -> {
                    stopNow()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // ---- 読み込み（裏のスレッド） ----

    private fun ensureLoaded(): Boolean {
        initResult?.let { return it }
        val ok = try {
            val dir = copyAssets()
            val ort = Onnxruntime.loadOnce().perform()
            val jtalk = OpenJtalk(File(dir, DICT).absolutePath)
            // スマホの CPU の芯を使って速く作る（最大4本）
            val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
            val s = Synthesizer.builder(ort, jtalk).cpuNumThreads(threads).build()
            // 音声モデルのファイルは開いたままにする（閉じると、後の片付けでエラーが出るため）
            val m = VoiceModelFile(File(dir, MODEL).absolutePath)
            s.loadVoiceModel(m).perform()
            model = m
            synthesizer = s
            // 1回目の音声づくりは準備で遅いので、起動時に短い文で済ませておく
            try {
                s.synthesis(s.createAudioQuery("こんにちは。", 3), 3).perform()
            } catch (_: Throwable) {
            }
            android.util.Log.i(TAG, "VOICEVOX を読み込んだ（$threads 本）")
            true
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "VOICEVOX を読み込めない: ${e.javaClass.simpleName}")
            false
        }
        initResult = ok
        return ok
    }

    /** APK の assets/voicevox を端末の中へ写す。版の目印が同じなら写し直さない。 */
    private fun copyAssets(): File {
        val dest = File(context.filesDir, "voicevox")
        val version = context.assets.open("voicevox/VERSION").use { it.readBytes() }
        val mark = File(dest, "VERSION")
        if (mark.exists() && mark.readBytes().contentEquals(version)) return dest
        dest.deleteRecursively()
        copyDir("voicevox", dest)
        mark.writeBytes(version) // 全部写し終えてから目印を書く
        return dest
    }

    private fun copyDir(assetPath: String, dest: File) {
        val children = context.assets.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            if (assetPath.endsWith("/VERSION")) return
            dest.parentFile?.mkdirs()
            context.assets.open(assetPath).use { input ->
                dest.outputStream().use { input.copyTo(it, 1 shl 16) }
            }
            return
        }
        dest.mkdirs()
        for (c in children) copyDir("$assetPath/$c", File(dest, c))
    }

    // ---- 話す ----

    private fun key(text: String, style: Int, speed: Double) = "$style|$speed|$text"

    /** 声を作り始める（作り始めていればそれを返す）。作るのは worker で1件ずつ。 */
    private fun synthFuture(text: String, style: Int, speed: Double): Future<ByteArray?> {
        val k = key(text, style, speed)
        prepared[k]?.let { return it }
        // 作ったまま使われない分が溜まらないようにする
        if (prepared.size > MAX_PREPARED) prepared.clear()
        val f = worker.submit<ByteArray?> {
            try {
                if (!ensureLoaded()) null else {
                    val s = synthesizer!!
                    val query = s.createAudioQuery(text, style)
                    query.speedScale = speed
                    s.synthesis(query, style).perform()
                }
            } catch (e: Throwable) {
                android.util.Log.w(TAG, "声を作れない: ${e.javaClass.simpleName}")
                null
            }
        }
        prepared[k] = f
        return f
    }

    private fun speak(id: Int, text: String, style: Int, speed: Double, result: MethodChannel.Result) {
        val gen = generation
        val k = key(text, style, speed)
        val f = synthFuture(text, style, speed)
        waiter.execute {
            val wav = try {
                f.get()
            } catch (_: Throwable) {
                null
            }
            prepared.remove(k, f)
            main.post {
                if (gen != generation || wav == null) {
                    result.success(false) // 作っている間に止められた・作れなかった
                } else {
                    play(id, wav, result)
                }
            }
        }
    }

    /** WAV（16bit・モノラル）を鳴らす。主スレッドで呼ぶ。 */
    private fun play(id: Int, wav: ByteArray, result: MethodChannel.Result) {
        val pcm = Pcm.fromWav(wav)
        if (pcm == null || pcm.frames == 0) {
            result.success(false)
            return
        }
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(pcm.sampleRate)
                    .setChannelMask(
                        if (pcm.channels == 2) AudioFormat.CHANNEL_OUT_STEREO
                        else AudioFormat.CHANNEL_OUT_MONO,
                    )
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(pcm.data.size)
            .build()
        t.write(pcm.data, 0, pcm.data.size)
        track = t
        pending = result
        val gen = generation
        t.notificationMarkerPosition = pcm.frames
        t.setPlaybackPositionUpdateListener(
            object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(track: AudioTrack) = finish(gen, true)
                override fun onPeriodicNotification(track: AudioTrack) {}
            },
            main,
        )
        val durationMs = pcm.frames * 1000L / pcm.sampleRate
        // 念のため：終わりの通知が来なくても、長さ＋1秒で終わらせる
        main.postDelayed({ finish(gen, true) }, durationMs + 1000)
        t.play()
        channel.invokeMethod("started", mapOf("id" to id, "durationMs" to durationMs))
    }

    private fun finish(gen: Int, ok: Boolean) {
        if (gen != generation) return
        generation++
        release()
        pending?.success(ok)
        pending = null
    }

    private fun stopNow() {
        generation++
        prepared.clear() // 止めた話の続きの文は使わない
        release()
        pending?.success(false)
        pending = null
    }

    private fun release() {
        track?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        track = null
    }

    fun dispose() {
        stopNow()
        channel.setMethodCallHandler(null)
        worker.shutdown()
        waiter.shutdown()
    }

    /** WAV の中の音のデータ。 */
    private class Pcm(val data: ByteArray, val sampleRate: Int, val channels: Int) {
        val frames get() = data.size / (2 * channels)

        companion object {
            fun fromWav(wav: ByteArray): Pcm? {
                if (wav.size < 12) return null
                val b = ByteBuffer.wrap(wav).order(ByteOrder.LITTLE_ENDIAN)
                var pos = 12
                var rate = 24000
                var ch = 1
                while (pos + 8 <= wav.size) {
                    val tag = String(wav, pos, 4, Charsets.US_ASCII)
                    val size = b.getInt(pos + 4)
                    val body = pos + 8
                    if (tag == "fmt ") {
                        ch = b.getShort(body + 2).toInt()
                        rate = b.getInt(body + 4)
                    } else if (tag == "data") {
                        val end = minOf(wav.size, body + size)
                        return Pcm(wav.copyOfRange(body, end), rate, ch)
                    }
                    pos = body + size + (size and 1)
                }
                return null
            }
        }
    }

    companion object {
        private const val TAG = "Voicevox"
        private const val MODEL = "0.vvm"
        private const val DICT = "open_jtalk_dic_utf_8-1.11"
        private const val MAX_PREPARED = 8
    }
}
