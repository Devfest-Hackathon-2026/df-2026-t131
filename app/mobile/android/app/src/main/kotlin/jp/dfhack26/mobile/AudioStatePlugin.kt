package jp.dfhack26.mobile

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * イヤホンの有無と通話中かどうかを1秒ごとに Flutter に送る。
 * 通話中は AudioManager の mode を見るので、電話の権限は要らない。
 * - EventChannel "mobile/audio_state"：{earphone, inCall}
 * - MethodChannel "mobile/device"：battery() → {levelPct, tempC}（デバッグ画面用。歩行ログには入れない）
 */
class AudioStatePlugin(private val context: Context, messenger: BinaryMessenger) :
    EventChannel.StreamHandler {

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    private val poll = object : Runnable {
        override fun run() {
            sink?.success(mapOf("earphone" to hasEarphone(), "inCall" to isInCall()))
            handler.postDelayed(this, POLL_MS)
        }
    }

    init {
        EventChannel(messenger, "mobile/audio_state").setStreamHandler(this)
        MethodChannel(messenger, "mobile/device").setMethodCallHandler { call, result ->
            when (call.method) {
                "battery" -> result.success(battery())
                else -> result.notImplemented()
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        handler.removeCallbacks(poll)
        handler.post(poll)
    }

    override fun onCancel(arguments: Any?) {
        handler.removeCallbacks(poll)
        sink = null
    }

    fun dispose() {
        handler.removeCallbacks(poll)
        sink = null
    }

    private fun hasEarphone(): Boolean =
        audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { isEarphone(it.type) }

    private fun isEarphone(type: Int): Boolean = when (type) {
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_USB_HEADSET -> true
        else -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            type == AudioDeviceInfo.TYPE_BLE_HEADSET
    }

    private fun isInCall(): Boolean {
        val mode = audioManager.mode
        return mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_IN_COMMUNICATION
    }

    private fun battery(): Map<String, Any?> {
        val intent: Intent? =
            context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val temp = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            ?: Int.MIN_VALUE
        return mapOf(
            "levelPct" to if (level >= 0 && scale > 0) level * 100.0 / scale else null,
            "tempC" to if (temp != Int.MIN_VALUE) temp / 10.0 else null,
        )
    }

    companion object {
        private const val POLL_MS = 1000L
    }
}
