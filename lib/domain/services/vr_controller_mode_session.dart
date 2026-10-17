import '../models/vr_controller_mode_request.dart';

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
