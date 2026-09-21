import 'dart:convert';

import 'vr_controller_mode.dart';

/// Authenticated host-to-controller UI recommendation, not an input event.
/// The client must release held inputs before acknowledging [revision] in its
/// next full state as `hostModeRevision`; driving starts paused, never with A.
class VrControllerModeRequest {
  const VrControllerModeRequest({
    required this.mode,
    required this.revision,
    this.actions = const {},
  });

  static const type = 'vrlizate.controllerMode';
  static const version = 1;
  static const maxRevision = 9007199254740991; // Exact integer in browser JS.

  /// Buttons a host may caption. Anything else on the wire is dropped.
  static const actionKeys = {'A', 'B', 'X', 'Y', 'L', 'R', 'GRIP'};

  /// Longest caption a phone button subtitle can show.
  static const maxActionLength = 24;

  final RemoteControllerMode mode;
  final int revision;

  /// What each button does in the active experience, keyed by [actionKeys].
  /// Optional and version-neutral: a client that predates captions ignores
  /// the field, a host that has none omits it. Empty means "use defaults".
  final Map<String, String> actions;

  Map<String, Object> toJson() {
    if (mode == RemoteControllerMode.laser ||
        revision < 0 ||
        revision > maxRevision) {
      throw ArgumentError(
        'Host mode must be joystick/driving with a safe revision.',
      );
    }
    final clean = sanitizeActions(actions);
    return {
      'type': type,
      'version': version,
      'mode': mode.name,
      'revision': revision,
      if (clean.isNotEmpty) 'actions': clean,
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
          value['type'] != type ||
          value['version'] != version) {
        return null;
      }
      final revision = value['revision'];
      if (revision is! int || revision < 0 || revision > maxRevision) {
        return null;
      }
      final mode = switch (value['mode']) {
        'joystick' => RemoteControllerMode.joystick,
        'driving' => RemoteControllerMode.driving,
        _ => null,
      };
      return mode == null
          ? null
          : VrControllerModeRequest(
              mode: mode,
              revision: revision,
              actions: sanitizeActions(value['actions']),
            );
    } on FormatException {
      return null;
    }
  }
}

/// One instance per native/web-equivalent socket session. Reset only after
/// accepting a new authenticated connection so old messages cannot undo a mode.
class VrControllerModeSession {
  int? _revision;
  int? get revision => _revision;

  VrControllerModeRequest? accept(Object? wire) {
    final request = VrControllerModeRequest.tryParse(wire);
    if (request == null ||
        (_revision != null && request.revision <= _revision!)) {
      return null;
    }
    _revision = request.revision;
    return request;
  }

  void reset() => _revision = null;
}
