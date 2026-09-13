import 'dart:math' as math;

import 'package:vector_math/vector_math.dart';

/// Observed sensor availability, not an OS/device compatibility guarantee.
enum VrMotionCapability { checking, available, unavailable }

/// Normalized driving controls. Positive steering means turn right.
class VrSteeringState {
  final double steering;
  final double throttle;
  final double brake;
  final bool paused;

  const VrSteeringState({
    this.steering = 0,
    this.throttle = 0,
    this.brake = 0,
    this.paused = false,
  });
}

/// Calibrated, screen-normal twist steering, independent of rendering/sensors.
///
/// Supply device-frame orientation (not head orientation). The screen's normal
/// is local Z in both landscape directions. Clockwise rotation, as seen by
/// the person holding the screen, yields positive steering. This is relative
/// 3DoF input, not positional tracking; raw gyro integration can drift.
class VrSteeringController {
  /// Twist needed for full lock. 55 degrees gives finer control than the
  /// previous 45-degree range without reducing the reachable output [-1, 1].
  final double rangeRadians;
  final double deadzoneRadians;

  /// Applied only to motion input after the deadzone. 1 is linear; values
  /// above 1 soften the center while preserving direction and full lock.
  final double responseExponent;
  final double pedalRisePerSecond;
  final double pedalFallPerSecond;
  final Quaternion _neutral = Quaternion.identity();
  final Quaternion _orientation = Quaternion.identity();
  double _motionSteering = 0;
  double? _touchSteering;
  double _throttle = 0;
  double _brake = 0;
  bool _throttleHeld = false;
  bool _brakeHeld = false;
  bool _paused = false;
  bool _motionAvailable = false;

  VrSteeringController({
    this.rangeRadians = 55 * math.pi / 180,
    this.deadzoneRadians = math.pi / 90,
    this.responseExponent = 1.15,
    this.pedalRisePerSecond = 3,
    this.pedalFallPerSecond = 6,
  }) {
    if (!rangeRadians.isFinite ||
        rangeRadians <= 0 ||
        rangeRadians > math.pi ||
        !deadzoneRadians.isFinite ||
        deadzoneRadians < 0 ||
        deadzoneRadians >= rangeRadians ||
        !responseExponent.isFinite ||
        responseExponent < 1 ||
        responseExponent > 3 ||
        !pedalRisePerSecond.isFinite ||
        pedalRisePerSecond <= 0 ||
        !pedalFallPerSecond.isFinite ||
        pedalFallPerSecond <= 0) {
      throw ArgumentError(
        'Invalid steering range, deadzone, response exponent or pedal rates.',
      );
    }
  }

  VrSteeringState get state => VrSteeringState(
    steering: _paused
        ? 0
        : (_touchSteering ?? (_motionAvailable ? _motionSteering : 0)),
    throttle: _paused ? 0 : _throttle,
    brake: _paused ? 0 : _brake,
    paused: _paused,
  );

  bool get motionAvailable => _motionAvailable;

  void setMotionAvailable(bool available) {
    if (available == _motionAvailable) return;
    _motionAvailable = available;
    // A recovered sensor must not introduce a stale steering jump.
    calibrate(_orientation);
  }

  /// Defines straight ahead locally. Never requests a visor/head recenter.
  void calibrate(Quaternion orientation) {
    _validateOrientation(orientation);
    _neutral.setFrom(orientation);
    _neutral.normalize();
    _orientation.setFrom(_neutral);
    _motionSteering = 0;
    _touchSteering = null;
  }

  void updateOrientation(Quaternion orientation) {
    _validateOrientation(orientation);
    _orientation.setFrom(orientation);
    _orientation.normalize();
    final relative = _neutral.conjugated() * _orientation;
    // Swing/twist decomposition around local Z. At a 180° swing the twist
    // is undefined: return neutral rather than an arbitrary full-lock turn.
    if (relative.z * relative.z + relative.w * relative.w < 1e-12) {
      _motionSteering = 0;
      return;
    }
    var angle = -2 * math.atan2(relative.z, relative.w);
    angle = (angle + math.pi) % (2 * math.pi) - math.pi;
    final magnitude =
        ((angle.abs() - deadzoneRadians) / (rangeRadians - deadzoneRadians))
            .clamp(0.0, 1.0);
    _motionSteering =
        angle.sign * math.pow(magnitude, responseExponent).toDouble();
  }

  /// Touch owns steering while non-null; null returns to the motion source.
  /// Without motion, releasing the touch always springs to neutral.
  void setTouchSteering(double? value) {
    if (value != null && !value.isFinite) {
      throw ArgumentError.value(value, 'value', 'Must be finite.');
    }
    _touchSteering = _paused ? null : value?.clamp(-1.0, 1.0);
  }

  void setPedals({required bool throttlePressed, required bool brakePressed}) {
    _throttleHeld = !_paused && throttlePressed;
    _brakeHeld = !_paused && brakePressed;
  }

  /// Advances ramps using elapsed seconds, not a presumed sensor/frame rate.
  /// A long scheduling gap is capped so returning from suspension cannot surge.
  void advance(double elapsedSeconds) {
    if (!elapsedSeconds.isFinite || elapsedSeconds < 0) {
      throw ArgumentError.value(elapsedSeconds, 'elapsedSeconds');
    }
    if (_paused) return;
    final dt = elapsedSeconds.clamp(0.0, 0.1);
    _brake = _ramp(_brake, _brakeHeld, dt);
    // Braking wins over accelerator, including the brake's release ramp.
    _throttle = _brakeHeld || _brake > 0
        ? 0
        : _ramp(_throttle, _throttleHeld, dt);
  }

  double _ramp(double current, bool held, double dt) =>
      (current + (held ? pedalRisePerSecond : -pedalFallPerSecond) * dt).clamp(
        0.0,
        1.0,
      );

  /// Immediate safety release: no ramp and no sticky pedals after suspension.
  void release() {
    _throttleHeld = false;
    _brakeHeld = false;
    _throttle = 0;
    _brake = 0;
    calibrate(_orientation);
  }

  void setPaused(bool paused) {
    release();
    _paused = paused;
  }

  static void _validateOrientation(Quaternion q) {
    if (!q.x.isFinite ||
        !q.y.isFinite ||
        !q.z.isFinite ||
        !q.w.isFinite ||
        !q.length2.isFinite ||
        q.length2 < 1e-12) {
      throw ArgumentError.value(q, 'orientation', 'Must be a finite pose.');
    }
  }
}
