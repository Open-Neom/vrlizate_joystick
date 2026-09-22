import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vrlizate/vrlizate.dart';

import 'phone_controller_page.dart';
import 'vr_controller_mode.dart';
import 'vr_pairing_camera_session.dart';
import 'vr_pairing_link.dart';

/// Strict invitation boundary for QR and explicit manual entry. No URL is
/// launched, and no browser/web invitation is converted to an insecure socket.
VrPairingPayload parseVrControllerPairingCode(
  String raw, {
  Set<VrTransportType> supportedTransports = const {
    VrTransportType.localSocket,
  },
}) {
  final text = raw.trim();
  final uri = text.length <= 8192 ? Uri.tryParse(text) : null;
  if (uri == null ||
      uri.scheme != 'vrlizate' ||
      uri.host != 'pair' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.path.isNotEmpty ||
      uri.hasFragment) {
    throw const FormatException(
      'Usa el QR «Mando con app» del visor (vrlizate://pair). '
      'Los enlaces web no se abren aquí.',
    );
  }
  final payload = tryParseVrPairingUri(text);
  if (payload == null ||
      payload.host.contains(RegExp(r'[\s/?#@]')) ||
      payload.host.isEmpty) {
    throw const FormatException(
      'El enlace está incompleto o no es válido. Vuelve a mostrar el QR del visor.',
    );
  }
  if (payload.role != VrDeviceRole.child) {
    throw const FormatException(
      'Este QR no es una invitación para un mando. Usa el QR del visor para conectar un segundo teléfono.',
    );
  }
  if (!supportedTransports.contains(payload.transportType)) {
    final label = payload.transportType == VrTransportType.bluetoothLe
        ? 'Bluetooth LE'
        : 'Wi-Fi Direct';
    throw FormatException(
      '$label no está disponible en esta app. Usa el emparejamiento Wi-Fi local del visor.',
    );
  }
  if (payload.transportType == VrTransportType.bluetoothLe &&
      !RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(payload.bleServiceUuid ?? '')) {
    throw const FormatException(
      'Falta el identificador Bluetooth válido del visor. Genera un nuevo QR.',
    );
  }
  return payload;
}

/// Pair a native smartphone controller without leaving the app for a browser.
/// Camera access starts only while this page is open on Android/iOS. Other
/// platforms and denied permissions retain explicit paste/manual entry.
/// This route requests portrait; the controller requests landscape on entry.
/// The host owns restoring its orientation when the scanner is popped.
class VrControllerPairingPage extends StatefulWidget {
  const VrControllerPairingPage({
    super.key,
    this.cameraFactory,
    this.controllerBuilder,
    this.supportedTransports = const {VrTransportType.localSocket},
  });

  /// Overrides the native camera backend; the page owns and disposes it.
  /// A supplied factory is also used on desktop to support camera-free tests.
  final VrPairingCameraSession Function()? cameraFactory;

  /// Test/host customization after camera shutdown, retaining pushReplacement.
  final Widget Function(BuildContext, VrPairingPayload)? controllerBuilder;

  /// Additional transports require a host-provided controller builder.
  final Set<VrTransportType> supportedTransports;

  @override
  State<VrControllerPairingPage> createState() =>
      _VrControllerPairingPageState();
}

class _VrControllerPairingPageState extends State<VrControllerPairingPage>
    with WidgetsBindingObserver {
  final _link = TextEditingController();
  VrPairingCameraSession? _camera;
  StreamSubscription<String>? _codes;
  Future<void> _cameraOperations = Future.value();
  Future<void>? _cameraClose;
  bool _foreground = true;
  bool _routeCurrent = true;
  bool _disposed = false;
  bool _busy = false;
  bool _navigated = false;
  String? _error;
  String? _lastRejectedCode;
  VrPairingPayload? _readyInvitation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _applyScannerOrientation();
    final native =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    if (widget.cameraFactory != null || native) {
      _camera = (widget.cameraFactory ?? createVrPairingCameraSession)();
      _codes = _camera!.codes.listen(
        (raw) => unawaited(_acceptCode(raw, fromCamera: true)),
        onError: (_) => _showError(
          'No se pudo leer la cámara. Puedes pegar el enlace del visor.',
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncCamera());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (current != _routeCurrent) {
      _routeCurrent = current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncCamera();
        if (current) {
          _applyScannerOrientation();
          _openControllerIfReady();
        }
      });
    }
  }

  void _applyScannerOrientation() {
    if (_disposed || !_foreground || !_routeCurrent || _navigated) return;
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }

  void _showError(String message) {
    if (!_disposed && mounted) setState(() => _error = message);
  }

  /// Serializes start/stop, including a permission dialog that overlaps a
  /// lifecycle transition. Check desired state at execution, not enqueue time.
  void _syncCamera({bool retry = false}) {
    final camera = _camera;
    if (camera == null || _disposed || _cameraClose != null) return;
    _cameraOperations = _cameraOperations
        .then((_) async {
          if (_disposed || _cameraClose != null) return;
          if (!_foreground || !_routeCurrent || _busy) {
            await camera.stop();
          } else if (retry || camera.state.value.error == null) {
            await camera.start();
            if (_disposed || !_foreground || !_routeCurrent || _busy) {
              await camera.stop();
            }
          }
        })
        .catchError((Object _) {
          _showError(
            'No se pudo iniciar la cámara. Pega el enlace o vuelve a intentar.',
          );
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncCamera();
    if (_foreground) {
      _applyScannerOrientation();
      _openControllerIfReady();
    }
  }

  Future<void> _closeCamera() => _cameraClose ??= () async {
    await _codes?.cancel();
    _codes = null;
    await _cameraOperations;
    final camera = _camera;
    if (camera == null) return;
    try {
      await camera.stop();
    } finally {
      await camera.dispose();
    }
  }();

  Future<void> _acceptCode(String raw, {bool fromCamera = false}) async {
    if (_disposed || !mounted || _busy || !_foreground || !_routeCurrent) {
      return;
    }
    if (fromCamera && raw == _lastRejectedCode) return;
    final VrPairingPayload invitation;
    try {
      invitation = parseVrControllerPairingCode(
        raw,
        supportedTransports: widget.controllerBuilder == null
            ? const {VrTransportType.localSocket}
            : widget.supportedTransports,
      );
    } on FormatException catch (error) {
      if (fromCamera) _lastRejectedCode = raw;
      _showError(error.message);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _lastRejectedCode = null;
    });
    _link.clear();
    // Remove the preview/listenable widgets before disposing their controller.
    await WidgetsBinding.instance.endOfFrame;
    try {
      await _closeCamera();
    } catch (_) {
      _showError(
        'No se pudo cerrar la cámara. Vuelve atrás e intenta de nuevo.',
      );
      return; // Fail closed: never start the controller with a live camera.
    }
    if (_disposed || !mounted) return;
    _readyInvitation = invitation;
    _openControllerIfReady();
  }

  void _openControllerIfReady() {
    final invitation = _readyInvitation;
    if (_disposed ||
        !mounted ||
        !_foreground ||
        !_routeCurrent ||
        _navigated ||
        invitation == null) {
      return;
    }
    _navigated = true;
    Navigator.of(context).pushReplacement<void, void>(
      MaterialPageRoute(
        builder: (context) =>
            widget.controllerBuilder?.call(context, invitation) ??
            PhoneControllerPage(
              initialMode: RemoteControllerMode.joystick,
              targetHost: invitation.host,
              targetPort: invitation.port,
              sessionToken: invitation.sessionToken,
              transportType: invitation.transportType,
              isChildRole: true,
              autoConnect: true,
            ),
      ),
    );
  }

  Future<void> _pasteLink() async {
    // Clipboard access is exclusively initiated by this explicit button.
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (_disposed || !mounted || _busy) return;
      final text = data?.text;
      if (text == null || text.trim().isEmpty) {
        _showError('El portapapeles no contiene un enlace de emparejamiento.');
        return;
      }
      _link.text = text;
      await _acceptCode(text);
    } catch (_) {
      _showError('No se pudo pegar el enlace. Puedes escribirlo abajo.');
    }
  }

  Future<void> _toggleTorch() async {
    final camera = _camera;
    if (_busy ||
        _disposed ||
        camera == null ||
        !camera.state.value.running ||
        !camera.state.value.torchAvailable) {
      return;
    }
    _cameraOperations = _cameraOperations
        .then((_) async {
          if (_disposed ||
              _cameraClose != null ||
              _busy ||
              !_foreground ||
              !camera.state.value.running ||
              !camera.state.value.torchAvailable) {
            return;
          }
          await camera.toggleTorch();
        })
        .catchError((Object _) {
          _showError(
            'La linterna no está disponible. Acerca el QR o mejora la iluminación.',
          );
        });
    await _cameraOperations;
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_closeCamera().catchError((Object _) {}));
    _link.dispose();
    super.dispose();
  }

  String _cameraMessage(VrPairingCameraState state) => switch (state.error) {
    VrPairingCameraError.permissionDenied =>
      'Permiso de cámara denegado. Puedes habilitarlo en Ajustes o pegar el enlace del visor.',
    VrPairingCameraError.unsupported =>
      'No hay una cámara compatible. Pega o escribe el enlace del visor.',
    VrPairingCameraError.failed =>
      'No se pudo usar la cámara. Puedes pegar el enlace o volver a intentar.',
    null =>
      state.running
          ? 'Apunta al QR «Mando con app» que aparece en el visor.'
          : 'Preparando cámara… Si prefieres, pega el enlace.',
  };

  @override
  Widget build(BuildContext context) {
    final camera = _camera;
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: const Color(0xFF080816),
        appBar: AppBar(title: const Text('Conectar mando')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Escanea el QR del visor',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Conecta ambos teléfonos a la misma red Wi-Fi. '
                      'El mando se abrirá aquí, sin usar Chrome ni otra cámara.',
                    ),
                    const SizedBox(height: 20),
                    if (_busy) ...[
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 12),
                      const Text(
                        'Cerrando cámara y preparando el mando…',
                        textAlign: TextAlign.center,
                      ),
                    ] else if (camera != null)
                      ValueListenableBuilder<VrPairingCameraState>(
                        valueListenable: camera.state,
                        builder: (context, state, _) => Column(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: SizedBox(
                                height:
                                    (MediaQuery.sizeOf(context).height * .38)
                                        .clamp(180.0, 320.0),
                                width: double.infinity,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    camera.buildPreview(context),
                                    const IgnorePointer(
                                      child: Center(
                                        child: Icon(
                                          Icons.crop_free,
                                          size: 150,
                                          color: Colors.white70,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _cameraMessage(state),
                              textAlign: TextAlign.center,
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (state.torchAvailable)
                                  TextButton.icon(
                                    key: const ValueKey('vr_pairing_torch'),
                                    onPressed: state.running
                                        ? _toggleTorch
                                        : null,
                                    icon: Icon(
                                      state.torchOn
                                          ? Icons.flashlight_off
                                          : Icons.flashlight_on,
                                    ),
                                    label: const Text('Linterna'),
                                  ),
                                if (state.error != null)
                                  TextButton(
                                    key: const ValueKey('vr_pairing_retry'),
                                    onPressed: () => _syncCamera(retry: true),
                                    child: const Text('Reintentar cámara'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      )
                    else
                      const Text(
                        'El escáner integrado está disponible en Android e iOS. '
                        'Aquí puedes pegar o escribir el enlace del visor.',
                      ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        key: const ValueKey('vr_pairing_error'),
                        style: const TextStyle(color: Colors.amber),
                      ),
                    ],
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      key: const ValueKey('vr_pairing_paste'),
                      onPressed: _busy ? null : _pasteLink,
                      icon: const Icon(Icons.content_paste),
                      label: const Text('Pegar enlace'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey('vr_pairing_link'),
                      controller: _link,
                      enabled: !_busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Enlace de emparejamiento',
                        hintText: 'vrlizate://pair?…',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (raw) => unawaited(_acceptCode(raw)),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const ValueKey('vr_pairing_connect'),
                      onPressed: _busy
                          ? null
                          : () => unawaited(_acceptCode(_link.text)),
                      child: const Text('Conectar mando'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
