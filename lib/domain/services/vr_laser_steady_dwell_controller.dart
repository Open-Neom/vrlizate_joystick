import 'dart:math' as math;

import '../../utils/constants/vr_joystick_constants.dart';
import '../../utils/constants/vr_joystick_translation_constants.dart';

/// Tracks 5-second steady aiming in one-handed laser mode and triggers a single
/// auto-click when the user holds the laser steady on a target for
/// [dwellDurationSeconds].
class VrLaserSteadyDwellController {
  VrLaserSteadyDwellController({
    this.dwellDurationSeconds = VrJoystickConstants.laserAutoClickDwellSeconds,
    this.steadyOmegaThreshold = VrJoystickConstants.laserSteadyOmegaThreshold,
  }) {
    if (dwellDurationSeconds <= 0 || steadyOmegaThreshold < 0) {
      throw ArgumentError(
        VrJoystickTranslationConstants.errorInvalidDwellConfig,
      );
    }
  }

  final double dwellDurationSeconds;
  final double steadyOmegaThreshold;

  double _elapsedSteadySeconds = 0.0;
  bool _hasTriggeredForCurrentHold = false;

  /// Normalized progress from `0.0` to `1.0` toward the 5-second auto-click.
  double get progress =>
      (_elapsedSteadySeconds / dwellDurationSeconds).clamp(0.0, 1.0);

  /// Elapsed steady time in seconds.
  double get elapsedSeconds => _elapsedSteadySeconds;

  /// Remaining seconds before the auto-click fires.
  double get remainingSeconds =>
      math.max(0.0, dwellDurationSeconds - _elapsedSteadySeconds);

  /// Whether the auto-click has already fired for the current steady hold.
  bool get hasTriggeredForCurrentHold => _hasTriggeredForCurrentHold;

  /// Advances the steady timer by [dtSeconds] given the current gyroscope
  /// angular speed [angularSpeedRadiansPerSec].
  ///
  /// Returns `true` on the exact frame when [dwellDurationSeconds] (`5.0s`) is
  /// reached so the caller can emit a click pulse.
  bool update({
    required double angularSpeedRadiansPerSec,
    required double dtSeconds,
    bool paused = false,
  }) {
    if (paused || !dtSeconds.isFinite || dtSeconds <= 0) {
      if (paused) {
        reset();
      }
      return false;
    }

    final clampedDt = math.min(
      dtSeconds,
      VrJoystickConstants.laserMaxDeltaSeconds,
    );

    if (!angularSpeedRadiansPerSec.isFinite ||
        angularSpeedRadiansPerSec > steadyOmegaThreshold) {
      _elapsedSteadySeconds = 0.0;
      _hasTriggeredForCurrentHold = false;
      return false;
    }

    if (_hasTriggeredForCurrentHold) {
      return false;
    }

    _elapsedSteadySeconds += clampedDt;
    if (_elapsedSteadySeconds >= dwellDurationSeconds) {
      _elapsedSteadySeconds = dwellDurationSeconds;
      _hasTriggeredForCurrentHold = true;
      return true;
    }
    return false;
  }

  /// Restarts the 5-second countdown (for example, after a manual tap click or
  /// mode switch).
  void reset() {
    _elapsedSteadySeconds = 0.0;
    _hasTriggeredForCurrentHold = false;
  }
}
