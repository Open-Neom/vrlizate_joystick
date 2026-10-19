/// Visual rendering style selected by the vertical thumb position (`normY`) or
/// center double-tap during the dual-thumb Passthrough gesture on the Joystick.
enum VrPassthroughVisualStyle {
  /// Middle vertical band (`0.35 <= normY <= 0.65`): blends both camera feed
  /// and 3D AI neon wireframe contours.
  hybridCameraAndWireframe,

  /// Upper vertical band (`normY < 0.35`): prioritizes the real-world camera
  /// passthrough feed (`visorCameraPassthrough`).
  fullCameraFeed,

  /// Lower vertical band (`normY > 0.65`): renders only the glowing 3D AI
  /// wireframe contours (`aiWireframeContours`) on top of the virtual world.
  aiWireframeOnly,

  /// Triggered by a quick dual-thumb double-tap in the center: emits a 3D
  /// echolocation sonar wave that briefly illuminates room contours (`0->100->0%`).
  sonarEcholocationPulse,
}
