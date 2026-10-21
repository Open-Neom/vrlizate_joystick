/// Right-stick camera/look modes for the VRlizate Smartphone Joystick.
///
/// Inspired by open-source VR & gyro controller designs (`JoyShockMapper`,
/// `Steam Controller`, and comfort VR locomotion standards):
/// - [smoothDualAxis]: Continuous horizontal yaw turn + vertical pitch.
/// - [comfortSnapTurn]: Discrete step turns ($30^\circ$/$45^\circ$ pulses) with
///   cooldown to prevent motion sickness in VR.
/// - [flickStick]: Snapping the stick to the outer rim quickly rotates toward
///   that $360^\circ$ angle; sweeping around the rim rotates 1:1.
/// - [inertialTrackball]: Flicking the stick imparts angular momentum that
///   glides and decays with exponential friction until touched again.
enum VrRightStickLookMode {
  smoothDualAxis,
  comfortSnapTurn,
  flickStick,
  inertialTrackball,
}
