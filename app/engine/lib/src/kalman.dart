import 'geo.dart';

/// 位置の平滑化（docs/design.md 5章）。状態 [x, y, vx, vy]、等速モデルのカルマンフィルタ。
///
/// 観測は位置（精度 acc_m を標準偏差とする）と、端末が出す速さ・進行方向（あるときだけ）。
/// 乱数・時計は使わず、同じ観測の列なら必ず同じ結果になる。
final class KalmanFilter2D {
  /// 加速度の標準偏差（m/s²）。歩行の速さの揺れを表す。
  final double accelNoise;

  /// 速度の観測の標準偏差（m/s）。
  final double velocityNoise;

  final List<double> _x = List.filled(4, 0);
  final List<List<double>> _p = List.generate(4, (_) => List.filled(4, 0));
  bool _initialized = false;

  KalmanFilter2D({required this.accelNoise, required this.velocityNoise});

  bool get initialized => _initialized;
  Vec2 get position => Vec2(_x[0], _x[1]);
  Vec2 get velocity => Vec2(_x[2], _x[3]);

  /// 最初の観測、または長い欠測のあとに状態を作り直す。
  void reset(Vec2 position, double accM, Vec2? velocity) {
    _x[0] = position.x;
    _x[1] = position.y;
    _x[2] = velocity?.x ?? 0;
    _x[3] = velocity?.y ?? 0;
    for (final row in _p) {
      row.fillRange(0, 4, 0);
    }
    final posVar = accM * accM;
    // 速度が分からないときは、歩く速さ程度（2 m/s）のばらつきを置く。
    final velVar = velocity == null ? 4.0 : velocityNoise * velocityNoise;
    _p[0][0] = posVar;
    _p[1][1] = posVar;
    _p[2][2] = velVar;
    _p[3][3] = velVar;
    _initialized = true;
  }

  /// dt 秒だけ等速で進める。
  void predict(double dt) {
    if (dt <= 0) return;
    _x[0] += _x[2] * dt;
    _x[1] += _x[3] * dt;
    // P = F P F^T + Q
    final p = _p;
    for (final (i, j) in const [(0, 2), (1, 3)]) {
      // 位置の行に速度の行を dt 倍で足す（F P）
      for (var c = 0; c < 4; c++) {
        p[i][c] += dt * p[j][c];
      }
      // 位置の列に速度の列を dt 倍で足す（(F P) F^T）
      for (var r = 0; r < 4; r++) {
        p[r][i] += dt * p[r][j];
      }
    }
    final q = accelNoise * accelNoise;
    final dt2 = dt * dt;
    final dt3 = dt2 * dt;
    final dt4 = dt3 * dt;
    for (final (i, j) in const [(0, 2), (1, 3)]) {
      p[i][i] += q * dt4 / 4;
      p[i][j] += q * dt3 / 2;
      p[j][i] += q * dt3 / 2;
      p[j][j] += q * dt2;
    }
  }

  void updatePosition(Vec2 z, double accM) =>
      _update2(0, 1, z.x, z.y, accM * accM);

  void updateVelocity(Vec2 v) =>
      _update2(2, 3, v.x, v.y, velocityNoise * velocityNoise);

  /// 状態の2成分（a, b）を直接観測したときの更新。観測の雑音は対角で r。
  void _update2(int a, int b, double za, double zb, double r) {
    final p = _p;
    final s00 = p[a][a] + r, s01 = p[a][b], s10 = p[b][a], s11 = p[b][b] + r;
    final det = s00 * s11 - s01 * s10;
    if (det.abs() < 1e-12) return;
    final i00 = s11 / det, i01 = -s01 / det, i10 = -s10 / det, i11 = s00 / det;
    // K = P H^T S^-1（4x2）
    final k = List.generate(4, (row) {
      final pa = p[row][a], pb = p[row][b];
      return (pa * i00 + pb * i10, pa * i01 + pb * i11);
    });
    final ya = za - _x[a], yb = zb - _x[b];
    for (var row = 0; row < 4; row++) {
      _x[row] += k[row].$1 * ya + k[row].$2 * yb;
    }
    // P = (I - K H) P
    final rowA = List.of(p[a]), rowB = List.of(p[b]);
    for (var row = 0; row < 4; row++) {
      for (var c = 0; c < 4; c++) {
        p[row][c] -= k[row].$1 * rowA[c] + k[row].$2 * rowB[c];
      }
    }
  }
}
