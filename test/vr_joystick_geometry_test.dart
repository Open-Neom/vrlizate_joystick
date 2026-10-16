import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/src/vr_joystick_geometry.dart';

const _leftButtons = [
  VrJoystickControl.l,
  VrJoystickControl.y,
  VrJoystickControl.x,
];
const _rightButtons = [
  VrJoystickControl.r,
  VrJoystickControl.b,
  VrJoystickControl.a,
];

void main() {
  for (final size in [
    const Size(420, 180),
    const Size(620, 220),
    const Size(780, 280),
    const Size(940, 340),
    const Size(1180, 680),
    const Size(320, 120),
  ]) {
    test('paths, labels and unique hit ownership fit $size', () {
      final layout = VrJoystickGeometry.fit(size);
      expect(layout.bounds, hasLength(VrJoystickControl.values.length));
      for (final control in VrJoystickControl.values) {
        final rect = layout[control];
        final path = layout.shape(control);
        if (control == VrJoystickControl.laserPad) {
          expect(rect, Rect.zero);
          expect(path.getBounds(), Rect.zero);
          expect(layout.labels[control], isNull);
          continue;
        }
        for (final value in [rect.left, rect.top, rect.right, rect.bottom]) {
          expect(value.isFinite, isTrue, reason: '$control at $size');
        }
        expect(rect.left, greaterThanOrEqualTo(-1e-5));
        expect(rect.top, greaterThanOrEqualTo(-1e-5));
        expect(rect.right, lessThanOrEqualTo(size.width + 1e-5));
        expect(rect.bottom, lessThanOrEqualTo(size.height + 1e-5));
        expect(rect.shortestSide, greaterThan(0));
        expect(path.getBounds().width, greaterThan(0));
        expect(path.getBounds().height, greaterThan(0));
        final label = layout.labels[control];
        if (label != null) {
          expect(
            path.contains(label),
            isTrue,
            reason: '$control label must be on its solid shape, not the notch',
          );
          expect(layout.hitTest(label), control);
        }
      }
      for (final control in [..._leftButtons, ..._rightButtons]) {
        expect(
          layout.labels[control],
          isNotNull,
          reason: 'Every edge action needs a visible label anchor',
        );
      }

      // Rectangles legitimately overlap around concave regions. Test actual
      // paths instead: a single down position must never own two controls.
      for (var row = 0; row < 37; row++) {
        for (var column = 0; column < 79; column++) {
          final point = Offset(
            size.width * (column + .371) / 79,
            size.height * (row + .613) / 37,
          );
          final owners = _owners(layout, point);
          expect(
            owners.length,
            lessThanOrEqualTo(1),
            reason: '$point has owners $owners at $size',
          );
          expect(layout.hitTest(point), owners.isEmpty ? null : owners.single);
        }
      }
      for (final point in [
        const Offset(-1, 0),
        const Offset(0, -1),
        Offset(size.width + 1, size.height / 2),
        Offset(size.width / 2, size.height + 1),
      ]) {
        expect(layout.hitTest(point), isNull);
      }
    });

    test(
      'left thumb stays familiar while right frees a wider center at $size',
      () {
        final layout = VrJoystickGeometry.fit(size);
        final left = layout[VrJoystickControl.moveStick];
        final right = layout[VrJoystickControl.lookStick];
        final previous = _previousBottomAndStickShapes(
          size,
          leftInset: 0,
          rightInset: 0,
        );
        final oldLeft = previous[VrJoystickControl.moveStick]!.getBounds();
        final oldRight = previous[VrJoystickControl.lookStick]!.getBounds();
        expect(left.left, closeTo(oldLeft.left, 1e-3));
        expect(left.top, closeTo(oldLeft.top, 1e-3));
        expect(left.width, closeTo(oldLeft.width, 1e-3));
        expect(left.height, closeTo(oldLeft.height, 1e-3));
        expect(right.width / left.width, closeTo(.78, 1e-4));
        expect(right.height / left.height, closeTo(.78, 1e-4));
        expect(right.center.dy, closeTo(left.center.dy, 1e-3));
        expect(right.center.dx, greaterThan(oldRight.center.dx));
        final oldCenterWidth = math.min(
          size.width * .4,
          (size.width * .30).clamp(128.0, 360.0),
        );
        expect(layout.centerPanel.width, greaterThan(oldCenterWidth));
        expect(left.right, lessThanOrEqualTo(layout.centerPanel.left));
        expect(right.left, greaterThanOrEqualTo(layout.centerPanel.right));
        expect(layout.previewPanel.left, greaterThan(layout.centerPanel.left));
        expect(layout.previewPanel.right, lessThan(layout.centerPanel.right));
        expect(
          layout.previewPanel.top,
          greaterThan(layout[VrJoystickControl.recenter].bottom),
        );
        expect(
          layout.previewPanel.bottom,
          lessThanOrEqualTo(size.height - layout.footerHeight),
        );
        expect(layout.hitTest(layout.previewPanel.center), isNull);
        for (var row = 0; row < 9; row++) {
          for (var column = 0; column < 13; column++) {
            final point = Offset(
              layout.previewPanel.left +
                  layout.previewPanel.width * (column + .5) / 13,
              layout.previewPanel.top +
                  layout.previewPanel.height * (row + .5) / 9,
            );
            expect(layout.hitTest(point), isNull);
            expect(
              layout.shape(VrJoystickControl.laserPad).contains(point),
              isFalse,
            );
          }
        }
      },
    );

    test(
      'circular holes belong to sticks, never surrounding bands at $size',
      () {
        final layout = VrJoystickGeometry.fit(size);
        for (final (stick, bands) in [
          (VrJoystickControl.moveStick, _leftButtons),
          (VrJoystickControl.lookStick, _rightButtons),
        ]) {
          final rect = layout[stick];
          final center = rect.center;
          final radius = rect.shortestSide / 2;
          expect(layout.hitTest(center), stick);
          for (final fraction in [.2, .7, .97]) {
            for (var angleStep = 0; angleStep < 24; angleStep++) {
              final angle = angleStep * math.pi / 12;
              final point =
                  center +
                  Offset(math.cos(angle), math.sin(angle)) * radius * fraction;
              expect(layout.shape(stick).contains(point), isTrue);
              expect(layout.hitTest(point), stick);
              for (final band in bands) {
                expect(
                  layout.shape(band).contains(point),
                  isFalse,
                  reason: '$band steals the $stick hole at $point',
                );
              }
            }
          }
          // A circular stick must not intercept the corners of its square box.
          for (final corner in [
            rect.topLeft + const Offset(.5, .5),
            rect.topRight + const Offset(-.5, .5),
            rect.bottomLeft + const Offset(.5, -.5),
            rect.bottomRight + const Offset(-.5, -.5),
          ]) {
            expect(layout.shape(stick).contains(corner), isFalse);
          }
        }
      },
    );

    if (size.width >= 420 && size.height >= 180) {
      test('bands reach outer edges and lower corners at $size', () {
        final layout = VrJoystickGeometry.fit(size);
        final expected = <Offset, VrJoystickControl>{
          const Offset(1, 1): VrJoystickControl.l,
          Offset(size.width - 1, 1): VrJoystickControl.r,
          Offset(1, size.height - 1): VrJoystickControl.x,
          Offset(size.width - 1, size.height - 1): VrJoystickControl.a,
          Offset(1, layout[VrJoystickControl.moveStick].center.dy):
              VrJoystickControl.y,
          Offset(size.width - 1, layout[VrJoystickControl.lookStick].center.dy):
              VrJoystickControl.b,
        };
        for (final entry in expected.entries) {
          expect(
            layout.hitTest(entry.key),
            entry.value,
            reason: 'Missing full-bleed edge at ${entry.key}',
          );
        }
        for (final control in [
          VrJoystickControl.x,
          VrJoystickControl.a,
          VrJoystickControl.l,
          VrJoystickControl.r,
        ]) {
          final rect = layout[control];
          final y =
              control == VrJoystickControl.x || control == VrJoystickControl.a
              ? size.height - 1
              : 1.0;
          // Whole lower/upper lateral band, not one isolated corner key.
          for (final fraction in [.05, .25, .5, .75, .95]) {
            expect(
              layout.hitTest(Offset(rect.left + rect.width * fraction, y)),
              control,
            );
          }
        }
      });
    }
  }

  for (final size in [
    const Size(480, 280),
    const Size(640, 320),
    const Size(800, 360),
    const Size(960, 420),
  ]) {
    for (final (leftInset, rightInset) in [
      (0.0, 0.0),
      (32.0, 0.0),
      (0.0, 32.0),
    ]) {
      test(
        'Y/B retain primary outer edges at $size, insets $leftInset/$rightInset',
        () {
          final layout = VrJoystickGeometry.fit(
            size,
            leftInset: leftInset,
            rightInset: rightInset,
          );
          final radius = _openingRadius(size, leftInset, rightInset);
          final topEnd = math.max(51.0, size.height * .16);
          final bottomStart = size.height * .53 + radius * .55;
          final gap = math.min(6.0, size.height * .02);
          for (final (side, top, x) in [
            (VrJoystickControl.y, VrJoystickControl.l, 1.0),
            (VrJoystickControl.b, VrJoystickControl.r, size.width - 1),
          ]) {
            final sideHeight = _sampledEdgeHeight(layout.shape(side), x, size);
            final topHeight = _sampledEdgeHeight(layout.shape(top), x, size);
            // Priority is the usable outer edge, where the player finds Y/B
            // by touch. The less reachable upper INNER lobes belong to L/R,
            // so ordering the buttons by total area is no longer appropriate.
            expect(
              sideHeight,
              greaterThan(topHeight),
              reason:
                  '$side must keep a longer usable outer edge than $top: '
                  '$sideHeight versus $topHeight logical px',
            );
            expect(
              sideHeight,
              closeTo(bottomStart - topEnd - gap, .75),
              reason: 'Do not shrink the previously enlarged $side outer edge',
            );
            expect(
              topHeight,
              closeTo(topEnd - gap / 2, .75),
              reason: 'The added $top arm is inner, not along the outer edge',
            );
          }

          // Shoulder keys remain useful even after giving the side keys more
          // room. Their physical outer edges keep a 48 px tall touch target.
          for (final (top, x) in [
            (VrJoystickControl.l, 1.0),
            (VrJoystickControl.r, size.width - 1),
          ]) {
            for (var y = .5; y < 48; y += 1) {
              expect(
                layout.hitTest(Offset(x, y)),
                top,
                reason: '$top must retain 48 px along the top outer edge',
              );
            }
          }

          // The movement side is unchanged; right-side space is deliberately
          // reassigned to the passive center and the smaller look/laser stick.
          final previous = _previousBottomAndStickShapes(
            size,
            leftInset: leftInset,
            rightInset: rightInset,
          );
          for (final entry in previous.entries.where(
            (entry) =>
                entry.key == VrJoystickControl.moveStick ||
                entry.key == VrJoystickControl.x,
          )) {
            final actual = layout.shape(entry.key);
            final expected = entry.value;
            final bounds = expected.getBounds();
            expect(actual.getBounds().left, closeTo(bounds.left, 1e-3));
            expect(actual.getBounds().top, closeTo(bounds.top, 1e-3));
            expect(actual.getBounds().width, closeTo(bounds.width, 1e-3));
            expect(actual.getBounds().height, closeTo(bounds.height, 1e-3));
            for (var row = 0; row < 29; row++) {
              for (var column = 0; column < 29; column++) {
                final point = Offset(
                  bounds.left + bounds.width * (column + .31) / 29,
                  bounds.top + bounds.height * (row + .47) / 29,
                );
                expect(
                  actual.contains(point),
                  expected.contains(point),
                  reason: '${entry.key} footprint changed at $point',
                );
              }
            }
          }
        },
      );

      test(
        'upper inner lobes belong to L/R at $size, insets $leftInset/$rightInset',
        () {
          final layout = VrJoystickGeometry.fit(
            size,
            leftInset: leftInset,
            rightInset: rightInset,
          );
          final radius = _openingRadius(size, leftInset, rightInset);
          final topEnd = math.max(51.0, size.height * .16);
          final gap = math.min(6.0, size.height * .02);

          for (final (stick, side, shoulder, innerSign) in [
            (
              VrJoystickControl.moveStick,
              VrJoystickControl.y,
              VrJoystickControl.l,
              1.0,
            ),
            (
              VrJoystickControl.lookStick,
              VrJoystickControl.b,
              VrJoystickControl.r,
              -1.0,
            ),
          ]) {
            final center = layout[stick].center;
            // Probe just outside each upper circle quadrant. The inner one
            // was previously Y/B; only that lobe must transfer to L/R.
            for (final angle in [math.pi / 3, math.pi / 4]) {
              final delta =
                  Offset(innerSign * math.cos(angle), -math.sin(angle)) *
                  (radius * (stick == VrJoystickControl.lookStick ? .78 : 1) +
                      4);
              final inner = center + delta;
              final outer = center + Offset(-delta.dx, delta.dy);
              expect(layout.hitTest(inner), shoulder);
              expect(_owners(layout, inner), [shoulder]);
              expect(layout.hitTest(outer), side);
              expect(_owners(layout, outer), [side]);
            }
            final besideCenterPanel = Offset(
              innerSign > 0
                  ? layout.centerPanel.left - 1
                  : layout.centerPanel.right + 1,
              topEnd + gap + 4,
            );
            expect(layout.hitTest(besideCenterPanel), shoulder);
            expect(_owners(layout, besideCenterPanel), [shoulder]);
            expect(
              layout.hitTest(
                Offset(innerSign > 0 ? 1 : size.width - 1, center.dy),
              ),
              side,
            );
          }

          // Include both notch orientations in ownership coverage: one press
          // cannot reach both the new shoulder arm and the retained side band.
          for (var row = 0; row < 37; row++) {
            for (var column = 0; column < 79; column++) {
              final point = Offset(
                size.width * (column + .371) / 79,
                size.height * (row + .613) / 37,
              );
              final owners = _owners(layout, point);
              expect(
                owners.length,
                lessThanOrEqualTo(1),
                reason:
                    '$point has owners $owners with insets $leftInset/$rightInset',
              );
              expect(
                layout.hitTest(point),
                owners.isEmpty ? null : owners.single,
              );
            }
          }
        },
      );
    }
  }

  test('invalid constraints cannot create NaN or negative hit regions', () {
    for (final size in [
      Size.zero,
      const Size(double.infinity, 300),
      const Size(500, double.nan),
      const Size(-1, 300),
    ]) {
      expect(() => VrJoystickGeometry.fit(size), throwsArgumentError);
    }
  });
}

/// Geometry-only routing checks. Held/cancelled multi-pointer lifecycle must
/// also be exercised by the actual controller widget tests, not this helper.
List<VrJoystickControl> _owners(VrJoystickGeometry layout, Offset point) => [
  for (final control in VrJoystickControl.values)
    if (layout.shape(control).contains(point)) control,
];

double _sampledEdgeHeight(Path path, double x, Size size) {
  const step = .5;
  var samplesInside = 0;
  for (var y = step / 2; y < size.height; y += step) {
    if (path.contains(Offset(x, y))) samplesInside++;
  }
  return samplesInside * step;
}

double _openingRadius(Size size, double leftInset, double rightInset) {
  final centerWidth = math.min(
    size.width * .4,
    (size.width * .30).clamp(128.0, 360.0),
  );
  final sideWidth = (size.width - centerWidth) / 2;
  final rail = math.min(
    sideWidth - 20,
    math.max(48.0, math.max(leftInset, rightInset) + 32),
  );
  return math.max(8.0, math.min(size.height * .31, (sideWidth - rail) / 2));
}

/// Accepted edge-layout geometry before promoting Y/B over L/R. Reconstruct
/// only the parts that must not move, rather than comparing a rendered image.
Map<VrJoystickControl, Path> _previousBottomAndStickShapes(
  Size size, {
  required double leftInset,
  required double rightInset,
}) {
  final centerWidth = math.min(
    size.width * .4,
    (size.width * .30).clamp(128.0, 360.0),
  );
  final sideWidth = (size.width - centerWidth) / 2;
  final rail = math.min(
    sideWidth - 20,
    math.max(48.0, math.max(leftInset, rightInset) + 32),
  );
  final radius = math.max(
    8.0,
    math.min(size.height * .31, (sideWidth - rail) / 2),
  );
  final stickRadius = math.max(4.0, radius - math.min(14.0, radius * .22));
  final cy = size.height * .53;
  final cx = sideWidth - radius + math.min(6.0, radius * .1);
  final bottomStart = cy + radius * .55;
  final gap = math.min(6.0, size.height * .02);
  return {
    for (final right in [false, true]) ...{
      right ? VrJoystickControl.a : VrJoystickControl.x: Path.combine(
        PathOperation.difference,
        Path()..addRect(
          Rect.fromLTWH(
            right ? size.width - sideWidth : 0,
            bottomStart + gap / 2,
            sideWidth,
            size.height - bottomStart - gap / 2,
          ),
        ),
        Path()..addOval(
          Rect.fromCircle(
            center: Offset(right ? size.width - cx : cx, cy),
            radius: radius,
          ),
        ),
      ),
      right ? VrJoystickControl.lookStick : VrJoystickControl.moveStick: Path()
        ..addOval(
          Rect.fromCircle(
            center: Offset(right ? size.width - cx : cx, cy),
            radius: stickRadius,
          ),
        ),
    },
  };
}
