import '../models/remote_controller_state.dart';
import '../../utils/enums/remote_controller_mode.dart';
import 'vr_display_posture_gate.dart';

/// One gate for visible rays and remote pointer ownership in Home and demos.
/// An aim quaternion/offset alone is never evidence of physical phone posture.
abstract final class VrPhonePointerPolicy {
  static bool isPointing(
    RemoteControllerState state, {
    VrDisplayPostureDecision? displayDecision,
  }) {
    if (state.isNeutralized || !state.controllerVisible) return false;
    final postureSatisfied =
        state.pointerPoseReady ||
        (displayDecision != null &&
            !displayDecision.requiresGravityPointerPosture);
    if (!postureSatisfied) return false;
    return state.mode == RemoteControllerMode.laser ||
        state.laserSlideActive ||
        state.laserX.abs() > .015 ||
        state.laserY.abs() > .015;
  }

  static void writePayload(
    Map<String, dynamic> payload,
    RemoteControllerState state,
  ) {
    payload['laserX'] = state.laserX;
    payload['laserY'] = state.laserY;
    payload['relativeToHead'] = true;
    payload.remove('orientation');
  }
}
