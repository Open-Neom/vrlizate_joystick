import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String reason = 'condition',
  String Function()? diagnostics,
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 5)) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  fail('Timed out waiting for $reason. ${diagnostics?.call() ?? ''}');
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
    test('requires upright landscape; lateral roll never switches', () {
      final detector = VrOneHandedLaserDetector();
      for (var t = 0; t <= 500000; t += 20000) {
        expect(
          detector.shouldSwitchToLaser(
            gx: 4,
            gy: 7.5,
            gz: 5,
            omegaMagnitude: .6,
            dualTouchActive: false,
            timestampUs: t,
          ),
          isFalse,
        );
      }
      var switches = 0;
      for (var t = 520000; t <= 900000; t += 20000) {
        if (detector.shouldSwitchToLaser(
          gx: 9.81,
          gy: .1,
          gz: .1,
          omegaMagnitude: 0,
          dualTouchActive: false,
          timestampUs: t,
        )) {
          switches++;
        }
      }
      expect(switches, 1);
      expect(detector.isOneHandedLaserActive, isTrue);
      detector.setModeActive(false);
      expect(
        detector.shouldSwitchToLaser(
          gx: 9.81,
          gy: .1,
          gz: .1,
          omegaMagnitude: 0,
          dualTouchActive: false,
          timestampUs: 920000,
        ),
        isFalse,
        reason: 'Manual gamepad selection wins until posture exits',
      );
    });

    test('touch or fast motion cannot cause automatic layout changes', () {
      final detector = VrOneHandedLaserDetector();
      for (var t = 0; t <= 400000; t += 20000) {
        expect(
          detector.shouldSwitchToLaser(
            gx: 9.81,
            gy: .1,
            gz: .1,
            omegaMagnitude: .1,
            dualTouchActive: true,
            timestampUs: t,
          ),
          isFalse,
        );
      }
      expect(
        detector.shouldSwitchToLaser(
          gx: 9.81,
          gy: .1,
          gz: .1,
          omegaMagnitude: 3,
          dualTouchActive: false,
          timestampUs: 420000,
        ),
        isFalse,
      );
    });
  });

  group('VrLaserSteadyDwellController', () {
    test(
      'triggers auto-click after 5.0 seconds of steady aiming and resets on movement',
      () {
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
      },
    );
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
        service.requestControllerMode(
          RemoteControllerMode.joystick,
          actions: const {VrJoystickConstants.actionKeyA: 'QA READY'},
        );
        expect(
          await tester.runAsync(() => service.startServer(port: 0)),
          isTrue,
        );

        var testClockUs = 0;
        final diagnosticStates = <Map<String, Object?>>[];
        final diagnosticSub = service.onState.listen((state) {
          if (diagnosticStates.length == 24) diagnosticStates.removeAt(0);
          diagnosticStates.add({
            'clockUs': testClockUs,
            'mode': state.mode.name,
            'pose': state.pointerPoseReady,
            'visible': state.controllerVisible,
            'laserX': state.laserX,
            'laserY': state.laserY,
            'motion': state.motionAvailable,
            'neutral': state.isNeutralized,
            'orientation': [
              state.orientation.x,
              state.orientation.y,
              state.orientation.z,
              state.orientation.w,
            ],
          });
        });
        addTearDown(diagnosticSub.cancel);
        await tester.pumpWidget(
          MaterialApp(
            home: PhoneControllerPage(
              initialMode: RemoteControllerMode.joystick,
              autoSwitchToOneHandedLaser: true,
              monotonicMicroseconds: () => testClockUs,
              targetHost: '127.0.0.1',
              targetPort: service.serverPort!,
              sessionToken: service.sessionToken,
              autoConnect: true,
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () => service.isConnected,
          reason: 'connected',
        );
        // Server attachment precedes delivery of its initial profile. Wait for
        // a caption from that exact request so its neutral mode reset cannot
        // race the synthetic posture/gyro stream in this fake-time test.
        await _pumpUntil(
          tester,
          () => find.textContaining('QA READY').evaluate().isNotEmpty,
          reason: 'initial host profile applied on controller',
        );
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

        var sensorUs = 100000.0;
        Future<void> pointingFor(
          int milliseconds, {
          double gyroX = 0,
          double gyroY = 0,
        }) async {
          for (var i = 0; i < milliseconds; i += 20) {
            sensorUs += 20000;
            testClockUs += 20000;
            pushGyro(gyroX, gyroY, 0, sensorUs);
            pushAccel(9.81, .1, .1, sensorUs);
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        // Sideways/portrait tilt no longer opens the laser layout.
        for (var i = 0; i < 20; i++) {
          sensorUs += 20000;
          testClockUs += 20000;
          pushGyro(.2, .3, -.4, sensorUs);
          pushAccel(4, 7.6, 4.8, sensorUs);
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.byType(VirtualThumbstick), findsNWidgets(2));
        await pointingFor(280);

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

        // 2. Feed a continuous native-rate rotation with fresh posture samples.
        // A startup/mode handoff can reset one gyro delta; a real movement is
        // a stream, rather than two isolated packets followed by stale gravity.
        await pointingFor(300, gyroX: -1, gyroY: -.8);
        await _pumpUntil(
          tester,
          () =>
              service.latestState.laserX > 0.02 &&
              service.latestState.laserY > 0.02,
          reason: 'gyro laser aim movement',
          diagnostics: () {
            final views = find.byType(VrLaserPointingView).evaluate();
            final view = views.isEmpty
                ? null
                : views.single.widget as VrLaserPointingView;
            return jsonEncode({
              'clockUs': testClockUs,
              'sensorUs': sensorUs,
              'localAim': view == null ? null : [view.aimX, view.aimY],
              'localAngles': view == null
                  ? null
                  : [view.yawDegrees, view.pitchDegrees],
              'localReady': view?.pointingReady,
              'receiver': service.latestState.toString(),
              'packets': diagnosticStates,
            });
          },
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
        // Wait for pulse release with a fresh observed posture.
        await pointingFor(200);
        await _pumpUntil(
          tester,
          () =>
              !service.latestState.isTriggerPressed &&
              !service.latestState.btnA,
          reason: 'tap click release',
        );

        // 4. Waiting 5 seconds aiming steadily triggers an automatic Click
        recordedStates.clear();
        await pointingFor(5500);
        await _pumpUntil(
          tester,
          () => recordedStates.any((s) => s.isTriggerPressed && s.btnA),
          reason: '5-second steady dwell auto-click',
        );
        await tester.pump(const Duration(milliseconds: 200));

        // A flat phone suppresses local reticle and both tap/dwell clicks.
        recordedStates.clear();
        sensorUs += 20000;
        testClockUs += 20000;
        pushAccel(.1, .1, 9.81, sensorUs);
        await tester.pump(const Duration(milliseconds: 40));
        expect(
          find.byKey(const Key(VrJoystickConstants.keyLaserPointingReticle)),
          findsNothing,
        );
        await tester.tap(
          find.byKey(const Key(VrJoystickConstants.keyLaserPointingSurface)),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          recordedStates.where((s) => s.isTriggerPressed || s.btnA),
          isEmpty,
        );
        await _pumpUntil(
          tester,
          () => !service.latestState.pointerPoseReady,
          reason: 'flat posture revoked on receiver',
        );

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
