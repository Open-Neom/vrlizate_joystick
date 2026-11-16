import 'package:flutter/foundation.dart';
import 'package:vrlizate/vrlizate.dart' show VrCompactGamepadFrame;

import '../../utils/constants/vr_joystick_constants.dart';

/// Suppresses redundant snapshots without delaying button edges or releases.
///
/// The caller samples the latest controls on each tick; rejected analog samples
/// are replaced by that latest state, never queued for later replay. Keepalives
/// remain below the receiver's 500 ms input watchdog. This is send pacing, not
/// an acknowledgement or a substitute for transport backpressure.
class VrControllerStatePacer {
  static const keepAliveInterval = Duration(milliseconds: 200);
  static const bleAnalogInterval = Duration(microseconds: 33333);
  static const socketAnalogInterval = Duration(milliseconds: 16);

  static const Set<String> _releaseAxes = VrJoystickConstants.pacerReleaseAxes;

  Map<String, Object?>? _lastState;
  VrCompactGamepadFrame? _lastCompact;
  int? _lastSentUs;

  /// [state] contains semantic controls only, without sequence or timestamp.
  /// [nowUs] must be the sender's monotonic time, not the remote wall clock.
  bool shouldSend(
    Map<String, Object?> state, {
    required int nowUs,
    required bool bluetooth,
    bool force = false,
    Duration? customAnalogInterval,
  }) {
    final previous = _lastState;
    final elapsed = _lastSentUs == null ? null : nowUs - _lastSentUs!;
    final urgent =
        previous != null &&
        state.entries.any((entry) {
          if (entry.value == previous[entry.key]) return false;
          return entry.value is bool ||
              entry.value is String ||
              entry.key == VrJoystickConstants.fieldHostModeRevision ||
              (_releaseAxes.contains(entry.key) && entry.value == 0);
        });
    final interval =
        customAnalogInterval ??
        (bluetooth ? bleAnalogInterval : socketAnalogInterval);
    if (!force && previous != null && elapsed != null && elapsed >= 0) {
      if (mapEquals(state, previous)) {
        if (elapsed < keepAliveInterval.inMicroseconds) return false;
      } else if (!urgent && elapsed < interval.inMicroseconds) {
        return false;
      }
    }
    _lastCompact = null;
    _lastState = Map.of(state);
    _lastSentUs = nowUs;
    return true;
  }

  /// Zero-Map pacing fast-path for 120 Hz [VrCompactGamepadFrame] links.
  bool shouldSendCompact(
    VrCompactGamepadFrame candidate, {
    required int nowUs,
    required bool bluetooth,
    bool force = false,
    Duration? customAnalogInterval,
  }) {
    final previous = _lastCompact;
    final elapsed = _lastSentUs == null ? null : nowUs - _lastSentUs!;
    final urgent =
        previous != null && _hasUrgentCompactDelta(candidate, previous);
    final interval =
        customAnalogInterval ??
        (bluetooth ? bleAnalogInterval : socketAnalogInterval);
    if (!force && previous != null && elapsed != null && elapsed >= 0) {
      if (_sameCompactControls(candidate, previous)) {
        if (elapsed < keepAliveInterval.inMicroseconds) return false;
      } else if (!urgent && elapsed < interval.inMicroseconds) {
        return false;
      }
    }
    _lastState = null;
    _lastCompact = candidate;
    _lastSentUs = nowUs;
    return true;
  }

  static bool _hasUrgentCompactDelta(
    VrCompactGamepadFrame a,
    VrCompactGamepadFrame b,
  ) =>
      a.modeIndex != b.modeIndex ||
      a.hostModeRevision != b.hostModeRevision ||
      a.trigger != b.trigger ||
      a.action != b.action ||
      a.btnA != b.btnA ||
      a.btnB != b.btnB ||
      a.btnX != b.btnX ||
      a.btnY != b.btnY ||
      a.btnL != b.btnL ||
      a.btnR != b.btnR ||
      a.btnZL != b.btnZL ||
      a.btnZR != b.btnZR ||
      a.btnGrip != b.btnGrip ||
      a.stickClick != b.stickClick ||
      a.recenter != b.recenter ||
      a.moveAtEdge != b.moveAtEdge ||
      a.laserSlideActive != b.laserSlideActive ||
      a.pointerPoseReady != b.pointerPoseReady ||
      a.controllerVisible != b.controllerVisible ||
      a.drivingPaused != b.drivingPaused ||
      a.motionAvailable != b.motionAvailable ||
      a.passthroughActive != b.passthroughActive ||
      a.spatialHudVisible != b.spatialHudVisible ||
      (a.stickX == 0 && b.stickX != 0) ||
      (a.stickY == 0 && b.stickY != 0) ||
      (a.lookX == 0 && b.lookX != 0) ||
      (a.lookY == 0 && b.lookY != 0) ||
      (a.laserX == 0 && b.laserX != 0) ||
      (a.laserY == 0 && b.laserY != 0) ||
      (a.steering == 0 && b.steering != 0) ||
      (a.drivingTilt == 0 && b.drivingTilt != 0) ||
      (a.throttle == 0 && b.throttle != 0) ||
      (a.brake == 0 && b.brake != 0);

  static bool _sameCompactControls(
    VrCompactGamepadFrame a,
    VrCompactGamepadFrame b,
  ) =>
      !_hasUrgentCompactDelta(a, b) &&
      a.stickX == b.stickX &&
      a.stickY == b.stickY &&
      a.lookX == b.lookX &&
      a.lookY == b.lookY &&
      a.laserX == b.laserX &&
      a.laserY == b.laserY &&
      a.steering == b.steering &&
      a.drivingTilt == b.drivingTilt &&
      a.throttle == b.throttle &&
      a.brake == b.brake &&
      a.passthroughMix == b.passthroughMix &&
      a.rangeMeters == b.rangeMeters &&
      a.orientation == b.orientation &&
      a.angularVelocity == b.angularVelocity;

  void reset() {
    _lastState = null;
    _lastCompact = null;
    _lastSentUs = null;
  }
}
