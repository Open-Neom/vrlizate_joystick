import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _TestLink implements VrControllerLink {
  final inbound = StreamController<Object?>();
  final packets = <Map<String, dynamic>>[];
  bool open = true;

  @override
  Stream<Object?> get messages => inbound.stream;

  @override
  bool get isOpen => open;

  @override
  void add(Object data) {
    final decoded = jsonDecode(data as String);
    if (decoded is Map<String, dynamic>) {
      packets.add(decoded);
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!open) return;
    open = false;
    await inbound.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      VrJoystickConstants.prefKeyHapticsEnabled: false,
    });
  });

  group('1. Dynamic / Floating Touch Origin (nipplejs / AirConsole inspired)', () {
    testWidgets(
      'off-center blind touch anchors (0, 0) at initial contact and still reaches 100% rim',
      (tester) async {
        final samples = <(double, double)>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: VirtualThumbstick(
                  size: 160,
                  knobRadius: 28,
                  deadzone: 0.05,
                  dynamicTouchOrigin: true,
                  hapticsEnabled: false,
                  onChanged: (x, y) => samples.add((x, y)),
                ),
              ),
            ),
          ),
        );

        final stickFinder = find.byType(VirtualThumbstick);
        final center = tester.getCenter(stickFinder);

        // User touches 14px to the right and 10px below geometric center
        // without looking (wearing VR visor).
        final gesture = await tester.startGesture(center + const Offset(14, 10));
        await tester.pump();
        expect(samples.last, (0.0, 0.0));

        // Dragging right from the floating origin reaches full +1.0 deflection.
        await gesture.moveBy(const Offset(80, 0));
        await tester.pump();
        expect(samples.last.$1, closeTo(1.0, 1e-4));
        expect(samples.last.$2, closeTo(0.0, 1e-4));

        await gesture.up();
        await tester.pump();
        expect(samples.last, (0.0, 0.0));
      },
    );
  });

  group('2. Radial & Cardinal Haptic Detents (Steam Controller / VirtualGamePad)', () {
    test('triggers mid-ring (50%), outer-rim (92%), and 4 cardinal axis detents with hysteresis', () {
      final controller = VrThumbstickHapticDetentController();

      // Below 50%: no detent
      expect(controller.evaluate(0.20, 0.15), isNull);

      // Crossing 50% mid-ring along a non-cardinal diagonal (45 deg)
      expect(
        controller.evaluate(0.42, 0.42),
        VrHapticPatternPreset.lightTap,
      );
      expect(controller.isInMidRing, isTrue);

      // Crossing 92% sprint rim along 45 deg
      expect(
        controller.evaluate(0.70, 0.70),
        VrHapticPatternPreset.buttonPress,
      );
      expect(controller.isInOuterRim, isTrue);

      // Sweeping onto the 90 deg (Up / North) cardinal axis triggers a cardinal detent
      expect(
        controller.evaluate(0.0, 0.75),
        VrHapticPatternPreset.lightTap,
      );
      expect(controller.activeCardinalIndex, 1);

      // Small wobble within hysteresis does not re-trigger
      expect(controller.evaluate(0.04, 0.75), isNull);

      // Sweeping to 0 deg (Right / East) triggers cardinal index 0
      expect(controller.evaluate(0.55, 0.55), isNull);
      expect(
        controller.evaluate(0.75, 0.0),
        VrHapticPatternPreset.lightTap,
      );
      expect(controller.activeCardinalIndex, 0);
    });
  });

  group('3. Flick Stick & Comfort Snap-Turn (JoyShockMapper inspired)', () {
    test('comfortSnapTurn fires a discrete step pulse and waits for cooldown/re-arm', () {
      final controller = VrFlickStickController();

      // Deflect right past threshold (0.85 >= 0.72)
      final first = controller.update(
        mode: VrRightStickLookMode.comfortSnapTurn,
        x: 0.85,
        y: 0.0,
        dtSeconds: 0.016,
      );
      expect(first, 1.0);

      // Advance past pulse duration (0.12s) while still holding right -> output drops to 0.0
      final afterPulse = controller.update(
        mode: VrRightStickLookMode.comfortSnapTurn,
        x: 0.85,
        y: 0.0,
        dtSeconds: 0.15,
      );
      expect(afterPulse, 0.0);

      // Re-center to re-arm and wait out cooldown
      controller.update(
        mode: VrRightStickLookMode.comfortSnapTurn,
        x: 0.0,
        y: 0.0,
        dtSeconds: 0.35,
      );

      // Next snap left emits -1.0
      final leftSnap = controller.update(
        mode: VrRightStickLookMode.comfortSnapTurn,
        x: -0.90,
        y: 0.0,
        dtSeconds: 0.016,
      );
      expect(leftSnap, -1.0);
    });

    test('flickStick snaps to initial rim angle and sweeps 1:1 along rim', () {
      final controller = VrFlickStickController();

      // Flick stick to 90 deg right (x = 1.0, y = 0.0)
      final snapTurn = controller.update(
        mode: VrRightStickLookMode.flickStick,
        x: 1.0,
        y: 0.0,
        dtSeconds: 0.05,
      );
      expect(controller.isFlickEngaged, isTrue);
      expect(snapTurn, greaterThan(0.25));

      // Complete initial snap
      controller.update(
        mode: VrRightStickLookMode.flickStick,
        x: 1.0,
        y: 0.0,
        dtSeconds: 0.15,
      );

      // Sweep clockwise toward bottom-right (x = 0.707, y = -0.707) -> positive turn
      final sweepRight = controller.update(
        mode: VrRightStickLookMode.flickStick,
        x: 0.707,
        y: -0.707,
        dtSeconds: 0.032,
      );
      expect(sweepRight, greaterThan(0.1));

      // Release to center disengages flick stick
      final released = controller.update(
        mode: VrRightStickLookMode.flickStick,
        x: 0.0,
        y: 0.0,
        dtSeconds: 0.016,
      );
      expect(released, 0.0);
      expect(controller.isFlickEngaged, isFalse);
    });
  });

  group('4. Double-Tap (L3/R3) & Auto-Walk / Sprint Lock (moonlight-android)', () {
    test('double-tap + forward rim push latches Auto-Walk Lock and next touch cancels', () {
      final controller = VrAutoWalkLockController();

      // First tap near center
      expect(controller.onPointerDown(100000), isFalse);
      controller.onStickChanged(
        0.0,
        0.05,
        timestampUs: 150000,
        autoWalkEnabled: true,
      );
      expect(
        controller.onPointerUp(200000, autoWalkEnabled: true),
        isFalse,
      );

      // Second tap within 360ms -> emits stickClick (true)
      expect(controller.onPointerDown(320000), isTrue);

      // Push forward to upper rim (0.0, 0.95) and release -> latches Auto-Walk Lock
      controller.onStickChanged(
        0.0,
        0.95,
        timestampUs: 450000,
        autoWalkEnabled: true,
      );
      expect(
        controller.onPointerUp(560000, autoWalkEnabled: true),
        isTrue,
      );
      expect(controller.isAutoWalkLocked, isTrue);
      expect(controller.lockedStickY, 1.0);

      // Next touch on the left stick immediately cancels Auto-Walk Lock
      expect(controller.onPointerDown(900000), isFalse);
      expect(controller.isAutoWalkLocked, isFalse);
    });
  });

  group('5. Inertial Virtual Trackball (Steam Controller inspired)', () {
    test('coasts with exponential friction after flick release and stops on touch', () {
      final trackball = VrInertialTrackballController();

      trackball.onTouchDown(100000);
      trackball.onTouchMove(0.25, 0.0, timestampUs: 116000);
      trackball.onTouchMove(0.75, 0.0, timestampUs: 132000);
      trackball.onTouchUp();

      expect(trackball.isCoasting, isTrue);
      final step1 = trackball.advance(0.05);
      final step2 = trackball.advance(0.05);
      expect(step1.x, greaterThan(step2.x));
      expect(step2.x, greaterThan(0.0));

      // Touching the pad halts inertia immediately
      trackball.onTouchDown(300000);
      expect(trackball.isCoasting, isFalse);
      expect(trackball.advance(0.05).x, 0.0);
    });
  });

  testWidgets(
    'PhoneControllerPage exposes new ergonomic toggles and right-stick look modes in Settings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final link = _TestLink();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            allowWifiConnection: false,
            autoConnect: true,
            linkConnector: () async => link,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      final dynamicOriginToggle = find.byKey(
        const ValueKey(VrJoystickConstants.keyControllerDynamicOriginToggle),
      );
      final cardinalDetentsToggle = find.byKey(
        const ValueKey(VrJoystickConstants.keyControllerCardinalDetentsToggle),
      );
      final autoWalkToggle = find.byKey(
        const ValueKey(VrJoystickConstants.keyControllerAutoWalkToggle),
      );
      final lookModeSelector = find.byKey(
        const ValueKey(VrJoystickConstants.keyControllerRightLookModeSelector),
      );

      await tester.ensureVisible(dynamicOriginToggle);
      expect(dynamicOriginToggle, findsOneWidget);
      await tester.ensureVisible(cardinalDetentsToggle);
      expect(cardinalDetentsToggle, findsOneWidget);
      await tester.ensureVisible(autoWalkToggle);
      expect(autoWalkToggle, findsOneWidget);
      await tester.ensureVisible(lookModeSelector);
      expect(lookModeSelector, findsOneWidget);

      await tester.tap(
        find.text(VrJoystickTranslationConstants.rightLookModeSnapLabel),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byIcon(Icons.close_rounded));
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
