import 'package:flutter/foundation.dart';

import '../../utils/constants/vr_joystick_constants.dart';
import 'remote_controller_state.dart';

/// Configurable logical button remapping and hold-center-for-home duration.
///
/// Allows VR experiences or user accessibility settings to remap physical
/// smartphone controller keys (`A`, `B`, `X`, `Y`, `L`, `R`, `GRIP`) and customize
/// the long-press hold duration required to return to the VR Home environment.
@immutable
class VrButtonMapping {
  /// Maps a physical button key (`A`, `B`, `X`, `Y`, `L`, `R`, `GRIP`) to its
  /// logical action button key. Unmapped keys resolve to themselves.
  final Map<String, String> buttonOverrides;

  /// Duration the user must hold the center/home region to trigger a Home exit.
  final Duration holdCenterForHomeDuration;

  /// Whether `A` and `B` confirm/cancel roles are swapped (e.g., Nintendo vs Xbox layout).
  final bool swapConfirmCancel;

  const VrButtonMapping({
    this.buttonOverrides = const {},
    this.holdCenterForHomeDuration = const Duration(milliseconds: 800),
    this.swapConfirmCancel = false,
  });

  /// Default identity button mapping with an 800 ms hold-center-for-home gesture.
  const factory VrButtonMapping.standard() = VrButtonMapping;

  /// Resolves the logical button key for [physicalKey].
  String resolveButton(String physicalKey) {
    final normalized = physicalKey.trim().toUpperCase();
    if (!VrJoystickConstants.allowedActionKeys.contains(normalized)) {
      return normalized;
    }
    if (swapConfirmCancel) {
      if (normalized == VrJoystickConstants.actionKeyA) {
        return VrJoystickConstants.actionKeyB;
      }
      if (normalized == VrJoystickConstants.actionKeyB) {
        return VrJoystickConstants.actionKeyA;
      }
    }
    final mapped = buttonOverrides[normalized]?.trim().toUpperCase();
    if (mapped != null &&
        VrJoystickConstants.allowedActionKeys.contains(mapped)) {
      return mapped;
    }
    return normalized;
  }

  /// Applies this button mapping to an incoming [RemoteControllerState].
  RemoteControllerState applyToState(RemoteControllerState state) {
    if (buttonOverrides.isEmpty && !swapConfirmCancel) {
      return state;
    }
    final activeLogical = <String>{};
    final physicalStates = <String, bool>{
      VrJoystickConstants.actionKeyA: state.btnA,
      VrJoystickConstants.actionKeyB: state.btnB,
      VrJoystickConstants.actionKeyX: state.btnX,
      VrJoystickConstants.actionKeyY: state.btnY,
      VrJoystickConstants.actionKeyL: state.btnL,
      VrJoystickConstants.actionKeyR: state.btnR,
      VrJoystickConstants.actionKeyGrip: state.btnGrip,
    };
    for (final entry in physicalStates.entries) {
      if (entry.value) {
        activeLogical.add(resolveButton(entry.key));
      }
    }
    final nextA = activeLogical.contains(VrJoystickConstants.actionKeyA);
    final nextB = activeLogical.contains(VrJoystickConstants.actionKeyB);
    final nextX = activeLogical.contains(VrJoystickConstants.actionKeyX);
    final nextY = activeLogical.contains(VrJoystickConstants.actionKeyY);
    final nextL = activeLogical.contains(VrJoystickConstants.actionKeyL);
    final nextR = activeLogical.contains(VrJoystickConstants.actionKeyR);
    final nextGrip = activeLogical.contains(VrJoystickConstants.actionKeyGrip);

    return RemoteControllerState(
      orientation: state.orientation.clone(),
      angularVelocity: state.angularVelocity.clone(),
      isTriggerPressed: state.isTriggerPressed || nextR,
      isActionPressed: nextB,
      btnA: nextA,
      btnB: nextB,
      btnX: nextX,
      btnY: nextY,
      btnL: nextL,
      btnR: nextR,
      btnGrip: nextGrip,
      stickClick: state.stickClick,
      stickX: state.stickX,
      stickY: state.stickY,
      moveAtEdge: state.moveAtEdge,
      touchX: state.touchX,
      touchY: state.touchY,
      turnRate: state.turnRate,
      pitchRate: state.pitchRate,
      laserX: state.laserX,
      laserY: state.laserY,
      laserSlideActive: state.laserSlideActive,
      recenter: state.recenter,
      controllerVisible: state.controllerVisible,
      steering: state.steering,
      drivingTilt: state.drivingTilt,
      throttle: state.throttle,
      brake: state.brake,
      drivingPaused: state.drivingPaused,
      motionAvailable: state.motionAvailable,
      isNeutralized: state.isNeutralized,
      rangeMeters: state.rangeMeters,
      searchQuery: state.searchQuery,
      searchSubmitted: state.searchSubmitted,
      passthroughMix: state.passthroughMix,
      passthroughActive: state.passthroughActive,
      passthroughCommandRevision: state.passthroughCommandRevision,
      spatialHudVisible: state.spatialHudVisible,
      leftFootU: state.leftFootU,
      leftFootV: state.leftFootV,
      rightFootU: state.rightFootU,
      rightFootV: state.rightFootV,
      feetConfidence: state.feetConfidence,
      handU: state.handU,
      handV: state.handV,
      handConfidence: state.handConfidence,
      visorU: state.visorU,
      visorV: state.visorV,
      visorWidth: state.visorWidth,
      joystickCameraRole: state.joystickCameraRole,
      joystickMiniFrame: state.joystickMiniFrame,
      mode: state.mode,
      timestamp: state.timestamp,
    );
  }

  VrButtonMapping copyWith({
    Map<String, String>? buttonOverrides,
    Duration? holdCenterForHomeDuration,
    bool? swapConfirmCancel,
  }) {
    return VrButtonMapping(
      buttonOverrides: buttonOverrides ?? this.buttonOverrides,
      holdCenterForHomeDuration:
          holdCenterForHomeDuration ?? this.holdCenterForHomeDuration,
      swapConfirmCancel: swapConfirmCancel ?? this.swapConfirmCancel,
    );
  }

  Map<String, Object> toJson() => {
    'buttonOverrides': buttonOverrides,
    'holdCenterForHomeMs': holdCenterForHomeDuration.inMilliseconds,
    'swapConfirmCancel': swapConfirmCancel,
  };

  factory VrButtonMapping.fromJson(Map<String, dynamic> json) {
    final rawOverrides = json['buttonOverrides'];
    final cleanOverrides = <String, String>{};
    if (rawOverrides is Map) {
      for (final entry in rawOverrides.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is String && v is String) {
          final upperK = k.trim().toUpperCase();
          final upperV = v.trim().toUpperCase();
          if (VrJoystickConstants.allowedActionKeys.contains(upperK) &&
              VrJoystickConstants.allowedActionKeys.contains(upperV)) {
            cleanOverrides[upperK] = upperV;
          }
        }
      }
    }
    final holdMs = (json['holdCenterForHomeMs'] as num?)?.toInt() ?? 800;
    return VrButtonMapping(
      buttonOverrides: Map.unmodifiable(cleanOverrides),
      holdCenterForHomeDuration: Duration(
        milliseconds: holdMs.clamp(200, 5000),
      ),
      swapConfirmCancel: json['swapConfirmCancel'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VrButtonMapping &&
          mapEquals(buttonOverrides, other.buttonOverrides) &&
          holdCenterForHomeDuration == other.holdCenterForHomeDuration &&
          swapConfirmCancel == other.swapConfirmCancel;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(
      buttonOverrides.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    holdCenterForHomeDuration,
    swapConfirmCancel,
  );
}
