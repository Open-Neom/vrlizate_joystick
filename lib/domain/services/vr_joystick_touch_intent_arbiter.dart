import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Outcome returned by [VrJoystickTouchIntentArbiter] when evaluating whether
/// a thumb touch near a face/shoulder button was meant for that button or for
/// the adjacent analog thumbstick.
enum VrTouchIntentAction {
  /// Wait briefly inside the near-rim collar before committing to a button.
  defer,

  /// Commit immediately to pressing the button.
  fireButtonDown,

  /// The user dragged toward/into the stick before the button fired; suppress
  /// the button completely and hand the live pointer directly to the stick.
  handoffToStick,

  /// The user touched farther onto the button and immediately dragged inward
  /// toward the stick; retract the accidental button press and hand off live.
  cancelButtonAndHandoffToStick,

  /// Pointer is already owned by the stick handoff — keep streaming drag.
  continueStickHandoff,

  /// A quick stationary tap inside the near-rim collar completed cleanly.
  quickTapButton,

  /// Normal release of an active button press.
  releaseButton,

  /// Release of a pointer that was handed off to the stick.
  releaseStickHandoff,

  /// No state change.
  none,
}

enum _IntentState { deferredNearRim, buttonActive, handedOffToStick }

final class _TrackedTouch {
  _TrackedTouch({
    required this.pointerId,
    required this.isLeftWing,
    required this.downPosition,
    required this.downTimestampUs,
    required this.stickCenter,
    required this.stickRadius,
    required this.initialDistToStick,
    required this.state,
  });

  final int pointerId;
  final bool isLeftWing;
  final Offset downPosition;
  final int downTimestampUs;
  final Offset stickCenter;
  final double stickRadius;
  final double initialDistToStick;
  _IntentState state;
}

/// Pure-Dart touch-intent inference engine for blind VR joystick operation.
///
/// While wearing a VR headset, a user reaching for the left (`MOVER`) or right
/// (`MIRAR`) thumbstick frequently lands slightly outside the drawn stick ring
/// onto the inner edge of `A`, `B`, `X`, `Y`, `ZL`, or `ZR` and immediately
/// drags their thumb to walk or look.
///
/// This arbiter resolves intent using **radial proximity + drag kinematics**:
/// 1. **Near-rim grace collar** (`distToStick <= stickRadius + nearRimCollar`
///    and away from the button's label center): defers button firing for
///    [deferWindowUs] (`75 ms`). If the thumb moves `>= 8.5 px` or `>= 5.5 px`
///    toward the stick, the button is **suppressed completely** and the live
///    pointer is handed seamlessly to the stick.
/// 2. **Mid-button slide-to-stick retraction**: touches farther out fire the
///    button with `0 ms` latency for crisp button responsiveness, yet if the
///    thumb immediately drags inward toward the stick (`>= 12 px` inward within
///    [slideRetractWindowUs]), the accidental button press is retracted and
///    handed live to the stick without requiring the user to lift their thumb.
/// 3. **Stationary quick taps** inside the collar fire cleanly as deliberate
///    button taps on release.
class VrJoystickTouchIntentArbiter {
  VrJoystickTouchIntentArbiter({
    this.maxNearRimCollarPx = 28.0,
    this.labelSafeRadiusPx = 22.0,
    this.deferWindowUs = 75000,
    this.slideRetractWindowUs = 165000,
    this.deferredDragThresholdPx = 8.5,
    this.deferredInwardThresholdPx = 5.5,
    this.retractInwardThresholdPx = 12.0,
    this.retractDragThresholdPx = 16.0,
  });

  final double maxNearRimCollarPx;
  final double labelSafeRadiusPx;
  final int deferWindowUs;
  final int slideRetractWindowUs;
  final double deferredDragThresholdPx;
  final double deferredInwardThresholdPx;
  final double retractInwardThresholdPx;
  final double retractDragThresholdPx;

  final Map<int, _TrackedTouch> _touches = <int, _TrackedTouch>{};

  bool isHandedOffToStick(int pointerId) =>
      _touches[pointerId]?.state == _IntentState.handedOffToStick;

  bool isLeftWing(int pointerId) => _touches[pointerId]?.isLeftWing ?? true;

  /// Evaluates a pointer-down landing on a surrounding button.
  VrTouchIntentAction onButtonPointerDown({
    required int pointerId,
    required bool isLeftWing,
    required Offset position,
    required Offset buttonLabelPosition,
    required Offset stickCenter,
    required double stickRadius,
    required int timestampUs,
    bool stickAlreadyActiveOnWing = false,
  }) {
    final distToStick = (position - stickCenter).distance;
    final distToLabel = (position - buttonLabelPosition).distance;
    final collar = math.min(maxNearRimCollarPx, stickRadius * 0.36);

    // If a finger lands directly on the narrow collar hugging the stick ring
    // (and not centered on the button's label), wait briefly to infer whether
    // the thumb is starting a stick drag or making a deliberate button press.
    final inNearRimCollar =
        !stickAlreadyActiveOnWing &&
        distToStick <= stickRadius + collar &&
        distToLabel > labelSafeRadiusPx;

    final state = inNearRimCollar
        ? _IntentState.deferredNearRim
        : _IntentState.buttonActive;

    _touches[pointerId] = _TrackedTouch(
      pointerId: pointerId,
      isLeftWing: isLeftWing,
      downPosition: position,
      downTimestampUs: timestampUs,
      stickCenter: stickCenter,
      stickRadius: stickRadius,
      initialDistToStick: distToStick,
      state: state,
    );

    return inNearRimCollar
        ? VrTouchIntentAction.defer
        : VrTouchIntentAction.fireButtonDown;
  }

  /// Evaluates a pointer-move update for a tracked button touch.
  VrTouchIntentAction onButtonPointerMove({
    required int pointerId,
    required Offset position,
    required int timestampUs,
    bool stickAlreadyActiveOnWing = false,
  }) {
    final touch = _touches[pointerId];
    if (touch == null) return VrTouchIntentAction.none;

    if (touch.state == _IntentState.handedOffToStick) {
      return VrTouchIntentAction.continueStickHandoff;
    }

    if (stickAlreadyActiveOnWing) {
      return VrTouchIntentAction.none;
    }

    final dragDist = (position - touch.downPosition).distance;
    final currentDistToStick = (position - touch.stickCenter).distance;
    final inwardProgress = touch.initialDistToStick - currentDistToStick;
    final elapsedUs = timestampUs - touch.downTimestampUs;

    if (touch.state == _IntentState.deferredNearRim) {
      if (dragDist >= deferredDragThresholdPx ||
          inwardProgress >= deferredInwardThresholdPx) {
        touch.state = _IntentState.handedOffToStick;
        return VrTouchIntentAction.handoffToStick;
      }
      if (elapsedUs >= deferWindowUs) {
        touch.state = _IntentState.buttonActive;
        return VrTouchIntentAction.fireButtonDown;
      }
      return VrTouchIntentAction.none;
    }

    // Active button touch: if the thumb immediately sweeps inward toward the
    // stick circle right after landing, infer accidental edge contact and
    // retract the button into a smooth live stick takeover.
    if (elapsedUs <= slideRetractWindowUs) {
      final sweptIntoStickZone =
          inwardProgress >= retractInwardThresholdPx &&
          currentDistToStick <= touch.stickRadius * 1.32;
      final strongInwardDrag =
          dragDist >= retractDragThresholdPx &&
          inwardProgress >= retractInwardThresholdPx * 0.72;
      if (sweptIntoStickZone || strongInwardDrag) {
        touch.state = _IntentState.handedOffToStick;
        return VrTouchIntentAction.cancelButtonAndHandoffToStick;
      }
    }

    return VrTouchIntentAction.none;
  }

  /// Called when the short near-rim timer expires without a drag.
  VrTouchIntentAction onDeferTimerExpired(int pointerId) {
    final touch = _touches[pointerId];
    if (touch == null || touch.state != _IntentState.deferredNearRim) {
      return VrTouchIntentAction.none;
    }
    touch.state = _IntentState.buttonActive;
    return VrTouchIntentAction.fireButtonDown;
  }

  /// Evaluates pointer release or cancellation.
  VrTouchIntentAction onButtonPointerEnd(
    int pointerId, {
    bool cancelled = false,
  }) {
    final touch = _touches.remove(pointerId);
    if (touch == null) return VrTouchIntentAction.none;
    return switch (touch.state) {
      _IntentState.deferredNearRim =>
        cancelled ? VrTouchIntentAction.none : VrTouchIntentAction.quickTapButton,
      _IntentState.buttonActive => VrTouchIntentAction.releaseButton,
      _IntentState.handedOffToStick => VrTouchIntentAction.releaseStickHandoff,
    };
  }

  void clear() => _touches.clear();
}
