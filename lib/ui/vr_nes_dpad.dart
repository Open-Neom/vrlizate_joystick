import 'package:flutter/material.dart';

import '../utils/constants/vr_joystick_constants.dart';
import '../utils/constants/vr_joystick_translation_constants.dart';
import 'vr_nes_dpad_painter.dart';

class VrNesDpad extends StatefulWidget {
  const VrNesDpad({super.key, required this.onChanged});
  final void Function(double x, double y) onChanged;
  @override
  State<VrNesDpad> createState() => _VrNesDpadState();
}

class _VrNesDpadState extends State<VrNesDpad> {
  final _pointers = <int, Offset>{};
  double _x = 0, _y = 0;
  void _update(Size size) {
    var left = false, right = false, up = false, down = false;
    for (final point in _pointers.values) {
      if (!(Offset.zero & size).contains(point)) continue;
      final x = (point.dx / size.width - .5) * 2;
      final y = (.5 - point.dy / size.height) * 2;
      left |= x < -.28;
      right |= x > .28;
      up |= y > .28;
      down |= y < -.28;
    }
    final x = (right ? 1.0 : 0.0) - (left ? 1.0 : 0.0);
    final y = (up ? 1.0 : 0.0) - (down ? 1.0 : 0.0);
    if (_x == x && _y == y) return;
    // The page owns the visible controller state and rebuilds after accepting
    // this change. Never setState from cancellation of an obsolete surface.
    _x = x;
    _y = y;
    widget.onChanged(x, y);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      void release(PointerEvent event) {
        _pointers.remove(event.pointer);
        _update(size);
      }

      return Listener(
        key: const ValueKey(VrJoystickConstants.keyNesDpad),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          _pointers[event.pointer] = event.localPosition;
          _update(size);
        },
        onPointerMove: (event) {
          if (!_pointers.containsKey(event.pointer)) return;
          _pointers[event.pointer] = event.localPosition;
          _update(size);
        },
        onPointerUp: release,
        onPointerCancel: release,
        child: Semantics(
          label: VrJoystickTranslationConstants.nesDpadSemantics,
          child: CustomPaint(painter: VrNesDpadPainter(_x, _y)),
        ),
      );
    },
  );
}
