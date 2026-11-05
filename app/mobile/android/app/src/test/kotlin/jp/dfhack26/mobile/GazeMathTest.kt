package jp.dfhack26.mobile

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * 回転行列の代表例で、視線の方位と傾きが期待どおりになるかを確かめる。
 * 行列は端末座標（X=画面右, Y=画面上, Z=画面から手前）→ 世界座標（東, 北, 上）。
 */
class GazeMathTest {
    private val eps = 1e-6

    /** 列ベクトル（端末の X・Y・Z 軸を世界座標で表したもの）から行優先の9要素を作る。 */
    private fun fromAxes(x: DoubleArray, y: DoubleArray, z: DoubleArray): FloatArray =
        floatArrayOf(
            x[0].toFloat(), y[0].toFloat(), z[0].toFloat(),
            x[1].toFloat(), y[1].toFloat(), z[1].toFloat(),
            x[2].toFloat(), y[2].toFloat(), z[2].toFloat(),
        )

    private fun gaze(r: FloatArray): Pair<Double, Double> {
        val d = GazeMath.cameraDirection(r)
        return GazeMath.azimuthDeg(d.east, d.north) to GazeMath.pitchDeg(d.up)
    }

    @Test
    fun 縦持ちで北を向く() {
        // 画面が南を向く＝背面カメラは北。X=東, Y=上, Z=南
        val r = fromAxes(doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, 0.0, 1.0), doubleArrayOf(0.0, -1.0, 0.0))
        val (az, pitch) = gaze(r)
        assertEquals(0.0, az, eps)
        assertEquals(0.0, pitch, eps)
    }

    @Test
    fun 縦持ちで東を向く() {
        // 背面カメラが東。X=南, Y=上, Z=西
        val r = fromAxes(doubleArrayOf(0.0, -1.0, 0.0), doubleArrayOf(0.0, 0.0, 1.0), doubleArrayOf(-1.0, 0.0, 0.0))
        val (az, pitch) = gaze(r)
        assertEquals(90.0, az, eps)
        assertEquals(0.0, pitch, eps)
    }

    @Test
    fun 横持ちで南を向く() {
        // 横持ちで背面カメラが南。X=上, Y=東, Z=北
        val r = fromAxes(doubleArrayOf(0.0, 0.0, 1.0), doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, 1.0, 0.0))
        val (az, pitch) = gaze(r)
        assertEquals(180.0, az, eps)
        assertEquals(0.0, pitch, eps)
    }

    @Test
    fun 横持ち逆向きでも同じ式で西を向く() {
        // 逆向きの横持ちで背面カメラが西。X=下, Y=北, Z=東
        val r = fromAxes(doubleArrayOf(0.0, 0.0, -1.0), doubleArrayOf(0.0, 1.0, 0.0), doubleArrayOf(1.0, 0.0, 0.0))
        val (az, pitch) = gaze(r)
        assertEquals(270.0, az, eps)
        assertEquals(0.0, pitch, eps)
    }

    @Test
    fun 北へ30度見上げる() {
        val s = Math.sin(Math.toRadians(30.0))
        val c = Math.cos(Math.toRadians(30.0))
        // 背面カメラ方向 = (0, c, s) なので Z = (0, -c, -s)。Y は Z と X に直交するよう (0, -s, c)
        val r = fromAxes(doubleArrayOf(1.0, 0.0, 0.0), doubleArrayOf(0.0, -s, c), doubleArrayOf(0.0, -c, -s))
        val (az, pitch) = gaze(r)
        assertEquals(0.0, az, 1e-5)
        assertEquals(30.0, pitch, 1e-4)
    }

    @Test
    fun 偏角を足して真北にする() {
        // 磁北で 0° のとき、偏角 -7.6°（西偏）なら真北で 352.4°
        assertEquals(352.4, GazeMath.azimuthDeg(0.0, 1.0, -7.6), 1e-9)
    }

    @Test
    fun 境目をまたいでもなめらかにする() {
        val sm = GazeSmoother(alpha = 0.5)
        fun dir(deg: Double) = GazeMath.Direction(
            Math.sin(Math.toRadians(deg)), Math.cos(Math.toRadians(deg)), 0.0
        )
        sm.update(dir(350.0))
        sm.update(dir(10.0))
        // 角度で平均すると 180° になってしまうが、ベクトルなら 0° 付近
        val az = sm.azimuthDeg(0.0)
        val diff = minOf(az, 360.0 - az)
        assertEquals(0.0, diff, 1e-6)
    }

    @Test
    fun 真下を向いたら方位を決めない() {
        val sm = GazeSmoother()
        sm.update(GazeMath.Direction(0.0, 0.0, -1.0))
        assertFalse(sm.hasValue())
    }
}
