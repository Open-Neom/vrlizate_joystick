import '../../utils/constants/vr_joystick_constants.dart';

/// Detects thumbstick double-taps (`L3` / `R3` `stickClick`) and manages
/// `moonlight-android`-inspired **Auto-Walk / Sprint Lock** on the left
/// movement thumbstick.
///
/// Workflow:
/// 1. Quick double-tap on the stick emits a `stickClick` pulse.
/// 2. If [autoWalkEnabled] is true and the user double-taps and pushes the
///    left stick into the upper forward rim (`y >= autoWalkForwardMinY`,
///    `|x| <= autoWalkForwardMaxAbsX`), holding for [autoWalkHoldLockDurationUs]
///    or releasing at the upper rim latches [isAutoWalkLocked] = `true`.
/// 3. Touching the movement stick again immediately cancels [isAutoWalkLocked].
class VrAutoWalkLockController {
  final int doubleTapMaxTapDurationUs;
  final int doubleTapMaxIntervalUs;
  final double autoWalkForwardMinY;
  final double autoWalkForwardMaxAbsX;
  final int autoWalkHoldLockDurationUs;

  int? _firstTapDownUs;
  int? _firstTapUpUs;
  bool _firstTapStayedNearCenter = false;
  bool _isSecondTapGesture = false;
  int? _forwardRimEnteredUs;
  bool _isAutoWalkLocked = false;
  double _lastX = 0.0;
  double _lastY = 0.0;

  VrAutoWalkLockController({
    this.doubleTapMaxTapDurationUs =
        VrJoystickConstants.doubleTapMaxTapDurationUs,
    this.doubleTapMaxIntervalUs = VrJoystickConstants.doubleTapMaxIntervalUs,
    this.autoWalkForwardMinY = VrJoystickConstants.autoWalkForwardMinY,
    this.autoWalkForwardMaxAbsX = VrJoystickConstants.autoWalkForwardMaxAbsX,
    this.autoWalkHoldLockDurationUs =
        VrJoystickConstants.autoWalkHoldLockDurationUs,
  });

  bool get isAutoWalkLocked => _isAutoWalkLocked;
  double get lockedStickX => 0.0;
  double get lockedStickY => _isAutoWalkLocked ? 1.0 : 0.0;

  /// Called when the thumb touches the stick.
  ///
  /// Returns `true` if a double-tap (`L3`/`R3` `stickClick`) was just detected.
  /// If [isAutoWalkLocked] was active, touching the stick cancels the lock.
  bool onPointerDown(int timestampUs) {
    if (_isAutoWalkLocked) {
      _isAutoWalkLocked = false;
      _clearTapHistory();
      return false;
    }

    final previousUpUs = _firstTapUpUs;
    if (previousUpUs != null &&
        _firstTapStayedNearCenter &&
        timestampUs - previousUpUs >= 0 &&
        timestampUs - previousUpUs <= doubleTapMaxIntervalUs) {
      _isSecondTapGesture = true;
      _forwardRimEnteredUs = null;
      _firstTapDownUs = null;
      _firstTapUpUs = null;
      return true;
    }

    _isSecondTapGesture = false;
    _forwardRimEnteredUs = null;
    _firstTapDownUs = timestampUs;
    _firstTapUpUs = null;
    _firstTapStayedNearCenter = true;
    _lastX = 0.0;
    _lastY = 0.0;
    return false;
  }

  /// Called while the thumb moves on the stick.
  ///
  /// Returns `true` if Auto-Walk Lock just engaged during a second-tap forward
  /// hold.
  bool onStickChanged(
    double x,
    double y, {
    required int timestampUs,
    required bool autoWalkEnabled,
  }) {
    _lastX = x;
    _lastY = y;

    if (!_isSecondTapGesture) {
      if (x * x + y * y > 0.30 * 0.30) {
        _firstTapStayedNearCenter = false;
      }
      return false;
    }

    if (!autoWalkEnabled) return false;

    final inForwardRim =
        y >= autoWalkForwardMinY && x.abs() <= autoWalkForwardMaxAbsX;
    if (inForwardRim) {
      _forwardRimEnteredUs ??= timestampUs;
      if (!_isAutoWalkLocked &&
          timestampUs - _forwardRimEnteredUs! >= autoWalkHoldLockDurationUs) {
        _isAutoWalkLocked = true;
        return true;
      }
    } else {
      _forwardRimEnteredUs = null;
    }
    return false;
  }

  /// Called when the thumb releases the stick.
  ///
  /// Returns `true` if [isAutoWalkLocked] remains or becomes latched on release.
  bool onPointerUp(
    int timestampUs, {
    required bool autoWalkEnabled,
  }) {
    if (_isSecondTapGesture) {
      final inForwardRim =
          _lastY >= autoWalkForwardMinY &&
          _lastX.abs() <= autoWalkForwardMaxAbsX;
      if (autoWalkEnabled && inForwardRim) {
        _isAutoWalkLocked = true;
      }
      _isSecondTapGesture = false;
      _forwardRimEnteredUs = null;
      return _isAutoWalkLocked;
    }

    final downUs = _firstTapDownUs;
    if (downUs != null &&
        timestampUs - downUs >= 0 &&
        timestampUs - downUs <= doubleTapMaxTapDurationUs &&
        _firstTapStayedNearCenter) {
      _firstTapUpUs = timestampUs;
    } else {
      _clearTapHistory();
    }
    return _isAutoWalkLocked;
  }

  void reset() {
    _isAutoWalkLocked = false;
    _clearTapHistory();
  }

  void _clearTapHistory() {
    _firstTapDownUs = null;
    _firstTapUpUs = null;
    _firstTapStayedNearCenter = false;
    _isSecondTapGesture = false;
    _forwardRimEnteredUs = null;
    _lastX = 0.0;
    _lastY = 0.0;
  }
}
