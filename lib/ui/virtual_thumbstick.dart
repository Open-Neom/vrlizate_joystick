import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/services/vr_thumbstick_haptic_detent_controller.dart';
import '../utils/constants/vr_joystick_constants.dart';
import '../utils/enums/vr_haptic_pattern_preset.dart';
import 'vr_thumbstick_base_painter.dart';

/// Interactive on-screen Virtual Analog Thumbstick for VR/Gamepad navigation.
///
/// Features:
/// - 360-degree continuous analog vector $(x, y) \in [-1.0, 1.0]$.
/// - Configurable deadzone threshold to avoid sensor and finger drift.
/// - Optional **Dynamic / Floating Touch Origin** ([dynamicTouchOrigin],
///   inspired by `nipplejs` & `AirConsole`) so blind thumb contact while
///   wearing a VR headset anchors the `(0, 0)` center where the thumb lands.
/// - **Radial & Cardinal Haptic Detents** ([enableCardinalDetents], inspired by
///   `Steam Controller` & `VirtualGamePad`) at 50% walk ring, 92% sprint rim,
///   and the 4 cardinal axes ($0^\circ, 90^\circ, 180^\circ, 270^\circ$).
/// - Automatic spring recenter upon finger release (or visual forward latch
///   when [isAutoWalkLocked] is active).
class VirtualThumbstick extends StatefulWidget {
  /// Diameter of the outer base area in pixels.
  final double size;

  /// Radius of the inner draggable knob in pixels.
  final double knobRadius;

  /// Normalized distance threshold under which output is zeroed.
  final double deadzone;

  /// Constrain both the visible thumb and its output to vertical travel.
  final bool horizontalEnabled;

  /// Callback delivering normalized coordinates:
  /// - `x`: -1.0 (Left) to +1.0 (Right)
  /// - `y`: +1.0 (Forward/Up) to -1.0 (Backward/Down)
  final void Function(double stickX, double stickY) onChanged;

  /// Reports the owning finger's contact immediately, including at the center.
  /// Additional fingers cannot take over or prolong this contact.
  final ValueChanged<bool>? onPressed;

  /// Optional callback invoked when the stick returns to center.
  final VoidCallback? onRelease;

  /// Optional accent color for borders and highlights (defaults to neon cyan).
  final Color accentColor;

  /// Whether tactile haptic feedback / vibration is enabled for touch, boundary, and release.
  final bool hapticsEnabled;

  /// When true, the initial pointer-down position (clamped within
  /// [maxDynamicOriginRatio] of the travel radius) becomes the `(0, 0)` origin
  /// for that drag gesture so off-center blind thumb contact does not cause
  /// unintended initial movement or turning.
  final bool dynamicTouchOrigin;

  /// Maximum fraction of `_maxRadius` that [dynamicTouchOrigin] can shift the
  /// origin from the geometric center, guaranteeing full 100% rim deflection.
  final double maxDynamicOriginRatio;

  /// Whether 50% mid-ring and 4-way cardinal axis haptic detents are enabled.
  final bool enableCardinalDetents;

  /// Whether Auto-Walk / Sprint Lock is currently holding the knob at the top
  /// forward position.
  final bool isAutoWalkLocked;

  const VirtualThumbstick({
    super.key,
    this.size = 150.0,
    this.knobRadius = 28.0,
    this.deadzone = 0.08,
    this.horizontalEnabled = true,
    this.accentColor = const Color(0xFF00E5FF),
    this.hapticsEnabled = true,
    this.dynamicTouchOrigin = false,
    this.maxDynamicOriginRatio =
        VrJoystickConstants.defaultDynamicOriginMaxRatio,
    this.enableCardinalDetents = true,
    this.isAutoWalkLocked = false,
    required this.onChanged,
    this.onRelease,
    this.onPressed,
  });

  @override
  State<VirtualThumbstick> createState() => _VirtualThumbstickState();
}

class _VirtualThumbstickState extends State<VirtualThumbstick>
    with SingleTickerProviderStateMixin {
  Offset _dragOffset = Offset.zero;
  Offset _originOffset = Offset.zero;
  bool _isDragging = false;
  bool _hasHitBoundary = false;
  bool _disposed = false;
  int? _pointer;
  final VrThumbstickHapticDetentController _detentController =
      VrThumbstickHapticDetentController();

  late AnimationController _recenterController;
  late Animation<Offset> _recenterAnimation;

  @override
  void initState() {
    super.initState();
    _recenterController =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 120),
        )..addListener(() {
          if (_disposed || !mounted) return;
          setState(() {
            _dragOffset = _recenterAnimation.value;
          });
        });
  }

  @override
  void dispose() {
    // Hit-test routes retain their old Listener until the pointer ends, even
    // when a mode change or resize has already removed this widget.
    _disposed = true;
    _pointer = null;
    _isDragging = false;
    _recenterController.dispose();
    super.dispose();
  }

  double get _maxRadius => (widget.size / 2) - widget.knobRadius;

  void _onPointerDown(PointerDownEvent event) {
    if (_disposed || !mounted || _pointer != null) return;
    _pointer = event.pointer;
    _recenterController.stop();
    _isDragging = true;
    _hasHitBoundary = false;
    _detentController.reset();
    if (widget.dynamicTouchOrigin) {
      final center = Offset(widget.size / 2, widget.size / 2);
      final rawOrigin = Offset(
        widget.horizontalEnabled ? event.localPosition.dx - center.dx : 0.0,
        event.localPosition.dy - center.dy,
      );
      final maxOriginDist =
          _maxRadius * widget.maxDynamicOriginRatio.clamp(0.0, 0.75);
      final dist = rawOrigin.distance;
      _originOffset = dist <= maxOriginDist || dist == 0
          ? rawOrigin
          : (rawOrigin / dist) * maxOriginDist;
    } else {
      _originOffset = Offset.zero;
    }
    widget.onPressed?.call(true);
    if (_disposed || !mounted) return;
    _updateOffset(event.localPosition);
    if (!_disposed && mounted && widget.hapticsEnabled) {
      HapticFeedback.selectionClick();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_disposed || !mounted || event.pointer != _pointer) return;
    _updateOffset(event.localPosition);
  }

  void _onPointerEnd(PointerEvent event) {
    if (_disposed || !mounted || event.pointer != _pointer) return;
    _pointer = null;
    _releaseStick();
  }

  void _updateOffset(Offset localPos) {
    if (_disposed || !mounted || _pointer == null) return;
    final center = Offset(widget.size / 2, widget.size / 2) + _originOffset;
    final delta = Offset(
      widget.horizontalEnabled ? localPos.dx - center.dx : 0,
      localPos.dy - center.dy,
    );
    final dist = delta.distance;

    Offset clampedOffset;
    if (dist <= _maxRadius) {
      clampedOffset = delta;
      // Reset boundary tripwire when user moves back towards the center
      if (dist < _maxRadius * 0.85) {
        _hasHitBoundary = false;
      }
    } else {
      clampedOffset = (delta / dist) * _maxRadius;
      if (!_hasHitBoundary) {
        _hasHitBoundary = true;
        if (widget.hapticsEnabled) {
          HapticFeedback.lightImpact();
        }
      }
    }

    setState(() {
      _dragOffset = clampedOffset;
    });

    // Compute normalized stick coordinates:
    // X: -1.0 (left) to +1.0 (right)
    // Y: +1.0 (up/forward) to -1.0 (down/backward)
    final normalizedDist = clampedOffset.distance / _maxRadius;
    if (normalizedDist < widget.deadzone) {
      _detentController.reset();
      widget.onChanged(0.0, 0.0);
    } else {
      final normX = (clampedOffset.dx / _maxRadius).clamp(-1.0, 1.0);
      final normY = (-clampedOffset.dy / _maxRadius).clamp(-1.0, 1.0);
      final detent = _detentController.evaluate(
        normX,
        normY,
        enableCardinalDetents: widget.enableCardinalDetents,
      );
      if (detent == VrHapticPatternPreset.lightTap &&
          widget.hapticsEnabled &&
          widget.enableCardinalDetents) {
        HapticFeedback.selectionClick();
      }
      widget.onChanged(normX, normY);
    }
  }

  void _releaseStick() {
    if (_disposed || !mounted || !_isDragging) return;
    _isDragging = false;
    _hasHitBoundary = false;
    _originOffset = Offset.zero;
    _detentController.reset();
    _recenterAnimation = Tween<Offset>(begin: _dragOffset, end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _recenterController,
            curve: Curves.easeOutCubic,
          ),
        );
    _recenterController.forward(from: 0.0);

    widget.onChanged(0.0, 0.0);
    if (_disposed || !mounted) return;
    widget.onPressed?.call(false);
    if (_disposed || !mounted) return;
    widget.onRelease?.call();
    if (!_disposed && mounted && widget.hapticsEnabled) {
      HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = Offset(widget.size / 2, widget.size / 2);
    final effectiveOffset = !_isDragging && widget.isAutoWalkLocked
        ? Offset(0, -_maxRadius * 0.92)
        : _dragOffset;
    final knobPos = center + effectiveOffset;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
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
              painter: VrThumbstickBasePainter(
                maxRadius: _maxRadius,
                deadzone: widget.deadzone,
                isDragging: _isDragging,
                accentColor: widget.accentColor,
                horizontalEnabled: widget.horizontalEnabled,
                originOffset: _originOffset,
                isAutoWalkLocked: widget.isAutoWalkLocked,
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
                        : [
                            widget.accentColor,
                            widget.accentColor.withValues(alpha: 0.5),
                          ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          (_isDragging
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
