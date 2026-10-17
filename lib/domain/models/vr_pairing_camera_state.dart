import '../../utils/enums/vr_pairing_camera_error.dart';

/// Camera-only state. Never contains a decoded invitation or session token.
class VrPairingCameraState {
  const VrPairingCameraState({
    this.running = false,
    this.torchAvailable = false,
    this.torchOn = false,
    this.error,
  });

  final bool running;
  final bool torchAvailable;
  final bool torchOn;
  final VrPairingCameraError? error;
}
