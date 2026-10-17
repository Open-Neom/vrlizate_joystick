import 'dart:math' as math;

/// Momentary relative-tilt joystick: hold the look pad, rotate the phone away
/// from that gesture's neutral posture, and keep looking at the requested rate
/// even after the phone stops rotating. Release immediately returns neutral.
/// The host sums this bounded contribution with touch and clamps the result.
///
/// Android/sensors_plus natural device axes: X right, Y towards the natural top,
/// Z out of the display. Gyro uses right-hand-rule rad/s; accelerometer includes
/// gravity in m/s² (stationary support points upwards). A fresh gesture freezes
/// gravityUp and screenRight = normalized(gravityUp.xy × screenNormal).
/// Its relative quaternion maps the current body frame into the press frame.
/// We project its rotation vector onto -gravityUp for yaw and screenRight for
/// pitch: positive X turns right, positive Y looks up in both landscapes.
/// This has no forward-vector singularity when crossing a flat posture. Roll
/// can contribute yaw with an inclined phone because gravityUp.z is nonzero.
///
/// Gravity selects axes, not an absolute heading. Without a magnetometer/bias
/// calibration, long holds can drift; the angular deadzone absorbs small errors.
/// There is no translation, positional tracking, laser pose or heading reset.
/// Supply a monotonic arrival clock for freshness. Optional sensor timestamps
/// determine integration intervals independently of callback scheduling; their
/// epoch may differ, but each active stream must strictly increase. Reset on
/// lifecycle or sensor errors.
class VrMotionLookController {
  static const maxContribution = .60;
  static const deadzoneRadians = 3 * math.pi / 180;
  static const fullScaleRadians = 25 * math.pi / 180;
  static const responseExponent = 1.25;
  static const staleAfterUs = 150000;
  static const maximumGestureRadians = 170 * math.pi / 180;
  static const _gravityFilterSeconds = .12;
  static const _maximumGyroRate = 8.0;
  static const _minimumGravityProjection = .20;

  bool _active = false, _gravityReliable = false, _hasScreenRight = false;
  bool _hasReference = false;
  int? _activationUs, _lastGravityUs, _lastGyroUs, _lastSensorTimeUs;
  double _gx = 0, _gy = 0, _gz = 0;
  double _rawGx = 0, _rawGy = 0, _rawGz = 0;
  double _rightX = 0, _rightY = 0;
  double _up0x = 0, _up0y = 0, _up0z = 0, _right0x = 0, _right0y = 0;
  double _qx = 0, _qy = 0, _qz = 0, _qw = 1;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0, _z1 = 0, _z2 = 0;
  double _filteredX = 0, _filteredY = 0, _filteredZ = 0;

  bool get active => _active;

  void updateGravity(double x, double y, double z, int nowUs) {
    final previousUs = _lastGravityUs;
    if (previousUs != null && nowUs >= 0 && nowUs <= previousUs) return;
    final magnitude = math.sqrt(x * x + y * y + z * z);
    if (nowUs < 0 || !magnitude.isFinite || magnitude < 8 || magnitude > 11.5) {
      _gravityReliable = false;
      _disarm();
      return;
    }
    x /= magnitude;
    y /= magnitude;
    z /= magnitude;
    final freshBasis = previousUs == null || nowUs - previousUs >= staleAfterUs;
    if (!freshBasis) {
      final dt = (nowUs - previousUs) / 1e6;
      final maximumAngle = .15 + 12 * dt;
      final dot = (x * _rawGx + y * _rawGy + z * _rawGz).clamp(-1.0, 1.0);
      if (maximumAngle < math.pi && dot < math.cos(maximumAngle)) {
        _gravityReliable = false;
        _disarm();
        return;
      }
      final alpha = 1 - math.exp(-dt / _gravityFilterSeconds);
      _gx += alpha * (x - _gx);
      _gy += alpha * (y - _gy);
      _gz += alpha * (z - _gz);
      final length = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
      if (length < .25 || !length.isFinite) {
        _gravityReliable = false;
        _disarm();
        return;
      }
      _gx /= length;
      _gy /= length;
      _gz /= length;
    } else {
      if (_active && _lastGyroUs != null) _disarm();
      _gx = x;
      _gy = y;
      _gz = z;
    }
    _rawGx = x;
    _rawGy = y;
    _rawGz = z;
    _lastGravityUs = nowUs;
    _gravityReliable = true;
    final projection = math.sqrt(_gx * _gx + _gy * _gy);
    if (projection >= _minimumGravityProjection) {
      _rightX = _gy / projection;
      _rightY = -_gx / projection;
      _hasScreenRight = true;
    }
    // At a flat posture retain an observed axis; do not invent an initial one.
    // Gesture reference axes stay frozen even when the live basis changes.
  }

  void setActive(bool value, int nowUs) {
    if (nowUs < 0) {
      reset();
      return;
    }
    if (_active == value) return;
    _disarm();
    if (!value) return;
    _active = true;
    _activationUs = nowUs;
    if (_gravityIsFresh(nowUs) && _hasScreenRight) _captureReference();
  }

  void _captureReference() {
    _up0x = _gx;
    _up0y = _gy;
    _up0z = _gz;
    _right0x = _rightX;
    _right0y = _rightY;
    _hasReference = true;
  }

  void updateGyroscope(
    double x,
    double y,
    double z,
    int nowUs, {
    int? sensorTimeUs,
  }) {
    if (!_active) return;
    if (nowUs < 0) {
      _disarm();
      return;
    }
    final previousUs = _lastGyroUs;
    if (nowUs <= _activationUs! ||
        (previousUs != null &&
            (nowUs < previousUs ||
                (nowUs == previousUs && sensorTimeUs == null)))) {
      return;
    }
    final sourceUs = sensorTimeUs ?? nowUs;
    final previousSourceUs = _lastSensorTimeUs;
    final magnitude = math.sqrt(x * x + y * y + z * z);
    if (!magnitude.isFinite ||
        magnitude > _maximumGyroRate ||
        sourceUs < 0 ||
        (previousSourceUs != null &&
            (sourceUs <= previousSourceUs ||
                sourceUs - previousSourceUs >= staleAfterUs)) ||
        (previousUs != null && nowUs - previousUs >= staleAfterUs) ||
        (previousUs == null && nowUs - _activationUs! >= staleAfterUs)) {
      _disarm();
      return;
    }
    if (!_gravityIsFresh(nowUs) || !_hasScreenRight) {
      if (previousUs != null) _disarm();
      return;
    }
    if (!_hasReference) _captureReference();
    _lastGyroUs = nowUs;
    _lastSensorTimeUs = sourceUs;
    // Median-of-three rejects one isolated impulse without a velocity
    // deadband: slow return motion must undo the complete stored angle.
    final mx = _median(x, _x1, _x2);
    final my = _median(y, _y1, _y2);
    final mz = _median(z, _z1, _z2);
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    _z2 = _z1;
    _z1 = z;
    if (previousSourceUs != null) {
      _integrate(
        (mx + _filteredX) * .5,
        (my + _filteredY) * .5,
        (mz + _filteredZ) * .5,
        (sourceUs - previousSourceUs) / 1e6,
      );
      if (!_active) return;
    }
    _filteredX = mx;
    _filteredY = my;
    _filteredZ = mz;
  }

  void _integrate(double x, double y, double z, double dt) {
    final speed = math.sqrt(x * x + y * y + z * z);
    if (speed == 0) return; // Quiet gyro preserves the deflected posture.
    final halfAngle = speed * dt * .5;
    final scale = math.sin(halfAngle) / speed;
    final dx = x * scale, dy = y * scale, dz = z * scale;
    final dw = math.cos(halfAngle);
    // q * delta(body omega): current body -> gesture's initial body frame.
    final qx = _qw * dx + _qx * dw + _qy * dz - _qz * dy;
    final qy = _qw * dy - _qx * dz + _qy * dw + _qz * dx;
    final qz = _qw * dz + _qx * dy - _qy * dx + _qz * dw;
    final qw = _qw * dw - _qx * dx - _qy * dy - _qz * dz;
    final length = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw);
    _qx = qx / length;
    _qy = qy / length;
    _qz = qz / length;
    _qw = qw / length;
    // Avoid the principal logarithm's 180° branch. This guards the gesture,
    // not the 25° speed limit; normal over-range deflections retain full state.
    // Preserve quaternion sign: abs(w) would alias a single step crossing
    // 180° back below the guard and reverse the principal rotation vector.
    if (_qw <= math.cos(maximumGestureRadians * .5)) {
      _disarm();
    }
  }

  ({double x, double y}) sample(int nowUs) {
    if (!_active) return (x: 0, y: 0);
    final last = _lastGyroUs;
    if (nowUs < _activationUs! ||
        (last != null &&
            (nowUs < last ||
                nowUs - last >= staleAfterUs ||
                !_gravityIsFresh(nowUs))) ||
        (last == null && nowUs - _activationUs! >= staleAfterUs)) {
      _disarm();
      return (x: 0, y: 0);
    }
    // PointerDown samples immediately, before either sensor can send anything.
    // Preserve that pending gesture until its first valid sample or timeout.
    if (last == null || !_hasReference) return (x: 0, y: 0);
    final length = math.sqrt(_qx * _qx + _qy * _qy + _qz * _qz);
    if (length < 1e-12) return (x: 0, y: 0);
    final sign = _qw < 0 ? -1.0 : 1.0;
    final scale = 2 * math.atan2(length, _qw.abs()) / length * sign;
    final rx = _qx * scale, ry = _qy * scale, rz = _qz * scale;
    var x = _response(-(rx * _up0x + ry * _up0y + rz * _up0z));
    var y = _response(rx * _right0x + ry * _right0y);
    final magnitude = math.sqrt(x * x + y * y);
    if (magnitude > maxContribution) {
      x *= maxContribution / magnitude;
      y *= maxContribution / magnitude;
    }
    return (x: x, y: y);
  }

  bool _gravityIsFresh(int nowUs) {
    final last = _lastGravityUs;
    return _gravityReliable &&
        last != null &&
        nowUs >= last &&
        nowUs - last < staleAfterUs;
  }

  static double _median(double a, double b, double c) =>
      a + b + c - math.min(a, math.min(b, c)) - math.max(a, math.max(b, c));

  static double _response(double angle) {
    final fraction =
        ((angle.abs() - deadzoneRadians) / (fullScaleRadians - deadzoneRadians))
            .clamp(0.0, 1.0);
    return angle.sign * maxContribution * math.pow(fraction, responseExponent);
  }

  void _disarm() {
    _active = _hasReference = false;
    _activationUs = _lastGyroUs = _lastSensorTimeUs = null;
    _qx = _qy = _qz = 0;
    _qw = 1;
    _x1 = _x2 = _y1 = _y2 = _z1 = _z2 = 0;
    _filteredX = _filteredY = _filteredZ = 0;
  }

  /// Lifecycle/sensor reset forgets the gravity basis too. Ending a gesture
  /// through setActive(false, ...) retains its fresh basis for the next press.
  void reset() {
    _disarm();
    _gravityReliable = _hasScreenRight = false;
    _lastGravityUs = null;
    _gx = _gy = _gz = _rawGx = _rawGy = _rawGz = 0;
    _rightX = _rightY = 0;
  }
}
