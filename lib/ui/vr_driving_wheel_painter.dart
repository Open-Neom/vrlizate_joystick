import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Feedback only: touching the wheel cannot produce a steering command.
class VrDrivingWheelPainter extends CustomPainter {
  final double angle;
  final bool available;

  const VrDrivingWheelPainter({required this.angle, required this.available});

  @override
  void paint(Canvas canvas, Size size) {
    final radius = math.min(size.width, size.height) * .40;
    if (radius <= 0) return;
    final paint = Paint()
      ..color = available ? const Color(0xFF00E5FF) : Colors.white30
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(3, radius * .10)
      ..strokeCap = StrokeCap.round;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(angle);
    canvas.drawCircle(Offset.zero, radius, paint);
    for (final theta in [0.0, math.pi, math.pi / 2]) {
      canvas.drawLine(
        Offset(math.cos(theta), math.sin(theta)) * radius * .22,
        Offset(math.cos(theta), math.sin(theta)) * radius * .85,
        paint,
      );
    }
    canvas.drawCircle(Offset.zero, radius * .18, paint);
    paint.color = available ? Colors.white : Colors.white38;
    canvas.drawLine(Offset(0, -radius), Offset(0, -radius * .83), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(VrDrivingWheelPainter oldDelegate) =>
      oldDelegate.angle != angle || oldDelegate.available != available;
}
