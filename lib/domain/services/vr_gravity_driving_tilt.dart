import 'dart:math' as math;

/// Uses the elevation of the screen normal, so landscapeLeft/right and wheel
/// twist share the same sign. Slow translational acceleration is inherently
/// ambiguous with gravity; large impulses are rejected and input stays zero
/// until 200 ms of fresh plausible samples have arrived.
class VrGravityDrivingTilt {
  static const _deadzone = 10 * math.pi / 180;
  static const _range = 32 * math.pi / 180;
  static const _settleUs = 200000;
  static const _staleUs = 400000;
  double? _filteredAngle, _neutralAngle;
  int? _lastSampleUs, _stableSinceUs;

  void calibrate() {
    _filteredAngle = _neutralAngle = null;
    _lastSampleUs = _stableSinceUs = null;
  }

  void addSample(double x, double y, double z, int nowUs) {
    final magnitude = math.sqrt(x * x + y * y + z * z);
    if (!magnitude.isFinite || magnitude < 8 || magnitude > 11.5 || nowUs < 0) {
      // A shake must neither drive the car nor redefine the neutral posture.
      _filteredAngle = null;
      _lastSampleUs = _stableSinceUs = null;
      return;
    }
    final previousUs = _lastSampleUs;
    if (previousUs != null && nowUs <= previousUs) return;
    if (previousUs != null && nowUs - previousUs > _staleUs) calibrate();
    // Rotating about the normal only changes X/Y, leaving this elevation
    // unchanged. Unlike a signed device-Y pitch, both landscape flips work.
    final angle = math.atan2(z, math.sqrt(x * x + y * y));
    if (_filteredAngle == null) {
      _filteredAngle = angle;
      _stableSinceUs = nowUs;
    } else {
      final dt = (nowUs - _lastSampleUs!) / 1e6;
      final alpha = 1 - math.exp(-dt / .12);
      _filteredAngle = _filteredAngle! + alpha * (angle - _filteredAngle!);
    }
    _lastSampleUs = nowUs;
    if (nowUs - _stableSinceUs! >= _settleUs) {
      _neutralAngle ??= _filteredAngle;
    }
  }

  double valueAt(int nowUs) {
    final last = _lastSampleUs;
    if (last == null) return 0;
    if (nowUs < last || nowUs - last > _staleUs) {
      calibrate();
      return 0;
    }
    if (_neutralAngle == null || last - _stableSinceUs! < _settleUs) return 0;
    final delta = _filteredAngle! - _neutralAngle!;
    final magnitude = ((delta.abs() - _deadzone) / (_range - _deadzone)).clamp(
      0.0,
      1.0,
    );
    return delta.sign * math.pow(magnitude, 1.35).toDouble();
  }
}
