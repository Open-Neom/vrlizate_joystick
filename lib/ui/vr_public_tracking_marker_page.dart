import 'dart:math';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../domain/models/vr_tracking_marker_configuration.dart';

/// A visible, public reference. Its dimensions require a ruler, never screen DPI.
class VrPublicTrackingMarkerPage extends StatefulWidget {
  const VrPublicTrackingMarkerPage({
    super.key,
    required this.onConfiguration,
    this.initialConfiguration,
  });

  final ValueChanged<VrTrackingMarkerConfiguration> onConfiguration;
  final VrTrackingMarkerConfiguration? initialConfiguration;

  @override
  State<VrPublicTrackingMarkerPage> createState() => _MarkerPageState();
}

class _MarkerPageState extends State<VrPublicTrackingMarkerPage> {
  late VrTrackingMarkerConfiguration _configuration;
  late final TextEditingController _width;
  String? _error;

  @override
  void initState() {
    super.initState();
    final random = Random.secure();
    final id = List.generate(8, (_) => random.nextInt(256)
        .toRadixString(16).padLeft(2, '0')).join();
    _configuration = widget.initialConfiguration ??
        VrTrackingMarkerConfiguration(markerId: 'vrlizate-marker-v1:$id');
    _width = TextEditingController(text: _configuration.widthMeters == null
        ? '' : (_configuration.widthMeters! * 100).toStringAsFixed(2));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onConfiguration(_configuration);
    });
  }

  @override
  void dispose() {
    _width.dispose();
    super.dispose();
  }

  void _applyWidth() {
    final cm = double.tryParse(_width.text.trim().replaceAll(',', '.'));
    if (cm == null || !cm.isFinite || cm < 2 || cm > 30) {
      setState(() => _error = 'Introduce el ancho medido, entre 2 y 30 cm.');
      return;
    }
    setState(() {
      _error = null;
      _configuration = VrTrackingMarkerConfiguration(
        markerId: _configuration.markerId, widthMeters: cm / 100);
    });
    widget.onConfiguration(_configuration);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Marcador público de calibración')),
    body: LayoutBuilder(builder: (context, constraints) {
      // Keyboard insets must not resize the physical calibration reference.
      final side = (MediaQuery.sizeOf(context).shortestSide - 140)
          .clamp(160.0, 280.0);
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(spacing: 28, runSpacing: 20, children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(20),
            child: QrImageView(
              key: const ValueKey('public-tracking-marker'),
              data: _configuration.markerId,
              size: side,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
          SizedBox(width: 340, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Coloca este cuadrado frente a la cámara trasera del visor. '
                  'Mide el lado del QR, excluyendo el margen blanco. '
                  'Mantén el tamaño de pantalla fijo durante la calibración.'),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('tracking-marker-width-cm'),
                controller: _width,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'Ancho del QR en cm', errorText: _error),
              ),
              const SizedBox(height: 10),
              FilledButton(onPressed: _applyWidth, child: const Text('Guardar ancho medido')),
              Text(_configuration.hasMeasuredScale
                  ? 'Ancho manual: ${(_configuration.widthMeters! * 100).toStringAsFixed(2)} cm'
                  : 'Sin escala métrica; se puede comprobar detección del marcador.'),
              const SizedBox(height: 10),
              const Text('Este QR solo identifica la referencia visual. '
                  'No contiene la contraseña de vinculación.'),
            ],
          )),
        ]),
      );
    }),
  );
}
