import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Concave circular cradle edge sculpted onto a [VrYinYangButtonPair] so upper
/// (`X/Y`) and lower (`A/B`) buttons curve gracefully around the giant central
/// `MOVER` / `MIRAR` thumbstick.
enum VrYinYangCradleEdge { none, bottom, top }

/// Exact sculptural Yin-Yang S-curve geometry shared between VRlizate's 1D
/// handheld console and 2D dedicated smartphone joystick decks.
abstract final class VrYinYangGeometry {
  static const double _seamHalfGap = 2.0;

  /// Builds the disjoint interlocking [lowerLeft] (`X` / `A`) and [upperRight]
  /// (`Y` / `B`) lobe paths inside [size], optionally sculpting a concave
  /// circular cradle along [cradleEdge] to hug an adjacent oversized stick.
  static ({Path lowerLeft, Path upperRight}) buildPaths(
    Size size, {
    VrYinYangCradleEdge cradleEdge = VrYinYangCradleEdge.none,
  }) {
    final w = math.max(4.0, size.width);
    final h = math.max(4.0, size.height);
    final radius = math.min(h * 0.48, 42.0);
    var outer = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(1.0, 1.0, math.max(2.0, w - 2.0), math.max(2.0, h - 2.0)),
          Radius.circular(radius),
        ),
      );

    if (cradleEdge != VrYinYangCradleEdge.none && w >= 60.0 && h >= 28.0) {
      // Sculpt a smooth concave cradle arc at the center of the stick-facing
      // edge while keeping both outer wing lobes lush and deep.
      final archDepth = (h * 0.22).clamp(4.0, 18.0);
      final archHalfW = w * 0.30;
      final circleRadius =
          (archHalfW * archHalfW + archDepth * archDepth) / (2.0 * archDepth);
      final centerY = cradleEdge == VrYinYangCradleEdge.bottom
          ? (h - archDepth + circleRadius)
          : (archDepth - circleRadius);
      final cradleCutout = Path()
        ..addOval(
          Rect.fromCircle(
            center: Offset(w * 0.5, centerY),
            radius: circleRadius,
          ),
        );
      outer = Path.combine(PathOperation.difference, outer, cradleCutout);
    }

    final p0x = w * 0.45;
    final c1x = w * 0.36;
    final c1y = h * 0.56;
    final c2x = w * 0.74;
    final c2y = h * 0.64;
    final p3y = h * 0.74;
    const g = _seamHalfGap;

    final lowerRaw = Path()
      ..moveTo(-8, -8)
      ..lineTo(p0x - g, -8)
      ..lineTo(p0x - g, 0)
      ..cubicTo(c1x - g, c1y + g, c2x - g, c2y + g, w + 4, p3y + g)
      ..lineTo(w + 8, h + 8)
      ..lineTo(-8, h + 8)
      ..close();

    final upperRaw = Path()
      ..moveTo(p0x + g, -8)
      ..lineTo(w + 8, -8)
      ..lineTo(w + 8, p3y - g)
      ..cubicTo(c2x + g, c2y - g, c1x + g, c1y - g, p0x + g, 0)
      ..close();

    return (
      lowerLeft: Path.combine(PathOperation.intersect, outer, lowerRaw),
      upperRight: Path.combine(PathOperation.intersect, outer, upperRaw),
    );
  }

  /// Evaluates the Yin-Yang dividing S-curve Y coordinate at horizontal [x].
  static double seamYAt(double x, Size size) {
    final w = math.max(4.0, size.width);
    final h = math.max(4.0, size.height);
    final p0x = w * 0.45;
    if (x <= p0x * 0.90) return 0.0;
    final c1x = w * 0.36;
    final c1y = h * 0.56;
    final c2x = w * 0.74;
    final c2y = h * 0.64;
    final p3y = h * 0.74;
    var bestY = h * 0.5;
    var bestDist = double.infinity;
    for (var i = 0; i <= 20; i++) {
      final t = i / 20.0;
      final mt = 1.0 - t;
      final bx =
          mt * mt * mt * p0x +
          3 * mt * mt * t * c1x +
          3 * mt * t * t * c2x +
          t * t * t * w;
      final d = (bx - x).abs();
      if (d < bestDist) {
        bestDist = d;
        bestY =
            3 * mt * mt * t * c1y +
            3 * mt * t * t * c2y +
            t * t * t * p3y;
      }
    }
    return bestY;
  }

  /// Visual/label core center of the lower-left lobe (`X` / `A`) in local coords.
  static Offset lowerLeftCenter(Size size) =>
      Offset(size.width * 0.24, size.height * 0.56);

  /// Visual/label core center of the upper-right lobe (`Y` / `B`) in local coords.
  static Offset upperRightCenter(Size size) =>
      Offset(size.width * 0.75, size.height * 0.34);

  /// Returns `true` when [local] hits the lower-left lobe (`X` / `A`), or
  /// `false` when it hits the upper-right lobe (`Y` / `B`).
  static bool hitsLowerLeft(
    Offset local,
    Size size, {
    VrYinYangCradleEdge cradleEdge = VrYinYangCradleEdge.none,
  }) {
    final paths = buildPaths(size, cradleEdge: cradleEdge);
    if (paths.lowerLeft.contains(local)) return true;
    if (paths.upperRight.contains(local)) return false;
    return local.dy >= seamYAt(local.dx, size);
  }
}

/// Callback invoked when a pointer interacts with either lobe of
/// [VrYinYangButtonPair], enabling [VrJoystickTouchIntentArbiter] to infer
/// thumbstick vs button intent cleanly.
typedef VrYinYangPointerDownCallback =
    void Function(
      bool isFirstLobe,
      PointerDownEvent event,
      Offset lobeCenterLocal,
    );

typedef VrYinYangPointerMoveCallback =
    void Function(bool isFirstLobe, PointerMoveEvent event);

typedef VrYinYangPointerEndCallback =
    void Function(
      bool isFirstLobe,
      PointerEvent event, {
      required bool cancelled,
    });

/// Sculpted interlocking Yin-Yang button pair (`X/Y` or `A/B`) styled after
/// VRlizate's 1D OLED console, upscaled for dedicated 2D smartphone joysticks
/// with optional stick-vs-button touch-intent interception.
class VrYinYangButtonPair extends StatefulWidget {
  const VrYinYangButtonPair({
    super.key,
    required this.width,
    required this.height,
    this.emphasized = false,
    this.cradleEdge = VrYinYangCradleEdge.none,
    required this.firstKey,
    required this.firstPrimary,
    required this.firstCaption,
    required this.firstActive,
    required this.firstColor,
    required this.onFirstChanged,
    required this.secondKey,
    required this.secondPrimary,
    required this.secondCaption,
    required this.secondActive,
    required this.secondColor,
    required this.onSecondChanged,
    this.onPointerDownIntercept,
    this.onPointerMoveIntercept,
    this.onPointerEndIntercept,
  });

  final double width;
  final double height;
  final bool emphasized;
  final VrYinYangCradleEdge cradleEdge;

  final Key firstKey;
  final String firstPrimary;
  final String firstCaption;
  final bool firstActive;
  final Color firstColor;
  final ValueChanged<bool> onFirstChanged;

  final Key secondKey;
  final String secondPrimary;
  final String secondCaption;
  final bool secondActive;
  final Color secondColor;
  final ValueChanged<bool> onSecondChanged;

  final VrYinYangPointerDownCallback? onPointerDownIntercept;
  final VrYinYangPointerMoveCallback? onPointerMoveIntercept;
  final VrYinYangPointerEndCallback? onPointerEndIntercept;

  @override
  State<VrYinYangButtonPair> createState() => _VrYinYangButtonPairState();
}

class _VrYinYangButtonPairState extends State<VrYinYangButtonPair> {
  final Map<int, bool> _pointerLobe = <int, bool>{};
  int? _firstPointer;
  int? _secondPointer;
  bool _globalRouteAttached = false;

  bool get _usesIntercept => widget.onPointerDownIntercept != null;

  void _syncGlobalRoute() {
    final need =
        _firstPointer != null ||
        _secondPointer != null ||
        _pointerLobe.isNotEmpty;
    if (need && !_globalRouteAttached) {
      _globalRouteAttached = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    } else if (!need && _globalRouteAttached) {
      _globalRouteAttached = false;
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    }
  }

  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerUpEvent && event is! PointerCancelEvent) return;
    final cancelled = event is PointerCancelEvent;
    if (_usesIntercept) {
      final isFirst = _pointerLobe.remove(event.pointer);
      if (isFirst != null) {
        _syncGlobalRoute();
        widget.onPointerEndIntercept?.call(
          isFirst,
          event,
          cancelled: cancelled,
        );
      }
      return;
    }
    if (_firstPointer == event.pointer) {
      _releaseFirst();
    } else if (_secondPointer == event.pointer) {
      _releaseSecond();
    }
  }

  void _releaseFirst() {
    if (_firstPointer == null) return;
    _firstPointer = null;
    _syncGlobalRoute();
    widget.onFirstChanged(false);
  }

  void _releaseSecond() {
    if (_secondPointer == null) return;
    _secondPointer = null;
    _syncGlobalRoute();
    widget.onSecondChanged(false);
  }

  @override
  void deactivate() {
    _firstPointer = null;
    _secondPointer = null;
    _pointerLobe.clear();
    _syncGlobalRoute();
    super.deactivate();
  }

  @override
  void dispose() {
    _firstPointer = null;
    _secondPointer = null;
    _pointerLobe.clear();
    _syncGlobalRoute();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    final h = widget.height;
    final size = Size(w, h);
    final xlarge = h >= 76;
    final lush = h >= 60;
    final firstAnchorW = math.max(32.0, w * 0.44);
    final firstAnchorH = math.min(h, math.max(32.0, h * 0.86));
    final secondAnchorW = math.max(32.0, w * 0.48);
    final secondAnchorH = math.min(h, math.max(28.0, h * 0.64));
    final showFirstCaption =
        widget.firstCaption.trim().isNotEmpty &&
        widget.firstCaption.trim().toUpperCase() !=
            widget.firstPrimary.trim().toUpperCase();
    final showSecondCaption =
        widget.secondCaption.trim().isNotEmpty &&
        widget.secondCaption.trim().toUpperCase() !=
            widget.secondPrimary.trim().toUpperCase();

    return SizedBox(
      width: w,
      height: h,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          final isFirst = VrYinYangGeometry.hitsLowerLeft(
            event.localPosition,
            size,
            cradleEdge: widget.cradleEdge,
          );
          if (_usesIntercept) {
            _pointerLobe[event.pointer] = isFirst;
            _syncGlobalRoute();
            final lobeCenter = isFirst
                ? VrYinYangGeometry.lowerLeftCenter(size)
                : VrYinYangGeometry.upperRightCenter(size);
            widget.onPointerDownIntercept!(isFirst, event, lobeCenter);
            return;
          }
          if (isFirst) {
            if (_firstPointer != null) return;
            _firstPointer = event.pointer;
            _syncGlobalRoute();
            HapticFeedback.lightImpact();
            widget.onFirstChanged(true);
          } else {
            if (_secondPointer != null) return;
            _secondPointer = event.pointer;
            _syncGlobalRoute();
            HapticFeedback.lightImpact();
            widget.onSecondChanged(true);
          }
        },
        onPointerMove: (event) {
          if (!_usesIntercept) return;
          final isFirst = _pointerLobe[event.pointer];
          if (isFirst != null) {
            widget.onPointerMoveIntercept?.call(isFirst, event);
          }
        },
        onPointerUp: (event) {
          if (_usesIntercept) {
            final isFirst = _pointerLobe.remove(event.pointer);
            if (isFirst != null) {
              _syncGlobalRoute();
              widget.onPointerEndIntercept?.call(
                isFirst,
                event,
                cancelled: false,
              );
            }
            return;
          }
          if (_firstPointer == event.pointer) {
            _releaseFirst();
          } else if (_secondPointer == event.pointer) {
            _releaseSecond();
          }
        },
        onPointerCancel: (event) {
          if (_usesIntercept) {
            final isFirst = _pointerLobe.remove(event.pointer);
            if (isFirst != null) {
              _syncGlobalRoute();
              widget.onPointerEndIntercept?.call(
                isFirst,
                event,
                cancelled: true,
              );
            }
            return;
          }
          if (_firstPointer == event.pointer) {
            _releaseFirst();
          } else if (_secondPointer == event.pointer) {
            _releaseSecond();
          }
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _VrYinYangButtonPairPainter(
                  firstActive: widget.firstActive,
                  secondActive: widget.secondActive,
                  emphasized: widget.emphasized,
                  cradleEdge: widget.cradleEdge,
                  firstColor: widget.firstColor,
                  secondColor: widget.secondColor,
                ),
              ),
            ),
            // Lower-left lobe label + hit anchor (L / X / ZR / A)
            Positioned(
              left: 0,
              bottom: 0,
              width: firstAnchorW,
              height: firstAnchorH,
              child: IgnorePointer(
                child: Container(
                  key: widget.firstKey,
                  alignment: const Alignment(-0.10, 0.12),
                  padding: const EdgeInsets.only(
                    left: 12,
                    right: 6,
                    top: 4,
                    bottom: 4,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.firstPrimary,
                          maxLines: 1,
                          style: TextStyle(
                            color: widget.firstActive
                                ? Colors.white
                                : widget.firstColor,
                            fontSize: xlarge ? 23.0 : (lush ? 19.5 : 15.0),
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        if (showFirstCaption) ...[
                          SizedBox(height: xlarge ? 3.0 : 2.0),
                          Text(
                            widget.firstCaption,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.86),
                              fontSize: xlarge ? 10.5 : (lush ? 9.2 : 7.8),
                              fontWeight: FontWeight.w700,
                              height: 1.0,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Upper-right lobe label + hit anchor (ZL / Y / R / B)
            Positioned(
              right: 0,
              top: 0,
              width: secondAnchorW,
              height: secondAnchorH,
              child: IgnorePointer(
                child: Container(
                  key: widget.secondKey,
                  alignment: const Alignment(0.14, -0.08),
                  padding: const EdgeInsets.only(
                    left: 10,
                    right: 12,
                    top: 4,
                    bottom: 2,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.secondPrimary,
                          maxLines: 1,
                          style: TextStyle(
                            color: widget.secondActive
                                ? Colors.white
                                : widget.secondColor,
                            fontSize: xlarge ? 23.0 : (lush ? 19.5 : 15.0),
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                            decoration: TextDecoration.none,
                          ),
                        ),
                        if (showSecondCaption) ...[
                          SizedBox(height: xlarge ? 3.0 : 2.0),
                          Text(
                            widget.secondCaption,
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.86),
                              fontSize: xlarge ? 10.5 : (lush ? 9.2 : 7.8),
                              fontWeight: FontWeight.w700,
                              height: 1.0,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ],
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

class _VrYinYangButtonPairPainter extends CustomPainter {
  const _VrYinYangButtonPairPainter({
    required this.firstActive,
    required this.secondActive,
    required this.emphasized,
    required this.cradleEdge,
    required this.firstColor,
    required this.secondColor,
  });

  final bool firstActive;
  final bool secondActive;
  final bool emphasized;
  final VrYinYangCradleEdge cradleEdge;
  final Color firstColor;
  final Color secondColor;

  void _paintLobe(
    Canvas canvas,
    Size size,
    Path path, {
    required Color color,
    required bool active,
    required Offset accentDot,
  }) {
    final rect = Offset.zero & size;
    if (active || emphasized) {
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: active ? 0.36 : 0.14)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, active ? 8.0 : 4.0),
      );
    }

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: active
            ? [
                color.withValues(alpha: 0.58),
                color.withValues(alpha: 0.36),
              ]
            : [
                emphasized
                    ? const Color(0xD8182846)
                    : const Color(0xBE121D34),
                emphasized
                    ? const Color(0xCE0D182F)
                    : const Color(0xAE0B1324),
              ],
      ).createShader(rect);
    canvas.drawPath(path, fillPaint);

    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = active ? 2.4 : (emphasized ? 1.9 : 1.55)
      ..color = active || emphasized ? color : color.withValues(alpha: 0.78);
    canvas.drawPath(path, borderPaint);

    canvas.drawCircle(
      accentDot,
      2.4,
      Paint()
        ..color = active
            ? Colors.white.withValues(alpha: 0.92)
            : color.withValues(alpha: 0.68),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final paths = VrYinYangGeometry.buildPaths(size, cradleEdge: cradleEdge);
    final dotLowerY = cradleEdge == VrYinYangCradleEdge.bottom ? 0.78 : 0.87;
    final dotUpperY = cradleEdge == VrYinYangCradleEdge.top ? 0.30 : 0.22;
    _paintLobe(
      canvas,
      size,
      paths.lowerLeft,
      color: firstColor,
      active: firstActive,
      accentDot: Offset(size.width * 0.86, size.height * dotLowerY),
    );
    _paintLobe(
      canvas,
      size,
      paths.upperRight,
      color: secondColor,
      active: secondActive,
      accentDot: Offset(size.width * 0.56, size.height * dotUpperY),
    );
  }

  @override
  bool shouldRepaint(covariant _VrYinYangButtonPairPainter oldDelegate) =>
      oldDelegate.firstActive != firstActive ||
      oldDelegate.secondActive != secondActive ||
      oldDelegate.emphasized != emphasized ||
      oldDelegate.cradleEdge != cradleEdge ||
      oldDelegate.firstColor != firstColor ||
      oldDelegate.secondColor != secondColor;
}

/// Rounded dark-glass shoulder button pill matching VRlizate's 1D top shoulder
/// (`L · Escribir`, `ZL · Turbo`, `ZR · Saltar`, `R · Menú`) with optional
/// pointer-intent interception for seamless stick handoff.
class VrDeckShoulderPill extends StatefulWidget {
  const VrDeckShoulderPill({
    super.key,
    required this.buttonKey,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.accent,
    required this.onChanged,
    this.leadingIcon,
    this.onPointerDownIntercept,
    this.onPointerMoveIntercept,
    this.onPointerEndIntercept,
  });

  final Key buttonKey;
  final String title;
  final String subtitle;
  final bool active;
  final Color accent;
  final ValueChanged<bool> onChanged;
  final IconData? leadingIcon;
  final void Function(PointerDownEvent event)? onPointerDownIntercept;
  final void Function(PointerMoveEvent event)? onPointerMoveIntercept;
  final void Function(PointerEvent event, {required bool cancelled})?
  onPointerEndIntercept;

  @override
  State<VrDeckShoulderPill> createState() => _VrDeckShoulderPillState();
}

class _VrDeckShoulderPillState extends State<VrDeckShoulderPill> {
  int? _pointer;
  bool _globalRouteAttached = false;

  bool get _usesIntercept => widget.onPointerDownIntercept != null;

  void _syncGlobalRoute() {
    final need = _pointer != null;
    if (need && !_globalRouteAttached) {
      _globalRouteAttached = true;
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    } else if (!need && _globalRouteAttached) {
      _globalRouteAttached = false;
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    }
  }

  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerUpEvent && event is! PointerCancelEvent) return;
    if (_pointer != event.pointer) return;
    _pointer = null;
    _syncGlobalRoute();
    if (_usesIntercept) {
      widget.onPointerEndIntercept?.call(
        event,
        cancelled: event is PointerCancelEvent,
      );
    } else {
      widget.onChanged(false);
    }
  }

  @override
  void dispose() {
    _pointer = null;
    _syncGlobalRoute();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      key: widget.buttonKey,
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        if (_pointer != null) return;
        _pointer = event.pointer;
        _syncGlobalRoute();
        if (_usesIntercept) {
          widget.onPointerDownIntercept!(event);
        } else {
          HapticFeedback.lightImpact();
          widget.onChanged(true);
        }
      },
      onPointerMove: (event) {
        if (_pointer == event.pointer && _usesIntercept) {
          widget.onPointerMoveIntercept?.call(event);
        }
      },
      onPointerUp: (event) {
        if (_pointer != event.pointer) return;
        _pointer = null;
        _syncGlobalRoute();
        if (_usesIntercept) {
          widget.onPointerEndIntercept?.call(event, cancelled: false);
        } else {
          widget.onChanged(false);
        }
      },
      onPointerCancel: (event) {
        if (_pointer != event.pointer) return;
        _pointer = null;
        _syncGlobalRoute();
        if (_usesIntercept) {
          widget.onPointerEndIntercept?.call(event, cancelled: true);
        } else {
          widget.onChanged(false);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: widget.active
                ? [
                    widget.accent.withValues(alpha: 0.52),
                    widget.accent.withValues(alpha: 0.30),
                  ]
                : [
                    const Color(0xC814213B),
                    const Color(0xB40C1527),
                  ],
          ),
          border: Border.all(
            color: widget.active
                ? widget.accent
                : widget.accent.withValues(alpha: 0.62),
            width: widget.active ? 2.0 : 1.35,
          ),
          boxShadow: widget.active
              ? [
                  BoxShadow(
                    color: widget.accent.withValues(alpha: 0.34),
                    blurRadius: 10,
                  ),
                ]
              : const [],
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.leadingIcon != null) ...[
                Icon(
                  widget.leadingIcon,
                  size: 14,
                  color: widget.active ? Colors.white : widget.accent,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                widget.title,
                maxLines: 1,
                style: TextStyle(
                  color: widget.active ? Colors.white : const Color(0xFFF8FAFC),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.2,
                  decoration: TextDecoration.none,
                ),
              ),
              if (widget.subtitle.isNotEmpty)
                Text(
                  ' · ${widget.subtitle}',
                  maxLines: 1,
                  style: TextStyle(
                    color: widget.active
                        ? Colors.white.withValues(alpha: 0.92)
                        : const Color(0xFFCBD5E1),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.15,
                    decoration: TextDecoration.none,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Deterministic responsive layout for VRlizate's **1D-Matching Symmetrical
/// Yin-Yang 2D Gamepad** (`PhoneControllerPage`).
///
/// Gives both wings the exact 1D deck layout upscaled for dedicated 2D
/// smartphone controllers:
/// - **Left Deck:** Top `L` Shoulder Pill → Upper Yin-Yang (`X` / `Y`) →
///   Center `MOVER` Stick (Double-Tap = Turbo) → Lower Yin-Yang (`A` / `B`).
/// - **Right Deck:** Top `R` Shoulder Pill → Upper Yin-Yang (`X` / `Y`) →
///   Center Equal-Size `MIRAR` Stick (Double-Tap = Láser) → Lower Yin-Yang
///   (`A` / `B`).
/// - **Center Column:** Chrome bar, `Recenter`, `Vista / Láser` + Preview, and
///   status footer.
class Vr2dYinYangDeckLayout {
  const Vr2dYinYangDeckLayout({
    required this.leftDeck,
    required this.rightDeck,
    required this.centerPanel,
    required this.recenterRect,
    required this.previewPanel,
    required this.footerHeight,
    required this.deckPadding,
    required this.gap,
    required this.shoulderHeight,
    required this.yinYangHeight,
    required this.stickSize,
    required this.leftShoulderRect,
    required this.rightShoulderRect,
    required this.leftStickRect,
    required this.rightStickRect,
    required this.leftTopPairRect,
    required this.leftBottomPairRect,
    required this.rightTopPairRect,
    required this.rightBottomPairRect,
  });

  final Rect leftDeck;
  final Rect rightDeck;
  final Rect centerPanel;
  final Rect recenterRect;
  final Rect previewPanel;
  final double footerHeight;
  final double deckPadding;
  final double gap;
  final double shoulderHeight;
  final double yinYangHeight;
  final double stickSize;
  final Rect leftShoulderRect;
  final Rect rightShoulderRect;
  final Rect leftStickRect;
  final Rect rightStickRect;
  final Rect leftTopPairRect;
  final Rect leftBottomPairRect;
  final Rect rightTopPairRect;
  final Rect rightBottomPairRect;

  factory Vr2dYinYangDeckLayout.fit(
    Size size, {
    double leftInset = 0,
    double rightInset = 0,
    double topInset = 0,
    double bottomInset = 0,
  }) {
    final w = size.width;
    final h = size.height;
    // Use full vertical screen height (minimal 2 dp edge trim) and keep
    // horizontal safe insets only for camera punch-holes so BOTH decks and all
    // buttons + joysticks fill the full screen cleanly.
    final padL = math.max(2.0, leftInset);
    final padR = math.max(2.0, rightInset);
    final padT = math.max(2.0, topInset);
    final padB = math.max(2.0, bottomInset);
    final safeW = math.max(120.0, w - padL - padR);
    final safeH = math.max(100.0, h - padT - padB);

    final spacious = safeW >= 720 && safeH >= 340;
    final deckPad = spacious ? 4.0 : 3.0;
    final gap = spacious ? 3.5 : 2.5;
    final deckGap = spacious ? 6.0 : 4.0;

    // Tighten center column (~26.5% width) so Left & Right decks get lush,
    // full-size width (~36% each) for giant sticks and large sculpted buttons.
    final centerW = (safeW * 0.265).clamp(
      math.min(132.0, safeW * 0.32),
      math.min(256.0, safeW * 0.34),
    );
    final deckW = math.max(88.0, (safeW - centerW - deckGap * 2) / 2.0);
    final innerW = math.max(64.0, deckW - deckPad * 2);

    final leftDeck = Rect.fromLTWH(padL, padT, deckW, safeH);
    final rightDeck = Rect.fromLTWH(w - padR - deckW, padT, deckW, safeH);
    final centerLeft = leftDeck.right + deckGap;
    final centerWidth = math.max(60.0, rightDeck.left - deckGap - centerLeft);
    final centerPanel = Rect.fromLTWH(centerLeft, 0, centerWidth, h);

    // Full-height 4-row sculpted stack inside each deck:
    // Top L/R Shoulder Pill -> Upper X/Y Curved Yin-Yang -> Giant MOVER/MIRAR Stick
    // -> Lower A/B Curved Yin-Yang, stretching edge-to-edge with zero wasted margin!
    final availH = math.max(84.0, safeH - deckPad * 2 - gap * 3);
    final shoulderH = (safeH * 0.105).clamp(26.0, spacious ? 42.0 : 34.0);
    final bodyH = math.max(60.0, availH - shoulderH);
    final stickSize = math.min(
      innerW,
      (bodyH * 0.56).clamp(56.0, spacious ? 248.0 : 196.0),
    );
    final yinYangH = math.max(26.0, (bodyH - stickSize) / 2.0);

    final stackH = shoulderH + yinYangH * 2 + stickSize + gap * 3;
    final yStart = padT + math.max(deckPad, (safeH - stackH) / 2.0);

    Rect makeDeckRow(Rect deck, double y, double rowH) =>
        Rect.fromLTWH(deck.left + deckPad, y, innerW, rowH);

    final shoulderY = yStart;
    final topPairY = shoulderY + shoulderH + gap;
    final stickY = topPairY + yinYangH + gap;
    final bottomPairY = stickY + stickSize + gap;

    final leftShoulder = makeDeckRow(leftDeck, shoulderY, shoulderH);
    final rightShoulder = makeDeckRow(rightDeck, shoulderY, shoulderH);
    final leftTopPair = makeDeckRow(leftDeck, topPairY, yinYangH);
    final rightTopPair = makeDeckRow(rightDeck, topPairY, yinYangH);
    final leftBottomPair = makeDeckRow(leftDeck, bottomPairY, yinYangH);
    final rightBottomPair = makeDeckRow(rightDeck, bottomPairY, yinYangH);

    final leftStick = Rect.fromCenter(
      center: Offset(leftDeck.center.dx, stickY + stickSize / 2.0),
      width: stickSize,
      height: stickSize,
    );
    final rightStick = Rect.fromCenter(
      center: Offset(rightDeck.center.dx, stickY + stickSize / 2.0),
      width: stickSize,
      height: stickSize,
    );

    // Center column (top chrome, Recenter, Vista/Láser + preview, footer).
    final centerInset = spacious ? 8.0 : 5.0;
    final headerH = (safeH * 0.21).clamp(44.0, 74.0);
    final recenterH = (safeH * 0.145).clamp(36.0, spacious ? 54.0 : 46.0);
    final footerH = padB + (safeH * 0.16).clamp(28.0, 62.0);
    final recenterRect = Rect.fromLTWH(
      centerPanel.left + centerInset,
      padT + headerH,
      math.max(40.0, centerPanel.width - centerInset * 2),
      recenterH,
    );
    final previewTop = recenterRect.bottom + gap;
    final previewRect = Rect.fromLTWH(
      recenterRect.left,
      previewTop,
      recenterRect.width,
      math.max(12.0, h - footerH - previewTop - 4.0),
    );

    return Vr2dYinYangDeckLayout(
      leftDeck: leftDeck,
      rightDeck: rightDeck,
      centerPanel: centerPanel,
      recenterRect: recenterRect,
      previewPanel: previewRect,
      footerHeight: footerH,
      deckPadding: deckPad,
      gap: gap,
      shoulderHeight: shoulderH,
      yinYangHeight: yinYangH,
      stickSize: stickSize,
      leftShoulderRect: leftShoulder,
      rightShoulderRect: rightShoulder,
      leftStickRect: leftStick,
      rightStickRect: rightStick,
      leftTopPairRect: leftTopPair,
      leftBottomPairRect: leftBottomPair,
      rightTopPairRect: rightTopPair,
      rightBottomPairRect: rightBottomPair,
    );
  }
}
