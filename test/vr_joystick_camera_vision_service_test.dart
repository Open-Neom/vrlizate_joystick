import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/domain/services/vr_joystick_camera_vision_service.dart';
import 'package:vrlizate_joystick/utils/constants/vr_joystick_constants.dart';
import 'fixtures/body_pose_fixture.dart';

// The plugin exports CameraImage but not its platform-interface factory types.
// Use its retained method-channel factory to exercise actual plane layouts.
CameraImage image({
  int width = 24,
  int height = 18,
  int format = 35,
  required List<Map<String, Object>> planes,
}) {
  // ignore: deprecated_member_use
  return CameraImage.fromPlatformData({
    'width': width,
    'height': height,
    'format': format,
    'planes': planes,
  });
}

Map<String, Object> plane(
  Uint8List bytes,
  int rowStride, [
  int pixelStride = 1,
]) => {'bytes': bytes, 'bytesPerRow': rowStride, 'bytesPerPixel': pixelStride};

Uint8List checkerboard() => Uint8List.fromList(
  List.generate(432, (i) => ((i % 24) + i ~/ 24).isEven ? 20 : 235),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late int nowUs;
  late VrJoystickCameraVisionService service;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    nowUs = 0;
    service = VrJoystickCameraVisionService(monotonicMicroseconds: () => nowUs);
  });
  tearDown(() {
    service.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('hardware and sonar need opt-in; stable lens is the default', () async {
    expect(service.enableHardwareCameraStream, isFalse);
    expect(service.enableUltrasonicRanging, isFalse);
    expect(service.autoMultiplexLenses, isFalse);
    expect(service.bodyDetectionEnabled, isFalse);
    expect(service.bodyPresent, isFalse);
    expect(service.bodyStatus, 'disabled');
    await service.start();
    expect(service.isCameraStreaming, isFalse);
    expect(service.hasCameraSample, isFalse);
    expect(service.cameraSampleAge, isNull);
    expect(service.buildVisionTelemetryPayload(), isNull);
  });

  test('burst drops before sampling and accepts only the latest due frame', () {
    var notifications = 0;
    service.addListener(() => notifications++);
    final first = image(
      planes: [plane(Uint8List(432)..fillRange(0, 432, 21), 24)],
    );
    final latest = image(
      planes: [plane(Uint8List(432)..fillRange(0, 432, 199), 24)],
    );
    service.ingestCameraImage(first);
    for (var i = 0; i < 100; i++) {
      nowUs += 1000;
      service.ingestCameraImage(latest);
    }
    expect(service.cameraFramesReceived, 101);
    expect(service.cameraFramesProcessed, 1);
    expect(service.cameraFramesDropped, 100);
    expect(service.rearMiniFrame!.toSet(), {21});
    expect(notifications, 1);
    nowUs = 150000;
    service.ingestCameraImage(latest);
    expect(service.cameraFramesProcessed, 2);
    expect(service.rearMiniFrame!.toSet(), {199});
    expect(notifications, 2);
    expect(service.lastCameraProcessingMicroseconds, greaterThanOrEqualTo(0));
  });

  test('Y sampling honors row padding and non-unit pixel stride', () {
    const width = 48;
    const height = 36;
    const rowStride = 104;
    final bytes = Uint8List(rowStride * height)
      ..fillRange(0, rowStride * height, 254);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        bytes[y * rowStride + x * 2] = (x + y * 2) % 230;
      }
    }
    service.ingestCameraImage(
      image(width: width, height: height, planes: [plane(bytes, rowStride, 2)]),
    );
    final expected = Uint8List.fromList(
      List.generate(432, (i) {
        final x = (i % 24) * 2 + 1;
        final y = (i ~/ 24) * 2 + 1;
        return (x + y * 2) % 230;
      }),
    );
    expect(service.rearMiniFrame, orderedEquals(expected));
    // The small owned image is independent of camera-buffer reuse.
    bytes.fillRange(0, bytes.length, 0);
    expect(service.rearMiniFrame, orderedEquals(expected));
  });

  test('iOS BGRA is sampled as luminance with padded rows', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const rowStride = 104;
    final bytes = Uint8List(rowStride * 18);
    for (var y = 0; y < 18; y++) {
      for (var x = 0; x < 24; x++) {
        final index = y * rowStride + x * 4;
        bytes[index] = 20;
        bytes[index + 1] = 100;
        bytes[index + 2] = 220;
        bytes[index + 3] = 255;
      }
    }
    service.ingestCameraImage(
      image(format: 1111970369, planes: [plane(bytes, rowStride, 4)]),
    );
    expect(service.rearMiniFrame!.toSet(), {
      (220 * 77 + 100 * 150 + 20 * 29) >> 8,
    });
    expect(service.cameraFramesProcessed, 1);
  });

  test('independent chroma strides work without assuming U and V aliases', () {
    final u = Uint8List(17 * 9);
    final v = Uint8List(40 * 9);
    for (var y = 0; y < 9; y++) {
      for (var x = 0; x < 12; x++) {
        u[y * 17 + x] = 100;
        v[y * 40 + x * 2] = 150;
      }
    }
    service.ingestCameraImage(
      image(
        planes: [
          plane(Uint8List(432)..fillRange(0, 432, 100), 24),
          plane(u, 17),
          plane(v, 40, 2),
        ],
      ),
      role: VrJoystickConstants.cameraRoleFront,
    );
    expect(service.handConfidence, greaterThan(0));
    expect(service.handConfidence, lessThanOrEqualTo(.35));
    expect(service.hasFreshVisorEstimate, isFalse);
  });

  test(
    'malformed frames and unsupported formats are rejected, not clamped',
    () {
      for (final frame in [
        image(planes: []),
        image(planes: [plane(Uint8List(12), 24)]),
        image(planes: [plane(Uint8List(432), 12)]),
        image(format: 256, planes: [plane(Uint8List(432), 24)]),
      ]) {
        service.ingestCameraImage(frame);
      }
      expect(service.cameraFramesProcessed, 0);
      expect(service.cameraFramesDropped, 4);
      service.ingestCameraImage(image(planes: [plane(checkerboard(), 24)]));
      expect(service.cameraFramesProcessed, 1);
      expect(service.cameraFramesReceived, 5);
    },
  );

  test('empty chroma safely falls back to luminance', () {
    service.ingestCameraImage(
      image(
        planes: [
          plane(Uint8List(432)..fillRange(0, 432, 100), 24),
          plane(Uint8List(0), 12),
          plane(Uint8List(0), 12),
        ],
      ),
      role: VrJoystickConstants.cameraRoleFront,
    );
    expect(service.cameraFramesProcessed, 1);
    expect(service.handConfidence, 0);
    expect(service.hasFreshVisorEstimate, isFalse);
  });

  test('BLE omits images; requested Wi-Fi thumbnail matches owned source', () {
    final mini = checkerboard();
    final expected = Uint8List.fromList(mini);
    service.ingestSyntheticMiniFrame(mini);
    mini.fillRange(0, mini.length, 0);
    final ble = service.buildVisionTelemetryPayload(includeMiniFrame: false)!;
    expect(
      ble.containsKey(VrJoystickConstants.fieldJoystickMiniFrame),
      isFalse,
    );
    final wifi = service.buildVisionTelemetryPayload()!;
    expect(
      base64Decode(wifi[VrJoystickConstants.fieldJoystickMiniFrame] as String),
      orderedEquals(expected),
    );
    expect(service.rearMiniFrame, orderedEquals(expected));
  });

  test('camera confidence and thumbnails expire per lens', () {
    service.ingestSyntheticMiniFrame(checkerboard());
    expect(service.feetConfidence, greaterThan(0));
    nowUs = 1900000;
    service.ingestSyntheticMiniFrame(checkerboard(), role: 'front');
    nowUs = 2100000;
    expect(service.hasFreshRearCameraSample, isFalse);
    expect(service.feetConfidence, 0);
    expect(service.hasFreshFrontCameraSample, isTrue);
    expect(service.cameraSampleAge, const Duration(milliseconds: 200));
    nowUs = 4000001;
    expect(service.hasCameraSample, isTrue);
    expect(service.hasFreshCameraSample, isFalse);
    expect(service.handConfidence, 0);
    expect(service.buildVisionTelemetryPayload(), isNull);
  });

  test('IMU and blank frames do not fabricate optical landmarks', () {
    service.updateImuGravity(4, 5, 8);
    service.updateImuGravity(double.nan, 0, 8);
    expect(service.imuPitchRadians.isFinite, isTrue);
    expect(service.hasCameraSample, isFalse);
    expect(service.feetConfidence, 0);
    expect(service.handConfidence, 0);
    service.ingestSyntheticMiniFrame(Uint8List(432));
    expect(service.feetConfidence, 0);
    service.ingestSyntheticMiniFrame(Uint8List(432), role: 'front');
    expect(service.handConfidence, 0);
    expect(service.hasFreshVisorEstimate, isFalse);
  });

  test(
    'lifecycle suspension skips frames and resume accepts current input',
    () async {
      service.didChangeAppLifecycleState(AppLifecycleState.inactive);
      service.ingestCameraImage(image(planes: [plane(checkerboard(), 24)]));
      expect(service.cameraFramesReceived, 0);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      service.ingestCameraImage(image(planes: [plane(checkerboard(), 24)]));
      expect(service.cameraFramesProcessed, 1);
      await service.stop();
      service.dispose();
      nowUs = 300000;
      service.ingestCameraImage(image(planes: [plane(checkerboard(), 24)]));
      expect(service.cameraFramesProcessed, 1);
      expect(service.buildVisionTelemetryPayload(), isNull);
    },
  );

  test('native ranging requires all measurement provenance flags', () {
    final valid = <String, dynamic>{
      'echoDistanceMeters': .4,
      'snrDb': 8.5,
      'measurementValid': true,
      'micAnalyzed': true,
      'emitted': true,
      'calibrated': true,
    };
    service.ingestUltrasonicResult(valid);
    expect(service.ultrasonicActive, isTrue);
    expect(service.ultrasonicUnavailable, isFalse);
    expect(service.currentRangeMeters, .4);
    expect(service.hasValidMetricRange, isTrue);
    for (final flag in [
      'measurementValid',
      'micAnalyzed',
      'emitted',
      'calibrated',
    ]) {
      service.ingestUltrasonicResult({...valid, flag: false});
      expect(service.ultrasonicActive, isFalse, reason: flag);
      expect(service.currentRangeMeters, isNull, reason: flag);
    }
    service.ingestUltrasonicResult({
      'candidateEchoDistanceMeters': .4,
      'snrDb': 100,
      'emitted': true,
    });
    expect(service.ultrasonicActive, isFalse);
    expect(service.ultrasonicUnavailable, isTrue);
  });

  test('invalid numeric acoustic samples cannot enter fusion', () {
    for (final distance in [double.nan, double.infinity, .4]) {
      service.ingestUltrasonicResult({
        'echoDistanceMeters': distance,
        'snrDb': distance == .4 ? double.nan : 8.5,
        'measurementValid': true,
        'micAnalyzed': true,
        'emitted': true,
        'calibrated': true,
      });
      expect(service.ultrasonicActive, isFalse);
      expect(service.currentRangeMeters, isNull);
    }
  });

  test('synthetic echo and optical silhouette cannot supply metric range', () {
    service.ingestSyntheticMiniFrame(checkerboard(), ultrasonicEchoMeters: .4);
    service.ingestSyntheticMiniFrame(checkerboard(), role: 'front');
    service.updateImuGravity(4, 5, 8);
    expect(service.hasFreshVisorEstimate, isTrue);
    expect(service.ultrasonicActive, isFalse);
    expect(service.hasValidMetricRange, isFalse);
    expect(service.currentRangeMeters, isNull);
    expect(service.feetConfidence, lessThanOrEqualTo(.35));
    expect(service.handConfidence, lessThanOrEqualTo(.35));
    final packet = service.buildVisionTelemetryPayload()!;
    expect(packet[VrJoystickConstants.fieldRangeMeters], isNull);
    expect(packet['rangeSource'], isNull);
    expect(packet['opticalEstimated'], isTrue);
    expect(packet['opticalSource'], 'heuristic_edges_chroma');
  });

  test('calibrated acoustic range expires and is not blended with posture', () {
    service.ingestUltrasonicResult({
      'echoDistanceMeters': .4,
      'snrDb': 8.5,
      'measurementValid': true,
      'micAnalyzed': true,
      'emitted': true,
      'calibrated': true,
    });
    service.ingestSyntheticMiniFrame(checkerboard(), role: 'front');
    service.updateImuGravity(4, 5, 8);
    expect(service.currentRangeMeters, .4);
    final packet = service.buildVisionTelemetryPayload()!;
    expect(packet[VrJoystickConstants.fieldRangeMeters], .4);
    expect(packet['rangeSource'], 'calibrated_acoustic_echo');
    nowUs = 1600001;
    expect(service.ultrasonicActive, isFalse);
    expect(service.currentRangeMeters, isNull);
    expect(service.hasValidMetricRange, isFalse);
  });

  group('native body model consumer with synthetic channel fixtures', () {
    const channel = MethodChannel('vrlizate/vision_inference');
    const camera = CameraDescription(
      name: '0',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 0,
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Map<String, dynamic> response;
    late int calls;
    setUp(() {
      calls = 0;
      response = {
        'status': 'ok',
        'inferenceMs': 12.0,
        'pose': {
          'status': 'ok',
          'present': true,
          'landmarks': [
            for (final point in bodyPoseFixture())
              {
                'type': point.type,
                'x': point.u * 480,
                'y': point.v * 360,
                'z': -2.0,
                'inFrameLikelihood': .9,
              },
          ],
        },
        'markers': [],
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'capabilities') {
          return {'supportsYuv420Planes': false};
        }
        calls++;
        return response;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Future<void> frame() => service.ingestInferenceCameraImage(
      image(
        width: 480,
        height: 360,
        planes: [
          plane(Uint8List(480 * 360), 480),
          plane(Uint8List(240 * 180), 240),
          plane(Uint8List(240 * 180), 240),
        ],
      ),
      camera: camera,
      orientation: DeviceOrientation.portraitUp,
    );

    test(
      'opt-in plus native output yields 33 points, never metric distance',
      () async {
        await frame();
        expect(calls, 0);
        await service.setBodyDetectionEnabled(true);
        await frame();
        expect(calls, 1);
        expect(service.bodyStatus, 'confirming_pose');
        expect(service.bodyLandmarks, isEmpty);
        nowUs = 1000000;
        await frame();
        nowUs = 2000000;
        await frame();
        expect(service.bodyStatus, 'ready');
        expect(service.bodyLandmarks.length, 33);
        expect(service.bodySourceId, 'joystick:back:0');
        expect(service.bodyInferenceMs, 12);
        expect(service.bodyDisplacementU, 0);
        expect(service.currentRangeMeters, isNull);
        expect(
          service.hasLiveSensorSample,
          isFalse,
        ); // Test fixtures do not assert physical hardware evidence.
        expect(service.hasCameraSample, isFalse);
        nowUs = 4000001;
        expect(service.bodyPresent, isFalse);
        expect(service.bodyLandmarks, isEmpty);
        expect(service.bodyStatus, 'stale');
      },
    );

    test(
      'rate limit, measured image change, no-person baseline reset',
      () async {
        await service.setBodyDetectionEnabled(true);
        await frame();
        nowUs = 199999;
        await frame();
        expect(calls, 1);
        expect(service.bodyInferenceFramesDropped, 1);
        nowUs = 1000000;
        await frame();
        nowUs = 2000000;
        await frame();
        expect(service.bodyPresent, isTrue);
        final pose = response['pose'] as Map;
        for (final joint in pose['landmarks'] as List) {
          joint['x'] += 48.0;
        }
        nowUs = 2500000;
        await frame();
        expect(service.bodyDisplacementU, closeTo(.1, 1e-9));
        expect(service.bodyDisplacementV, closeTo(0, 1e-9));
        response = {
          'status': 'ok',
          'pose': {'status': 'ok', 'present': false, 'landmarks': []},
        };
        nowUs = 3000000;
        await frame();
        expect(service.bodyPresent, isFalse);
        expect(service.bodyStatus, 'no_person');
        expect(service.bodyDisplacementU, isNull);
      },
    );

    test(
      'invalid confidences, missing model and IMU cannot create body pose',
      () async {
        await service.setBodyDetectionEnabled(true);
        response = {'status': 'unavailable'};
        await frame();
        service.updateImuGravity(4, 5, 8);
        expect(service.bodyStatus, 'unavailable');
        expect(service.bodyPresent, isFalse);
        nowUs = 1000000;
        await frame();
        expect(
          calls,
          1,
        ); // Explicit opt-in retry needed; no missing-plugin polling.
        await service.setBodyDetectionEnabled(false);
        await service.setBodyDetectionEnabled(true);
        response = {
          'status': 'ok',
          'pose': {
            'status': 'ok',
            'present': true,
            'landmarks': [
              {
                'type': 11,
                'x': double.nan,
                'y': 2,
                'z': 0,
                'inFrameLikelihood': .99,
              },
              {'type': 12, 'x': 1, 'y': 2, 'z': 0, 'inFrameLikelihood': 2},
            ],
          },
        };
        await frame();
        expect(service.bodyPresent, isFalse);
        expect(service.currentRangeMeters, isNull);
      },
    );

    test(
      'thermal refusal clears accepted pose and defers without claiming no-person',
      () async {
        await service.setBodyDetectionEnabled(true);
        for (final time in [0, 1000000, 2000000]) {
          nowUs = time;
          await frame();
        }
        expect(service.bodyPresent, isTrue);
        response = {
          'status': 'thermal_backoff',
          'thermalStatus': 4,
          'retryAfterMs': 3000,
        };
        nowUs = 2500000;
        await frame();
        expect(service.bodyStatus, 'thermal_backoff');
        expect(service.bodyThermalStatus, 4);
        expect(service.bodyRetryAfterMs, 3000);
        expect(service.bodyPresent, isFalse);
        expect(service.bodyLandmarks, isEmpty);
        expect(service.bodyInferenceMs, isNull);
        expect(service.bodyRoundTripMs, isNull);
        expect(service.bodyDisplacementU, isNull);
        final count = calls;
        nowUs = 5000000;
        await frame();
        expect(calls, count);
        await service.stop();
        expect(service.bodyThermalStatus, isNull);
        expect(service.bodyRetryAfterMs, isNull);
      },
    );

    test('body inference never retains unrequested marker results', () async {
      await service.setBodyDetectionEnabled(true);
      response['markers'] = [
        for (final id in [
          'vrlizate-marker-v1:test-public',
          'vrlizate://pair?token=test-fixture',
        ])
          {
            'rawValue': id,
            'corners': [
              {'x': 10, 'y': 10},
              {'x': 20, 'y': 10},
              {'x': 20, 'y': 20},
              {'x': 10, 'y': 20},
            ],
          },
      ];
      await frame();
      expect(service.publicMarkers, isEmpty);
      await service.stop();
      expect(service.bodyPresent, isFalse);
      expect(service.publicMarkers, isEmpty);
    });
  });
}
