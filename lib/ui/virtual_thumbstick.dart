import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/services/vr_thumbstick_haptic_detent_controller.dart';
import '../utils/constants/vr_joystick_constants.dart';
import '../utils/enums/vr_haptic_pattern_preset.dart';
import 'vr_thumbstick_base_painter.dart';

/// Imperative bridge allowing [VrJoystickTouchIntentArbiter] to hand an
/// in-flight near-rim drag pointer directly into a mounted [VirtualThumbstick]
/// without requiring the user to lift their thumb.
class VirtualThumbstickController {
  _VirtualThumbstickState? _state;

  bool get isActive => _state?._pointer != null;

  bool beginExternalDrag({
    required int pointerId,
    required Offset globalPosition,
    Offset? anchorGlobalPosition,
  }) =>
      _state?._beginExternalDrag(
        pointerId: pointerId,
        globalPosition: globalPosition,
        anchorGlobalPosition: anchorGlobalPosition,
      ) ??
      false;

  void updateExternalDrag({
    required int pointerId,
    required Offset globalPosition,
  }) => _state?._updateExternalDrag(
    pointerId: pointerId,
    globalPosition: globalPosition,
  );

  void endExternalDrag({required int pointerId}) =>
      _state?._endExternalDrag(pointerId: pointerId);
}

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

  /// Superimposes 4 cardinal D-pad segments ("la cruz") along the outer rim of
  /// the thumbstick so 2D/3D controllers can navigate central menus without
  /// adding a separate D-pad widget or moving the analog walking stick.
  final bool enableRimDpad;

  /// Invoked with `(-1|0|1, -1|0|1)` when a superimposed outer-rim D-pad
  /// segment is pressed or released.
  final void Function(double dpadX, double dpadY)? onDpadChanged;

  /// Optional controller allowing [VrJoystickTouchIntentArbiter] to hand off
  /// an in-flight near-rim drag directly into this stick.
  final VirtualThumbstickController? controller;

  /// Extends the physical thumb travel radius (`_maxRadius * travelExtension`)
  /// before saturating at `100%`, giving longer, finer analog control on both
  /// Left and Right sticks while keeping the visual thumb cleanly framed.
  final double travelExtension;

  /// Optional crisp center label drawn inside the thumbstick cap (e.g.
  /// `'MOVER'` or `'MIRAR'`), matching VRlizate's 1D handheld console design.
  final String? centerLabel;

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
    this.enableRimDpad = false,
    this.onDpadChanged,
    this.controller,
    this.travelExtension = 1.0,
    this.centerLabel,
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
  bool _rimDpadGesture = false;
  double _activeRimDpadX = 0.0;
  double _activeRimDpadY = 0.0;
  final VrThumbstickHapticDetentController _detentController =
      VrThumbstickHapticDetentController();

  late AnimationController _recenterController;
  late Animation<Offset> _recenterAnimation;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
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
  void didUpdateWidget(covariant VirtualThumbstick oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      if (identical(oldWidget.controller?._state, this)) {
        oldWidget.controller?._state = null;
      }
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    // Hit-test routes retain their old Listener until the pointer ends, even
    // when a mode change or resize has already removed this widget.
    _disposed = true;
    if (identical(widget.controller?._state, this)) {
      widget.controller?._state = null;
    }
    _pointer = null;
    _isDragging = false;
    _recenterController.dispose();
    super.dispose();
  }

  double get _maxRadius => (widget.size / 2) - widget.knobRadius;

  double get _analogTravelRadius =>
      _maxRadius * widget.travelExtension.clamp(1.0, 2.0);

  Offset? _globalToLocal(Offset globalPosition) {
    final renderBox = context.findRenderObject();
    if (renderBox is! RenderBox || !renderBox.hasSize) return null;
    return renderBox.globalToLocal(globalPosition);
  }

  bool _beginExternalDrag({
    required int pointerId,
    required Offset globalPosition,
    Offset? anchorGlobalPosition,
  }) {
    if (_disposed || !mounted || _pointer != null) return false;
    final localPos = _globalToLocal(globalPosition);
    if (localPos == null) return false;
    final anchorLocal = anchorGlobalPosition == null
        ? localPos
        : (_globalToLocal(anchorGlobalPosition) ?? localPos);
    _pointer = pointerId;
    _rimDpadGesture = false;
    _recenterController.stop();
    _isDragging = true;
    _hasHitBoundary = false;
    _detentController.reset();
    // Anchor the neutral origin cleanly at the initial contact point (even if
    // it landed in the near-rim collar slightly outside the drawn circle) so
    // the drag immediately produces smooth directional motion without a jump.
    final center = Offset(widget.size / 2, widget.size / 2);
    _originOffset = Offset(
      widget.horizontalEnabled ? anchorLocal.dx - center.dx : 0.0,
      anchorLocal.dy - center.dy,
    );
    widget.onPressed?.call(true);
    if (_disposed || !mounted) return false;
    _updateOffset(localPos);
    if (!_disposed && mounted && widget.hapticsEnabled) {
      HapticFeedback.selectionClick();
    }
    return true;
  }

  void _updateExternalDrag({
    required int pointerId,
    required Offset globalPosition,
  }) {
    if (_disposed || !mounted || pointerId != _pointer) return;
    final localPos = _globalToLocal(globalPosition);
    if (localPos == null) return;
    _updateOffset(localPos);
  }

  void _endExternalDrag({required int pointerId}) {
    if (_disposed || !mounted || pointerId != _pointer) return;
    _pointer = null;
    _releaseStick();
  }

  (double, double)? _hitTestRimDpad(Offset localPos) {
    if (!widget.enableRimDpad || widget.onDpadChanged == null) return null;
    final outerRadius = widget.size / 2;
    if (outerRadius <= 0) return null;
    final dx = localPos.dx - outerRadius;
    final dy = localPos.dy - outerRadius;
    final dist = Offset(dx, dy).distance;
    // Outer 26% ring around the cardinal axes (within ~29° of N/S/E/W)
    if (dist < outerRadius * 0.74 || dist > outerRadius * 1.06) return null;
    if (dy.abs() >= dx.abs() * 1.75) {
      return (0.0, dy < 0 ? 1.0 : -1.0);
    }
    if (widget.horizontalEnabled && dx.abs() >= dy.abs() * 1.75) {
      return (dx < 0 ? -1.0 : 1.0, 0.0);
    }
    return null;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_disposed || !mounted || _pointer != null) return;
    _pointer = event.pointer;
    final rimHit = _hitTestRimDpad(event.localPosition);
    if (rimHit != null) {
      _rimDpadGesture = true;
      setState(() {
        _activeRimDpadX = rimHit.$1;
        _activeRimDpadY = rimHit.$2;
      });
      if (widget.hapticsEnabled) {
        HapticFeedback.selectionClick();
      }
      widget.onDpadChanged?.call(rimHit.$1, rimHit.$2);
      return;
    }
    _rimDpadGesture = false;
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
    if (_rimDpadGesture) return;
    _updateOffset(event.localPosition);
  }

  void _onPointerEnd(PointerEvent event) {
    if (_disposed || !mounted || event.pointer != _pointer) return;
    _pointer = null;
    if (_rimDpadGesture) {
      _rimDpadGesture = false;
      setState(() {
        _activeRimDpadX = 0.0;
        _activeRimDpadY = 0.0;
      });
      widget.onDpadChanged?.call(0.0, 0.0);
      return;
    }
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
    final travelRadius = _analogTravelRadius;

    Offset normalizedVector;
    if (dist <= travelRadius) {
      normalizedVector = delta;
      // Reset boundary tripwire when user moves back towards the center
      if (dist < travelRadius * 0.85) {
        _hasHitBoundary = false;
      }
    } else {
      normalizedVector = (delta / dist) * travelRadius;
      if (!_hasHitBoundary) {
        _hasHitBoundary = true;
        if (widget.hapticsEnabled) {
          HapticFeedback.lightImpact();
        }
      }
    }

    // Visual knob scales cleanly inside `_maxRadius` while analog travel uses
    // the full extended `travelRadius` (`+38%` longer ergonomic throw).
    final visualOffset = travelRadius > 0
        ? normalizedVector * (_maxRadius / travelRadius)
        : Offset.zero;

    setState(() {
      _dragOffset = visualOffset;
    });

    // Compute normalized stick coordinates:
    // X: -1.0 (left) to +1.0 (right)
    // Y: +1.0 (up/forward) to -1.0 (down/backward)
    final normalizedDist = travelRadius > 0
        ? normalizedVector.distance / travelRadius
        : 0.0;
    if (normalizedDist < widget.deadzone) {
      _detentController.reset();
      widget.onChanged(0.0, 0.0);
    } else {
      final normX = (normalizedVector.dx / travelRadius).clamp(-1.0, 1.0);
      final normY = (-normalizedVector.dy / travelRadius).clamp(-1.0, 1.0);
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
                enableRimDpad: widget.enableRimDpad,
                activeRimDpadX: _activeRimDpadX,
                activeRimDpadY: _activeRimDpadY,
              ),
            ),

            // Draggable Knob (styled after VRlizate's 1D OLED console thumb cap)
            Positioned(
              left: knobPos.dx - widget.knobRadius,
              top: knobPos.dy - widget.knobRadius,
              child: Container(
                width: widget.knobRadius * 2,
                height: widget.knobRadius * 2,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: _isDragging
                        ? [
                            widget.accentColor.withValues(alpha: 0.92),
                            Color.lerp(
                              const Color(0xFF0E1B33),
                              widget.accentColor,
                              0.55,
                            )!,
                          ]
                        : [
                            Color.lerp(
                              const Color(0xFF1A2A48),
                              widget.accentColor,
                              0.28,
                            )!,
                            const Color(0xFF0D162B),
                          ],
                  ),
                  border: Border.all(
                    color: _isDragging
                        ? Colors.white.withValues(alpha: 0.92)
                        : widget.accentColor.withValues(alpha: 0.85),
                    width: _isDragging ? 2.4 : 1.8,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.accentColor.withValues(
                        alpha: _isDragging ? 0.58 : 0.30,
                      ),
                      blurRadius: _isDragging ? 18 : 10,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Center(
                  child: widget.centerLabel != null
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              widget.centerLabel!,
                              maxLines: 1,
                              style: TextStyle(
                                color: _isDragging
                                    ? Colors.white
                                    : widget.accentColor.withValues(
                                        alpha: 0.94,
                                      ),
                                fontSize: (widget.knobRadius * 0.44).clamp(
                                  9.0,
                                  14.0,
                                ),
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                        )
                      : Container(
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
