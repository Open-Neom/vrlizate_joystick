import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  testWidgets('VirtualThumbstick renders with initial center state', (
    tester,
  ) async {
    double? lastX;
    double? lastY;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: VirtualThumbstick(
              size: 150,
              onChanged: (x, y) {
                lastX = x;
                lastY = y;
              },
            ),
          ),
        ),
      ),
    );

    expect(find.byType(VirtualThumbstick), findsOneWidget);
    expect(lastX, isNull);
    expect(lastY, isNull);
  });

  testWidgets('VirtualThumbstick drag produces normalized coordinates', (
    tester,
  ) async {
    double lastX = 0.0;
    double lastY = 0.0;
    bool released = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: VirtualThumbstick(
              size: 150,
              knobRadius: 25,
              deadzone: 0.05,
              onChanged: (x, y) {
                lastX = x;
                lastY = y;
              },
              onRelease: () {
                released = true;
              },
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(VirtualThumbstick));

    // Drag right
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();

    expect(lastX, greaterThan(0.5));
    expect(lastY, closeTo(0.0, 0.1));

    // Drag forward/up
    await gesture.moveBy(const Offset(-40, -40));
    await tester.pump();

    expect(lastY, greaterThan(0.5));

    // Release stick
    await gesture.up();
    await tester.pumpAndSettle();

    expect(released, isTrue);
    expect(lastX, 0.0);
    expect(lastY, 0.0);
  });

  testWidgets('VirtualThumbstick works with hapticsEnabled set to false', (
    tester,
  ) async {
    double lastX = 0.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: VirtualThumbstick(
              size: 150,
              hapticsEnabled: false,
              onChanged: (x, y) {
                lastX = x;
              },
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byType(VirtualThumbstick));
    final gesture = await tester.startGesture(center);
    // Drag beyond boundary
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();

    expect(lastX, 1.0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(lastX, 0.0);
  });
}
