/// Tactile haptic vibration patterns for VR controller interactions.
enum VrHapticPatternPreset {
  /// Subtle boundary or release tick.
  lightTap(
    pulseDurationsMs: [12],
    pauseDurationsMs: [],
    intensity: 0.35,
  ),

  /// Crisp tactile click when pressing an action button.
  buttonPress(
    pulseDurationsMs: [24],
    pauseDurationsMs: [],
    intensity: 0.65,
  ),

  /// Double ascending pulse when entering a VR portal or pairing a visor.
  portalEnter(
    pulseDurationsMs: [35, 65],
    pauseDurationsMs: [90],
    intensity: 0.85,
  ),

  /// Heavy impact pulse for vehicle or obstacle collisions.
  collisionBump(
    pulseDurationsMs: [80],
    pauseDurationsMs: [],
    intensity: 1.0,
  ),

  /// Rhythmic warning pulses while holding the center/home exit gesture.
  holdExitWarning(
    pulseDurationsMs: [25, 25, 45],
    pauseDurationsMs: [60, 60],
    intensity: 0.75,
  );

  const VrHapticPatternPreset({
    required this.pulseDurationsMs,
    required this.pauseDurationsMs,
    required this.intensity,
  });

  /// Active vibration pulse durations in milliseconds.
  final List<int> pulseDurationsMs;

  /// Silence intervals between pulses in milliseconds.
  final List<int> pauseDurationsMs;

  /// Normalized vibration amplitude in `[0.0, 1.0]`.
  final double intensity;

  /// Total duration of all pulses and pauses in this haptic pattern.
  Duration get totalDuration {
    var totalMs = 0;
    for (final pulse in pulseDurationsMs) {
      totalMs += pulse;
    }
    for (final pause in pauseDurationsMs) {
      totalMs += pause;
    }
    return Duration(milliseconds: totalMs);
  }

  /// Resolves a preset by its wire/configuration name, defaulting to [buttonPress].
  static VrHapticPatternPreset fromWireName(String? raw) {
    if (raw == null) return VrHapticPatternPreset.buttonPress;
    for (final preset in VrHapticPatternPreset.values) {
      if (preset.name == raw.trim()) return preset;
    }
    return VrHapticPatternPreset.buttonPress;
  }
}
