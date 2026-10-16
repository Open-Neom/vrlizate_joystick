import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  testWidgets(
    'vertical stick ignores lateral displacement without weakening pitch',
    (tester) async {
      final values = <Offset>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: VirtualThumbstick(
              horizontalEnabled: false,
              hapticsEnabled: false,
              onChanged: (x, y) => values.add(Offset(x, y)),
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(VirtualThumbstick));
      final finger = await tester.startGesture(center);
      await finger.moveTo(center + const Offset(70, 0));
      expect(values.last, Offset.zero);
      await finger.moveTo(center + const Offset(70, -70));
      expect(values.last, const Offset(0, 1));
      await finger.up();
      expect(values.last, Offset.zero);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final cancel in [false, true]) {
    testWidgets(
      'removed held stick ignores late move and ${cancel ? 'cancel' : 'up'}',
      (tester) async {
        final callbacks = <Object>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: VirtualThumbstick(
                hapticsEnabled: false,
                onChanged: (x, y) => callbacks.add(Offset(x, y)),
                onPressed: callbacks.add,
                onRelease: () => callbacks.add('release'),
              ),
            ),
          ),
        );
        final center = tester.getCenter(find.byType(VirtualThumbstick));
        final gesture = await tester.startGesture(center);
        await gesture.moveTo(center + const Offset(40, 0));
        await tester.pump();
        final beforeRemoval = List<Object>.of(callbacks);
        await tester.pumpWidget(const SizedBox.shrink());
        await gesture.moveTo(center + const Offset(0, 40));
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.takeException(), isNull);
        expect(callbacks, beforeRemoval);
      },
    );
  }

  testWidgets('contact starts at center without pan and ends once on release', (
    tester,
  ) async {
    final contacts = <bool>[];
    final values = <Offset>[];
    var releases = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: VirtualThumbstick(
            hapticsEnabled: false,
            onChanged: (x, y) => values.add(Offset(x, y)),
            onPressed: contacts.add,
            onRelease: () => releases++,
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(VirtualThumbstick)),
    );
    expect(contacts, [true]);
    expect(values.last, Offset.zero);
    expect(releases, 0);
    await gesture.up();
    expect(contacts, [true, false]);
    expect(releases, 1);
    expect(values.last, Offset.zero);
    await tester.pumpAndSettle();
  });

  testWidgets('raw pointer coordinates respond below touch slop', (
    tester,
  ) async {
    var value = Offset.zero;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: VirtualThumbstick(
            size: 150,
            knobRadius: 25,
            deadzone: 0,
            hapticsEnabled: false,
            onChanged: (x, y) => value = Offset(x, y),
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(VirtualThumbstick));
    final gesture = await tester.startGesture(center + const Offset(3, -2));
    expect(value.dx, closeTo(.06, 1e-10));
    expect(value.dy, closeTo(.04, 1e-10));
    await gesture.moveTo(center + const Offset(4, -3));
    expect(value.dx, closeTo(.08, 1e-10));
    expect(value.dy, closeTo(.06, 1e-10));
    await gesture.cancel();
    expect(value, Offset.zero);
    await tester.pumpAndSettle();
  });

  testWidgets('only the owning pointer can move or release, with no takeover', (
    tester,
  ) async {
    final contacts = <bool>[];
    var value = Offset.zero;
    var releases = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: VirtualThumbstick(
            size: 150,
            knobRadius: 25,
            hapticsEnabled: false,
            onChanged: (x, y) => value = Offset(x, y),
            onPressed: contacts.add,
            onRelease: () => releases++,
          ),
        ),
      ),
    );
    final center = tester.getCenter(find.byType(VirtualThumbstick));
    final owner = await tester.startGesture(
      center + const Offset(50, 0),
      pointer: 1,
    );
    final ignored = await tester.startGesture(
      center + const Offset(-50, 0),
      pointer: 2,
    );
    await ignored.moveTo(center + const Offset(0, -50));
    expect(value, const Offset(1, 0));
    expect(contacts, [true]);
    await owner.cancel();
    expect(value, Offset.zero);
    expect(contacts, [true, false]);
    expect(releases, 1);
    await ignored.moveTo(center + const Offset(-50, 0));
    expect(value, Offset.zero);
    final fresh = await tester.startGesture(
      center + const Offset(0, -50),
      pointer: 3,
    );
    expect(value, const Offset(0, 1));
    await ignored.up();
    expect(value, const Offset(0, 1));
    expect(contacts, [true, false, true]);
    expect(releases, 1);
    await fresh.up();
    expect(value, Offset.zero);
    expect(contacts, [true, false, true, false]);
    expect(releases, 2);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'release is immediately neutral while knob springs back visually',
    (tester) async {
      var value = Offset.zero;
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: VirtualThumbstick(
              size: 150,
              knobRadius: 25,
              onChanged: (x, y) => value = Offset(x, y),
            ),
          ),
        ),
      );
      final center = tester.getCenter(find.byType(VirtualThumbstick));
      final gesture = await tester.startGesture(center);
      await gesture.moveTo(center + const Offset(65, 0));
      await gesture.moveTo(center + const Offset(70, 0));
      await tester.pump();
      expect(value, const Offset(1, 0));
      expect(haptics, [
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.lightImpact',
      ]);
      final knob = find.descendant(
        of: find.byType(VirtualThumbstick),
        matching: find.byType(Positioned),
      );
      expect(tester.widget<Positioned>(knob).left, 100);
      await gesture.up();
      expect(value, Offset.zero);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.widget<Positioned>(knob).left, inExclusiveRange(50, 100));
      await tester.pumpAndSettle();
      expect(tester.widget<Positioned>(knob).left, 50);
      expect(haptics.last, 'HapticFeedbackType.lightImpact');
      expect(haptics.length, 3);
    },
  );

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
