import 'package:flutter/foundation.dart';

import '../../utils/enums/vr_controller_disconnect_reason.dart';

/// A cheap, immutable snapshot of receiver-side controller health.
///
/// Counters accumulate for the service's lifetime, including reconnects.
/// [inputAge] uses only the visor's monotonic clock: it is time since the last
/// accepted state on the current link, not network latency or remote clock age.
@immutable
class VrControllerTelemetry {
  const VrControllerTelemetry({
    required this.isConnected,
    required this.inputAge,
    required this.acceptedStates,
    required this.rejectedStates,
    required this.watchdogNeutralizations,
    required this.lastDisconnectReason,
  });

  final bool isConnected;
  final Duration? inputAge;
  final int acceptedStates;
  final int rejectedStates;
  final int watchdogNeutralizations;
  final VrControllerDisconnectReason? lastDisconnectReason;
}
