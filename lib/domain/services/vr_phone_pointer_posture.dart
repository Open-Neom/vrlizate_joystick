import 'dart:math' as math;

/// Observes a phone held in landscape with its display upright and its rear
/// optical axis approximately level. Uses natural phone axes (X right,
/// Y toward the portrait top, Z out of the display), in m/s².
///
/// A side-of-body grip, with the display inward and the rear camera outward,
/// also qualifies. World yaw is unrestricted; the phone need not be in front
/// of the chest. A face-up display still fails this inclination gate.
///
/// Gravity cannot establish compass heading, which phone the camera faces,
/// position or optical tracking. This gate never opens a camera or changes aim.
/// Call with a monotonic arrival clock; missing or invalid samples fail closed.
class VrPhonePointerPosture {
  VrPhonePointerPosture({this.holdUs = 200000, this.staleAfterUs = 150000}) {
    if (holdUs < 0 || staleAfterUs <= 0) {
      throw ArgumentError('Invalid pointing posture timing.');
    }
  }

  final int holdUs;
  final int staleAfterUs;
  int? _lastSampleUs, _candidateSinceUs;
  bool _ready = false;
  double _upX = 0, _upY = 0, _upZ = 0;
  double _rightX = 0, _rightY = 0;

  bool isReadyAt(int nowUs) =>
      _ready &&
      _lastSampleUs != null &&
      nowUs >= _lastSampleUs! &&
      nowUs - _lastSampleUs! < staleAfterUs;

  void updateGravity(double x, double y, double z, int nowUs) {
    final previousUs = _lastSampleUs;
    if (nowUs < 0 || (previousUs != null && nowUs < previousUs)) {
      reset();
      return;
    }
    final magnitude = math.sqrt(x * x + y * y + z * z);
    if (!magnitude.isFinite || magnitude < 8 || magnitude > 11.5) {
      reset();
      return;
    }
    if (previousUs == nowUs) return;
    if (previousUs == null || nowUs - previousUs >= staleAfterUs) {
      _ready = false;
      _candidateSinceUs = null;
    }
    _lastSampleUs = nowUs;
    _upX = x / magnitude;
    _upY = y / magnitude;
    _upZ = z / magnitude;
    final planar = math.sqrt(x * x + y * y);
    _rightX = planar > 1e-6 ? y / planar : 0;
    _rightY = planar > 1e-6 ? -x / planar : 0;
    final gx = x.abs() / magnitude;
    final gy = y.abs() / magnitude;
    final gz = z.abs() / magnitude;
    // Hysteresis allows modest natural roll/pitch while already pointing.
    // A flat phone (Z dominant) or portrait phone (Y dominant) exits at once.
    if (_ready) {
      if (gx < .72 || gy > .40 || gz > .57) {
        _ready = false;
        _candidateSinceUs = null;
      }
      return;
    }
    if (gx < .85 || gy > .28 || gz > .42) {
      _candidateSinceUs = null;
      return;
    }
    _candidateSinceUs ??= nowUs;
    if (nowUs - _candidateSinceUs! >= holdUs) _ready = true;
  }

  /// Project fresh gyro samples on the observed upright phone axes. Positive
  /// yaw aims right, positive pitch up, in either landscape orientation.
  /// Call only while [isReadyAt] is true; these are rates, not absolute heading.
  double yawRate(double x, double y, double z) =>
      -(x * _upX + y * _upY + z * _upZ);

  double pitchRate(double x, double y) => x * _rightX + y * _rightY;

  void reset() {
    _lastSampleUs = null;
    _candidateSinceUs = null;
    _ready = false;
    _upX = _upY = _upZ = _rightX = _rightY = 0;
  }
}
