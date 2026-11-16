import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/constants/vr_joystick_constants.dart';

class VrThumbstickBasePainter extends CustomPainter {
  final double maxRadius;
  final double deadzone;
  final bool isDragging;
  final Color accentColor;
  final bool horizontalEnabled;
  final Offset originOffset;
  final bool isAutoWalkLocked;
  final bool enableRimDpad;
  final double activeRimDpadX;
  final double activeRimDpadY;

  VrThumbstickBasePainter({
    required this.maxRadius,
    required this.deadzone,
    required this.isDragging,
    required this.accentColor,
    required this.horizontalEnabled,
    this.originOffset = Offset.zero,
    this.isAutoWalkLocked = false,
    this.enableRimDpad = false,
    this.activeRimDpadX = 0.0,
    this.activeRimDpadY = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final activeOrigin = center + originOffset;

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

    // Outer 92% sprint/rim detent ring
    final rimPaint = Paint()
      ..color = accentColor.withValues(alpha: isAutoWalkLocked ? 0.55 : 0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = isAutoWalkLocked ? 1.8 : 1.0;
    canvas.drawCircle(
      center,
      maxRadius * VrJoystickConstants.hapticOuterRimThreshold,
      rimPaint,
    );

    // Dynamic floating origin indicator when off-center
    if (isDragging && originOffset.distance > 1.5) {
      final originPaint = Paint()
        ..color = accentColor.withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawCircle(activeOrigin, 6.0, originPaint);
    }

    // Deadzone circle
    final deadzonePaint = Paint()
      ..color = const Color(0xFFFF007F).withValues(alpha: 0.2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(activeOrigin, maxRadius * deadzone, deadzonePaint);

    // Superimposed cardinal rim D-pad ("cruz en las orillas") for 2D/3D menu selection
    if (enableRimDpad) {
      final outerRadius = size.shortestSide / 2;
      final arcRadius = outerRadius * 0.86;
      final bandWidth = (outerRadius * 0.19).clamp(6.0, 18.0);
      const sweep = math.pi * 0.24; // ~43° per cardinal rim segment
      final segments = <(double startAngle, bool active, String arrow, Offset chevronPos)>[
        (
          -math.pi / 2 - sweep / 2,
          activeRimDpadY > 0.5,
          VrJoystickConstants.arrowUp,
          Offset(center.dx, center.dy - arcRadius),
        ),
        (
          math.pi / 2 - sweep / 2,
          activeRimDpadY < -0.5,
          VrJoystickConstants.arrowDown,
          Offset(center.dx, center.dy + arcRadius),
        ),
        if (horizontalEnabled) ...[
          (
            math.pi - sweep / 2,
            activeRimDpadX < -0.5,
            VrJoystickConstants.arrowLeft,
            Offset(center.dx - arcRadius, center.dy),
          ),
          (
            -sweep / 2,
            activeRimDpadX > 0.5,
            VrJoystickConstants.arrowRight,
            Offset(center.dx + arcRadius, center.dy),
          ),
        ],
      ];
      final arcRect = Rect.fromCircle(center: center, radius: arcRadius);
      for (final (startAngle, active, arrow, chevronPos) in segments) {
        canvas.drawArc(
          arcRect,
          startAngle,
          sweep,
          false,
          Paint()
            ..color = active
                ? accentColor.withValues(alpha: 0.72)
                : accentColor.withValues(alpha: 0.16)
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = bandWidth,
        );
        _drawLabel(
          canvas,
          arrow,
          chevronPos,
          scale: 1.35,
          color: active ? Colors.white : accentColor.withValues(alpha: 0.85),
        );
      }
    } else {
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
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset position, {
    double scale = 1.0,
    Color? color,
  }) {
    // Geometry keeps directional hints independent of font availability.
    final direction =
        switch (text) {
          VrJoystickConstants.arrowUp => const Offset(0, -4),
          VrJoystickConstants.arrowDown => const Offset(0, 4),
          VrJoystickConstants.arrowLeft => const Offset(-4, 0),
          _ => const Offset(4, 0),
        } *
        scale;
    final tip = position + direction;
    final base = position - direction * .5;
    final side = Offset(-direction.dy, direction.dx) * .65;
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((base + side).dx, (base + side).dy)
        ..lineTo((base - side).dx, (base - side).dy)
        ..close(),
      Paint()..color = color ?? accentColor.withValues(alpha: .45),
    );
  }

  @override
  bool shouldRepaint(covariant VrThumbstickBasePainter oldDelegate) {
    return oldDelegate.isDragging != isDragging ||
        oldDelegate.maxRadius != maxRadius ||
        oldDelegate.deadzone != deadzone ||
        oldDelegate.horizontalEnabled != horizontalEnabled ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.originOffset != originOffset ||
        oldDelegate.isAutoWalkLocked != isAutoWalkLocked ||
        oldDelegate.enableRimDpad != enableRimDpad ||
        oldDelegate.activeRimDpadX != activeRimDpadX ||
        oldDelegate.activeRimDpadY != activeRimDpadY;
  }
}
