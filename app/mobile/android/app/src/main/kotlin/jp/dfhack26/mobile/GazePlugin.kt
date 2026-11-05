package jp.dfhack26.mobile

import android.content.Context
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 回転ベクトルセンサーから視線の方位・傾きを求めて Flutter に送る。
 * - EventChannel "mobile/gaze"：{azDeg, pitchDeg, declinationDeg} を約10Hzで送る
 * - MethodChannel "mobile/gaze_control"：setLocation(lat, lon, altM) で偏角を更新する
 * 回転ベクトルは磁北基準なので、偏角（富山市で約 -7.6°）を足して真北にする。
 */
class GazePlugin(context: Context, messenger: BinaryMessenger) :
    EventChannel.StreamHandler, SensorEventListener {

    private val sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val rotationSensor: Sensor? = sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
    private val smoother = GazeSmoother(alpha = 0.2)
    private val rotation = FloatArray(9)
    private var sink: EventChannel.EventSink? = null
    private var lastSentMs = 0L
    @Volatile private var declinationDeg = 0.0

    init {
        EventChannel(messenger, "mobile/gaze").setStreamHandler(this)
        MethodChannel(messenger, "mobile/gaze_control").setMethodCallHandler { call, result ->
            when (call.method) {
                "setLocation" -> {
                    val lat = call.argument<Double>("lat")
                    val lon = call.argument<Double>("lon")
                    val alt = call.argument<Double>("altM") ?: 0.0
                    if (lat == null || lon == null) {
                        result.error("bad_args", "lat と lon が必要", null)
                    } else {
                        val field = GeomagneticField(
                            lat.toFloat(), lon.toFloat(), alt.toFloat(), System.currentTimeMillis()
                        )
                        declinationDeg = field.declination.toDouble()
                        result.success(declinationDeg)
                    }
                }
                "isAvailable" -> result.success(rotationSensor != null)
                else -> result.notImplemented()
            }
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (rotationSensor == null) {
            events?.error("no_sensor", "回転ベクトルセンサーがない", null)
            return
        }
        sensorManager.registerListener(this, rotationSensor, SensorManager.SENSOR_DELAY_GAME)
    }

    override fun onCancel(arguments: Any?) {
        sensorManager.unregisterListener(this)
        sink = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        SensorManager.getRotationMatrixFromVector(rotation, event.values)
        smoother.update(GazeMath.cameraDirection(rotation))
        val now = SystemClock.elapsedRealtime()
        if (!smoother.hasValue() || now - lastSentMs < SEND_INTERVAL_MS) return
        lastSentMs = now
        sink?.success(
            mapOf(
                "azDeg" to smoother.azimuthDeg(declinationDeg),
                "pitchDeg" to smoother.pitchDeg(),
                "declinationDeg" to declinationDeg,
            )
        )
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    fun dispose() {
        sensorManager.unregisterListener(this)
        sink = null
    }

    companion object {
        private const val SEND_INTERVAL_MS = 100L
    }
}
