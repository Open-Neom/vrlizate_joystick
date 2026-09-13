import 'dart:convert';

import 'vr_controller_mode.dart';

/// Authenticated host-to-controller UI recommendation, not an input event.
/// The client must release held inputs before acknowledging [revision] in its
/// next full state as `hostModeRevision`; driving starts paused, never with A.
class VrControllerModeRequest {
  const VrControllerModeRequest({required this.mode, required this.revision});

  static const type = 'vrlizate.controllerMode';
  static const version = 1;
  static const maxRevision = 9007199254740991; // Exact integer in browser JS.
  final RemoteControllerMode mode;
  final int revision;

  Map<String, Object> toJson() {
    if (mode == RemoteControllerMode.laser ||
        revision < 0 ||
        revision > maxRevision) {
      throw ArgumentError(
        'Host mode must be joystick/driving with a safe revision.',
      );
    }
    return {
      'type': type,
      'version': version,
      'mode': mode.name,
      'revision': revision,
    };
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
          : VrControllerModeRequest(mode: mode, revision: revision);
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
