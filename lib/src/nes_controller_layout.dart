import 'dart:math' as math;

import 'package:flutter/material.dart';

/// NES-shaped touch surface. Button names here describe the visible controls;
/// the parent retains ownership of protocol mapping and session neutralization.
class NesControllerLayout extends StatelessWidget {
  const NesControllerLayout({
    super.key,
    required this.onDirection,
    required this.onButton,
    required this.onSettings,
    required this.connected,
    required this.pressed,
    required this.captions,
    this.onConnect,
    this.preview,
  });

  final void Function(double x, double y) onDirection;
  final void Function(String button, bool down) onButton;
  final VoidCallback onSettings;
  final VoidCallback? onConnect;
  final Widget? preview;
  final bool connected;
  final Set<String> pressed;
  final Map<String, String> captions;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('nes_surface'),
    color: const Color(0xFFC6C4BC),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final small = constraints.maxWidth < 650;
            Widget button(String id, String label, {bool red = false}) =>
                _NesButton(
                  key: ValueKey('nes_button_$id'),
                  label: label,
                  caption: captions[id],
                  active: pressed.contains(id),
                  red: red,
                  onChanged: (down) => onButton(id, down),
                );
            return Column(
              children: [
                SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      const Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'VRLIZATE  /  NES',
                            style: TextStyle(
                              color: Color(0xFF972F36),
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: onConnect,
                        icon: Icon(
                          Icons.bluetooth_connected,
                          size: 15,
                          color: connected
                              ? const Color(0xFF28725D)
                              : const Color(0xFF6E655D),
                        ),
                        label: Text(
                          connected ? 'VINCULADO' : 'CONECTAR',
                          style: TextStyle(
                            fontSize: small ? 9 : 11,
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF3C4245),
                          ),
                        ),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: small ? 94 : 148,
                        child: button('home', 'HOME'),
                      ),
                      SizedBox(
                        width: 34,
                        child: IconButton(
                          tooltip: 'Ajustes y Modo',
                          onPressed: onSettings,
                          padding: EdgeInsets.zero,
                          icon: const Icon(
                            Icons.settings_rounded,
                            color: Color(0xFF404548),
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF24282B),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0xFF8F918A),
                        width: 3,
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(small ? 10 : 16),
                      child: LayoutBuilder(
                        builder: (context, body) {
                          final pad = math.min(
                            body.maxHeight - 16,
                            body.maxWidth * .33,
                          );
                          final actionSize = math.min(
                            body.maxHeight * .52,
                            body.maxWidth * .155,
                          );
                          return Row(
                            children: [
                              Expanded(
                                flex: 36,
                                child: Center(
                                  child: SizedBox.square(
                                    dimension: math.max(48, pad),
                                    child: _NesDpad(onChanged: onDirection),
                                  ),
                                ),
                              ),
                              Expanded(
                                flex: 27,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child:
                                          preview ??
                                          Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              for (var i = 0; i < 3; i++)
                                                Container(
                                                  height: small ? 7 : 10,
                                                  margin:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                        vertical: 2,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFF505557,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    SizedBox(
                                      height: small ? 62 : 72,
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: button('select', 'SELECT'),
                                          ),
                                          const SizedBox(width: 7),
                                          Expanded(
                                            child: button('start', 'START'),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    const FittedBox(
                                      child: Text(
                                        'CONTROL CLÁSICO',
                                        style: TextStyle(
                                          color: Color(0xFFADB3B3),
                                          fontSize: 10,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                flex: 37,
                                child: Center(
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      SizedBox(
                                        width: actionSize,
                                        height: actionSize + 30,
                                        child: button('B', 'B', red: true),
                                      ),
                                      SizedBox(
                                        width: actionSize,
                                        height: actionSize + 30,
                                        child: button('A', 'A', red: true),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _NesButton extends StatefulWidget {
  const _NesButton({
    super.key,
    required this.label,
    required this.active,
    required this.onChanged,
    this.caption,
    this.red = false,
  });
  final String label;
  final String? caption;
  final bool active, red;
  final ValueChanged<bool> onChanged;
  @override
  State<_NesButton> createState() => _NesButtonState();
}

class _NesButtonState extends State<_NesButton> {
  final _pointers = <int>{};
  void _release(PointerEvent event) {
    if (!_pointers.remove(event.pointer)) return;
    if (_pointers.isEmpty) widget.onChanged(false);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '${widget.label} ${widget.caption ?? ''}'.trim(),
    onTap: () {
      if (_pointers.isNotEmpty) return;
      widget.onChanged(true);
      widget.onChanged(false);
    },
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (_pointers.add(event.pointer) && _pointers.length == 1) {
          widget.onChanged(true);
        }
      },
      onPointerUp: _release,
      onPointerCancel: _release,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              margin: EdgeInsets.all(widget.red ? 3 : 0),
              decoration: BoxDecoration(
                shape: widget.red ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: widget.red ? null : BorderRadius.circular(9),
                color: widget.red
                    ? (widget.active
                          ? const Color(0xFFFF7772)
                          : const Color(0xFFC83342))
                    : (widget.active
                          ? const Color(0xFF858E91)
                          : const Color(0xFF454D51)),
                border: Border.all(
                  color: widget.active ? Colors.white : const Color(0xFF73797A),
                  width: widget.active ? 3 : 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .35),
                    blurRadius: 2,
                    offset: Offset(0, widget.active ? 0 : 3),
                  ),
                ],
              ),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        color: const Color(0xFFFFF9EE),
                        fontSize: widget.red ? 36 : 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (widget.caption?.isNotEmpty ?? false) ...[
            const SizedBox(height: 5),
            SizedBox(
              height: widget.red ? 19 : 13,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  widget.caption!,
                  style: TextStyle(
                    color: widget.label == 'HOME'
                        ? const Color(0xFF43484A)
                        : const Color(0xFFD1D1C9),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _NesDpad extends StatefulWidget {
  const _NesDpad({required this.onChanged});
  final void Function(double x, double y) onChanged;
  @override
  State<_NesDpad> createState() => _NesDpadState();
}

class _NesDpadState extends State<_NesDpad> {
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
        key: const ValueKey('nes_dpad'),
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
          label: 'Cruceta NES, ocho direcciones',
          child: CustomPaint(painter: _DpadPainter(_x, _y)),
        ),
      );
    },
  );
}

class _DpadPainter extends CustomPainter {
  const _DpadPainter(this.x, this.y);
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
  bool shouldRepaint(_DpadPainter oldDelegate) =>
      x != oldDelegate.x || y != oldDelegate.y;
}
