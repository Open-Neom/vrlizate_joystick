import 'dart:math' as math;

import '../../utils/constants/vr_joystick_constants.dart';
import '../../utils/enums/vr_haptic_pattern_preset.dart';

/// Evaluates thumbstick radial rings (`50%` walk, `92%` sprint/rim) and
/// 4 cardinal axes ($0^\circ, 90^\circ, 180^\circ, 270^\circ$) with hysteresis
/// so a user wearing a VR headset can feel virtual detents on a flat glass
/// touchscreen without looking at the phone.
class VrThumbstickHapticDetentController {
  final double midRingThreshold;
  final double midRingRelease;
  final double outerRimThreshold;
  final double outerRimRelease;
  final double cardinalMinRadius;
  final double cardinalEnterDegrees;
  final double cardinalExitDegrees;

  bool _inMidRing = false;
  bool _inOuterRim = false;
  int? _activeCardinalIndex;

  VrThumbstickHapticDetentController({
    this.midRingThreshold = VrJoystickConstants.hapticMidRingThreshold,
    this.midRingRelease = VrJoystickConstants.hapticMidRingRelease,
    this.outerRimThreshold = VrJoystickConstants.hapticOuterRimThreshold,
    this.outerRimRelease = VrJoystickConstants.hapticOuterRimRelease,
    this.cardinalMinRadius = VrJoystickConstants.hapticCardinalMinRadius,
    this.cardinalEnterDegrees = VrJoystickConstants.hapticCardinalEnterDegrees,
    this.cardinalExitDegrees = VrJoystickConstants.hapticCardinalExitDegrees,
  });

  bool get isInMidRing => _inMidRing;
  bool get isInOuterRim => _inOuterRim;
  int? get activeCardinalIndex => _activeCardinalIndex;

  /// Evaluates normalized thumbstick coordinates `(x, y)` in `[-1.0, 1.0]`
  /// and returns a [VrHapticPatternPreset] if a radial ring or cardinal axis
  /// detent was just crossed on this sample.
  VrHapticPatternPreset? evaluate(
    double x,
    double y, {
    bool enableCardinalDetents = true,
  }) {
    if (!x.isFinite || !y.isFinite) {
      reset();
      return null;
    }

    final radius = math.sqrt(x * x + y * y);
    VrHapticPatternPreset? triggered;

    // 1. Outer rim (sprint / edge-turn threshold, ~92%)
    if (!_inOuterRim && radius >= outerRimThreshold) {
      _inOuterRim = true;
      _inMidRing = true;
      triggered = VrHapticPatternPreset.buttonPress;
    } else if (_inOuterRim && radius < outerRimRelease) {
      _inOuterRim = false;
    }

    // 2. Mid-range ring (~50% walk-to-run transition)
    if (!_inMidRing && radius >= midRingThreshold) {
      _inMidRing = true;
      triggered ??= VrHapticPatternPreset.lightTap;
    } else if (_inMidRing && radius < midRingRelease) {
      _inMidRing = false;
    }

    // 3. Four cardinal axes (0° Right, 90° Up, 180° Left, 270° Down)
    if (!enableCardinalDetents || radius < cardinalMinRadius) {
      _activeCardinalIndex = null;
      return triggered;
    }

    var angleDeg = math.atan2(y, x) * 180.0 / math.pi;
    if (angleDeg < 0) angleDeg += 360.0;

    final currentCardinal = _activeCardinalIndex;
    if (currentCardinal != null) {
      final targetDeg = currentCardinal * 90.0;
      final diff = _angularDistanceDegrees(angleDeg, targetDeg);
      if (diff > cardinalExitDegrees) {
        _activeCardinalIndex = null;
      }
    }

    if (_activeCardinalIndex == null) {
      for (var i = 0; i < 4; i++) {
        final targetDeg = i * 90.0;
        if (_angularDistanceDegrees(angleDeg, targetDeg) <=
            cardinalEnterDegrees) {
          _activeCardinalIndex = i;
          triggered ??= VrHapticPatternPreset.lightTap;
          break;
        }
      }
    }

    return triggered;
  }

  void reset() {
    _inMidRing = false;
    _inOuterRim = false;
    _activeCardinalIndex = null;
  }

  static double _angularDistanceDegrees(double a, double b) {
    final diff = (a - b).abs() % 360.0;
    return diff > 180.0 ? 360.0 - diff : diff;
  }
}
