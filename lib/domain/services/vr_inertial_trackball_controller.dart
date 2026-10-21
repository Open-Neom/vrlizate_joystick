import 'dart:math' as math;

import '../../utils/constants/vr_joystick_constants.dart';

/// `Steam Controller`-inspired **Inertial Virtual Trackball** for the right
/// look stick/pad.
///
/// Tracks thumb movement velocity while held; when released after a flick,
/// continues emitting decaying `(x, y)` look rates using exponential friction
/// $v(t + \Delta t) = v(t) \cdot e^{-\mu \Delta t}$, halting immediately as
/// soon as the user touches the pad again.
class VrInertialTrackballController {
  final double frictionPerSecond;
  final double minLaunchSpeed;
  final double stopSpeedThreshold;
  final double velocitySmoothing;

  bool _isTouching = false;
  bool _isCoasting = false;
  double _lastX = 0.0;
  double _lastY = 0.0;
  int? _lastSampleUs;
  double _velocityX = 0.0;
  double _velocityY = 0.0;

  VrInertialTrackballController({
    this.frictionPerSecond = VrJoystickConstants.trackballFrictionPerSecond,
    this.minLaunchSpeed = VrJoystickConstants.trackballMinLaunchSpeed,
    this.stopSpeedThreshold = VrJoystickConstants.trackballStopSpeedThreshold,
    this.velocitySmoothing = VrJoystickConstants.trackballVelocitySmoothing,
  });

  bool get isCoasting => _isCoasting;
  double get velocityX => _velocityX;
  double get velocityY => _velocityY;

  /// Halts any active inertial coasting immediately when the thumb touches down.
  void onTouchDown(int timestampUs) {
    _isTouching = true;
    _isCoasting = false;
    _lastX = 0.0;
    _lastY = 0.0;
    _velocityX = 0.0;
    _velocityY = 0.0;
    _lastSampleUs = timestampUs;
  }

  /// Updates the tracked thumb position and estimates flick velocity.
  void onTouchMove(
    double x,
    double y, {
    required int timestampUs,
  }) {
    if (!x.isFinite || !y.isFinite) return;
    _isTouching = true;
    _isCoasting = false;
    final prevUs = _lastSampleUs;
    if (prevUs != null) {
      final dtSeconds = (timestampUs - prevUs) / 1e6;
      if (dtSeconds > 1e-4 && dtSeconds < 0.25) {
        final instVx = ((x - _lastX) / dtSeconds * 0.22).clamp(-1.0, 1.0);
        final instVy = ((y - _lastY) / dtSeconds * 0.22).clamp(-1.0, 1.0);
        _velocityX =
            _velocityX * (1.0 - velocitySmoothing) + instVx * velocitySmoothing;
        _velocityY =
            _velocityY * (1.0 - velocitySmoothing) + instVy * velocitySmoothing;
      }
    }
    // Also blend with the held deflection so releasing from a rapid edge swipe
    // carries natural momentum in that direction.
    if (x.abs() > _velocityX.abs()) {
      _velocityX = x.clamp(-1.0, 1.0);
    }
    if (y.abs() > _velocityY.abs()) {
      _velocityY = y.clamp(-1.0, 1.0);
    }
    _lastX = x;
    _lastY = y;
    _lastSampleUs = timestampUs;
  }

  /// Launches inertial coasting if the release velocity exceeds [minLaunchSpeed].
  void onTouchUp() {
    _isTouching = false;
    _lastSampleUs = null;
    final speed = math.sqrt(_velocityX * _velocityX + _velocityY * _velocityY);
    if (speed >= minLaunchSpeed) {
      _isCoasting = true;
    } else {
      _isCoasting = false;
      _velocityX = 0.0;
      _velocityY = 0.0;
    }
  }

  /// Advances inertial friction decay by [dtSeconds] and returns the current
  /// `(x, y)` coasting output.
  ({double x, double y}) advance(double dtSeconds) {
    if (_isTouching || !_isCoasting) {
      return (x: 0.0, y: 0.0);
    }
    if (!dtSeconds.isFinite || dtSeconds <= 0) {
      return (x: _velocityX.clamp(-1.0, 1.0), y: _velocityY.clamp(-1.0, 1.0));
    }
    final decay = math.exp(-frictionPerSecond * dtSeconds.clamp(0.0, 0.25));
    _velocityX *= decay;
    _velocityY *= decay;
    final speed = math.sqrt(_velocityX * _velocityX + _velocityY * _velocityY);
    if (speed < stopSpeedThreshold) {
      _isCoasting = false;
      _velocityX = 0.0;
      _velocityY = 0.0;
      return (x: 0.0, y: 0.0);
    }
    return (
      x: _velocityX.clamp(-1.0, 1.0),
      y: _velocityY.clamp(-1.0, 1.0),
    );
  }

  void reset() {
    _isTouching = false;
    _isCoasting = false;
    _lastX = 0.0;
    _lastY = 0.0;
    _lastSampleUs = null;
    _velocityX = 0.0;
    _velocityY = 0.0;
  }
}
