import 'dart:convert';

import '../../utils/constants/vr_joystick_constants.dart';
import '../../utils/constants/vr_joystick_translation_constants.dart';
import '../../utils/enums/remote_controller_mode.dart';

/// Authenticated host-to-controller UI recommendation, not an input event.
/// The client must release held inputs before acknowledging [revision] in its
/// next full state as `hostModeRevision`. A fresh foreground mode transition
/// can be ready to drive with neutral controls, never with a synthetic A.
/// Same-mode updates and reconnections must preserve the client's pause.
class VrControllerModeRequest {
  const VrControllerModeRequest({
    required this.mode,
    required this.revision,
    this.actions = const {},
    this.horizontalLook = false,
  });

  static const String type = VrJoystickConstants.controllerModeType;
  static const int version = VrJoystickConstants.controllerModeVersion;
  static const int maxRevision = VrJoystickConstants.maxSafeJsRevision;

  /// Buttons a host may caption. Anything else on the wire is dropped.
  static const Set<String> actionKeys = VrJoystickConstants.allowedActionKeys;

  /// Longest caption a phone button subtitle can show.
  static const int maxActionLength =
      VrJoystickConstants.maxActionCaptionLength;

  final RemoteControllerMode mode;
  final int revision;

  /// Whether the experience needs horizontal right-stick look (e.g. Doom).
  /// New hosts opt in explicitly; parsing an older host's absent field keeps
  /// its existing two-axis look behavior. This does not remap action buttons.
  final bool horizontalLook;

  /// What each button does in the active experience, keyed by [actionKeys].
  /// Keys retain their wire meaning in every layout: NES visible B uses X,
  /// Start uses Y, Select uses L and Home uses B. Captions never remap inputs.
  /// Optional and version-neutral: a client that predates captions ignores
  /// the field, a host that has none omits it. Empty means "use defaults".
  final Map<String, String> actions;

  Map<String, Object> toJson() {
    if (mode == RemoteControllerMode.laser ||
        revision < 0 ||
        revision > maxRevision) {
      throw ArgumentError(
        VrJoystickTranslationConstants.errorHostModeArgument,
      );
    }
    final clean = sanitizeActions(actions);
    return {
      VrJoystickConstants.fieldType: type,
      VrJoystickConstants.fieldVersion: version,
      VrJoystickConstants.fieldMode: mode.name,
      VrJoystickConstants.fieldRevision: revision,
      VrJoystickConstants.fieldHorizontalLook: horizontalLook,
      if (clean.isNotEmpty) VrJoystickConstants.fieldActions: clean,
    };
  }

  /// Keeps only known keys with non-empty string captions, trimmed and cut to
  /// [maxActionLength]. Applied on both ends so a hostile or buggy peer can
  /// neither inject unknown buttons nor overflow the layout.
  static Map<String, String> sanitizeActions(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! String) continue;
      final upper = key.trim().toUpperCase();
      if (!actionKeys.contains(upper)) continue;
      final text = value.trim();
      if (text.isEmpty) continue;
      out[upper] = text.length <= maxActionLength
          ? text
          : text.substring(0, maxActionLength);
    }
    return out;
  }

  static VrControllerModeRequest? tryParse(Object? wire) {
    try {
      if (wire is String && wire.length > 4096) return null;
      final value = wire is String ? jsonDecode(wire) : wire;
      if (value is! Map ||
          value[VrJoystickConstants.fieldType] != type ||
          value[VrJoystickConstants.fieldVersion] != version) {
        return null;
      }
      final revision = value[VrJoystickConstants.fieldRevision];
      if (revision is! int || revision < 0 || revision > maxRevision) {
        return null;
      }
      if (value.containsKey(VrJoystickConstants.fieldHorizontalLook) &&
          value[VrJoystickConstants.fieldHorizontalLook] is! bool) {
        return null;
      }
      final mode = switch (value[VrJoystickConstants.fieldMode]) {
        VrJoystickConstants.modeJoystick => RemoteControllerMode.joystick,
        VrJoystickConstants.modeDriving => RemoteControllerMode.driving,
        VrJoystickConstants.modeNes => RemoteControllerMode.nes,
        _ => null,
      };
      return mode == null
          ? null
          : VrControllerModeRequest(
              mode: mode,
              revision: revision,
              actions: sanitizeActions(value[VrJoystickConstants.fieldActions]),
              horizontalLook:
                  value[VrJoystickConstants.fieldHorizontalLook] as bool? ??
                  true,
            );
    } on FormatException {
      return null;
    }
  }
}
