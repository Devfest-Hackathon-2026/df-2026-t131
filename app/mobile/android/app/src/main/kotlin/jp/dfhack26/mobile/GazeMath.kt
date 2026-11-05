package jp.dfhack26.mobile

import kotlin.math.asin
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * 背面カメラが向いている方向（視線）の方位と傾きを、回転行列から求める。
 *
 * 回転行列 R（3x3、行優先の9要素）は端末座標→世界座標（東・北・上）。
 * 背面カメラは端末の -Z 方向を向くので、世界座標では
 *   東 = -R[2]、北 = -R[5]、上 = -R[8]
 * この式は縦持ち・横持ち（左右どちら向きでも）で同じなので、座標の付け替えは要らない。
 */
object GazeMath {
    /** 水平成分がこれより小さい（真上・真下を向いている）ときは方位を決められない。 */
    const val MIN_HORIZONTAL = 0.05

    data class Direction(val east: Double, val north: Double, val up: Double)

    fun cameraDirection(r: FloatArray): Direction =
        Direction(east = -r[2].toDouble(), north = -r[5].toDouble(), up = -r[8].toDouble())

    /** 方位（度、0〜360、北0°・時計回り）。[declinationDeg] を足して真北にする。 */
    fun azimuthDeg(east: Double, north: Double, declinationDeg: Double = 0.0): Double =
        normalizeDeg(Math.toDegrees(atan2(east, north)) + declinationDeg)

    /** 傾き（度、-90〜90、水平0°・上が正）。 */
    fun pitchDeg(up: Double): Double = Math.toDegrees(asin(up.coerceIn(-1.0, 1.0)))

    fun normalizeDeg(deg: Double): Double {
        val d = deg % 360.0
        return if (d < 0) d + 360.0 else d
    }

    fun horizontalNorm(east: Double, north: Double): Double = sqrt(east * east + north * north)
}

/**
 * 方位のなめらかにする処理。0/360 の境目で飛ばないように、角度ではなく
 * 水平の単位ベクトル（東・北）を指数移動平均する。傾きはそのまま平均する。
 */
class GazeSmoother(private val alpha: Double = 0.2) {
    private var east = 0.0
    private var north = 0.0
    private var pitch = 0.0
    private var hasValue = false

    /** 新しい向きを入れる。方位が決められない向きのときは方位を更新しない。 */
    fun update(dir: GazeMath.Direction) {
        val h = GazeMath.horizontalNorm(dir.east, dir.north)
        val p = GazeMath.pitchDeg(dir.up)
        if (!hasValue) {
            if (h < GazeMath.MIN_HORIZONTAL) return
            east = dir.east / h
            north = dir.north / h
            pitch = p
            hasValue = true
            return
        }
        if (h >= GazeMath.MIN_HORIZONTAL) {
            east += alpha * (dir.east / h - east)
            north += alpha * (dir.north / h - north)
        }
        pitch += alpha * (p - pitch)
    }

    fun hasValue(): Boolean = hasValue

    fun azimuthDeg(declinationDeg: Double): Double =
        GazeMath.azimuthDeg(east, north, declinationDeg)

    fun pitchDeg(): Double = pitch
}
