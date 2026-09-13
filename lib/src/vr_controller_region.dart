import 'package:flutter/material.dart';

/// The same concave path clips both paint and pointer hit testing.
/// A finger owns its original region until release/cancel; another finger on
/// that region cannot steal ownership or release the first finger's button.
class VrControllerRegion extends StatefulWidget {
  const VrControllerRegion({
    super.key,
    required this.path,
    required this.labelPosition,
    required this.label,
    required this.colors,
    required this.active,
    required this.onDown,
    required this.onUp,
    this.textColor = Colors.white,
  });
  final Path path;
  final Offset labelPosition;
  final String label;
  final List<Color> colors;
  final bool active;
  final Color textColor;
  final VoidCallback onDown, onUp;

  @override
  State<VrControllerRegion> createState() => _VrControllerRegionState();
}

class _VrControllerRegionState extends State<VrControllerRegion> {
  int? _owner;

  void _release(PointerEvent event) {
    if (event.pointer != _owner) return;
    _owner = null;
    widget.onUp();
  }

  @override
  Widget build(BuildContext context) => ClipPath(
    clipper: _RegionClipper(widget.path),
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (_owner != null) return;
        _owner = event.pointer;
        widget.onDown();
      },
      onPointerUp: _release,
      onPointerCancel: _release,
      child: Semantics(
        button: true,
        label: widget.label,
        onTap: () {
          if (_owner != null) return;
          widget.onDown();
          widget.onUp();
        },
        child: CustomPaint(
          painter: _RegionPainter(widget.path, widget.colors, widget.active),
          child: Stack(
            children: [
              Positioned(
                left: widget.labelPosition.dx - 24,
                top: widget.labelPosition.dy - 25,
                width: 48,
                height: 50,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: widget.textColor,
                        fontSize: 34,
                        fontWeight: FontWeight.w900,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _RegionClipper extends CustomClipper<Path> {
  const _RegionClipper(this.path);
  final Path path;
  @override
  Path getClip(Size size) => path;
  @override
  bool shouldReclip(_RegionClipper oldClipper) =>
      !identical(path, oldClipper.path);
}

class _RegionPainter extends CustomPainter {
  const _RegionPainter(this.path, this.colors, this.active);
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
  bool shouldRepaint(_RegionPainter oldDelegate) =>
      !identical(path, oldDelegate.path) ||
      active != oldDelegate.active ||
      colors != oldDelegate.colors;
}
