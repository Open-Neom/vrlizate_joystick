import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String reason = 'condition',
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 5)) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Timed out waiting for $reason.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorChannels = <String>[
    'dev.fluttercommunity.plus/sensors/method',
    'dev.fluttercommunity.plus/sensors/gyroscope',
    'dev.fluttercommunity.plus/sensors/accelerometer',
    'dev.fluttercommunity.plus/sensors/user_accel',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    for (final channel in sensorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });

  tearDown(() {
    for (final channel in sensorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  group('VrOneHandedLaserDetector', () {
    test('detects transition from 2-hand flat grip to 1-hand laser pointing grip', () {
      final detector = VrOneHandedLaserDetector();

      // Flat landscape 2-handed grip (gx ~ 9.81, gy ~ 0) never switches
      expect(
        detector.shouldSwitchToLaser(
          gx: 9.81,
          gy: 0.2,
          gz: 0.1,
          omegaMagnitude: 0.5,
          dualTouchActive: false,
          timestampUs: 0,
        ),
        isFalse,
      );

      // Dual touch active blocks switching even when tilted
      expect(
        detector.shouldSwitchToLaser(
          gx: 4.0,
          gy: 7.5,
          gz: 5.0,
          omegaMagnitude: 0.6,
          dualTouchActive: true,
          timestampUs: 100000,
        ),
        isFalse,
      );

      // One-handed lateral pointing grip starts candidate timer
      expect(
        detector.shouldSwitchToLaser(
          gx: 4.0,
          gy: 7.5,
          gz: 5.0,
          omegaMagnitude: 0.6,
          dualTouchActive: false,
          timestampUs: 200000,
        ),
        isFalse,
      );

      // Holding one-handed pointing grip past switchHoldUs (200ms) activates laser mode
      expect(
        detector.shouldSwitchToLaser(
          gx: 4.0,
          gy: 7.5,
          gz: 5.0,
          omegaMagnitude: 0.4,
          dualTouchActive: false,
          timestampUs: 450000,
        ),
        isTrue,
      );
      expect(detector.isOneHandedLaserActive, isTrue);

      // Returning to level 2-hand landscape posture for returnHoldUs (350ms) returns to joystick
      expect(
        detector.shouldReturnToJoystick(
          gx: 9.6,
          gy: 0.3,
          gz: 1.5,
          timestampUs: 500000,
        ),
        isFalse,
      );
      expect(
        detector.shouldReturnToJoystick(
          gx: 9.6,
          gy: 0.3,
          gz: 1.5,
          timestampUs: 900000,
        ),
        isTrue,
      );
      expect(detector.isOneHandedLaserActive, isFalse);
    });
  });

  group('VrLaserSteadyDwellController', () {
    test('triggers auto-click after 5.0 seconds of steady aiming and resets on movement', () {
      final dwell = VrLaserSteadyDwellController();
      expect(dwell.dwellDurationSeconds, closeTo(5.0, 1e-6));
      expect(dwell.progress, 0.0);

      // Accumulate 2.5 seconds steady (10 steps of 0.25s)
      for (var i = 0; i < 10; i++) {
        expect(
          dwell.update(angularSpeedRadiansPerSec: 0.1, dtSeconds: 0.25),
          isFalse,
        );
      }
      expect(dwell.progress, closeTo(0.5, 1e-5));
      expect(dwell.remainingSeconds, closeTo(2.5, 1e-5));

      // Fast phone movement resets progress to 0
      expect(
        dwell.update(angularSpeedRadiansPerSec: 1.2, dtSeconds: 0.1),
        isFalse,
      );
      expect(dwell.progress, 0.0);

      // Hold steady for a full 5.0 seconds (20 steps of 0.25s)
      var triggeredCount = 0;
      for (var i = 0; i < 20; i++) {
        if (dwell.update(angularSpeedRadiansPerSec: 0.08, dtSeconds: 0.25)) {
          triggeredCount++;
        }
      }
      expect(triggeredCount, 1);
      expect(dwell.progress, closeTo(1.0, 1e-5));

      // Subsequent steady frames do not spam repeated clicks until re-armed
      expect(
        dwell.update(angularSpeedRadiansPerSec: 0.05, dtSeconds: 0.25),
        isFalse,
      );
    });
  });

  group('PhoneControllerPage One-Handed Laser, Tap/5s Click & Wordsphere Search', () {
    testWidgets(
      'auto-switches to full-screen laser view on 1-hand posture, aims with gyro, clicks on tap or 5s wait, and opens Wordsphere on long press',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(840, 390));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final service = VrRemoteControllerService(
          inputTimeout: const Duration(seconds: 15),
        );
        addTearDown(service.dispose);
        expect(await tester.runAsync(() => service.startServer(port: 0)), isTrue);

        await tester.pumpWidget(
          MaterialApp(
            home: PhoneControllerPage(
              initialMode: RemoteControllerMode.joystick,
              targetHost: '127.0.0.1',
              targetPort: service.serverPort!,
              sessionToken: service.sessionToken,
              autoConnect: true,
            ),
          ),
        );
        await _pumpUntil(tester, () => service.isConnected, reason: 'connected');
        expect(find.byType(VirtualThumbstick), findsNWidgets(2));

        // 1. Simulate moving the phone into a one-handed pointing grip
        void pushGyro(double x, double y, double z, double tsUs) {
          tester.binding.channelBuffers.push(
            'dev.fluttercommunity.plus/sensors/gyroscope',
            const StandardMethodCodec().encodeSuccessEnvelope(<double>[
              x,
              y,
              z,
              tsUs,
            ]),
            (_) {},
          );
        }

        void pushAccel(double x, double y, double z, double tsUs) {
          tester.binding.channelBuffers.push(
            'dev.fluttercommunity.plus/sensors/accelerometer',
            const StandardMethodCodec().encodeSuccessEnvelope(<double>[
              x,
              y,
              z,
              tsUs,
            ]),
            (_) {},
          );
        }

        pushGyro(0.2, 0.3, -0.4, 100000);
        await tester.pump(const Duration(milliseconds: 20));
        pushAccel(4.0, 7.6, 4.8, 120000);
        await tester.pump(const Duration(milliseconds: 250));
        pushAccel(4.0, 7.6, 4.8, 400000);
        await tester.pump(const Duration(milliseconds: 30));

        // Screen stops showing the dual joystick and shows VrLaserPointingView
        expect(find.byType(VirtualThumbstick), findsNothing);
        expect(
          find.byKey(const Key(VrJoystickConstants.keyLaserPointingSurface)),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key(VrJoystickConstants.keyLaserPointingReticle)),
          findsOneWidget,
        );
        await _pumpUntil(
          tester,
          () => service.latestState.mode == RemoteControllerMode.laser,
          reason: 'laser mode on host',
        );

        // 2. Moving the phone updates the 3D laser aim via gyroscope
        pushGyro(0.8, 0.0, -1.0, 500000);
        await tester.pump(const Duration(milliseconds: 20));
        pushGyro(0.8, 0.0, -1.0, 600000);
        await tester.pump(const Duration(milliseconds: 20));
        await _pumpUntil(
          tester,
          () =>
              service.latestState.laserX > 0.02 &&
              service.latestState.laserY > 0.02,
          reason: 'gyro laser aim movement',
        );

        // 3. Single Tap with the other hand immediately generates a Click
        final recordedStates = <RemoteControllerState>[];
        final sub = service.onState.listen(recordedStates.add);
        addTearDown(sub.cancel);

        await tester.tap(
          find.byKey(const Key(VrJoystickConstants.keyLaserPointingSurface)),
        );
        await tester.pump();
        await _pumpUntil(
          tester,
          () => recordedStates.any((s) => s.isTriggerPressed && s.btnA),
          reason: 'free-hand tap click',
        );
        // Wait for pulse release
        await tester.pump(const Duration(milliseconds: 200));
        await _pumpUntil(
          tester,
          () => !service.latestState.isTriggerPressed && !service.latestState.btnA,
          reason: 'tap click release',
        );

        // 4. Waiting 5 seconds aiming steadily triggers an automatic Click
        recordedStates.clear();
        pushGyro(0.0, 0.0, 0.0, 700000);
        await tester.pump(const Duration(milliseconds: 20));
        for (var i = 0; i < 25; i++) {
          await tester.pump(const Duration(milliseconds: 220));
        }
        await _pumpUntil(
          tester,
          () => recordedStates.any((s) => s.isTriggerPressed && s.btnA),
          reason: '5-second steady dwell auto-click',
        );
        await tester.pump(const Duration(milliseconds: 200));

        // 5. Long Press with the other hand opens Wordsphere Search Sheet
        await tester.longPress(
          find.byKey(const Key(VrJoystickConstants.keyLaserPointingSurface)),
        );
        await tester.pump();
        expect(
          find.byKey(const Key(VrJoystickConstants.keyWordsphereSearchSheet)),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key(VrJoystickConstants.keyWordsphereBoard)),
          findsOneWidget,
        );

        // Selecting a destination or submitting Wordsphere text sends searchQuery + searchSubmitted
        recordedStates.clear();
        await tester.tap(
          find.byKey(
            const Key(
              '${VrJoystickConstants.keyWordsphereDestinationChipPrefix}Mall VR',
            ),
          ),
        );
        await tester.pump();
        await _pumpUntil(
          tester,
          () => recordedStates.any(
            (s) => s.searchQuery == 'Mall VR' && s.searchSubmitted,
          ),
          reason: 'Wordsphere destination search submitted',
        );

        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpUntil(tester, () => !service.isConnected);
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull);
      },
    );
  });
}
