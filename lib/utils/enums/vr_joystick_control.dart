enum VrJoystickControl {
  l,
  r,
  y,
  x,
  b,
  a,
  moveStick,
  lookStick,
  recenter,

  /// Retained for source compatibility. The center is now a passive display;
  /// its old laser pad has an empty path and never captures a pointer.
  laserPad,
}
