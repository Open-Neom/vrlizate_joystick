import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _CapturedLink implements VrControllerLink {
  final inbound = StreamController<Object?>();
  final packets = <Map<String, dynamic>>[];
  bool _open = true;

  @override
  bool get isOpen => _open;

  @override
  Stream<Object?> get messages => inbound.stream;

  @override
  void add(Object data) =>
      packets.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    await inbound.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channels = [
    'dev.fluttercommunity.plus/sensors/method',
    'dev.fluttercommunity.plus/sensors/gyroscope',
    'dev.fluttercommunity.plus/sensors/accelerometer',
    'dev.fluttercommunity.plus/sensors/user_accel',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  tearDown(() {
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  group('VrJoystickTouchIntentArbiter', () {
    const stickCenter = Offset(200, 200);
    const stickRadius = 80.0;
    const labelPos = Offset(100, 320);

    test(
      'near-rim collar defers and hands off to stick on drag without firing button',
      () {
        final arbiter = VrJoystickTouchIntentArbiter();
        final downPos = stickCenter + const Offset(0, stickRadius + 10);
        expect(
          arbiter.onButtonPointerDown(
            pointerId: 1,
            isLeftWing: true,
            position: downPos,
            buttonLabelPosition: labelPos,
            stickCenter: stickCenter,
            stickRadius: stickRadius,
            timestampUs: 0,
          ),
          VrTouchIntentAction.defer,
        );

        expect(
          arbiter.onButtonPointerMove(
            pointerId: 1,
            position: downPos + const Offset(0, -7),
            timestampUs: 18000,
          ),
          VrTouchIntentAction.handoffToStick,
        );
        expect(arbiter.isHandedOffToStick(1), isTrue);

        expect(
          arbiter.onButtonPointerMove(
            pointerId: 1,
            position: downPos + const Offset(24, -18),
            timestampUs: 36000,
          ),
          VrTouchIntentAction.continueStickHandoff,
        );

        expect(
          arbiter.onButtonPointerEnd(1),
          VrTouchIntentAction.releaseStickHandoff,
        );
      },
    );

    test('near-rim collar stationary quick tap fires button cleanly', () {
      final arbiter = VrJoystickTouchIntentArbiter();
      final downPos = stickCenter + const Offset(0, stickRadius + 12);
      expect(
        arbiter.onButtonPointerDown(
          pointerId: 2,
          isLeftWing: false,
          position: downPos,
          buttonLabelPosition: labelPos,
          stickCenter: stickCenter,
          stickRadius: stickRadius,
          timestampUs: 0,
        ),
        VrTouchIntentAction.defer,
      );
      expect(
        arbiter.onButtonPointerEnd(2),
        VrTouchIntentAction.quickTapButton,
      );
    });

    test(
      'near-rim collar stationary hold fires button when defer timer expires',
      () {
        final arbiter = VrJoystickTouchIntentArbiter();
        final downPos = stickCenter + const Offset(0, stickRadius + 12);
        expect(
          arbiter.onButtonPointerDown(
            pointerId: 3,
            isLeftWing: true,
            position: downPos,
            buttonLabelPosition: labelPos,
            stickCenter: stickCenter,
            stickRadius: stickRadius,
            timestampUs: 0,
          ),
          VrTouchIntentAction.defer,
        );
        expect(
          arbiter.onDeferTimerExpired(3),
          VrTouchIntentAction.fireButtonDown,
        );
        expect(
          arbiter.onButtonPointerEnd(3),
          VrTouchIntentAction.releaseButton,
        );
      },
    );

    test('direct label tap fires immediately with 0 ms latency', () {
      final arbiter = VrJoystickTouchIntentArbiter();
      expect(
        arbiter.onButtonPointerDown(
          pointerId: 4,
          isLeftWing: false,
          position: labelPos + const Offset(4, -3),
          buttonLabelPosition: labelPos,
          stickCenter: stickCenter,
          stickRadius: stickRadius,
          timestampUs: 0,
        ),
        VrTouchIntentAction.fireButtonDown,
      );
    });

    test(
      'mid-button rapid inward sweep cancels accidental button and hands off to stick',
      () {
        final arbiter = VrJoystickTouchIntentArbiter();
        final downPos = stickCenter + const Offset(0, stickRadius + 34);
        expect(
          arbiter.onButtonPointerDown(
            pointerId: 5,
            isLeftWing: true,
            position: downPos,
            buttonLabelPosition: labelPos,
            stickCenter: stickCenter,
            stickRadius: stickRadius,
            timestampUs: 0,
          ),
          VrTouchIntentAction.fireButtonDown,
        );

        expect(
          arbiter.onButtonPointerMove(
            pointerId: 5,
            position: downPos + const Offset(0, -20),
            timestampUs: 60000,
          ),
          VrTouchIntentAction.cancelButtonAndHandoffToStick,
        );
        expect(
          arbiter.onButtonPointerEnd(5),
          VrTouchIntentAction.releaseStickHandoff,
        );
      },
    );

    test(
      'never hijacks a button press when the wing stick is already active',
      () {
        final arbiter = VrJoystickTouchIntentArbiter();
        final downPos = stickCenter + const Offset(0, stickRadius + 10);
        expect(
          arbiter.onButtonPointerDown(
            pointerId: 6,
            isLeftWing: true,
            position: downPos,
            buttonLabelPosition: labelPos,
            stickCenter: stickCenter,
            stickRadius: stickRadius,
            timestampUs: 0,
            stickAlreadyActiveOnWing: true,
          ),
          VrTouchIntentAction.fireButtonDown,
        );
      },
    );
  });

  group('PhoneControllerPage 1D-inspired style & smart stick inference', () {
    testWidgets(
      'renders MOVER/MIRAR thumbsticks and infers stick drag from near-rim button collar without firing button',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(915, 412));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final link = _CapturedLink();
        await tester.pumpWidget(
          MaterialApp(
            home: PhoneControllerPage(
              allowWifiConnection: false,
              linkConnector: () async => link,
              autoConnect: true,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(link.packets, isNotEmpty);

        // 1D console Yin-Yang pairs and equal-sized MOVER/MIRAR thumbsticks render.
        expect(find.byType(VrYinYangButtonPair), findsNWidgets(4));
        expect(find.text('MOVER'), findsOneWidget);
        expect(find.text('MIRAR'), findsOneWidget);

        // Locate a point on the top rim of the bottom-left Yin-Yang pair (X/Y)
        // hugging the lower rim of moveStick (away from X & Y label centers)
        // and drag smoothly into the stick.
        final moveStickRect = tester.getRect(
          find.byKey(const ValueKey('joystick_move_stick')),
        );
        final lookStickRect = tester.getRect(
          find.byKey(const ValueKey('joystick_look_stick')),
        );
        expect(lookStickRect.width, closeTo(moveStickRect.width, 0.5));

        final xyPairFinder = find.ancestor(
          of: find.byKey(const ValueKey('joystick_button_X')),
          matching: find.byType(VrYinYangButtonPair),
        );
        final xyPairRect = tester.getRect(xyPairFinder);
        // X/Y now sits directly ABOVE moveStick (matching 1D deck layout), so
        // its bottom rim hugs moveStick.top.
        final collarPoint = Offset(
          moveStickRect.center.dx,
          xyPairRect.bottom - 4,
        );
        expect(xyPairRect.contains(collarPoint), isTrue);

        final beforeCount = link.packets.length;
        final gesture = await tester.startGesture(collarPoint, pointer: 21);
        await tester.pump(const Duration(milliseconds: 12));
        // Still deferred -> neither X nor Y may have fired!
        expect(link.packets.last['btnX'], isFalse);
        expect(link.packets.last['btnY'], isFalse);

        // Drag down-right smoothly into the stick -> hands off to moveStick!
        await gesture.moveBy(const Offset(48, 32));
        await tester.pump(const Duration(milliseconds: 40));

        final handedPackets = link.packets.sublist(beforeCount);
        expect(handedPackets.any((p) => p['btnX'] == true), isFalse);
        expect(handedPackets.any((p) => p['btnY'] == true), isFalse);
        expect((link.packets.last['stickX'] as num), greaterThan(0.05));

        await gesture.up();
        await tester.pump(const Duration(milliseconds: 50));
        expect(link.packets.last['btnX'], isFalse);
        expect(link.packets.last['btnY'], isFalse);
        expect((link.packets.last['stickX'] as num), 0);

        // Direct tap on A lobe center fires btnA immediately (0 ms latency).
        final aFinder = find.byKey(const ValueKey('joystick_button_A'));
        final tapA = await tester.startGesture(
          tester.getCenter(aFinder),
          pointer: 22,
        );
        await tester.pump();
        expect(link.packets.last['btnA'], isTrue);
        await tapA.up();
        await tester.pump();
        expect(link.packets.last['btnA'], isFalse);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });
}
