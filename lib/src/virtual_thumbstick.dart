import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Interactive on-screen Virtual Analog Thumbstick for VR/Gamepad navigation.
///
/// Features:
/// - 360-degree continuous analog vector $(x, y) \in [-1.0, 1.0]$.
/// - Configurable deadzone threshold to avoid sensor and finger drift.
/// - Automatic spring recenter upon finger release.
/// - Cyberpunk neon visual feedback with concentric range rings and crosshairs.
/// - Haptic feedback on boundary excursions and release.
class VirtualThumbstick extends StatefulWidget {
  /// Diameter of the outer base area in pixels.
  final double size;

  /// Radius of the inner draggable knob in pixels.
  final double knobRadius;

  /// Normalized distance threshold under which output is zeroed.
  final double deadzone;

  /// Callback delivering normalized coordinates:
  /// - `x`: -1.0 (Left) to +1.0 (Right)
  /// - `y`: +1.0 (Forward/Up) to -1.0 (Backward/Down)
  final void Function(double stickX, double stickY) onChanged;

  /// Optional callback invoked when the stick returns to center.
  final VoidCallback? onRelease;

  /// Optional accent color for borders and highlights (defaults to neon cyan).
  final Color accentColor;

  const VirtualThumbstick({
    super.key,
    this.size = 150.0,
    this.knobRadius = 28.0,
    this.deadzone = 0.08,
    this.accentColor = const Color(0xFF00E5FF),
    required this.onChanged,
    this.onRelease,
  });

  @override
  State<VirtualThumbstick> createState() => _VirtualThumbstickState();
}

class _VirtualThumbstickState extends State<VirtualThumbstick>
    with SingleTickerProviderStateMixin {
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;

  late AnimationController _recenterController;
  late Animation<Offset> _recenterAnimation;

  @override
  void initState() {
    super.initState();
    _recenterController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    )..addListener(() {
        setState(() {
          _dragOffset = _recenterAnimation.value;
        });
      });
  }

  @override
  void dispose() {
    _recenterController.dispose();
    super.dispose();
  }

  double get _maxRadius => (widget.size / 2) - widget.knobRadius;

  void _onPanStart(DragStartDetails details) {
    _recenterController.stop();
    _isDragging = true;
    _updateOffset(details.localPosition);
    HapticFeedback.selectionClick();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _updateOffset(details.localPosition);
  }

  void _onPanEnd(DragEndDetails details) {
    _releaseStick();
  }

  void _onPanCancel() {
    _releaseStick();
  }

  void _updateOffset(Offset localPos) {
    final center = Offset(widget.size / 2, widget.size / 2);
    final delta = localPos - center;
    final dist = delta.distance;

    Offset clampedOffset;
    if (dist <= _maxRadius) {
      clampedOffset = delta;
    } else {
      clampedOffset = (delta / dist) * _maxRadius;
    }

    setState(() {
      _dragOffset = clampedOffset;
    });

    // Compute normalized stick coordinates:
    // X: -1.0 (left) to +1.0 (right)
    // Y: +1.0 (up/forward) to -1.0 (down/backward)
    final normalizedDist = clampedOffset.distance / _maxRadius;
    if (normalizedDist < widget.deadzone) {
      widget.onChanged(0.0, 0.0);
    } else {
      final normX = (clampedOffset.dx / _maxRadius).clamp(-1.0, 1.0);
      final normY = (-clampedOffset.dy / _maxRadius).clamp(-1.0, 1.0);
      widget.onChanged(normX, normY);
    }
  }

  void _releaseStick() {
    _isDragging = false;
    _recenterAnimation = Tween<Offset>(
      begin: _dragOffset,
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _recenterController,
      curve: Curves.easeOutCubic,
    ));
    _recenterController.forward(from: 0.0);

    widget.onChanged(0.0, 0.0);
    widget.onRelease?.call();
    HapticFeedback.lightImpact();
  }

  @override
  Widget build(BuildContext context) {
    final center = Offset(widget.size / 2, widget.size / 2);
    final knobPos = center + _dragOffset;

    return GestureDetector(
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      onPanCancel: _onPanCancel,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF101528),
          border: Border.all(
            color: _isDragging
                ? widget.accentColor
                : widget.accentColor.withValues(alpha: 0.4),
            width: 2.0,
          ),
          boxShadow: [
            BoxShadow(
              color: widget.accentColor.withValues(
                alpha: _isDragging ? 0.35 : 0.15,
              ),
              blurRadius: _isDragging ? 20 : 12,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Stack(
          children: [
            // Custom Painter for crosshairs and inner ring
            CustomPaint(
              size: Size(widget.size, widget.size),
              painter: _ThumbstickBasePainter(
                maxRadius: _maxRadius,
                deadzone: widget.deadzone,
                isDragging: _isDragging,
                accentColor: widget.accentColor,
              ),
            ),

            // Draggable Knob
            Positioned(
              left: knobPos.dx - widget.knobRadius,
              top: knobPos.dy - widget.knobRadius,
              child: Container(
                width: widget.knobRadius * 2,
                height: widget.knobRadius * 2,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: _isDragging
                        ? [widget.accentColor, const Color(0xFFFF007F)]
                        : [widget.accentColor, widget.accentColor.withValues(alpha: 0.5)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (_isDragging
                              ? const Color(0xFFFF007F)
                              : widget.accentColor)
                          .withValues(alpha: 0.6),
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThumbstickBasePainter extends CustomPainter {
  final double maxRadius;
  final double deadzone;
  final bool isDragging;
  final Color accentColor;

  _ThumbstickBasePainter({
    required this.maxRadius,
    required this.deadzone,
    required this.isDragging,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final linePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    // Crosshairs
    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      linePaint,
    );
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
    _drawLabel(canvas, '▲', Offset(center.dx, center.dy - maxRadius + 14));
    _drawLabel(canvas, '▼', Offset(center.dx, center.dy + maxRadius - 14));
    _drawLabel(canvas, '◀', Offset(center.dx - maxRadius + 14, center.dy));
    _drawLabel(canvas, '▶', Offset(center.dx + maxRadius - 14, center.dy));
  }

  void _drawLabel(Canvas canvas, String text, Offset position) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: accentColor.withValues(alpha: 0.45),
          fontSize: 9,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, position - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ThumbstickBasePainter oldDelegate) {
    return oldDelegate.isDragging != isDragging ||
        oldDelegate.maxRadius != maxRadius ||
        oldDelegate.deadzone != deadzone;
  }
}
