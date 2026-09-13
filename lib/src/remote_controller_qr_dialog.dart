import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:vrlizate/vrlizate.dart';

import 'vr_remote_controller_service.dart';

/// A single, non-stereoscopic QR for setting up the second phone.
///
/// The app QR is intended for VRlizate's own scanner: external camera apps do
/// not consistently open custom URI schemes. This route borrows [service];
/// closing it leaves the connection and its owning visor running.
class RemoteControllerQrDialog extends StatefulWidget {
  final VrRemoteControllerService service;

  /// Explicit owner notification; embedded widgets never pop a host route.
  ///
  /// True means an authenticated controller is connected. False is an explicit
  /// manual close, regardless of the connection state at that moment.
  final ValueChanged<bool>? onCompleted;

  /// Whether an authenticated connection should complete this setup surface.
  ///
  /// Embedded instances default to staying visible. [show] defaults to closing,
  /// including when the service was already connected when setup was opened.
  final bool closeOnConnected;

  const RemoteControllerQrDialog({
    super.key,
    required this.service,
    this.onCompleted,
    this.closeOnConnected = false,
  });

  /// Opens setup and returns true only for an authenticated connection.
  ///
  /// Back/manual dismissal returns false. Only the route created here is
  /// removed: a later route opened above setup is never popped accidentally.
  /// Closing setup does not dispose or disconnect the borrowed [service].
  static Future<bool> show(
    BuildContext context, {
    required VrRemoteControllerService service,
    bool closeOnConnected = true,
  }) {
    final navigator = Navigator.of(context);
    late final MaterialPageRoute<bool> route;
    var completed = false;
    void complete(bool connected) {
      if (completed || !navigator.mounted || !route.isActive) return;
      completed = true;
      if (route.isCurrent) {
        navigator.pop<bool>(connected);
      } else {
        navigator.removeRoute<bool>(route, connected);
      }
    }

    route = MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: RemoteControllerQrDialog(
            service: service,
            onCompleted: complete,
            closeOnConnected: closeOnConnected,
          ),
        ),
      ),
    );
    return navigator.push<bool>(route).then((connected) {
      completed = true;
      return connected ?? false;
    });
  }

  @override
  State<RemoteControllerQrDialog> createState() =>
      _RemoteControllerQrDialogState();
}

class _RemoteControllerQrDialogState extends State<RemoteControllerQrDialog> {
  static const _accent = Color(0xFF00E5FF);
  StreamSubscription<bool>? _connectionSubscription;
  Timer? _copyFeedbackTimer;
  bool _webQr = false;
  String? _copiedLink;
  bool _completionScheduled = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _listenToConnection();
  }

  @override
  void didUpdateWidget(RemoteControllerQrDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) {
      _connectionSubscription?.cancel();
      _listenToConnection();
    } else if (oldWidget.closeOnConnected != widget.closeOnConnected ||
        oldWidget.onCompleted != widget.onCompleted) {
      _completeWhenConnected();
    }
  }

  void _listenToConnection() {
    _connectionSubscription = widget.service.onConnectionChanged.listen((_) {
      if (!mounted) return;
      setState(() {});
      _completeWhenConnected();
    });
    _completeWhenConnected();
  }

  void _completeWhenConnected() {
    if (_completed ||
        _completionScheduled ||
        !widget.closeOnConnected ||
        widget.onCompleted == null ||
        !widget.service.isConnected) {
      return;
    }
    _completionScheduled = true;
    // Connection delivery can happen during initial build or a route change.
    // Recheck the current service after the frame; a stale/disconnected service
    // must not complete a newly configured setup widget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _completionScheduled = false;
      if (!mounted || !widget.closeOnConnected || !widget.service.isConnected) {
        return;
      }
      _complete(true);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _complete(bool connected) {
    final onCompleted = widget.onCompleted;
    if (_completed || onCompleted == null) return;
    _completed = true;
    onCompleted(connected);
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _copyFeedbackTimer?.cancel();
    super.dispose();
  }

  String get _appLink {
    final endpoint = Uri.parse(widget.service.serverUrl!);
    return VrPairingPayload(
      host: endpoint.host,
      port: endpoint.port,
      sessionToken: widget.service.sessionToken,
      role: VrDeviceRole.child,
      transportType: VrTransportType.localSocket,
      deviceName: 'VRlizate-Visor',
    ).toUri().toString();
  }

  Future<void> _copyLink(String link) async {
    await Clipboard.setData(ClipboardData(text: link));
    if (!mounted) return;
    _copyFeedbackTimer?.cancel();
    setState(() => _copiedLink = link);
    _copyFeedbackTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copiedLink = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final webLink = widget.service.serverUrl;
    if (webLink == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.service.isRunning
                    ? 'Conecta este visor a Wi-Fi o activa un punto de acceso '
                          'y vuelve a abrir el QR. Los datos móviles no sirven '
                          'para emparejar los dos teléfonos en una red local.'
                    : 'No hay un visor activo. Vuelve al Home e intenta de nuevo.',
                textAlign: TextAlign.center,
              ),
              TextButton(
                onPressed: widget.onCompleted == null
                    ? null
                    : () => _complete(false),
                child: const Text('Cerrar'),
              ),
            ],
          ),
        ),
      );
    }
    final appLink = _appLink;
    final connected = widget.service.isConnected;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 560;
          final qrSize = wide
              ? (constraints.maxHeight - 140).clamp(200.0, 280.0)
              : math.min(280.0, math.max(160.0, constraints.maxWidth - 40));
          final qr = Center(
            child: QrImageView(
              key: ValueKey(_webQr ? webLink : appLink),
              data: _webQr ? webLink : appLink,
              version: QrVersions.auto,
              size: qrSize,
              padding: const EdgeInsets.all(20),
              backgroundColor: Colors.white,
              semanticsLabel: _webQr
                  ? 'QR para navegador'
                  : 'QR para app VRlizate',
            ),
          );
          final instructions = _instructions(appLink, webLink, connected);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: Material(
                color: const Color(0xFF0D1117),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: _accent.withValues(alpha: 0.45)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
                      child: Row(
                        children: [
                          const Icon(Icons.phonelink, color: _accent),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Conectar otro teléfono',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Cerrar',
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white70,
                            ),
                            onPressed: widget.onCompleted == null
                                ? null
                                : () => _complete(false),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        child: wide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(width: qrSize, child: qr),
                                  const SizedBox(width: 24),
                                  Expanded(child: instructions),
                                ],
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  qr,
                                  const SizedBox(height: 16),
                                  instructions,
                                ],
                              ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: widget.onCompleted == null
                              ? null
                              : () => _complete(false),
                          icon: Icon(
                            connected ? Icons.check_circle : Icons.arrow_back,
                          ),
                          label: Text(
                            connected
                                ? 'Continuar al visor'
                                : 'Volver al visor',
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: connected
                                ? _accent
                                : Colors.white12,
                            foregroundColor: connected
                                ? Colors.black
                                : Colors.white,
                            minimumSize: const Size(48, 48),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _instructions(String appLink, String webLink, bool connected) {
    return DefaultTextStyle(
      style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: const Text('Mando con app'),
                selected: !_webQr,
                onSelected: (_) => setState(() => _webQr = false),
              ),
              ChoiceChip(
                label: const Text('Sin instalar app'),
                selected: _webQr,
                onSelected: (_) => setState(() => _webQr = true),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            connected ? 'Mando conectado' : 'En el teléfono que será el mando:',
            style: TextStyle(
              color: connected ? _accent : Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          if (connected)
            const Text('Ya puedes colocar este teléfono en el visor.')
          else ...[
            const Text('Conecta ambos teléfonos a la misma red Wi-Fi.'),
            const SizedBox(height: 8),
            Text(
              _webQr
                  ? 'Escanea este QR con la cámara del teléfono y abre el enlace en su navegador.'
                  : 'Abre VRlizate > Usar como mando > Escanear QR',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _webQr
                  ? 'Control táctil en el navegador; no requiere sensores.'
                  : 'Apunta a este código con el escáner de VRlizate, no con la cámara del sistema.',
            ),
            const SizedBox(height: 8),
            const Text(
              'Retira este teléfono del visor para mostrar el QR.',
              style: TextStyle(color: Color(0xFFFFD54F), fontSize: 12),
            ),
          ],
          const SizedBox(height: 8),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              iconColor: Colors.white70,
              collapsedIconColor: Colors.white70,
              textColor: Colors.white70,
              collapsedTextColor: Colors.white70,
              title: const Text(
                'Opciones avanzadas',
                style: TextStyle(fontSize: 13),
              ),
              children: [
                const Text(
                  'Estos enlaces permiten controlar el visor. Compártelos sólo con personas de confianza.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                _linkOption('Enlace para VRlizate', appLink),
                _linkOption('Enlace para navegador', webLink),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkOption(String label, String link) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _accent, fontSize: 12)),
          const SizedBox(height: 4),
          SelectableText(
            link,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
          TextButton.icon(
            onPressed: () => _copyLink(link),
            icon: Icon(
              _copiedLink == link ? Icons.check : Icons.copy,
              size: 16,
            ),
            label: Text(_copiedLink == link ? 'Copiado' : 'Copiar $label'),
          ),
        ],
      ),
    );
  }
}
