import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/ui/nes_controller_layout.dart';

void main() {
  for (final (size, padding, gestures, target, gap) in [
    (
      const Size(480, 280),
      const EdgeInsets.only(left: 28),
      const EdgeInsets.only(right: 24, bottom: 16),
      48.0,
      8.0,
    ),
    (
      const Size(640, 320),
      const EdgeInsets.only(right: 48),
      EdgeInsets.zero,
      48.0,
      8.0,
    ),
    (const Size(960, 540), EdgeInsets.zero, EdgeInsets.zero, 56.0, 10.0),
  ]) {
    testWidgets('NES targets have independent finger clearance at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final events = <(String, bool)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: padding,
              viewPadding: padding,
              systemGestureInsets: gestures,
              textScaler: const TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: NesControllerLayout(
                connected: true,
                pressed: const {},
                captions: const {
                  'A': 'Acción',
                  'B': 'Cancelar',
                  'home': 'Salir',
                },
                onDirection: (_, _) {},
                onButton: (button, down) => events.add((button, down)),
                onSettings: () => events.add(('settings', true)),
                onConnect: () => events.add(('connect', true)),
              ),
            ),
          ),
        ),
      );

      Rect bounds(String id) => tester.getRect(find.byKey(ValueKey(id)));
      final controls = [
        bounds('nes_dpad'),
        bounds('nes_button_A'),
        bounds('nes_button_B'),
        bounds('nes_button_select'),
        bounds('nes_button_start'),
        bounds('nes_button_home'),
        tester.getRect(find.byType(IconButton)),
        tester.getRect(find.byType(TextButton)),
      ];
      final safe = EdgeInsets.fromLTRB(
        math.max(padding.left, gestures.left),
        math.max(padding.top, gestures.top),
        math.max(padding.right, gestures.right),
        math.max(padding.bottom, gestures.bottom),
      ).deflateRect(Offset.zero & size);
      for (final (i, first) in controls.indexed) {
        expect(safe.intersect(first), first);
        expect(first.shortestSide, greaterThanOrEqualTo(target - .01));
        for (final second in controls.skip(i + 1)) {
          final horizontal = math.max(
            first.left - second.right,
            second.left - first.right,
          );
          final vertical = math.max(
            first.top - second.bottom,
            second.top - first.bottom,
          );
          expect(
            math.max(horizontal, vertical),
            greaterThanOrEqualTo(gap - .01),
          );
        }
      }

      final a = bounds('nes_button_A');
      final b = bounds('nes_button_B');
      await tester.tapAt(Offset((a.left + b.right) / 2, a.center.dy));
      expect(events, isEmpty);
      final holdB = await tester.startGesture(Offset(b.right - 1, b.center.dy));
      final holdA = await tester.startGesture(Offset(a.left + 1, a.center.dy));
      await holdB.up();
      await holdA.cancel();
      expect(events, [('B', true), ('A', true), ('B', false), ('A', false)]);
      expect(tester.takeException(), isNull);
    });
  }
}
