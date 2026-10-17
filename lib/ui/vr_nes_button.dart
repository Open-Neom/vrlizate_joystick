import 'package:flutter/material.dart';

import '../utils/constants/vr_joystick_constants.dart';

class VrNesButton extends StatefulWidget {
  const VrNesButton({
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
  State<VrNesButton> createState() => _VrNesButtonState();
}

class _VrNesButtonState extends State<VrNesButton> {
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
                    color: widget.label == VrJoystickConstants.nesLabelHome
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
