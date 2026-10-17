import 'package:flutter/material.dart';

class VrRegionPainter extends CustomPainter {
  const VrRegionPainter(this.path, this.colors, this.active);
  final Path path;
  final List<Color> colors;
  final bool active;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Offset.zero & size),
    );
    if (active) {
      canvas.drawPath(
        path,
        Paint()..color = Colors.white.withValues(alpha: .20),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = active ? 4 : 2
        ..color = Colors.white.withValues(alpha: active ? .85 : .20),
    );
  }

  @override
  bool shouldRepaint(VrRegionPainter oldDelegate) =>
      !identical(path, oldDelegate.path) ||
      active != oldDelegate.active ||
      colors != oldDelegate.colors;
}
