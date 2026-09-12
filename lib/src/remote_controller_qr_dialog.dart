import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:vrlizate/vrlizate.dart';

import 'vr_remote_controller_service.dart';

/// Dedicated 2D setup page for a canonical pairing QR (`vrlizate://pair?...`).
///
/// QR pairing intentionally leaves the stereoscopic world: a camera cannot
/// fuse the two eye images and the physical visor obscures the display. The
/// user removes the visor, scans one unduplicated code, then returns to VR.
class RemoteControllerQrDialog extends StatefulWidget {
  final VrRemoteControllerService service;

  const RemoteControllerQrDialog({super.key, required this.service});

  static Future<void> show(
    BuildContext context, {
    required VrRemoteControllerService service,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(child: RemoteControllerQrDialog(service: service)),
        ),
      ),
    );
  }

  @override
  State<RemoteControllerQrDialog> createState() =>
      _RemoteControllerQrDialogState();
}

class _RemoteControllerQrDialogState extends State<RemoteControllerQrDialog> {
  static const _selectedTransport = VrTransportType.localSocket;
  StreamSubscription<bool>? _connectionSubscription;
  bool _webQr = false;

  bool _copiedDeepLink = false;
  bool _copiedWeb = false;

  @override
  void initState() {
    super.initState();
    _connectionSubscription = widget.service.onConnectionChanged.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  /// Canonical deep link that activates the Child Controller role on the scanning smartphone.
  String get _deepLinkUrl {
    final endpoint = Uri.parse(widget.service.serverUrl!);
    final payload = VrPairingPayload(
      host: endpoint.host,
      port: endpoint.port,
      sessionToken: widget.service.sessionToken,
      role: VrDeviceRole.child,
      transportType: _selectedTransport,
      deviceName: 'VRlizate-Visor',
    );
    return payload.toUri().toString();
  }

  String get _fallbackWebUrl => widget.service.serverUrl!;

  @override
  Widget build(BuildContext context) {
    if (widget.service.serverUrl == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No hay un visor activo. Vuelve al Home e intenta de nuevo.',
            ),
            IconButton(
              tooltip: 'Cerrar',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    }
    final isConnected = widget.service.isConnected;
    final deepLink = _deepLinkUrl;
    final fallbackUrl = _fallbackWebUrl;

    return Align(
      alignment: Alignment.center,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        decoration: BoxDecoration(
          color: const Color(0xFF0D1117),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.5),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00E5FF).withValues(alpha: 0.2),
              blurRadius: 24,
              spreadRadius: 2,
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.qr_code_scanner_rounded,
                      color: Color(0xFF00E5FF),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Vincular Mando VR (P2P)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          'Visor Padre ↔ Smartphone Hijo (Control 3D)',
                          style: TextStyle(
                            color: Colors.white60,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white54,
                      size: 20,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: 'Cerrar',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFB300).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: const Color(0xFFFFB300).withValues(alpha: 0.65),
                  ),
                ),
                child: const Text(
                  'MODO 2D · RETIRA EL VISOR PARA ESCANEAR',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFFFD54F),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Transport Protocol Selector (Socket / Bluetooth / Wi-Fi Direct)
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildTransportTab(
                        type: VrTransportType.localSocket,
                        title: 'Socket P2P',
                        icon: Icons.hub_rounded,
                      ),
                    ),
                    Expanded(
                      child: _buildTransportTab(
                        type: VrTransportType.bluetoothLe,
                        title: 'BLE · pendiente',
                        icon: Icons.bluetooth_rounded,
                      ),
                    ),
                    Expanded(
                      child: _buildTransportTab(
                        type: VrTransportType.wifiDirect,
                        title: 'Wi-Fi Direct · pendiente',
                        icon: Icons.wifi_tethering_rounded,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Connection Status Indicator
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: isConnected
                      ? const Color(0xFF00E676).withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: isConnected
                        ? const Color(0xFF00E676)
                        : Colors.white24,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.circle,
                      size: 8,
                      color: isConnected
                          ? const Color(0xFF00E676)
                          : Colors.amberAccent,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        isConnected
                            ? '🎮 Mando Hijo vinculado y sincronizado'
                            : 'Escanea el QR para activar Mando Hijo...',
                        style: TextStyle(
                          color: isConnected
                              ? const Color(0xFF00E676)
                              : Colors.white70,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // QR Code Box (Encodes the Canonical Deep Link vrlizate://pair?...)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: QrImageView(
                  data: _webQr ? fallbackUrl : deepLink,
                  semanticsLabel: _webQr ? 'QR para navegador' : 'QR para app VRlizate',
                  version: QrVersions.auto,
                  size: 160,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF0D1117),
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF0D1117),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Deep Link Pill with Copy Action
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.link_rounded,
                      size: 15,
                      color: Color(0xFF00E5FF),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Deep Link VRlizate (Apertura Automática):',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            deepLink,
                            style: const TextStyle(
                              color: Color(0xFF00E5FF),
                              fontFamily: 'monospace',
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: deepLink));
                        setState(() => _copiedDeepLink = true);
                        Future.delayed(const Duration(seconds: 2), () {
                          if (mounted) setState(() => _copiedDeepLink = false);
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Text(
                          _copiedDeepLink ? '¡Copiado!' : 'Copiar',
                          style: TextStyle(
                            color: _copiedDeepLink
                                ? const Color(0xFF00E676)
                                : Colors.white70,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),

              // Fallback Web Link Pill
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.language_rounded,
                      size: 13,
                      color: Colors.white54,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Web Fallback: $fallbackUrl',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontFamily: 'monospace',
                          fontSize: 10,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: fallbackUrl));
                        setState(() => _copiedWeb = true);
                        Future.delayed(const Duration(seconds: 2), () {
                          if (mounted) setState(() => _copiedWeb = false);
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        child: Text(
                          _copiedWeb ? '¡Copiado!' : 'Copiar',
                          style: TextStyle(
                            color: _copiedWeb
                                ? const Color(0xFF00E676)
                                : Colors.white54,
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),

              // 3-Step Quick Instructions
              Text(
                '1. Conecta ambos teléfonos a la misma red Wi-Fi.\n'
                '2. Escanea el QR con el segundo teléfono.\n'
                '${_webQr ? '3. Abre el enlace en el navegador.' : '3. Abre VRlizate instalada en el segundo teléfono.'}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10.5,
                  height: 1.35,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),

              // Bottom Buttons
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF007F),
                        side: const BorderSide(color: Color(0xFFFF007F)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      icon: const Icon(Icons.swap_horiz_rounded, size: 15),
                      label: Text(
                        _webQr ? 'Usar app nativa' : 'Usar navegador',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: () => setState(() => _webQr = !_webQr),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Listo',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTransportTab({
    required VrTransportType type,
    required String title,
    required IconData icon,
  }) {
    final isSelected = _selectedTransport == type;
    return GestureDetector(
      onTap: null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00E5FF).withValues(alpha: 0.2)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected
              ? Border.all(color: const Color(0xFF00E5FF), width: 1)
              : Border.all(color: Colors.transparent, width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 12,
              color: isSelected ? const Color(0xFF00E5FF) : Colors.white60,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                title,
                style: TextStyle(
                  color: isSelected ? const Color(0xFF00E5FF) : Colors.white60,
                  fontSize: 9.5,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
