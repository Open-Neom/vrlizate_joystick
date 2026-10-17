import 'dart:math' as math;

import 'package:flutter/material.dart';

class VrLaserSlidePadPainter extends CustomPainter {
  const VrLaserSlidePadPainter({
    required this.normX,
    required this.normY,
    required this.isActive,
    this.isGrip = false,
  });

  final double normX;
  final double normY;
  final bool isActive;
  final bool isGrip;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.42;

    final baseColor = isGrip
        ? const Color(0xFFFF9100)
        : (isActive ? const Color(0xFF10B981) : const Color(0xFF00E5FF));

    final gridPaint = Paint()
      ..color = (isGrip ? const Color(0xFFFF9100) : const Color(0xFF10B981))
          .withValues(alpha: isGrip ? 0.25 : 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Concentric 180° / full radar circles
    canvas.drawCircle(center, radius * 0.33, gridPaint);
    canvas.drawCircle(center, radius * 0.66, gridPaint);
    canvas.drawCircle(center, radius, gridPaint);

    // Crosshairs
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      gridPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      gridPaint,
    );

    // Target reticle position
    final targetX = center.dx + normX * (size.width * 0.45);
    final targetY = center.dy + normY * (size.height * 0.45);
    final targetOffset = Offset(targetX, targetY);

    // Aiming beam line from center to touch point
    if (isActive || normX.abs() > 0.01 || normY.abs() > 0.01) {
      final beamPaint = Paint()
        ..color = baseColor.withValues(alpha: isActive ? 0.7 : 0.25)
        ..strokeWidth = isGrip ? 3.0 : 2.0
        ..style = PaintingStyle.stroke;
      canvas.drawLine(center, targetOffset, beamPaint);

      // Glow halo around reticle
      final glowPaint = Paint()
        ..color = baseColor.withValues(
          alpha: isGrip ? 0.5 : (isActive ? 0.35 : 0.15),
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, isGrip ? 12 : 8);
      canvas.drawCircle(targetOffset, isGrip ? 18 : 14, glowPaint);

      // Reticle circle
      final reticlePaint = Paint()
        ..color = baseColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = isGrip ? 3.2 : 2.5;
      canvas.drawCircle(targetOffset, isGrip ? 10 : 8, reticlePaint);

      // Reticle center dot
      final dotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(targetOffset, isGrip ? 4 : 3, dotPaint);
    } else {
      // Resting center dot
      final restPaint = Paint()
        ..color = const Color(0xFF10B981).withValues(alpha: 0.5)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, 4, restPaint);
    }
  }

  @override
  bool shouldRepaint(covariant VrLaserSlidePadPainter oldDelegate) {
    return oldDelegate.normX != normX ||
        oldDelegate.normY != normY ||
        oldDelegate.isActive != isActive ||
        oldDelegate.isGrip != isGrip;
  }
}
