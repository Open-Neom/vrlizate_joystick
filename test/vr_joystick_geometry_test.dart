import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/src/vr_joystick_geometry.dart';

const _leftButtons = [
  VrJoystickControl.l,
  VrJoystickControl.zl,
  VrJoystickControl.y,
  VrJoystickControl.x,
];
const _rightButtons = [
  VrJoystickControl.r,
  VrJoystickControl.zr,
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
        expect(right.width / left.width, closeTo(.78, 1e-4));
        expect(right.height / left.height, closeTo(.78, 1e-4));
        expect(right.center.dy, closeTo(left.center.dy, 1e-3));
        expect(right.center.dx, greaterThan(left.center.dx));
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
          VrJoystickControl.zl,
          VrJoystickControl.zr,
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

  for (final (size, left, right, top, bottom, target, gap) in [
    (const Size(480, 280), 0.0, 0.0, 0.0, 0.0, 48.0, 8.0),
    (const Size(480, 280), 48.0, 48.0, 24.0, 24.0, 48.0, 8.0),
    (const Size(640, 320), 48.0, 16.0, 12.0, 24.0, 48.0, 8.0),
    (const Size(640, 320), 16.0, 48.0, 24.0, 12.0, 48.0, 8.0),
    (const Size(700, 360), 32.0, 32.0, 0.0, 24.0, 48.0, 8.0),
    (const Size(960, 540), 48.0, 16.0, 24.0, 28.0, 56.0, 10.0),
  ]) {
    test(
      'safe pressable cores and neutral gaps at $size, $left/$right/$top/$bottom',
      () {
        final layout = VrJoystickGeometry.fit(
          size,
          leftInset: left,
          rightInset: right,
          topInset: top,
          bottomInset: bottom,
        );
        final safe = Rect.fromLTRB(
          left,
          top,
          size.width - right,
          size.height - bottom,
        );
        for (final control in [
          ..._leftButtons,
          ..._rightButtons,
          VrJoystickControl.recenter,
        ]) {
          final core = Rect.fromCenter(
            center: layout.labels[control]!,
            width: target - .02,
            height: target - .02,
          );
          expect(
            safe.contains(core.topLeft),
            isTrue,
            reason: '$control top left',
          );
          expect(
            safe.contains(core.bottomRight),
            isTrue,
            reason: '$control bottom right',
          );
          for (var row = 0; row <= 8; row++) {
            for (var column = 0; column <= 8; column++) {
              final point = Offset(
                core.left + core.width * column / 8,
                core.top + core.height * row / 8,
              );
              expect(_owners(layout, point), [
                control,
              ], reason: '$control at $point');
            }
          }
        }
        for (final (outer, inner, side, bottomKey, stick, direction) in [
          (
            VrJoystickControl.l,
            VrJoystickControl.zl,
            VrJoystickControl.y,
            VrJoystickControl.x,
            VrJoystickControl.moveStick,
            1,
          ),
          (
            VrJoystickControl.r,
            VrJoystickControl.zr,
            VrJoystickControl.b,
            VrJoystickControl.a,
            VrJoystickControl.lookStick,
            -1,
          ),
        ]) {
          final outerEdge = direction == 1
              ? layout[outer].right
              : layout[outer].left;
          final innerEdge = direction == 1
              ? layout[inner].left
              : layout[inner].right;
          expect((outerEdge - innerEdge).abs(), closeTo(gap, .01));
          expect(
            layout[bottomKey].top - layout[side].bottom,
            closeTo(gap, .01),
          );
          final x = layout.labels[side]!.dx;
          final shoulderEnd = layout[side].top - gap;
          for (var step = 1; step < 8; step++) {
            final delta = gap * step / 8;
            expect(
              layout.hitTest(
                Offset(outerEdge + delta * direction, top + target / 2),
              ),
              isNull,
            );
            expect(layout.hitTest(Offset(x, shoulderEnd + delta)), isNull);
            expect(
              layout.hitTest(Offset(x, layout[side].bottom + delta)),
              isNull,
            );
          }
          final stickRect = layout[stick];
          expect(stickRect.width, greaterThanOrEqualTo(target - .01));
          expect(
            safe.contains(stickRect.topLeft + const Offset(.01, .01)),
            isTrue,
          );
          expect(
            safe.contains(stickRect.bottomRight - const Offset(.01, .01)),
            isTrue,
          );
          for (var angleStep = 0; angleStep < 48; angleStep++) {
            final angle = angleStep * math.pi / 24;
            final nearStick =
                stickRect.center +
                Offset(math.cos(angle), math.sin(angle)) *
                    (stickRect.width / 2 + gap - .02);
            expect(
              layout.hitTest(nearStick),
              isNull,
              reason: '$stick at $nearStick',
            );
          }
          final edgeX = direction == 1 ? 1.0 : size.width - 1;
          expect(layout.hitTest(Offset(edgeX, 1)), outer);
          expect(layout.hitTest(Offset(edgeX, layout.labels[side]!.dy)), side);
          expect(layout.hitTest(Offset(edgeX, size.height - 1)), bottomKey);
          final innerX = direction == 1
              ? layout.centerPanel.left - 1
              : layout.centerPanel.right + 1;
          expect(layout.hitTest(Offset(innerX, layout[side].top + 1)), inner);
        }
      },
    );
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
