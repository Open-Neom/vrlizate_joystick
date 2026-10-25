import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _TestControllerLink implements VrControllerLink {
  final StreamController<Object?> incoming = StreamController<Object?>.broadcast();
  final List<Object> sentToController = <Object>[];
  bool _open = true;

  @override
  Stream<Object?> get messages => incoming.stream;

  @override
  bool get isOpen => _open;

  @override
  void add(Object data) {
    sentToController.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _open = false;
    await incoming.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('VrPassthroughSplitGestureController', () {
    test('arms when both thumbs tap inside center zone within sync window', () {
      final controller = VrPassthroughSplitGestureController();
      expect(controller.mode, VrPassthroughSplitGestureMode.idle);
      expect(controller.passthroughMix, 0.0);

      final changed1 = controller.onPointerDown(
        pointerId: 1,
        normX: 0.44,
        normY: 0.50,
        timestampUs: 100000,
      );
      expect(changed1, isFalse);
      expect(controller.mode, VrPassthroughSplitGestureMode.idle);

      final changed2 = controller.onPointerDown(
        pointerId: 2,
        normX: 0.56,
        normY: 0.50,
        timestampUs: 140000,
      );
      expect(changed2, isTrue);
      expect(controller.mode, VrPassthroughSplitGestureMode.armedCenterTap);
      expect(controller.isGestureActive, isTrue);
    });

    test('fast outward slide toggles passthrough 0% -> 100% -> 0%', () {
      final controller = VrPassthroughSplitGestureController();

      // First fast outward flick: 0% -> 100%
      controller.onPointerDown(
        pointerId: 1,
        normX: 0.46,
        normY: 0.50,
        timestampUs: 0,
      );
      controller.onPointerDown(
        pointerId: 2,
        normX: 0.54,
        normY: 0.50,
        timestampUs: 20000,
      );

      // Slide both thumbs rapidly outward within 200 ms (200,000 us)
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.14,
        normY: 0.50,
        timestampUs: 180000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.86,
        normY: 0.50,
        timestampUs: 200000,
      );
      expect(controller.mode, VrPassthroughSplitGestureMode.fastToggleSwipe);
      expect(controller.passthroughMix, 1.0);
      expect(controller.passthroughActive, isTrue);

      controller.onPointerUpOrCancel(pointerId: 1, timestampUs: 220000);
      controller.onPointerUpOrCancel(pointerId: 2, timestampUs: 230000);
      expect(controller.passthroughMix, 1.0);

      // Second fast outward flick: 100% -> 0%
      controller.onPointerDown(
        pointerId: 3,
        normX: 0.46,
        normY: 0.50,
        timestampUs: 500000,
      );
      controller.onPointerDown(
        pointerId: 4,
        normX: 0.54,
        normY: 0.50,
        timestampUs: 520000,
      );
      controller.onPointerMove(
        pointerId: 3,
        normX: 0.12,
        normY: 0.50,
        timestampUs: 680000,
      );
      controller.onPointerMove(
        pointerId: 4,
        normX: 0.88,
        normY: 0.50,
        timestampUs: 700000,
      );
      controller.onPointerUpOrCancel(pointerId: 3, timestampUs: 720000);
      expect(controller.passthroughMix, 0.0);
      expect(controller.passthroughActive, isFalse);
    });

    test('slow outward slide blends virtual world and passthrough at mix %', () {
      final controller = VrPassthroughSplitGestureController();

      controller.onPointerDown(
        pointerId: 1,
        normX: 0.46,
        normY: 0.50,
        timestampUs: 0,
      );
      controller.onPointerDown(
        pointerId: 2,
        normX: 0.54,
        normY: 0.50,
        timestampUs: 20000,
      );

      // Moderate-slow outward slide (spread ~0.50 over 550 ms -> speed ~0.91/s)
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.27,
        normY: 0.50,
        timestampUs: 550000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.73,
        normY: 0.50,
        timestampUs: 570000,
      );

      expect(controller.mode, VrPassthroughSplitGestureMode.slowMixBlend);
      expect(controller.passthroughMix, closeTo(0.50, 0.08));

      // Release thumbs: mix stays latched at ~50%
      controller.onPointerUpOrCancel(pointerId: 1, timestampUs: 600000);
      expect(controller.passthroughMix, closeTo(0.50, 0.08));
      expect(controller.passthroughActive, isTrue);
    });

    test('ultra-slow outward traversal sweeps passthrough 0% -> 100% -> 0%', () {
      final controller = VrPassthroughSplitGestureController();

      controller.onPointerDown(
        pointerId: 1,
        normX: 0.46,
        normY: 0.50,
        timestampUs: 0,
      );
      controller.onPointerDown(
        pointerId: 2,
        normX: 0.54,
        normY: 0.50,
        timestampUs: 10000,
      );

      // 1) Halfway to edges (spread = 0.50) reached slowly at t = 1.2s -> 100% mix
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.27,
        normY: 0.50,
        timestampUs: 1200000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.73,
        normY: 0.50,
        timestampUs: 1210000,
      );
      expect(
        controller.mode,
        VrPassthroughSplitGestureMode.ultraSlowCycleZeroToHundredToZero,
      );
      expect(controller.passthroughMix, closeTo(1.0, 0.05));

      // 2) Continue ultra-slowly to outer edges (spread = 1.0) at t = 2.4s -> 0% mix
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.08,
        normY: 0.50,
        timestampUs: 2400000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.92,
        normY: 0.50,
        timestampUs: 2410000,
      );
      expect(
        controller.mode,
        VrPassthroughSplitGestureMode.ultraSlowCycleZeroToHundredToZero,
      );
      expect(controller.passthroughMix, closeTo(0.0, 0.02));
      expect(controller.passthroughActive, isFalse);
    });

    test('vertical thumb band selects fullCameraFeed, hybrid, or aiWireframeOnly', () {
      final controller = VrPassthroughSplitGestureController();

      // Upper band (normY = 0.20 < 0.35) -> fullCameraFeed
      controller.onPointerDown(
        pointerId: 1,
        normX: 0.45,
        normY: 0.20,
        timestampUs: 0,
      );
      controller.onPointerDown(
        pointerId: 2,
        normX: 0.55,
        normY: 0.20,
        timestampUs: 10000,
      );
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.25,
        normY: 0.20,
        timestampUs: 500000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.75,
        normY: 0.20,
        timestampUs: 510000,
      );
      expect(controller.visualStyle, VrPassthroughVisualStyle.fullCameraFeed);
      expect(controller.curtainLeftNormX, closeTo(0.25, 1e-4));
      expect(controller.curtainRightNormX, closeTo(0.75, 1e-4));

      // Lower band (normY = 0.80 > 0.65) -> aiWireframeOnly
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.20,
        normY: 0.80,
        timestampUs: 700000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.80,
        normY: 0.80,
        timestampUs: 710000,
      );
      expect(controller.visualStyle, VrPassthroughVisualStyle.aiWireframeOnly);
    });

    test('dual-thumb center double-tap triggers 3D echolocation sonar pulse', () {
      final controller = VrPassthroughSplitGestureController();

      // First short dual-thumb tap in center
      controller.onPointerDown(
        pointerId: 1,
        normX: 0.47,
        normY: 0.50,
        timestampUs: 0,
      );
      controller.onPointerDown(
        pointerId: 2,
        normX: 0.53,
        normY: 0.50,
        timestampUs: 10000,
      );
      controller.onPointerUpOrCancel(pointerId: 1, timestampUs: 90000);
      controller.onPointerUpOrCancel(pointerId: 2, timestampUs: 95000);
      expect(controller.isSonarPulseActive, isFalse);

      // Second short dual-thumb tap in center within 450 ms
      controller.onPointerDown(
        pointerId: 3,
        normX: 0.47,
        normY: 0.50,
        timestampUs: 220000,
      );
      controller.onPointerDown(
        pointerId: 4,
        normX: 0.53,
        normY: 0.50,
        timestampUs: 230000,
      );
      controller.onPointerUpOrCancel(pointerId: 3, timestampUs: 310000);
      controller.onPointerUpOrCancel(pointerId: 4, timestampUs: 315000);

      expect(controller.isSonarPulseActive, isTrue);
      expect(
        controller.visualStyle,
        VrPassthroughVisualStyle.sonarEcholocationPulse,
      );

      // Halfway through 1.2s sonar pulse (t = 310ms + 600ms = 910,000 us) -> 100% envelope peak
      final midProgress = controller.evaluateSonarPulseProgress(910000);
      expect(midProgress, closeTo(0.50, 0.02));
      expect(controller.passthroughMix, closeTo(1.0, 0.02));

      // After 1.2s -> automatically returns to 0%
      final endProgress = controller.evaluateSonarPulseProgress(1600000);
      expect(endProgress, 0.0);
      expect(controller.passthroughMix, 0.0);
      expect(controller.isSonarPulseActive, isFalse);
    });
  });

  group('Vision & Ultrasonic Telemetry Binding over BLE / Wi-Fi', () {
    test('VrJoystickCameraVisionService builds compact BLE payload without mini-frame and full Wi-Fi payload with mini-frame', () async {
      final service = VrJoystickCameraVisionService();
      addTearDown(service.dispose);

      // Build a 24x18 floor frame with left foot around (u=0.28, v=0.75) and right foot around (u=0.72, v=0.80)
      final mini = Uint8List(24 * 18)..fillRange(0, 24 * 18, 40);
      for (var y = 11; y <= 15; y++) {
        for (var x = 5; x <= 8; x++) {
          mini[y * 24 + x] = 225;
        }
        for (var x = 15; x <= 19; x++) {
          mini[y * 24 + x] = 235;
        }
      }
      service.ingestSyntheticMiniFrame(
        mini,
        role: 'rear',
        ultrasonicEchoMeters: 0.59,
        ultrasonicSnrDb: 9.2,
      );

      final blePayload = service.buildVisionTelemetryPayload(
        includeMiniFrame: false,
      );
      expect(blePayload, isNotNull);
      expect(
        blePayload![VrJoystickConstants.fieldType],
        VrJoystickConstants.visionTelemetryMessageType,
      );
      expect(
        blePayload.containsKey(VrJoystickConstants.fieldJoystickMiniFrame),
        isFalse,
      );
      expect(
        blePayload[VrJoystickConstants.fieldRangeMeters],
        isNull,
      );
      expect(
        blePayload[VrJoystickConstants.fieldLeftFootU],
        lessThan(0.45),
      );
      expect(
        blePayload[VrJoystickConstants.fieldRightFootU],
        greaterThan(0.55),
      );

      final wifiPayload = service.buildVisionTelemetryPayload(
        includeMiniFrame: true,
      );
      expect(wifiPayload, isNotNull);
      expect(
        wifiPayload![VrJoystickConstants.fieldJoystickMiniFrame],
        isA<String>(),
      );
      expect(
        (wifiPayload[VrJoystickConstants.fieldJoystickMiniFrame] as String)
            .isNotEmpty,
        isTrue,
      );
    });

    test('VrRemoteControllerService latches visionTelemetry and preserves feet/hands/ultrasonic across watchdog neutralization', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      var nowUs = 1000000;
      final service = VrRemoteControllerService(
        sessionToken: 'test_token_123',
        inputTimeout: const Duration(milliseconds: 100),
        watchdogInterval: const Duration(milliseconds: 20),
        nowMicroseconds: () => nowUs,
      );
      addTearDown(service.dispose);

      // Attach an in-memory duplex controller link
      final link = _TestControllerLink();
      expect(
        service.attachControllerLink(
          link,
          sessionToken: 'test_token_123',
        ),
        isTrue,
      );

      // 1) Send a visionTelemetry control envelope (Cám 2 floor/feet + Cám 3 hands + Ultrasonic range)
      link.incoming.add(
        '{"type":"vrlizate.visionTelemetry","rangeMeters":0.61,"leftFootU":0.33,"leftFootV":0.79,"rightFootU":0.67,"rightFootV":0.81,"handU":0.51,"handV":0.59,"visorU":0.50,"visorV":0.26,"visorWidth":0.35,"joystickCameraRole":"rear_floor"}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));

      expect(service.latestState.rangeMeters, closeTo(0.61, 1e-3));
      expect(service.latestState.leftFootU, closeTo(0.33, 1e-3));
      expect(service.latestState.leftFootV, closeTo(0.79, 1e-3));
      expect(service.latestState.rightFootU, closeTo(0.67, 1e-3));
      expect(service.latestState.rightFootV, closeTo(0.81, 1e-3));
      expect(service.latestState.handU, closeTo(0.51, 1e-3));
      expect(service.latestState.handV, closeTo(0.59, 1e-3));
      expect(service.latestState.joystickCameraRole, 'rear_floor');

      // 2) Send a joystick stick movement, then let the 100ms input watchdog expire
      link.incoming.add(
        '{"sequence":1,"qx":0,"qy":0,"qz":0,"qw":1,"stickX":0.8,"stickY":-0.5,"btnA":true}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(service.latestState.stickX, closeTo(0.8, 1e-3));
      expect(service.latestState.btnA, isTrue);

      // Advance clock past 100ms timeout so watchdog neutralizes stick/buttons
      nowUs += 250000;
      await Future<void>.delayed(const Duration(milliseconds: 45));

      expect(service.latestState.stickX, 0.0);
      expect(service.latestState.btnA, isFalse);
      // Latched spatial perception inputs MUST remain intact!
      expect(service.latestState.rangeMeters, closeTo(0.61, 1e-3));
      expect(service.latestState.leftFootU, closeTo(0.33, 1e-3));
      expect(service.latestState.rightFootU, closeTo(0.67, 1e-3));
      expect(service.latestState.handU, closeTo(0.51, 1e-3));
      expect(service.latestState.joystickCameraRole, 'rear_floor');

      // Expiration is explicit; do not revive the old range via HUD or input.
      link.incoming.add(
        '{"type":"vrlizate.visionTelemetry","rangeMeters":null}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(service.latestState.rangeMeters, isNull);
      service.setPassthroughMix(0.65);
      expect(service.latestState.rangeMeters, isNull);
      link.incoming.add('{"sequence":2,"stickX":0.2,"qw":1}');
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(service.latestState.rangeMeters, isNull);
      nowUs += 250000;
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(service.latestState.rangeMeters, isNull);
      link.incoming.add(
        '{"sequence":3,"qw":1,"rangeMeters":0.7}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(service.latestState.rangeMeters, closeTo(0.7, 1e-3));
      link.incoming.add(
        '{"sequence":4,"qw":1,"rangeMeters":null,"range":0.5}',
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(service.latestState.rangeMeters, isNull);
    });
  });
}
