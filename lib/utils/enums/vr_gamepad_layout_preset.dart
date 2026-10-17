import 'remote_controller_mode.dart';

/// High-level controller layout presets for VRlizate 1.0 experiences.
enum VrGamepadLayoutPreset {
  /// Full dual-stick VR locomotion with look/laser selector and edge buttons.
  dualStickVr,

  /// 8-way digital D-pad with classic B/A, Select, Start, and Home buttons.
  retroArcade8Way,

  /// 3DoF gyroscope steering wheel with longitudinal tilt and throttle/brake pedals.
  steeringWheel,

  /// Simplified media & presentation remote with laser aiming and primary actions.
  mediaRemote;

  /// Maps this layout preset to the underlying wire [RemoteControllerMode].
  RemoteControllerMode get recommendedMode => switch (this) {
    VrGamepadLayoutPreset.dualStickVr => RemoteControllerMode.joystick,
    VrGamepadLayoutPreset.retroArcade8Way => RemoteControllerMode.nes,
    VrGamepadLayoutPreset.steeringWheel => RemoteControllerMode.driving,
    VrGamepadLayoutPreset.mediaRemote => RemoteControllerMode.joystick,
  };

  /// Whether this preset exposes continuous analog thumbstick locomotion.
  bool get supportsAnalogStick =>
      this == VrGamepadLayoutPreset.dualStickVr;

  /// Whether this preset uses 3DoF gyroscope wheel twist and longitudinal tilt.
  bool get supportsGyroSteering =>
      this == VrGamepadLayoutPreset.steeringWheel;

  /// Whether this preset includes the touch-based 180° laser aiming pad.
  bool get supportsLaserAiming =>
      this == VrGamepadLayoutPreset.dualStickVr ||
      this == VrGamepadLayoutPreset.mediaRemote;

  /// Parses a preset name from serialized preferences or wire metadata.
  static VrGamepadLayoutPreset fromWireName(String? raw) {
    if (raw == null) return VrGamepadLayoutPreset.dualStickVr;
    for (final preset in VrGamepadLayoutPreset.values) {
      if (preset.name == raw.trim()) return preset;
    }
    return VrGamepadLayoutPreset.dualStickVr;
  }
}
