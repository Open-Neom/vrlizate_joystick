import 'dart:math' as math;

import '../../utils/constants/vr_joystick_constants.dart';
import '../../utils/enums/vr_passthrough_split_gesture_mode.dart';
import '../../utils/enums/vr_passthrough_visual_style.dart';
import '../models/vr_thumb_pointer_track.dart';

/// Recognizes the dual-thumb center-to-lateral ("curtain split") shortcut on
/// the VRlizate Smartphone Joystick to control Visor Passthrough:
///
/// 1. **Tap Center with Both Thumbs:** Both thumbs touch near the horizontal
///    center of the controller (`normX` in `[0.28, 0.72]`) within `320 ms`.
/// 2. **Double-Tap Center (`sonarEcholocationPulse`):** Tapping the center twice
///    rapidly with both thumbs emits a `1.2s` 3D sonar echolocation wave that
///    sweeps `0% -> 100% -> 0%` across the room's AI wireframe contours.
/// 3. **Fast Outward Slide (`fastToggleSwipe`):** Rapidly sliding the left thumb
///    left and the right thumb right toggles Passthrough (`0% <-> 100%`).
/// 4. **Slow Outward Slide (`slowMixBlend`):** Sliding slowly lets the user
///    blend Passthrough and the virtual world at any percentage (`0% .. 100%`),
///    latching the chosen mix and curtain aperture (`curtainLeftNormX .. curtainRightNormX`).
/// 5. **Ultra-Slow Full Traversal (`ultraSlowCycleZeroToHundredToZero`):**
///    Sliding even slower across the lateral span sweeps the mix smoothly
///    through `0% -> 100% -> 0%` (center = `0%`, mid-lateral = `100%`, outer
///    edges = `0%`).
/// 6. **Vertical Thumb Modulation (`visualStyle`):**
///    - Sliding along the upper band (`normY < 0.35`) selects `fullCameraFeed`.
///    - Sliding along the middle band (`0.35 <= normY <= 0.65`) selects `hybridCameraAndWireframe`.
///    - Sliding along the lower band (`normY > 0.65`) selects `aiWireframeOnly`.
class VrPassthroughSplitGestureController {
  VrPassthroughSplitGestureController({
    this.centerMinNormX = VrJoystickConstants.passthroughCenterMinNormX,
    this.centerMaxNormX = VrJoystickConstants.passthroughCenterMaxNormX,
    this.maxInitialThumbSpan =
        VrJoystickConstants.passthroughMaxInitialThumbSpan,
    this.thumbSyncWindowUs = VrJoystickConstants.passthroughThumbSyncWindowUs,
    this.fastSwipeMinSpeedPerSec =
        VrJoystickConstants.passthroughFastSwipeMinSpeedPerSec,
    this.fastSwipeMaxDurationUs =
        VrJoystickConstants.passthroughFastSwipeMaxDurationUs,
    this.ultraSlowMaxSpeedPerSec =
        VrJoystickConstants.passthroughUltraSlowMaxSpeedPerSec,
  });

  final double centerMinNormX;
  final double centerMaxNormX;
  final double maxInitialThumbSpan;
  final int thumbSyncWindowUs;
  final double fastSwipeMinSpeedPerSec;
  final int fastSwipeMaxDurationUs;
  final double ultraSlowMaxSpeedPerSec;

  final Map<int, VrThumbPointerTrack> _pointers = <int, VrThumbPointerTrack>{};
  int? _leftPointerId;
  int? _rightPointerId;
  int _gestureStartUs = 0;
  double _initialSpan = 0.0;
  double _baselineMixAtGestureStart = 0.0;
  double _lastSpread = 0.0;
  double _smoothedSpreadSpeedPerSec = 0.0;
  double _peakSpread = 0.0;
  int? _lastCenterShortTapReleaseUs;
  int? _sonarPulseStartUs;

  VrPassthroughSplitGestureMode _mode = VrPassthroughSplitGestureMode.idle;
  VrPassthroughVisualStyle _visualStyle =
      VrPassthroughVisualStyle.hybridCameraAndWireframe;
  double _passthroughMix = 0.0;
  double _curtainLeftNormX = 0.0;
  double _curtainRightNormX = 1.0;

  /// Current gesture recognition mode.
  VrPassthroughSplitGestureMode get mode => _mode;

  /// Active visual style selected by vertical thumb band or double-tap sonar.
  VrPassthroughVisualStyle get visualStyle => _visualStyle;

  /// Whether a dual-thumb center split gesture is currently in progress.
  bool get isGestureActive => _mode != VrPassthroughSplitGestureMode.idle;

  /// Current passthrough mix factor (`0.0` = 100% virtual world, `1.0` = 100%
  /// passthrough / AI wireframe).
  double get passthroughMix => _passthroughMix;

  /// Convenience getter (`true` when [passthroughMix] > `0.01` or sonar pulse active).
  bool get passthroughActive =>
      _passthroughMix > 0.01 || _sonarPulseStartUs != null;

  /// Normalized left edge (`0.0 .. 0.5`) of the spatial passthrough curtain.
  double get curtainLeftNormX => _curtainLeftNormX;

  /// Normalized right edge (`0.5 .. 1.0`) of the spatial passthrough curtain.
  double get curtainRightNormX => _curtainRightNormX;

  /// Whether a 3D echolocation sonar pulse is currently expanding.
  bool get isSonarPulseActive => _sonarPulseStartUs != null;

  /// Current normalized lateral spread (`0.0 .. 1.0`) between the two thumbs.
  double get currentSpread => _lastSpread;

  /// Current normalized X position (`0.0 .. 1.0`) of the left thumb, if active.
  double? get leftThumbNormX =>
      _leftPointerId != null ? _pointers[_leftPointerId]?.currentNormX : null;

  /// Current normalized X position (`0.0 .. 1.0`) of the right thumb, if active.
  double? get rightThumbNormX =>
      _rightPointerId != null ? _pointers[_rightPointerId]?.currentNormX : null;

  /// Directly sets or resets the latched passthrough mix (`0.0 .. 1.0`).
  void setPassthroughMix(double value) {
    _passthroughMix = value.clamp(0.0, 1.0);
    if (_passthroughMix <= 0.01) {
      _curtainLeftNormX = 0.5;
      _curtainRightNormX = 0.5;
    } else {
      _curtainLeftNormX = (0.5 - _passthroughMix * 0.5).clamp(0.0, 0.5);
      _curtainRightNormX = (0.5 + _passthroughMix * 0.5).clamp(0.5, 1.0);
    }
  }

  /// Evaluates the expanding 3D sonar pulse (`0.0 .. 1.0` progress) at [timestampUs],
  /// automatically updating [passthroughMix] along a `0% -> 100% -> 0%` envelope.
  double evaluateSonarPulseProgress(int timestampUs) {
    final startUs = _sonarPulseStartUs;
    if (startUs == null) return 0.0;
    final elapsedUs = timestampUs - startUs;
    if (elapsedUs <= 0) return 0.0;
    if (elapsedUs >= VrJoystickConstants.passthroughSonarPulseDurationUs) {
      _sonarPulseStartUs = null;
      _passthroughMix = 0.0;
      return 0.0;
    }
    final progress =
        (elapsedUs / VrJoystickConstants.passthroughSonarPulseDurationUs).clamp(
          0.0,
          1.0,
        );
    // Smooth sin(pi * progress) envelope: 0% -> 100% -> 0%
    _passthroughMix = math.sin(math.pi * progress).clamp(0.0, 1.0);
    _curtainLeftNormX = (0.5 - progress * 0.5).clamp(0.0, 0.5);
    _curtainRightNormX = (0.5 + progress * 0.5).clamp(0.5, 1.0);
    return progress;
  }

  /// Resets active pointer tracking without clearing the latched [passthroughMix].
  void cancelGesture() {
    _pointers.clear();
    _leftPointerId = null;
    _rightPointerId = null;
    _mode = VrPassthroughSplitGestureMode.idle;
    _lastSpread = 0.0;
    _peakSpread = 0.0;
    _smoothedSpreadSpeedPerSec = 0.0;
  }

  /// Registers a touch-down event at normalized screen coordinates `(normX, normY)`
  /// in `[0.0, 1.0]`. Returns `true` if the gesture state or mix changed.
  bool onPointerDown({
    required int pointerId,
    required double normX,
    required double normY,
    required int timestampUs,
  }) {
    final clampedX = normX.clamp(0.0, 1.0);
    final clampedY = normY.clamp(0.0, 1.0);
    _pointers[pointerId] = VrThumbPointerTrack(
      pointerId: pointerId,
      startNormX: clampedX,
      startNormY: clampedY,
      downTimestampUs: timestampUs,
    );

    if (_mode != VrPassthroughSplitGestureMode.idle) {
      return false;
    }

    final centerCandidates = _pointers.values.where((p) {
      return p.startNormX >= centerMinNormX &&
          p.startNormX <= centerMaxNormX &&
          (timestampUs - p.downTimestampUs).abs() <= thumbSyncWindowUs;
    }).toList();

    if (centerCandidates.length >= 2) {
      centerCandidates.sort((a, b) => a.startNormX.compareTo(b.startNormX));
      final left = centerCandidates.first;
      final right = centerCandidates.last;
      final span = (right.startNormX - left.startNormX).abs();
      if (span <= maxInitialThumbSpan) {
        _leftPointerId = left.pointerId;
        _rightPointerId = right.pointerId;
        _gestureStartUs = math.max(left.downTimestampUs, right.downTimestampUs);
        _initialSpan = span;
        _baselineMixAtGestureStart = _passthroughMix;
        _lastSpread = 0.0;
        _peakSpread = 0.0;
        _smoothedSpreadSpeedPerSec = 0.0;
        _mode = VrPassthroughSplitGestureMode.armedCenterTap;
        return true;
      }
    }
    return false;
  }

  /// Processes pointer movement at normalized screen coordinates `(normX, normY)`.
  /// Returns `true` if the gesture mode or [passthroughMix] updated.
  bool onPointerMove({
    required int pointerId,
    required double normX,
    required double normY,
    required int timestampUs,
  }) {
    final track = _pointers[pointerId];
    if (track == null) return false;

    final prevUpdateUs = track.lastUpdateTimestampUs;
    track.currentNormX = normX.clamp(0.0, 1.0);
    track.currentNormY = normY.clamp(0.0, 1.0);
    track.lastUpdateTimestampUs = timestampUs;

    if (_mode == VrPassthroughSplitGestureMode.idle) return false;
    if (pointerId != _leftPointerId && pointerId != _rightPointerId) {
      return false;
    }

    final left = _pointers[_leftPointerId];
    final right = _pointers[_rightPointerId];
    if (left == null || right == null) return false;

    final leftMovedLeft =
        left.currentNormX <=
        left.startNormX + VrJoystickConstants.passthroughDirectionToleranceNorm;
    final rightMovedRight =
        right.currentNormX >=
        right.startNormX -
            VrJoystickConstants.passthroughDirectionToleranceNorm;
    if (!leftMovedLeft || !rightMovedRight) {
      return false;
    }

    // Update vertical style from average thumb Y coordinate
    final meanNormY = (left.currentNormY + right.currentNormY) * 0.5;
    if (meanNormY < VrJoystickConstants.passthroughUpperCameraBandMaxNormY) {
      _visualStyle = VrPassthroughVisualStyle.fullCameraFeed;
    } else if (meanNormY >
        VrJoystickConstants.passthroughLowerWireframeBandMinNormY) {
      _visualStyle = VrPassthroughVisualStyle.aiWireframeOnly;
    } else {
      _visualStyle = VrPassthroughVisualStyle.hybridCameraAndWireframe;
    }

    final currentSpan = math.max(0.0, right.currentNormX - left.currentNormX);
    final denom = math.max(
      0.15,
      VrJoystickConstants.passthroughFullSpanNormDistance - _initialSpan,
    );
    final spread = ((currentSpan - _initialSpan) / denom).clamp(0.0, 1.0);

    final dtUs = math.max(1, timestampUs - prevUpdateUs);
    final dtSec = dtUs / 1000000.0;
    final deltaSpread = (spread - _lastSpread).abs();
    if (dtSec > 0.0 && deltaSpread > 0.0) {
      final instSpeed = deltaSpread / dtSec;
      _smoothedSpreadSpeedPerSec = _smoothedSpreadSpeedPerSec == 0.0
          ? instSpeed
          : (_smoothedSpreadSpeedPerSec * 0.65 + instSpeed * 0.35);
    }

    _lastSpread = spread;
    if (spread > _peakSpread) {
      _peakSpread = spread;
    }

    _curtainLeftNormX = left.currentNormX.clamp(0.0, 0.5);
    _curtainRightNormX = right.currentNormX.clamp(0.5, 1.0);

    if (spread < VrJoystickConstants.passthroughMinActivationSpread &&
        _mode == VrPassthroughSplitGestureMode.armedCenterTap) {
      return false;
    }

    final elapsedUs = math.max(1, timestampUs - _gestureStartUs);
    final elapsedSec = elapsedUs / 1000000.0;
    final averageOutwardSpeed = _peakSpread / elapsedSec;

    if (elapsedUs <= fastSwipeMaxDurationUs &&
        (averageOutwardSpeed >= fastSwipeMinSpeedPerSec ||
            _smoothedSpreadSpeedPerSec >= fastSwipeMinSpeedPerSec) &&
        spread >= VrJoystickConstants.passthroughFastSwipeMinSpread) {
      _mode = VrPassthroughSplitGestureMode.fastToggleSwipe;
      final targetToggle = _baselineMixAtGestureStart >= 0.5 ? 0.0 : 1.0;
      setPassthroughMix(targetToggle);
      return true;
    }

    if (averageOutwardSpeed <= ultraSlowMaxSpeedPerSec ||
        (elapsedUs >= VrJoystickConstants.passthroughUltraSlowMinDurationUs &&
            _smoothedSpreadSpeedPerSec <= ultraSlowMaxSpeedPerSec * 1.25)) {
      _mode =
          VrPassthroughSplitGestureMode.ultraSlowCycleZeroToHundredToZero;
      final cycleMix = (1.0 - (2.0 * spread - 1.0).abs()).clamp(0.0, 1.0);
      _passthroughMix = cycleMix;
      return true;
    }

    _mode = VrPassthroughSplitGestureMode.slowMixBlend;
    _passthroughMix = spread.clamp(0.0, 1.0);
    return true;
  }

  /// Processes pointer release/cancel. Latches the final [passthroughMix] or
  /// triggers a 3D Sonar Pulse on dual-thumb center double-tap.
  bool onPointerUpOrCancel({
    required int pointerId,
    required int timestampUs,
  }) {
    _pointers.remove(pointerId);
    if (pointerId != _leftPointerId && pointerId != _rightPointerId) {
      return false;
    }

    final wasActive = _mode != VrPassthroughSplitGestureMode.idle;
    final elapsedUs = math.max(1, timestampUs - _gestureStartUs);

    // Check for Dual-Thumb Center Double-Tap (two quick taps in center with minimal spread)
    if (_mode == VrPassthroughSplitGestureMode.armedCenterTap &&
        _peakSpread < VrJoystickConstants.passthroughMinActivationSpread &&
        elapsedUs <= VrJoystickConstants.passthroughDoubleTapMaxTapDurationUs) {
      final prevReleaseUs = _lastCenterShortTapReleaseUs;
      if (prevReleaseUs != null &&
          (timestampUs - prevReleaseUs) <=
              VrJoystickConstants.passthroughDoubleTapMaxIntervalUs) {
        _lastCenterShortTapReleaseUs = null;
        _sonarPulseStartUs = timestampUs;
        _visualStyle = VrPassthroughVisualStyle.sonarEcholocationPulse;
        _passthroughMix = 0.50;
        _curtainLeftNormX = 0.0;
        _curtainRightNormX = 1.0;
      } else {
        _lastCenterShortTapReleaseUs = timestampUs;
      }
    } else if (_mode == VrPassthroughSplitGestureMode.fastToggleSwipe ||
        (_mode != VrPassthroughSplitGestureMode.idle &&
            elapsedUs <= fastSwipeMaxDurationUs &&
            _peakSpread >= VrJoystickConstants.passthroughFastSwipeMinSpread)) {
      final targetToggle = _baselineMixAtGestureStart >= 0.5 ? 0.0 : 1.0;
      setPassthroughMix(targetToggle);
    }

    _leftPointerId = null;
    _rightPointerId = null;
    _mode = VrPassthroughSplitGestureMode.idle;
    _lastSpread = 0.0;
    _peakSpread = 0.0;
    _smoothedSpreadSpeedPerSec = 0.0;
    return wasActive;
  }
}
