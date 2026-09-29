import 'package:flutter/foundation.dart';

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

  static const _releaseAxes = {
    'stickX',
    'stickY',
    'lookX',
    'lookY',
    'laserX',
    'laserY',
    'steering',
    'drivingTilt',
    'throttle',
    'brake',
  };

  Map<String, Object?>? _lastState;
  int? _lastSentUs;

  /// [state] contains semantic controls only, without sequence or timestamp.
  /// [nowUs] must be the sender's monotonic time, not the remote wall clock.
  bool shouldSend(
    Map<String, Object?> state, {
    required int nowUs,
    required bool bluetooth,
    bool force = false,
  }) {
    final previous = _lastState;
    final elapsed = _lastSentUs == null ? null : nowUs - _lastSentUs!;
    final urgent =
        previous != null &&
        state.entries.any((entry) {
          if (entry.value == previous[entry.key]) return false;
          return entry.value is bool ||
              entry.value is String ||
              entry.key == 'hostModeRevision' ||
              (_releaseAxes.contains(entry.key) && entry.value == 0);
        });
    final interval = bluetooth ? bleAnalogInterval : socketAnalogInterval;
    if (!force && previous != null && elapsed != null && elapsed >= 0) {
      if (mapEquals(state, previous)) {
        if (elapsed < keepAliveInterval.inMicroseconds) return false;
      } else if (!urgent && elapsed < interval.inMicroseconds) {
        return false;
      }
    }
    _lastState = Map.of(state);
    _lastSentUs = nowUs;
    return true;
  }

  void reset() {
    _lastState = null;
    _lastSentUs = null;
  }
}
