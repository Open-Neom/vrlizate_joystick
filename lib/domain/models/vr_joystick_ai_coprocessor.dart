/// Injectable embedded-AI co-processor contract for a secondary smartphone
/// operating in **Modo Joystick (`2D` / `3D`)**.
///
/// The SDK never imports an inference framework (`saia_*`, `neom_ia`, `fllama`);
/// host apps register [defaultCoProcessor] or pass an instance to
/// `PhoneControllerPage` so the Joystick phone can offload local LLM inference
/// from the Visor smartphone over their existing authenticated link.
class VrJoystickAiCoProcessor {
  const VrJoystickAiCoProcessor({
    required this.probeCapabilities,
    required this.infer,
  });

  /// Host-registered default co-processor used by `PhoneControllerPage` when
  /// no explicit instance is supplied.
  static VrJoystickAiCoProcessor? defaultCoProcessor;

  /// Probes whether this secondary smartphone has enough RAM / thermal headroom
  /// to sustain embedded AI inference for the paired Visor.
  final Future<({bool supported, String engineLabel, int ramMb})> Function()
  probeCapabilities;

  /// Executes a bounded embedded AI inference request on the Joystick phone.
  final Future<({bool ok, String text, String engineLabel})> Function({
    required String prompt,
    String? systemPrompt,
    int maxTokens,
  })
  infer;
}
