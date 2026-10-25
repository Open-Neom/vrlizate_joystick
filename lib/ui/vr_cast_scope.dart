import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';

import '../domain/services/vr_remote_controller_service.dart';

/// Application-owned video session. Controller links only advertise its URL;
/// they never carry frames or start a second controller transport.
class VrAppCast {
  VrAppCast({VrCastHost? host})
    : host = host ?? VrCastHost(realtime: VrCastRealtimeHost()) {
    this.host.addListener(_announce);
  }

  final VrCastHost host;
  final _controllers = <VrRemoteControllerService, int>{};
  final _connections = <VrRemoteControllerService, StreamSubscription<bool>>{};
  bool _autoAllowed = true;
  bool _automatic = false;
  bool _disposed = false;

  bool get hasVideoSession => host.realtime?.hasVideoSession ?? false;

  Future<void> suspendVideoBeforeNavigation() async {
    await host.realtime?.suspendBeforeNavigation();
  }

  void _connectionChanged() {
    if (_disposed) return;
    final connected = _controllers.keys.any((service) => service.isConnected);
    if (connected && _autoAllowed && !host.isRunning) {
      _automatic = true;
      unawaited(
        host
            .start()
            .then((_) {
              if (_disposed ||
                  (_automatic &&
                      !_controllers.keys.any((s) => s.isConnected))) {
                return host.stop();
              }
            })
            .catchError((Object _) {}),
      );
    } else if (!connected && _automatic) {
      _automatic = false;
      unawaited(host.stop());
    }
  }

  Future<void> startManually() async {
    _autoAllowed = true;
    _automatic = false;
    await host.start();
  }

  Future<void> stopManually() async {
    _autoAllowed = false;
    _automatic = false;
    await host.stop();
  }

  void attach(VrRemoteControllerService service) {
    if (!_controllers.containsKey(service)) {
      _connections[service] = service.onConnectionChanged.listen(
        (_) => _connectionChanged(),
      );
    }
    _controllers.update(service, (count) => count + 1, ifAbsent: () => 1);
    service.setCastPreviewUri(host.preferredViewerUri);
    _connectionChanged();
  }

  void detach(VrRemoteControllerService service) {
    final count = _controllers[service];
    if (count == null) return;
    if (count > 1) {
      _controllers[service] = count - 1;
    } else {
      _controllers.remove(service);
      unawaited(_connections.remove(service)?.cancel());
      service.setCastPreviewUri(null);
      _connectionChanged();
    }
  }

  void _announce() {
    for (final service in _controllers.keys) {
      service.setCastPreviewUri(host.preferredViewerUri);
    }
  }

  void dispose() {
    _disposed = true;
    for (final subscription in _connections.values) {
      unawaited(subscription.cancel());
    }
    _connections.clear();
    host.removeListener(_announce);
    for (final service in _controllers.keys) {
      service.setCastPreviewUri(null);
    }
    _controllers.clear();
    host.dispose();
  }
}

class VrCastScope extends InheritedWidget {
  const VrCastScope({super.key, required this.cast, required super.child});

  final VrAppCast cast;

  static VrAppCast? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VrCastScope>()?.cast;

  @override
  bool updateShouldNotify(VrCastScope oldWidget) => cast != oldWidget.cast;
}

/// Only immersive routes register a source. Account, pairing and other modal
/// routes suspend it, so an underlying scene is never mistaken for current UI.
class VrCastExperience extends StatefulWidget {
  const VrCastExperience({
    super.key,
    required this.child,
    this.active = true,
    this.remoteController,
    this.realtimeStereo = true,
  });

  final Widget child;
  final bool active;
  final VrRemoteControllerService? remoteController;
  final bool realtimeStereo;

  @override
  State<VrCastExperience> createState() => _VrCastExperienceState();
}

class _VrCastExperienceState extends State<VrCastExperience> {
  VrAppCast? _cast;
  VrRemoteControllerService? _remote;

  void _bind(VrAppCast? cast) {
    if (identical(cast, _cast) && identical(widget.remoteController, _remote)) {
      return;
    }
    if (_remote != null) _cast?.detach(_remote!);
    _cast = cast;
    _remote = widget.remoteController;
    if (_remote != null) _cast?.attach(_remote!);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(VrCastScope.maybeOf(context));
  }

  @override
  void didUpdateWidget(VrCastExperience oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bind(_cast);
  }

  @override
  void dispose() {
    if (_remote != null) _cast?.detach(_remote!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cast = _cast;
    if (cast == null) return widget.child;
    return VrCastSurface(
      host: cast.host,
      // The surface owns route/lifecycle admission, including the short
      // inactive-to-resumed handoff after native screen-capture permission.
      enabled: widget.active,
      realtimeStereo: widget.realtimeStereo,
      child: widget.child,
    );
  }
}

class VrCastSettingsButton extends StatelessWidget {
  const VrCastSettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    final cast = VrCastScope.maybeOf(context);
    if (cast == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: cast.host,
      builder: (context, _) => OutlinedButton.icon(
        onPressed: () => openVrCastSettings(context),
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          textStyle: const TextStyle(fontSize: 11),
        ),
        icon: Icon(
          cast.host.isRunning ? Icons.cast_connected : Icons.cast,
          size: 15,
        ),
        label: Text(
          cast.host.isRunning
              ? 'Vista Wi-Fi activa'
              : 'Compartir vista por Wi-Fi',
        ),
      ),
    );
  }
}

Future<void> openVrCastSettings(BuildContext context) async {
  final cast = VrCastScope.maybeOf(context);
  if (cast == null) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _CastSettings(cast: cast),
  );
}

class _CastSettings extends StatefulWidget {
  const _CastSettings({required this.cast});
  final VrAppCast cast;
  VrCastHost get host => cast.host;

  @override
  State<_CastSettings> createState() => _CastSettingsState();
}

class _CastSettingsState extends State<_CastSettings> {
  bool _busy = false;
  bool _showQr = false;
  bool _copied = false;
  String? _error;

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _showQr = false;
      _copied = false;
    });
    try {
      if (widget.host.isRunning) {
        await widget.cast.stopManually();
      } else {
        await widget.cast.startManually();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'No se pudo abrir la vista. Comprueba la red Wi-Fi.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.host,
    builder: (context, _) {
      final uri = widget.host.preferredViewerUri;
      return AlertDialog(
        title: const Text('Compartir vista del visor'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Conecta ambos teléfonos a la misma red Wi-Fi. '
                  'Al vincular el mando Bluetooth, la vista aparece automáticamente en el teléfono mando.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'Vídeo por Wi-Fi · un ojo · objetivo 24 FPS · sin audio. '
                  'El visor solicita permiso de captura al conectar el receptor. '
                  'Si el vídeo no está disponible se conserva la vista previa. '
                  'Se detiene al abrir otra pantalla o salir de la app.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const ValueKey('cast-host-toggle'),
                  onPressed: _busy ? null : _toggle,
                  icon: Icon(widget.host.isRunning ? Icons.stop : Icons.cast),
                  label: Text(
                    _busy
                        ? 'Preparando…'
                        : widget.host.isRunning
                        ? 'Detener transmisión'
                        : 'Activar vista Wi-Fi',
                  ),
                ),
                if (uri != null) ...[
                  const SizedBox(height: 12),
                  Text('Disponible en ${uri.host}:${uri.port}'),
                  const Text(
                    'Comparte el enlace con tus espectadores en una red de confianza. '
                    'Al detener, el enlace deja de funcionar.',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: uri.toString()),
                          );
                          if (mounted) setState(() => _copied = true);
                        },
                        icon: const Icon(Icons.copy),
                        label: Text(
                          _copied ? 'Enlace copiado' : 'Copiar enlace',
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => setState(() => _showQr = !_showQr),
                        icon: const Icon(Icons.qr_code),
                        label: const Text('QR para navegador'),
                      ),
                    ],
                  ),
                  if (_showQr)
                    Center(
                      child: QrImageView(
                        data: uri.toString(),
                        backgroundColor: Colors.white,
                        size: 180,
                      ),
                    ),
                ],
                if (_error ?? widget.host.error case final String message) ...[
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Listo'),
          ),
        ],
      );
    },
  );
}
