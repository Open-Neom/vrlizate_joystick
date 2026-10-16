import 'dart:math' as math;
import 'dart:ui';

enum VrJoystickControl {
  l,
  r,
  y,
  x,
  b,
  a,
  moveStick,
  lookStick,
  recenter,

  /// Retained for source compatibility. The center is now a passive display;
  /// its old laser pad has an empty path and never captures a pointer.
  laserPad,
}

/// Full-bleed bands with a large movement stick and a smaller look/laser stick.
///
/// Paths are in surface coordinates and borrowed: do not mutate them. Cache
/// this geometry until the surface size changes; Path.combine is not input work.
class VrJoystickGeometry {
  final Map<VrJoystickControl, Rect> bounds;
  final Map<VrJoystickControl, Offset> labels;
  final Map<VrJoystickControl, Path> _shapes;
  final Rect centerPanel;

  /// Passive room preview and controller information, below recenter and above
  /// the footer. Hosts can reserve part of this area for mode-switch controls.
  final Rect previewPanel;
  final double footerHeight;

  VrJoystickGeometry._(
    this.bounds,
    this.labels,
    this._shapes,
    this.centerPanel,
    this.previewPanel,
    this.footerHeight,
  );

  factory VrJoystickGeometry.fit(
    Size size, {
    double leftInset = 0,
    double rightInset = 0,
  }) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0 ||
        !leftInset.isFinite ||
        !rightInset.isFinite ||
        leftInset < 0 ||
        rightInset < 0) {
      throw ArgumentError.value(size, 'size', 'Must be finite and positive.');
    }
    final width = size.width;
    final height = size.height;
    final previousCenterWidth = math.min(
      width * .4,
      (width * .30).clamp(128.0, 360.0),
    );
    final leftSideWidth = (width - previousCenterWidth) / 2;
    // A camera cutout protects the letter without moving the physical edge:
    // reserve more solid rail, reducing the circular opening when necessary.
    final rail = math.min(
      leftSideWidth - 20,
      math.max(48.0, math.max(leftInset, rightInset) + 32),
    );
    final radius = math.max(
      8.0,
      math.min(height * .31, (leftSideWidth - rail) / 2),
    );
    final stickRadius = math.max(4.0, radius - math.min(14.0, radius * .22));
    final cy = height * .53;
    // Keep the accepted movement control exactly where the left thumb expects
    // it. The smaller right control releases its inner space to the preview,
    // while preserving the solid outer rail used by B and the shoulder keys.
    const rightScale = .78;
    final rightRadius = radius * rightScale;
    final rightSideWidth = leftSideWidth - 2 * (radius - rightRadius);
    final centerWidth = width - leftSideWidth - rightSideWidth;
    // Secondary shoulders keep a usable 48 px strip on phone-sized surfaces.
    // Y/B retain the taller outer edges; the rarely touched upper-inner
    // quadrants belong to L/R. Neither stick nor the lower X/A band moves.
    final topEnd = height >= 240 ? math.max(51.0, height * .16) : height * .16;
    final bottomStart = cy + radius * .55;
    final gap = math.min(6.0, height * .02);
    final shapes = <VrJoystickControl, Path>{};
    final labels = <VrJoystickControl, Offset>{};
    final panel = Rect.fromLTWH(leftSideWidth, 0, centerWidth, height);

    for (final right in [false, true]) {
      final sideWidth = right ? rightSideWidth : leftSideWidth;
      final openingRadius = right ? rightRadius : radius;
      final controlRadius = right ? stickRadius * rightScale : stickRadius;
      final cx = sideWidth - openingRadius + math.min(6.0, radius * .1);
      final x0 = right ? width - sideWidth : 0.0;
      final center = Offset(right ? width - cx : cx, cy);
      final circle = Path()
        ..addOval(Rect.fromCircle(center: center, radius: openingRadius));
      final top = right ? VrJoystickControl.r : VrJoystickControl.l;
      final side = right ? VrJoystickControl.b : VrJoystickControl.y;
      final bottom = right ? VrJoystickControl.a : VrJoystickControl.x;
      Path band(double y, double h) => Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(x0, y, sideWidth, h)),
        circle,
      );
      final outerX = right ? width : 0.0;
      final innerX = right ? x0 : sideWidth;
      final shoulderEdge = center.dx + (right ? -gap / 2 : gap / 2);
      // One connected shoulder contour: top strip plus its inner circular
      // surround. The exact same path also owns pointer hit testing.
      shapes[top] = Path.combine(
        PathOperation.difference,
        Path()
          ..moveTo(outerX, 0)
          ..lineTo(innerX, 0)
          ..lineTo(innerX, cy)
          ..lineTo(shoulderEdge, cy)
          ..lineTo(shoulderEdge, topEnd - gap / 2)
          ..lineTo(outerX, topEnd - gap / 2)
          ..close(),
        circle,
      );
      shapes[side] = Path.combine(
        PathOperation.difference,
        Path()..addRect(
          Rect.fromLTWH(
            right ? center.dx + gap / 2 : 0,
            topEnd + gap / 2,
            cx - gap / 2,
            bottomStart - topEnd - gap,
          ),
        ),
        circle,
      );
      shapes[bottom] = band(
        bottomStart + gap / 2,
        height - bottomStart - gap / 2,
      );
      final labelX = sideWidth * .30;
      labels[top] = Offset(right ? width - labelX : labelX, topEnd * .44);
      labels[bottom] = Offset(
        right ? width - labelX : labelX,
        bottomStart + (height - bottomStart) * .58,
      );
      final sideLabelX = math.max(1.0, (cx - openingRadius) / 2);
      labels[side] = Offset(right ? width - sideLabelX : sideLabelX, cy);
      final stick = right
          ? VrJoystickControl.lookStick
          : VrJoystickControl.moveStick;
      shapes[stick] = Path()
        ..addOval(Rect.fromCircle(center: center, radius: controlRadius));
      labels[stick] = center;
    }

    final header = math.min(height * .28, 82.0);
    final recenterHeight = math.min(48.0, height * .17);
    final footer = math.min(66.0, height * .24);
    final inset = math.min(8.0, centerWidth * .06);
    final recenter = Rect.fromLTWH(
      panel.left + inset,
      header,
      centerWidth - inset * 2,
      recenterHeight,
    );
    final preview = Rect.fromLTWH(
      panel.left + inset,
      recenter.bottom + 8,
      centerWidth - inset * 2,
      math.max(8, height - footer - recenter.bottom - 12),
    );
    shapes[VrJoystickControl.recenter] = Path()..addRect(recenter);
    shapes[VrJoystickControl.laserPad] = Path();
    labels[VrJoystickControl.recenter] = recenter.center;
    return VrJoystickGeometry._(
      Map.unmodifiable(
        shapes.map((control, path) => MapEntry(control, path.getBounds())),
      ),
      Map.unmodifiable(labels),
      Map.unmodifiable(shapes),
      panel,
      preview,
      footer,
    );
  }

  Rect operator [](VrJoystickControl control) => bounds[control]!;
  Path shape(VrJoystickControl control) => _shapes[control]!;
  VrJoystickControl? hitTest(Offset position) {
    for (final entry in _shapes.entries) {
      if (entry.value.contains(position)) return entry.key;
    }
    return null;
  }
}
