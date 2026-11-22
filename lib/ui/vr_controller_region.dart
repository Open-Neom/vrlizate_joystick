import 'package:flutter/material.dart';

import 'vr_region_clipper.dart';
import 'vr_region_painter.dart';

/// The same concave path clips both paint and pointer hit testing.
/// A finger owns its original region until release/cancel; another finger on
/// that region cannot steal ownership or release the first finger's button.
class VrControllerRegion extends StatefulWidget {
  const VrControllerRegion({
    super.key,
    required this.path,
    required this.labelPosition,
    required this.label,
    this.actionLabel,
    required this.colors,
    required this.active,
    required this.onDown,
    required this.onUp,
    this.textColor = Colors.white,
    this.onPointerDownIntercept,
    this.onPointerMoveIntercept,
    this.onPointerEndIntercept,
  });
  final Path path;
  final Offset labelPosition;
  final String label;
  final String? actionLabel;
  final List<Color> colors;
  final bool active;
  final Color textColor;
  final VoidCallback onDown, onUp;

  /// Optional pointer-intent interception hooks used by `PhoneControllerPage`
  /// to infer whether a near-rim touch was intended for the adjacent thumbstick
  /// rather than this button. When [onPointerDownIntercept] is provided, it
  /// owns calling [onDown] / [onUp] (or handing the pointer to the stick).
  final void Function(PointerDownEvent event)? onPointerDownIntercept;
  final void Function(PointerMoveEvent event)? onPointerMoveIntercept;
  final void Function(PointerEvent event, {required bool cancelled})?
  onPointerEndIntercept;

  @override
  State<VrControllerRegion> createState() => _VrControllerRegionState();
}

class _VrControllerRegionState extends State<VrControllerRegion> {
  int? _owner;

  void _release(PointerEvent event, {required bool cancelled}) {
    if (event.pointer != _owner) return;
    _owner = null;
    if (widget.onPointerEndIntercept != null) {
      widget.onPointerEndIntercept!(event, cancelled: cancelled);
      return;
    }
    widget.onUp();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.colors.isNotEmpty
        ? widget.colors.first
        : widget.textColor;
    final showSubtitle =
        widget.actionLabel != null &&
        widget.actionLabel!.trim().isNotEmpty &&
        widget.actionLabel!.trim().toUpperCase() !=
            widget.label.trim().toUpperCase();
    return ClipPath(
      clipper: VrRegionClipper(widget.path),
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (_owner != null) return;
          _owner = event.pointer;
          if (widget.onPointerDownIntercept != null) {
            widget.onPointerDownIntercept!(event);
            return;
          }
          widget.onDown();
        },
        onPointerMove: (event) {
          if (event.pointer != _owner) return;
          widget.onPointerMoveIntercept?.call(event);
        },
        onPointerUp: (event) => _release(event, cancelled: false),
        onPointerCancel: (event) => _release(event, cancelled: true),
        child: Semantics(
          button: true,
          label: widget.actionLabel == null || widget.actionLabel == widget.label
              ? widget.label
              : '${widget.label} · ${widget.actionLabel}',
          excludeSemantics: true,
          onTap: () {
            if (_owner != null) return;
            widget.onDown();
            widget.onUp();
          },
          child: CustomPaint(
            painter: VrRegionPainter(widget.path, widget.colors, widget.active),
            child: Stack(
              children: [
                Positioned(
                  left: widget.labelPosition.dx - 34,
                  top: widget.labelPosition.dy - 28,
                  width: 68,
                  height: 56,
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.label,
                            style: TextStyle(
                              color: widget.active ? Colors.white : accent,
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withValues(alpha: 0.65),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                          if (showSubtitle) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.actionLabel!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white.withValues(
                                  alpha: widget.active ? 0.96 : 0.78,
                                ),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                height: 1.0,
                              ),
                            ),
                          ],
                        ],
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
}
