import '../../utils/constants/vr_joystick_constants.dart';
import 'vr_phone_pointer_posture.dart';

/// Selects one-handed laser mode only after an upright landscape pointing
/// posture is observed. Sideways motion/portrait roll never activates it.
/// Legacy angle constructor fields remain source compatible; the physical
/// geometry and freshness contract is defined by [posture].
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
  }) : posture = VrPhonePointerPosture(holdUs: switchHoldUs);

  final VrPhonePointerPosture posture;
  bool autoSwitchEnabled;
  final double lateralTiltMinRatio;
  final double pointingMinOmega;
  final int switchHoldUs;
  final double returnFlatGxRatio;
  final double returnFlatGyMaxRatio;
  final int returnHoldUs;

  bool _waitForPostureExit = false;
  int? _twoHandedFlatCandidateSinceUs;
  bool _isOneHandedLaserActive = false;

  /// Whether the detector currently considers the phone to be in one-handed
  /// laser pointing posture.
  bool get isOneHandedLaserActive => _isOneHandedLaserActive;

  /// Synchronizes internal state when the user manually switches modes.
  void setModeActive(bool laserActive) {
    _isOneHandedLaserActive = laserActive;
    _waitForPostureExit = !laserActive;
    _twoHandedFlatCandidateSinceUs = null;
  }

  /// Resets all candidate timers and active state.
  void reset() {
    _isOneHandedLaserActive = false;
    _waitForPostureExit = false;
    _twoHandedFlatCandidateSinceUs = null;
    posture.reset();
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
    posture.updateGravity(gx, gy, gz, timestampUs);
    if (!posture.isReadyAt(timestampUs)) {
      _waitForPostureExit = false;
      return false;
    }
    // Rotation speed is not an activation gesture. Do not change layouts in
    // the middle of a fast rotation, while playing, or after an explicit exit
    // until the user has left and re-entered the pointing posture.
    if (!autoSwitchEnabled ||
        dualTouchActive ||
        _isOneHandedLaserActive ||
        _waitForPostureExit ||
        !omegaMagnitude.isFinite ||
        omegaMagnitude < 0 ||
        omegaMagnitude > 2) {
      return false;
    }
    _isOneHandedLaserActive = true;
    _twoHandedFlatCandidateSinceUs = null;
    return true;
  }

  /// Returns `true` after the phone leaves its pointing posture for
  /// [returnHoldUs]. This does not infer how many hands hold the phone.
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

    posture.updateGravity(gx, gy, gz, timestampUs);
    if (posture.isReadyAt(timestampUs)) {
      _twoHandedFlatCandidateSinceUs = null;
      return false;
    }

    _twoHandedFlatCandidateSinceUs ??= timestampUs;
    if (timestampUs - _twoHandedFlatCandidateSinceUs! >= returnHoldUs) {
      _isOneHandedLaserActive = false;
      _twoHandedFlatCandidateSinceUs = null;
      _waitForPostureExit = false;
      return true;
    }
    return false;
  }
}
