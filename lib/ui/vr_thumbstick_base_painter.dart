import 'package:flutter/material.dart';

import '../utils/constants/vr_joystick_constants.dart';

class VrThumbstickBasePainter extends CustomPainter {
  final double maxRadius;
  final double deadzone;
  final bool isDragging;
  final Color accentColor;
  final bool horizontalEnabled;

  VrThumbstickBasePainter({
    required this.maxRadius,
    required this.deadzone,
    required this.isDragging,
    required this.accentColor,
    required this.horizontalEnabled,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final linePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    // Crosshairs
    if (horizontalEnabled) {
      canvas.drawLine(
        Offset(center.dx - maxRadius, center.dy),
        Offset(center.dx + maxRadius, center.dy),
        linePaint,
      );
    }
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      linePaint,
    );

    // Inner 50% radius guideline
    final midPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, maxRadius * 0.5, midPaint);

    // Deadzone circle
    final deadzonePaint = Paint()
      ..color = const Color(0xFFFF007F).withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, maxRadius * deadzone, deadzonePaint);

    // Directional labels (W, S, A, D)
    _drawLabel(
      canvas,
      VrJoystickConstants.arrowUp,
      Offset(center.dx, center.dy - maxRadius + 14),
    );
    _drawLabel(
      canvas,
      VrJoystickConstants.arrowDown,
      Offset(center.dx, center.dy + maxRadius - 14),
    );
    if (horizontalEnabled) {
      _drawLabel(
        canvas,
        VrJoystickConstants.arrowLeft,
        Offset(center.dx - maxRadius + 14, center.dy),
      );
      _drawLabel(
        canvas,
        VrJoystickConstants.arrowRight,
        Offset(center.dx + maxRadius - 14, center.dy),
      );
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset position) {
    // Geometry keeps directional hints independent of font availability.
    final direction = switch (text) {
      VrJoystickConstants.arrowUp => const Offset(0, -4),
      VrJoystickConstants.arrowDown => const Offset(0, 4),
      VrJoystickConstants.arrowLeft => const Offset(-4, 0),
      _ => const Offset(4, 0),
    };
    final tip = position + direction;
    final base = position - direction * .5;
    final side = Offset(-direction.dy, direction.dx) * .65;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((base + side).dx, (base + side).dy)
        ..lineTo((base - side).dx, (base - side).dy)
        ..close(),
      Paint()..color = accentColor.withValues(alpha: .45),
    );
  }

  @override
  bool shouldRepaint(covariant VrThumbstickBasePainter oldDelegate) {
    return oldDelegate.isDragging != isDragging ||
        oldDelegate.maxRadius != maxRadius ||
        oldDelegate.deadzone != deadzone ||
        oldDelegate.horizontalEnabled != horizontalEnabled ||
        oldDelegate.accentColor != accentColor;
  }
}
