import 'dart:math' as math;

import '../../utils/constants/vr_joystick_constants.dart';

/// Detects when the user transitions from a two-handed horizontal gamepad grip
/// into a one-handed laser pointing posture (wand grip), and vice versa.
class VrOneHandedLaserDetector {
  VrOneHandedLaserDetector({
    this.autoSwitchEnabled = true,
    this.lateralTiltMinRatio = VrJoystickConstants.oneHandedLateralTiltMinRatio,
    this.pointingMinOmega = VrJoystickConstants.oneHandedPointingMinOmega,
    this.switchHoldUs = VrJoystickConstants.oneHandedSwitchHoldUs,
    this.returnFlatGxRatio = VrJoystickConstants.oneHandedReturnFlatGxRatio,
    this.returnFlatGyMaxRatio =
        VrJoystickConstants.oneHandedReturnFlatGyMaxRatio,
    this.returnHoldUs = VrJoystickConstants.oneHandedReturnHoldUs,
  });

  bool autoSwitchEnabled;
  final double lateralTiltMinRatio;
  final double pointingMinOmega;
  final int switchHoldUs;
  final double returnFlatGxRatio;
  final double returnFlatGyMaxRatio;
  final int returnHoldUs;

  int? _oneHandedCandidateSinceUs;
  int? _twoHandedFlatCandidateSinceUs;
  bool _isOneHandedLaserActive = false;

  /// Whether the detector currently considers the phone to be in one-handed
  /// laser pointing posture.
  bool get isOneHandedLaserActive => _isOneHandedLaserActive;

  /// Synchronizes internal state when the user manually switches modes.
  void setModeActive(bool laserActive) {
    _isOneHandedLaserActive = laserActive;
    _oneHandedCandidateSinceUs = null;
    _twoHandedFlatCandidateSinceUs = null;
  }

  /// Resets all candidate timers and active state.
  void reset() {
    _isOneHandedLaserActive = false;
    _oneHandedCandidateSinceUs = null;
    _twoHandedFlatCandidateSinceUs = null;
  }

  /// Evaluates gravity `(gx, gy, gz)` in $\text{m/s}^2$, gyroscope angular
  /// speed `omegaMagnitude` in $\text{rad/s}$, and whether two-handed gamepad
  /// controls (`dualTouchActive`) are currently held.
  ///
  /// Returns `true` when the controller should automatically switch from
  /// `RemoteControllerMode.joystick` to `RemoteControllerMode.laser`.
  bool shouldSwitchToLaser({
    required double gx,
    required double gy,
    required double gz,
    required double omegaMagnitude,
    required bool dualTouchActive,
    required int timestampUs,
  }) {
    if (!autoSwitchEnabled || dualTouchActive) {
      _oneHandedCandidateSinceUs = null;
      return false;
    }

    final gMag = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (!gMag.isFinite ||
        gMag < VrJoystickConstants.oneHandedMinGravityMagnitude ||
        gMag > VrJoystickConstants.oneHandedMaxGravityMagnitude) {
      _oneHandedCandidateSinceUs = null;
      return false;
    }

    // In landscape phone controller posture, holding with two hands keeps the
    // long axis horizontal (`|gy| / gMag` near 0). Rotating the phone into a
    // one-handed pointing grip (on its side or upright wand posture) raises
    // `|gy| / gMag >= lateralTiltMinRatio` (~25°-35°+) while moving/aiming.
    final lateralRatio = gy.abs() / gMag;
    final forwardPitchRatio = gz.abs() / gMag;
    final isOneHandedPosture =
        lateralRatio >= lateralTiltMinRatio ||
        (lateralRatio >= lateralTiltMinRatio * 0.75 &&
            forwardPitchRatio >= lateralTiltMinRatio &&
            omegaMagnitude >= pointingMinOmega);

    if (!isOneHandedPosture) {
      _oneHandedCandidateSinceUs = null;
      return false;
    }

    if (_oneHandedCandidateSinceUs == null) {
      if (omegaMagnitude < pointingMinOmega &&
          lateralRatio < lateralTiltMinRatio * 1.25) {
        return false;
      }
      _oneHandedCandidateSinceUs = timestampUs;
      return false;
    }

    if (timestampUs - _oneHandedCandidateSinceUs! >= switchHoldUs) {
      _isOneHandedLaserActive = true;
      _oneHandedCandidateSinceUs = null;
      _twoHandedFlatCandidateSinceUs = null;
      return true;
    }
    return false;
  }

  /// Returns `true` when a phone in one-handed laser mode is returned to a
  /// stable, level two-handed landscape gamepad posture for [returnHoldUs].
  bool shouldReturnToJoystick({
    required double gx,
    required double gy,
    required double gz,
    required int timestampUs,
  }) {
    if (!autoSwitchEnabled || !_isOneHandedLaserActive) {
      _twoHandedFlatCandidateSinceUs = null;
      return false;
    }

    final gMag = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (!gMag.isFinite ||
        gMag < VrJoystickConstants.oneHandedMinGravityMagnitude ||
        gMag > VrJoystickConstants.oneHandedMaxGravityMagnitude) {
      _twoHandedFlatCandidateSinceUs = null;
      return false;
    }

    final gxRatio = gx.abs() / gMag;
    final gyRatio = gy.abs() / gMag;
    final isLevelLandscape =
        gxRatio >= returnFlatGxRatio && gyRatio <= returnFlatGyMaxRatio;

    if (!isLevelLandscape) {
      _twoHandedFlatCandidateSinceUs = null;
      return false;
    }

    _twoHandedFlatCandidateSinceUs ??= timestampUs;
    if (timestampUs - _twoHandedFlatCandidateSinceUs! >= returnHoldUs) {
      _isOneHandedLaserActive = false;
      _twoHandedFlatCandidateSinceUs = null;
      _oneHandedCandidateSinceUs = null;
      return true;
    }
    return false;
  }
}
