import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/domain/services/vr_vision_inference_client.dart';

import 'vr_joystick_camera_vision_service_test.dart' as frames;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vrlizate/vision_inference');
  const back = CameraDescription(
    name: '0',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );
  const front = CameraDescription(
    name: '1',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 270,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late VrVisionInferenceClient client;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    client = VrVisionInferenceClient();
  });
  tearDown(() {
    client.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  CameraImage paddedFrame() => frames.image(
    width: 4,
    height: 2,
    planes: [
      frames.plane(
        Uint8List.fromList([
          1,
          91,
          2,
          91,
          3,
          91,
          4,
          91,
          99,
          99,
          5,
          91,
          6,
          91,
          7,
          91,
          8,
        ]),
        10,
        2,
      ),
      frames.plane(Uint8List.fromList([20, 21, 99]), 3),
      frames.plane(Uint8List.fromList([30, 99, 31]), 4, 2),
    ],
  );

  Future<Map<String, dynamic>> analyze(
    CameraImage image, {
    bool pose = false,
  }) => client.analyzeFrame(
    image,
    camera: back,
    orientation: DeviceOrientation.landscapeLeft,
    sourceId: 'test-camera:0',
    sequence: 7,
    detectPose: pose,
    detectMarker: true,
  );

  test(
    'packs independent padded Y U V planes as NV21 and sends real metadata',
    () async {
      MethodCall? captured;
      messenger.setMockMethodCallHandler(channel, (call) async {
        captured = call;
        return {'status': 'ok', 'markers': []};
      });
      final result = await analyze(paddedFrame());
      expect(captured!.method, 'analyze');
      final args = captured!.arguments as Map;
      expect(
        args['bytes'],
        orderedEquals([1, 2, 3, 4, 5, 6, 7, 8, 30, 20, 31, 21]),
      );
      expect(args['rotationDegrees'], 0);
      expect(args['sourceId'], 'test-camera:0');
      expect(args['captureSequence'], 7);
      expect(args['detectPose'], isFalse);
      expect(result['imageWidth'], 4);
      expect(result['imageHeight'], 2);
    },
  );

  test('front and back compensate sensor and current device orientation', () {
    expect(
      VrVisionInferenceClient.rotationDegreesFor(
        back,
        DeviceOrientation.portraitUp,
      ),
      90,
    );
    expect(
      VrVisionInferenceClient.rotationDegreesFor(
        back,
        DeviceOrientation.landscapeRight,
      ),
      180,
    );
    expect(
      VrVisionInferenceClient.rotationDegreesFor(
        front,
        DeviceOrientation.landscapeLeft,
      ),
      0,
    );
    expect(
      VrVisionInferenceClient.rotationDegreesFor(
        front,
        DeviceOrientation.landscapeRight,
      ),
      180,
    );
  });

  test(
    'rejects low resolution pose input and malformed planes before native',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return {'status': 'ok'};
      });
      expect(
        (await analyze(paddedFrame(), pose: true))['status'],
        'unsupported_resolution',
      );
      final malformed = frames.image(
        width: 4,
        height: 2,
        planes: [frames.plane(Uint8List(8), 4)],
      );
      expect((await analyze(malformed))['status'], 'invalid_frame');
      expect(calls, 0);
    },
  );

  test(
    'keeps one request inflight across cancellation; late output is ignored',
    () async {
      final nativeEntered = Completer<void>();
      final nativeResult = Completer<Map<String, dynamic>>();
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        nativeEntered.complete();
        return nativeResult.future;
      });
      final pending = analyze(paddedFrame());
      await nativeEntered.future;
      expect(client.isBusy, isTrue);
      client.cancelPendingResults();
      expect((await analyze(paddedFrame()))['status'], 'busy');
      nativeResult.complete({
        'status': 'ok',
        'pose': {'present': true},
      });
      expect((await pending)['status'], 'cancelled');
      expect(calls, 1);
      expect(client.isBusy, isFalse);
    },
  );

  test('absent native model does not become a detection', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect((await analyze(paddedFrame()))['status'], 'unavailable');
  });

  test(
    'thermal backoff skips channel requests until retry, reset clears it',
    () async {
      var clockUs = 0;
      client.dispose();
      client = VrVisionInferenceClient(monotonicMicroseconds: () => clockUs);
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls++;
        return {
          'status': 'thermal_backoff',
          'thermalStatus': 4,
          'retryAfterMs': 2000,
        };
      });
      expect((await analyze(paddedFrame()))['status'], 'thermal_backoff');
      clockUs = 1000000;
      expect((await analyze(paddedFrame()))['thermalStatus'], 4);
      expect(calls, 1);
      clockUs = 2000000;
      await analyze(paddedFrame());
      expect(calls, 2);
      client.cancelPendingResults();
      await analyze(paddedFrame());
      expect(calls, 3);
    },
  );

  test(
    'native YUV fast path uses one cached capability query and exact plane strides',
    () async {
      var capabilityCalls = 0;
      final requests = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'capabilities') {
          capabilityCalls++;
          return {'supportsYuv420Planes': true};
        }
        requests.add(call);
        return {'status': 'ok', 'inputLayout': 'yuv420_planes'};
      });
      final frame = frames.image(
        width: 2,
        height: 2,
        planes: [
          frames.plane(Uint8List.fromList([1, 2, 99, 3, 4]), 3),
          frames.plane(Uint8List.fromList([20]), 2, 2),
          frames.plane(Uint8List.fromList([30]), 2, 2),
        ],
      );
      expect((await analyze(frame))['inputLayout'], 'yuv420_planes');
      await analyze(frame);
      expect(capabilityCalls, 1);
      expect(requests.every((r) => r.method == 'analyzeYuv'), isTrue);
      final args = requests.first.arguments as Map;
      expect(args.containsKey('bytes'), isFalse);
      final planes = args['planes'] as List;
      expect(planes[0]['bytesPerRow'], 3);
      expect(planes[1]['bytesPerPixel'], 2);
      expect(planes[0]['bytes'], orderedEquals([1, 2, 99, 3, 4]));
    },
  );

  test('legacy missing capabilities falls back once to packed NV21', () async {
    var capabilities = 0;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'capabilities') {
        capabilities++;
        throw MissingPluginException();
      }
      return {'status': 'ok'};
    });
    final frame = frames.image(
      width: 2,
      height: 2,
      planes: [
        frames.plane(Uint8List.fromList([1, 2, 3, 4]), 2),
        frames.plane(Uint8List.fromList([20]), 1),
        frames.plane(Uint8List.fromList([30]), 1),
      ],
    );
    await analyze(frame);
    await analyze(frame);
    expect(capabilities, 1);
    expect(methods, ['capabilities', 'analyze', 'analyze']);
  });

  group('AVFoundation NV12', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    CameraImage nv12Frame({int yStride = 6, int? yLength}) => frames.image(
      width: 4,
      height: 2,
      format: 875704438,
      planes: [
        // iOS omits bytesPerPixel for both Y and interleaved UV planes.
        {'bytes': Uint8List(yLength ?? 12), 'bytesPerRow': yStride},
        {
          'bytes': Uint8List.fromList([20, 30, 21, 31, 99, 99]),
          'bytesPerRow': 6,
        },
      ],
    );

    test(
      'sends two padded planes directly and keeps oriented pixel axes',
      () async {
        final methods = <String>[];
        MethodCall? request;
        messenger.setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          if (call.method == 'capabilities') {
            return {
              'supportsNv12Planes': true,
              'supportsYuv420Planes': false,
              'imageAlreadyOriented': true,
            };
          }
          request = call;
          return {
            'status': 'ok',
            'source': 'apple_vision_native',
            'inputLayout': 'nv12_planes',
            'imageWidth': 4,
            'imageHeight': 2,
            'rotationDegrees': 0,
            'metricPoseReady': false,
          };
        });
        final result = await client.analyzeFrame(
          nv12Frame(),
          camera: back,
          orientation: DeviceOrientation.portraitUp,
          sourceId: 'ipad:0',
          sequence: 8,
          detectPose: false,
          detectMarker: true,
        );
        await analyze(nv12Frame());
        expect(methods, ['capabilities', 'analyzeNv12', 'analyzeNv12']);
        final args = request!.arguments as Map;
        expect(args.containsKey('bytes'), isFalse);
        expect(args['rotationDegrees'], 0);
        expect(args['mirrored'], isFalse);
        final planes = args['planes'] as List;
        expect(planes, hasLength(2));
        expect(planes[0]['bytesPerRow'], 6);
        expect(planes[0]['bytesPerPixel'], 1);
        expect(planes[1]['bytesPerPixel'], 2);
        expect(planes[1]['bytes'], orderedEquals([20, 30, 21, 31, 99, 99]));
        expect(result['imageWidth'], 4);
        expect(result['imageHeight'], 2);
        expect(result['rotationDegrees'], 0);
        expect(result['imageAlreadyOriented'], isTrue);
        expect(result['source'], 'apple_vision_native');
        expect(result['metricPoseReady'], isFalse);
      },
    );

    test(
      'front reflection is explicit, with no second rotation or unmirror',
      () async {
        MethodCall? request;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'capabilities') {
            return {'supportsNv12Planes': true, 'imageAlreadyOriented': true};
          }
          request = call;
          return {'status': 'ok', 'markers': []};
        });
        for (final orientation in DeviceOrientation.values) {
          expect(
            VrVisionInferenceClient.rotationDegreesFor(front, orientation),
            0,
          );
        }
        final result = await client.analyzeFrame(
          nv12Frame(),
          camera: front,
          orientation: DeviceOrientation.landscapeRight,
          sourceId: 'ipad:1',
          sequence: 3,
          detectPose: false,
        );
        expect((request!.arguments as Map)['mirrored'], isTrue);
        expect((request!.arguments as Map)['rotationDegrees'], 0);
        expect(result['mirrored'], isTrue);
        expect(result['rotationDegrees'], 0);
      },
    );

    test(
      'rejects short rows/buffers before querying the native backend',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls++;
          return {'supportsNv12Planes': true, 'imageAlreadyOriented': true};
        });
        expect(
          (await analyze(nv12Frame(yStride: 3)))['status'],
          'invalid_frame',
        );
        expect(
          (await analyze(nv12Frame(yLength: 9)))['status'],
          'invalid_frame',
        );
        expect(calls, 0);
      },
    );

    test(
      'missing native NV12 support never falls back to Android packing',
      () async {
        final methods = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          throw MissingPluginException();
        });
        expect((await analyze(nv12Frame()))['status'], 'unavailable');
        expect(
          (await analyze(nv12Frame()))['reason'],
          'nv12_backend_unavailable',
        );
        expect(methods, ['capabilities']);
      },
    );

    test(
      'requires the backend to confirm its already-oriented input contract',
      () async {
        final methods = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          return {'supportsNv12Planes': true};
        });
        expect((await analyze(nv12Frame()))['status'], 'unavailable');
        expect(methods, ['capabilities']);
      },
    );

    test(
      'invalidated capability request cannot deliver a stale inference',
      () async {
        final entered = Completer<void>();
        final capabilities = Completer<Map<String, dynamic>>();
        final methods = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          entered.complete();
          return capabilities.future;
        });
        final pending = analyze(nv12Frame());
        await entered.future;
        client.cancelPendingResults();
        expect((await analyze(nv12Frame()))['status'], 'busy');
        capabilities.complete({
          'supportsNv12Planes': true,
          'imageAlreadyOriented': true,
        });
        expect((await pending)['status'], 'cancelled');
        expect(methods, ['capabilities']);
        expect(client.isBusy, isFalse);
      },
    );
  });
}
