import 'dart:math' as math;
import 'dart:ui';

import '../../utils/constants/vr_joystick_translation_constants.dart';
import '../../utils/enums/vr_joystick_control.dart';

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
    double topInset = 0,
    double bottomInset = 0,
  }) {
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width <= 0 ||
        size.height <= 0 ||
        [
          leftInset,
          rightInset,
          topInset,
          bottomInset,
        ].any((inset) => !inset.isFinite || inset < 0)) {
      throw ArgumentError.value(
        size,
        'size',
        VrJoystickTranslationConstants.errorInvalidSizeArgument,
      );
    }
    final width = size.width;
    final height = size.height;
    const rightScale = .78;
    final horizontalInset = math.max(leftInset, rightInset);
    final safeHeight = height - topInset - bottomInset;
    final comfortable =
        width - leftInset - rightInset >= 760 && safeHeight >= 400;
    final target = comfortable ? 56.0 : 48.0;
    final clearance = comfortable ? 10.0 : 8.0;
    final minimumOpening = (target / 2 + clearance) / rightScale;
    final minimumSideWidth =
        horizontalInset +
        math.max(
          target + 2 * minimumOpening,
          2 * target + clearance + 2 * (1 - rightScale) * minimumOpening,
        );
    // Tiny or partially occluded surfaces still need all controls. Reserve
    // full-size touch targets when all three bands and the preview fit.
    final hasTargetSpace =
        width >= 2 * minimumSideWidth + 96 &&
        safeHeight >= 3 * target + 2 * clearance;
    final preferredCenterWidth = math.min(
      width * .38,
      (width * .26).clamp(124.0, 320.0),
    );
    final leftSideWidth = math.max(
      (width - preferredCenterWidth) / 2,
      hasTargetSpace ? minimumSideWidth : 0.0,
    );
    final rail = math.min(
      leftSideWidth - 20,
      math.max(48.0, horizontalInset + (hasTargetSpace ? target : 32)),
    );
    final cy = hasTargetSpace
        ? (height * .53)
              .clamp(
                topInset + target + minimumOpening,
                height - bottomInset - target - clearance,
              )
              .toDouble()
        : height * .53;
    // Put both shoulder pairs above their stick openings. Reserve enough
    // width for the right pair when the smaller right stick widens the center.
    final roomForOpening = hasTargetSpace
        ? math.min(
            cy - topInset - target,
            math.min(
              height - bottomInset - cy,
              (leftSideWidth - horizontalInset - 2 * target - clearance) /
                  (2 * (1 - rightScale)),
            ),
          )
        : double.infinity;
    final radius = math.max(
      8.0,
      math.min(
        roomForOpening,
        math.min(height * .322, (leftSideWidth - rail) / 2),
      ),
    );
    final preferredStickRadius = radius - math.min(13.0, radius * .19);
    final stickRadius = math.max(
      4.0,
      hasTargetSpace
          ? (preferredStickRadius.clamp(
              target / (2 * rightScale),
              math.max(
                target / (2 * rightScale),
                radius - clearance / rightScale,
              ),
            )).toDouble()
          : preferredStickRadius,
    );
    final rightRadius = radius * rightScale;
    final rightSideWidth = leftSideWidth - 2 * (radius - rightRadius);
    final centerWidth = width - leftSideWidth - rightSideWidth;
    final gap = hasTargetSpace ? clearance : math.min(6.0, height * .02);
    final preferredTopEnd =
        (height >= 240 ? math.max(51.0, height * .16) : height * .16) - gap / 2;
    final topEnd = hasTargetSpace
        ? preferredTopEnd
              .clamp(
                topInset + target,
                math.min(
                  cy - radius,
                  height - bottomInset - 2 * (target + gap),
                ),
              )
              .toDouble()
        : preferredTopEnd;
    final sideStart = topEnd + gap;
    final preferredSideEnd = cy + radius * .55 - gap / 2;
    final sideEnd = hasTargetSpace
        ? preferredSideEnd
              .clamp(
                math.max(cy, sideStart + target).toDouble(),
                height - bottomInset - target - gap,
              )
              .toDouble()
        : preferredSideEnd;
    final bottomStart = sideEnd + gap;
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
      final trigger = right ? VrJoystickControl.zr : VrJoystickControl.zl;
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
      final shoulder = Path.combine(
        PathOperation.difference,
        Path()
          ..moveTo(outerX, 0)
          ..lineTo(innerX, 0)
          ..lineTo(innerX, cy)
          ..lineTo(shoulderEdge, cy)
          ..lineTo(shoulderEdge, topEnd)
          ..lineTo(outerX, topEnd)
          ..close(),
        circle,
      );
      final systemInset = right ? rightInset : leftInset;
      final safeInset = hasTargetSpace
          ? systemInset
          : math.min(systemInset, sideWidth * .5);
      final outerShoulderWidth = (sideWidth + safeInset) / 2;
      final splitX = right ? width - outerShoulderWidth : outerShoulderWidth;
      final splitGap = hasTargetSpace
          ? gap / 2
          : math.min(gap / 2, sideWidth * .05);
      final innerShoulderEdge = splitX + (right ? -splitGap : splitGap);
      final outerShoulderEdge = splitX + (right ? splitGap : -splitGap);
      // Keep two disjoint hit paths even when the shoulder's curved arm
      // reaches further across the top band on a narrow surface.
      shapes[top] = Path.combine(
        PathOperation.intersect,
        shoulder,
        Path()..addRect(
          Rect.fromLTRB(
            right ? outerShoulderEdge : x0,
            0,
            right ? width : outerShoulderEdge,
            cy,
          ),
        ),
      );
      shapes[trigger] = Path.combine(
        PathOperation.intersect,
        shoulder,
        Path()..addRect(
          Rect.fromLTRB(
            right ? innerX : innerShoulderEdge,
            0,
            right ? innerShoulderEdge : innerX,
            cy,
          ),
        ),
      );
      shapes[side] = Path.combine(
        PathOperation.difference,
        Path()..addRect(
          Rect.fromLTWH(
            right ? center.dx + gap / 2 : 0,
            sideStart,
            cx - gap / 2,
            sideEnd - sideStart,
          ),
        ),
        circle,
      );
      shapes[bottom] = band(bottomStart, height - bottomStart);
      final insideRail = math.min(cx - openingRadius, cx - gap / 2);
      final railLabelX = (safeInset + insideRail) / 2;
      final sideLabelX = hasTargetSpace
          ? railLabelX
          : math.max(1.0, (cx - openingRadius) / 2);
      final bottomLabelX = hasTargetSpace ? railLabelX : sideWidth * .30;
      labels[top] = Offset(
        (outerShoulderEdge + (right ? width - safeInset : safeInset)) / 2,
        ((hasTargetSpace ? topInset : 0.0) + topEnd) / 2,
      );
      labels[trigger] = Offset(
        (innerShoulderEdge + innerX) / 2,
        labels[top]!.dy,
      );
      labels[bottom] = Offset(
        right ? width - bottomLabelX : bottomLabelX,
        hasTargetSpace
            ? (bottomStart + height - bottomInset) / 2
            : bottomStart + (height - bottomStart) * .58,
      );
      labels[side] = Offset(
        right ? width - sideLabelX : sideLabelX,
        hasTargetSpace ? (sideStart + sideEnd) / 2 : cy,
      );
      final stick = right
          ? VrJoystickControl.lookStick
          : VrJoystickControl.moveStick;
      shapes[stick] = Path()
        ..addOval(Rect.fromCircle(center: center, radius: controlRadius));
      labels[stick] = center;
    }

    final previewGap = hasTargetSpace ? gap : 8.0;
    const previewBottomMargin = 4.0;
    final header = hasTargetSpace
        ? math
              .max(topInset, math.min(safeHeight * .28, 82.0))
              .clamp(
                topInset,
                height -
                    bottomInset -
                    2 * target -
                    previewGap -
                    previewBottomMargin,
              )
              .toDouble()
        : math.min(height * .28, 82.0);
    final recenterHeight = hasTargetSpace
        ? target
        : math.min(48.0, height * .17);
    final footer = hasTargetSpace
        ? bottomInset +
              math.min(
                math.min(66.0, safeHeight * .24),
                height -
                    bottomInset -
                    header -
                    recenterHeight -
                    target -
                    previewGap -
                    previewBottomMargin,
              )
        : math.min(66.0, height * .24);
    final inset = hasTargetSpace ? gap : math.min(8.0, centerWidth * .06);
    final recenter = Rect.fromLTWH(
      panel.left + inset,
      header,
      centerWidth - inset * 2,
      recenterHeight,
    );
    final preview = Rect.fromLTWH(
      panel.left + inset,
      recenter.bottom + previewGap,
      centerWidth - inset * 2,
      math.max(
        8,
        height - footer - recenter.bottom - previewGap - previewBottomMargin,
      ),
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
