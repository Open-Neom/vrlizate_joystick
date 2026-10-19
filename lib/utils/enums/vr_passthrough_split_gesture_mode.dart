/// Operating mode of the dual-thumb center-to-lateral Passthrough split gesture
/// on the VRlizate Smartphone Joystick.
enum VrPassthroughSplitGestureMode {
  /// No dual-thumb center gesture is active.
  idle,

  /// Both thumbs tapped simultaneously inside the central zone and are ready
  /// to slide outward toward the left and right edges.
  armedCenterTap,

  /// Fast outward slide (`< 380 ms` or high lateral speed): toggles Passthrough
  /// cleanly (`0% -> 100%` or `100% -> 0%`).
  fastToggleSwipe,

  /// Controlled slow slide: blends Passthrough and the virtual world at an
  /// adjustable percentage (`0% .. 100%`), latching when thumbs are released.
  slowMixBlend,

  /// Ultra-slow full-span traversal: continuously sweeps Passthrough across
  /// `0% -> 100% -> 0%` as thumbs travel from the center (`0%`), through the
  /// mid-lateral zone (`100%`), all the way to the outer edges (`0%`).
  ultraSlowCycleZeroToHundredToZero,
}
