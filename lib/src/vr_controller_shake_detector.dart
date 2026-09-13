import 'dart:math' as math;

/// Detects deliberate controller shakes without treating gravity/steering as
/// gestures. Feed accelerometer samples (including gravity) and monotonic time.
///
/// A shake needs two energetic samples within 250 ms, then a quiet interval and
/// a 1.2 s cooldown before another toggle. No per-sample objects are allocated.
class VrControllerShakeDetector {
  static const double _gravity = 9.80665;
  int? _lastUs;
  int? _firstPeakUs;
  int? _lastShakeUs;
  int? _quietSinceUs;
  double _gx = 0;
  double _gy = 0;
  double _gz = 0;
  bool _armed = true;

  /// Clears motion history, for example when entering/leaving app suspension.
  void reset() {
    _lastUs = null;
    _firstPeakUs = null;
    _lastShakeUs = null;
    _quietSinceUs = null;
    _armed = true;
  }

  bool addSample(double x, double y, double z, int elapsedMicroseconds) {
    if (!x.isFinite || !y.isFinite || !z.isFinite || elapsedMicroseconds < 0) {
      return false;
    }
    final magnitude = math.sqrt(x * x + y * y + z * z);
    if (!magnitude.isFinite || magnitude > 200) return false;
    final previous = _lastUs;
    if (previous == null || elapsedMicroseconds - previous > 1000000) {
      // Learn gravity only from a near-rest sample. Opening the controller
      // while moving must not create an accidental toggle.
      if ((magnitude - _gravity).abs() > 2) return false;
      _gx = x;
      _gy = y;
      _gz = z;
      _lastUs = elapsedMicroseconds;
      _firstPeakUs = null;
      return false;
    }
    if (elapsedMicroseconds <= previous) return false;
    _lastUs = elapsedMicroseconds;
    final dx = x - _gx;
    final dy = y - _gy;
    final dz = z - _gz;
    final linearSquared = dx * dx + dy * dy + dz * dz;
    final gravityDeviation = (magnitude - _gravity).abs();
    // Rotation of a stationary phone changes gravity's direction, not its
    // magnitude. Requiring both rejects even abrupt ordinary wheel tilts.
    final energetic = linearSquared >= 144 && gravityDeviation >= 3;
    if (!energetic) {
      final alpha = ((elapsedMicroseconds - previous) / 300000).clamp(0.0, 1.0);
      _gx += (x - _gx) * alpha;
      _gy += (y - _gy) * alpha;
      _gz += (z - _gz) * alpha;
      _firstPeakUs = null;
      if (gravityDeviation < 2) {
        _quietSinceUs ??= elapsedMicroseconds;
        if (elapsedMicroseconds - _quietSinceUs! >= 200000) _armed = true;
      } else {
        _quietSinceUs = null;
      }
      return false;
    }
    _quietSinceUs = null;
    if (!_armed ||
        (_lastShakeUs != null &&
            elapsedMicroseconds - _lastShakeUs! < 1200000)) {
      return false;
    }
    if (_firstPeakUs == null || elapsedMicroseconds - _firstPeakUs! > 250000) {
      _firstPeakUs = elapsedMicroseconds;
      return false;
    }
    _firstPeakUs = null;
    _lastShakeUs = elapsedMicroseconds;
    _armed = false;
    return true;
  }
}
