import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  testWidgets(
    'VirtualThumbstick superimposed rim D-pad emits dpadX/dpadY on outer cardinal edges without moving analog stick',
    (tester) async {
      final analogEvents = <(double, double)>[];
      final dpadEvents = <(double, double)>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: VirtualThumbstick(
                key: const ValueKey('test_left_stick'),
                size: 200,
                knobRadius: 38,
                enableRimDpad: true,
                onChanged: (sx, sy) => analogEvents.add((sx, sy)),
                onDpadChanged: (dx, dy) => dpadEvents.add((dx, dy)),
              ),
            ),
          ),
        ),
      );

      final rect = tester.getRect(find.byKey(const ValueKey('test_left_stick')));
      // Tap right outer rim (88% radius east) -> D-pad right (+1, 0), 0 analog movement!
      final eastRim = Offset(rect.center.dx + 88, rect.center.dy);
      final rimGesture = await tester.startGesture(eastRim);
      await tester.pump();
      expect(dpadEvents, [(1.0, 0.0)]);
      expect(analogEvents, isEmpty);

      await rimGesture.up();
      await tester.pump();
      expect(dpadEvents.last, (0.0, 0.0));
      expect(analogEvents, isEmpty);

      // Drag from inner stick zone out to the rim -> normal analog walk/sprint, 0 D-pad!
      dpadEvents.clear();
      final walkGesture = await tester.startGesture(
        Offset(rect.center.dx, rect.center.dy - 20),
      );
      await walkGesture.moveBy(const Offset(0, -75));
      await tester.pump();
      expect(dpadEvents, isEmpty);
      expect(analogEvents, isNotEmpty);
      expect(analogEvents.last.$2, greaterThan(0.8));
      await walkGesture.up();
      await tester.pump();
    },
  );

  test('VrCompactGamepadCodec packs and unpacks dpadUp/Down/Left/Right in 46 bytes', () {
    const codec = VrCompactGamepadCodec();
    final frame = VrCompactGamepadFrame(
      sequence: 42,
      senderTimestampMicroseconds: 123456,
      orientation: vm.Quaternion.identity(),
      angularVelocity: vm.Vector3.zero(),
      modeIndex: 0,
      dpadRight: true,
      dpadUp: true,
    );
    final encoded = codec.encode(frame);
    expect(encoded.length, 46);
    final decoded = codec.tryDecode(encoded)!;
    expect(decoded.dpadRight, isTrue);
    expect(decoded.dpadUp, isTrue);
    expect(decoded.dpadLeft, isFalse);
    expect(decoded.dpadDown, isFalse);
    expect(decoded.dpadX, 1.0);
    expect(decoded.dpadY, 1.0);
  });
}
