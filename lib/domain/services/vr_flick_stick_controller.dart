import 'dart:math' as math;

import '../../utils/constants/vr_joystick_constants.dart';
import '../../utils/enums/vr_right_stick_look_mode.dart';

/// Implements `JoyShockMapper`-inspired **Flick Stick** and VR **Comfort
/// Snap-Turn** for the right thumbstick.
///
/// - In [VrRightStickLookMode.comfortSnapTurn], pushing horizontally beyond
///   [snapTriggerThreshold] emits a discrete turn pulse for
///   [snapPulseDurationSeconds], then waits for [snapCooldownSeconds] or for
///   the stick to return inside [snapRearmThreshold].
/// - In [VrRightStickLookMode.flickStick], snapping the stick to the outer rim
///   ([flickRimEngageThreshold]) triggers a rapid turn proportional to the
///   target angle $\theta = \operatorname{atan2}(x, y)$ relative to forward
///   $(0, 1)$, and subsequent rim sweeping rotates continuously according to
///   angular delta $\Delta\theta$.
class VrFlickStickController {
  final double snapTriggerThreshold;
  final double snapRearmThreshold;
  final double snapPulseDurationSeconds;
  final double snapCooldownSeconds;
  final double flickRimEngageThreshold;
  final double flickStickRimReleaseThreshold;
  final double flickSnapDurationSeconds;
  final double flickSweepGain;

  bool _snapArmed = true;
  double _snapPulseRemaining = 0.0;
  double _snapCooldownRemaining = 0.0;
  double _snapDirection = 0.0;

  bool _flickEngaged = false;
  double _lastFlickAngleRad = 0.0;
  double _flickRemainingRad = 0.0;
  double _flickTimeRemaining = 0.0;
  double _pendingSweepTurn = 0.0;

  VrFlickStickController({
    this.snapTriggerThreshold = VrJoystickConstants.snapTurnTriggerThreshold,
    this.snapRearmThreshold = VrJoystickConstants.snapTurnRearmThreshold,
    this.snapPulseDurationSeconds =
        VrJoystickConstants.snapTurnPulseDurationSeconds,
    this.snapCooldownSeconds = VrJoystickConstants.snapTurnCooldownSeconds,
    this.flickRimEngageThreshold =
        VrJoystickConstants.flickStickRimEngageThreshold,
    this.flickStickRimReleaseThreshold =
        VrJoystickConstants.flickStickRimReleaseThreshold,
    this.flickSnapDurationSeconds =
        VrJoystickConstants.flickStickSnapDurationSeconds,
    this.flickSweepGain = VrJoystickConstants.flickStickSweepGain,
  });

  bool get isFlickEngaged => _flickEngaged;

  /// Updates the controller with the current right-stick `(x, y)` and elapsed
  /// time `dtSeconds`, returning the conditioned horizontal `lookX` in
  /// `[-1.0, 1.0]`.
  double update({
    required VrRightStickLookMode mode,
    required double x,
    required double y,
    required double dtSeconds,
  }) {
    if (!x.isFinite || !y.isFinite || !dtSeconds.isFinite || dtSeconds < 0) {
      reset();
      return 0.0;
    }
    final dt = dtSeconds.clamp(0.0, 0.25);

    switch (mode) {
      case VrRightStickLookMode.comfortSnapTurn:
        return _updateSnapTurn(x, dt);
      case VrRightStickLookMode.flickStick:
        return _updateFlickStick(x, y, dt);
      case VrRightStickLookMode.smoothDualAxis:
      case VrRightStickLookMode.inertialTrackball:
        reset();
        return x.clamp(-1.0, 1.0);
    }
  }

  double _updateSnapTurn(double x, double dt) {
    final absX = x.abs();
    if (absX < snapRearmThreshold) {
      _snapArmed = true;
    }

    if (_snapCooldownRemaining > 0) {
      _snapCooldownRemaining = math.max(0.0, _snapCooldownRemaining - dt);
    }

    if (_snapPulseRemaining > 0) {
      _snapPulseRemaining = math.max(0.0, _snapPulseRemaining - dt);
      if (_snapPulseRemaining > 0) {
        return _snapDirection;
      }
      return 0.0;
    }

    if (_snapArmed &&
        _snapCooldownRemaining <= 0 &&
        absX >= snapTriggerThreshold) {
      _snapArmed = false;
      _snapDirection = x.sign;
      _snapPulseRemaining = snapPulseDurationSeconds;
      _snapCooldownRemaining = snapCooldownSeconds;
      return _snapDirection;
    }

    return 0.0;
  }

  double _updateFlickStick(double x, double y, double dt) {
    final radius = math.sqrt(x * x + y * y);
    if (!_flickEngaged) {
      if (radius >= flickRimEngageThreshold) {
        _flickEngaged = true;
        // Angle relative to forward (0, +1): right is +pi/2, left is -pi/2.
        final angle = math.atan2(x, y);
        _lastFlickAngleRad = angle;
        _flickRemainingRad = angle;
        _flickTimeRemaining = flickSnapDurationSeconds;
        _pendingSweepTurn = 0.0;
      } else {
        return 0.0;
      }
    } else if (radius < flickStickRimReleaseThreshold) {
      reset();
      return 0.0;
    } else {
      final angle = math.atan2(x, y);
      final delta = _wrapAngleRadians(angle - _lastFlickAngleRad);
      _lastFlickAngleRad = angle;
      _pendingSweepTurn = delta;
    }

    var output = 0.0;
    if (_flickTimeRemaining > 0 && _flickRemainingRad.abs() > 1e-3) {
      final stepFraction = dt <= 0
          ? 0.35
          : (dt / _flickTimeRemaining).clamp(0.0, 1.0);
      final stepRad = _flickRemainingRad * stepFraction;
      _flickRemainingRad -= stepRad;
      _flickTimeRemaining = math.max(0.0, _flickTimeRemaining - dt);
      output += (stepRad / (math.pi * 0.35)).clamp(-1.0, 1.0);
    }

    if (_pendingSweepTurn.abs() > 1e-4) {
      final sweepRate = dt > 1e-4
          ? (_pendingSweepTurn / dt) * flickSweepGain * 0.18
          : _pendingSweepTurn * flickSweepGain * 3.0;
      output += sweepRate;
      _pendingSweepTurn = 0.0;
    }

    return output.clamp(-1.0, 1.0);
  }

  void reset() {
    _snapArmed = true;
    _snapPulseRemaining = 0.0;
    _snapCooldownRemaining = 0.0;
    _snapDirection = 0.0;
    _flickEngaged = false;
    _lastFlickAngleRad = 0.0;
    _flickRemainingRad = 0.0;
    _flickTimeRemaining = 0.0;
    _pendingSweepTurn = 0.0;
  }

  static double _wrapAngleRadians(double angle) {
    var wrapped = (angle + math.pi) % (2 * math.pi);
    if (wrapped < 0) wrapped += 2 * math.pi;
    return wrapped - math.pi;
  }
}
