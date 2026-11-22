import 'package:flutter/material.dart';

/// Paints a sculpted concave VR gamepad button region matching VRlizate's 1D
/// OLED console language: smoked dark-obsidian glass when idle, vivid luminous
/// signature accent fill & rim glow when pressed.
class VrRegionPainter extends CustomPainter {
  const VrRegionPainter(this.path, this.colors, this.active);
  final Path path;
  final List<Color> colors;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final accent = colors.isNotEmpty ? colors.first : const Color(0xFF00E5FF);
    final secondary = colors.length > 1 ? colors[1] : accent;
    final rect = Offset.zero & size;

    if (active) {
      canvas.drawPath(
        path,
        Paint()
          ..color = accent.withValues(alpha: 0.36)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0),
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          colors: active
              ? [
                  accent.withValues(alpha: 0.62),
                  secondary.withValues(alpha: 0.42),
                ]
              : [
                  Color.lerp(const Color(0xFF14213B), accent, 0.14)!,
                  Color.lerp(const Color(0xFF0B1324), secondary, 0.10)!,
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(rect),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 3.2 : 1.9
        ..color = active ? accent : accent.withValues(alpha: 0.72),
    );
  }

  @override
  bool shouldRepaint(VrRegionPainter oldDelegate) =>
      !identical(path, oldDelegate.path) ||
      active != oldDelegate.active ||
      colors != oldDelegate.colors;
}
