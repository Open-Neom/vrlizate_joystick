import 'package:flutter/material.dart';

class VrNesDpadPainter extends CustomPainter {
  const VrNesDpadPainter(this.x, this.y);
  final double x, y;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero), arm = size.width * .31;
    final cross = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: arm, height: size.height * .94),
          const Radius.circular(9),
        ),
      )
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: c, width: size.width * .94, height: arm),
          const Radius.circular(9),
        ),
      );
    canvas.drawPath(
      cross.shift(const Offset(0, 4)),
      Paint()..color = Colors.black,
    );
    canvas.drawPath(cross, Paint()..color = const Color(0xFF555B5D));
    for (final (dx, dy, active) in [
      (0.0, -.31, y > 0),
      (0.0, .31, y < 0),
      (-.31, 0.0, x < 0),
      (.31, 0.0, x > 0),
    ]) {
      final p = c + Offset(dx * size.width, dy * size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: p, width: arm * .68, height: arm * .68),
          const Radius.circular(5),
        ),
        Paint()
          ..color = active ? const Color(0xFFB7D9DD) : const Color(0xFF292F32),
      );
    }
    canvas.drawCircle(c, arm * .32, Paint()..color = const Color(0xFF3B4245));
  }

  @override
  bool shouldRepaint(VrNesDpadPainter oldDelegate) =>
      x != oldDelegate.x || y != oldDelegate.y;
}
