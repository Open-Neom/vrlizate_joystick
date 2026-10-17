import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Paints the live 3D laser beam projection, aiming grid, target reticle, and
/// 5-second auto-click steady dwell ring on the full-screen laser pointing view.
class VrLaserAimReticlePainter extends CustomPainter {
  const VrLaserAimReticlePainter({
    required this.aimX,
    required this.aimY,
    required this.dwellProgress,
    required this.clickActive,
  });

  /// Normalized horizontal laser aim in `[-1.0, 1.0]`.
  final double aimX;

  /// Normalized vertical laser aim in `[-1.0, 1.0]` (`+1.0` = up).
  final double aimY;

  /// Normalized 5-second steady dwell progress in `[0.0, 1.0]`.
  final double dwellProgress;

  /// Whether a click/select pulse is currently active.
  final bool clickActive;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);
    final gridPaint = Paint()
      ..color = const Color(0x2200E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Subtle spatial horizon and vertical reference axes
    canvas.drawLine(
      Offset(24, center.dy),
      Offset(size.width - 24, center.dy),
      gridPaint,
    );
    canvas.drawLine(
      Offset(center.dx, 24),
      Offset(center.dx, size.height - 24),
      gridPaint,
    );
    canvas.drawCircle(
      center,
      math.min(size.width, size.height) * 0.24,
      gridPaint,
    );

    final clampedX = aimX.clamp(-1.0, 1.0);
    final clampedY = aimY.clamp(-1.0, 1.0);
    final target = Offset(
      center.dx + clampedX * (size.width * 0.36),
      center.dy - clampedY * (size.height * 0.34),
    );
    final emitter = Offset(center.dx, size.height - 16.0);

    // Outer glow & core 3D laser beam from bottom wand emitter to target
    final beamGlowPaint = Paint()
      ..color = clickActive
          ? const Color(0x6669F0AE)
          : const Color(0x4400E5FF)
      ..strokeWidth = clickActive ? 8.0 : 5.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(emitter, target, beamGlowPaint);

    final beamCorePaint = Paint()
      ..color = clickActive
          ? const Color(0xFF69F0AE)
          : const Color(0xFF18FFFF)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(emitter, target, beamCorePaint);

    // Target reticle rings
    final reticleRadius = clickActive ? 22.0 : 18.0;
    final reticleRingPaint = Paint()
      ..color = clickActive
          ? const Color(0xFF69F0AE)
          : const Color(0xCC00E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(target, reticleRadius, reticleRingPaint);

    // 5-second steady dwell progress arc around target
    final clampedDwell = dwellProgress.clamp(0.0, 1.0);
    if (clampedDwell > 0.02) {
      final dwellArcPaint = Paint()
          ..color = const Color(0xFF69F0AE)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: target, radius: reticleRadius + 6.0),
        -math.pi / 2,
        math.pi * 2 * clampedDwell,
        false,
        dwellArcPaint,
      );
    }

    // Center laser dot
    final dotPaint = Paint()
      ..color = clickActive
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF00E5FF)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(target, clickActive ? 5.5 : 4.0, dotPaint);
  }

  @override
  bool shouldRepaint(covariant VrLaserAimReticlePainter oldDelegate) {
    return oldDelegate.aimX != aimX ||
        oldDelegate.aimY != aimY ||
        oldDelegate.dwellProgress != dwellProgress ||
        oldDelegate.clickActive != clickActive;
  }
}
