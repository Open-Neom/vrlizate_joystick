import 'package:flutter/material.dart';

import '../utils/constants/vr_joystick_translation_constants.dart';
import '../utils/enums/vr_passthrough_split_gesture_mode.dart';

/// Paints the visual curtain-split feedback and Passthrough Mix percentage HUD
/// on the Smartphone Joystick when the user performs the dual-thumb center-to-lateral
/// slide gesture.
class VrPassthroughCurtainOverlayPainter extends CustomPainter {
  const VrPassthroughCurtainOverlayPainter({
    required this.mode,
    required this.passthroughMix,
    required this.spread,
    this.leftThumbNormX,
    this.rightThumbNormX,
  });

  final VrPassthroughSplitGestureMode mode;
  final double passthroughMix;
  final double spread;
  final double? leftThumbNormX;
  final double? rightThumbNormX;

  @override
  void paint(Canvas canvas, Size size) {
    if (mode == VrPassthroughSplitGestureMode.idle && passthroughMix <= 0.01) {
      return;
    }

    final centerX = size.width * 0.5;
    final centerY = size.height * 0.5;
    final mixClamped = passthroughMix.clamp(0.0, 1.0);
    final percent = (mixClamped * 100).round();

    // Draw curtain split rails when the dual-thumb gesture is actively being dragged
    if (mode != VrPassthroughSplitGestureMode.idle) {
      final leftX = (leftThumbNormX ?? (0.5 - spread * 0.42)) * size.width;
      final rightX = (rightThumbNormX ?? (0.5 + spread * 0.42)) * size.width;

      final curtainRect = Rect.fromLTRB(
        leftX.clamp(0.0, size.width),
        0,
        rightX.clamp(0.0, size.width),
        size.height,
      );

      final fillPaint = Paint()
        ..color = const Color(0xFF00E5FF).withValues(
          alpha: (0.06 + mixClamped * 0.16).clamp(0.04, 0.24),
        )
        ..style = PaintingStyle.fill;
      canvas.drawRect(curtainRect, fillPaint);

      final railPaint = Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.85)
        ..strokeWidth = 2.4
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(leftX, size.height * 0.12),
        Offset(leftX, size.height * 0.88),
        railPaint,
      );
      canvas.drawLine(
        Offset(rightX, size.height * 0.12),
        Offset(rightX, size.height * 0.88),
        railPaint,
      );

      final handlePaint = Paint()
        ..color = const Color(0xFF10B981)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(leftX, centerY), 9.0, handlePaint);
      canvas.drawCircle(Offset(rightX, centerY), 9.0, handlePaint);
    }

    // Draw top-center Passthrough Mix Pill Badge
    final String labelPrefix = switch (mode) {
      VrPassthroughSplitGestureMode.ultraSlowCycleZeroToHundredToZero =>
        VrJoystickTranslationConstants.passthroughCycleBadgePrefix,
      VrPassthroughSplitGestureMode.fastToggleSwipe =>
        VrJoystickTranslationConstants.passthroughFastSwipeBadgePrefix,
      _ => VrJoystickTranslationConstants.passthroughMixBadgePrefix,
    };
    final String badgeText = mode == VrPassthroughSplitGestureMode.armedCenterTap
        ? VrJoystickTranslationConstants.passthroughCenterArmedHint
        : '$labelPrefix$percent${VrJoystickTranslationConstants.passthroughPercentSuffix}';

    final textPainter = TextPainter(
      text: TextSpan(
        text: badgeText,
        style: const TextStyle(
          color: Color(0xFF00E5FF),
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.6,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * 0.90);

    final pillRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(centerX, 20.0),
        width: textPainter.width + 20.0,
        height: textPainter.height + 10.0,
      ),
      const Radius.circular(10.0),
    );

    canvas.drawRRect(
      pillRect,
      Paint()..color = const Color(0xDD080816),
    );
    canvas.drawRRect(
      pillRect,
      Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    textPainter.paint(
      canvas,
      Offset(
        centerX - textPainter.width * 0.5,
        20.0 - textPainter.height * 0.5,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant VrPassthroughCurtainOverlayPainter oldDelegate) {
    return oldDelegate.mode != mode ||
        oldDelegate.passthroughMix != passthroughMix ||
        oldDelegate.spread != spread ||
        oldDelegate.leftThumbNormX != leftThumbNormX ||
        oldDelegate.rightThumbNormX != rightThumbNormX;
  }
}
