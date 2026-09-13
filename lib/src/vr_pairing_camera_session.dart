import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

enum VrPairingCameraError { permissionDenied, unsupported, failed }

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

/// Owned by one pairing page. Injectable so lifecycle/navigation tests do not
/// need camera permission, a native camera texture, or GPU resources.
abstract class VrPairingCameraSession {
  ValueListenable<VrPairingCameraState> get state;
  Stream<String> get codes;
  Widget buildPreview(BuildContext context);
  Future<void> start();
  Future<void> stop();
  Future<void> toggleTorch();
  Future<void> dispose();
}

/// Creation alone does not request camera permission. The page explicitly
/// starts this session only after mounting its camera preview.
VrPairingCameraSession createVrPairingCameraSession() =>
    _MobilePairingCameraSession();

class _MobilePairingCameraSession implements VrPairingCameraSession {
  _MobilePairingCameraSession() {
    _controller.addListener(_updateState);
  }

  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 300,
    returnImage: false,
  );
  final _state = ValueNotifier(const VrPairingCameraState());
  bool _disposed = false;

  @override
  ValueListenable<VrPairingCameraState> get state => _state;

  @override
  Stream<String> get codes => _controller.barcodes.expand(
    (capture) =>
        capture.barcodes.map((barcode) => barcode.rawValue).whereType<String>(),
  );

  void _updateState() {
    if (_disposed) return;
    final current = _controller.value;
    _state.value = VrPairingCameraState(
      running: current.isRunning,
      torchAvailable: current.torchState != TorchState.unavailable,
      torchOn: current.torchState == TorchState.on,
      error: switch (current.error?.errorCode) {
        null => null,
        MobileScannerErrorCode.permissionDenied =>
          VrPairingCameraError.permissionDenied,
        MobileScannerErrorCode.unsupported => VrPairingCameraError.unsupported,
        _ => VrPairingCameraError.failed,
      },
    );
  }

  @override
  Widget buildPreview(BuildContext context) => MobileScanner(
    controller: _controller,
    useAppLifecycleState: false,
    tapToFocus: true,
    fit: BoxFit.cover,
    errorBuilder: (_, _) => const ColoredBox(
      color: Color(0xFF101528),
      child: Center(child: Icon(Icons.no_photography_outlined, size: 48)),
    ),
  );

  @override
  Future<void> start() => _controller.start();

  @override
  Future<void> stop() => _controller.stop();

  @override
  Future<void> toggleTorch() => _controller.toggleTorch();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _controller.removeListener(_updateState);
    try {
      await _controller.dispose();
    } finally {
      _state.dispose();
    }
  }
}
