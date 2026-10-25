// Copyright 2026 Open Neom contributors.
// SPDX-License-Identifier: BSD-3-Clause
import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_android_camerax/src/camerax_library.dart' as cx;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Preview extends Fake implements cx.Preview {
  _Preview({this.fail = false});
  final bool fail;
  @override
  Future<void> releaseSurfaceProvider() async {
    if (fail) throw StateError('release_surface_failed');
  }
}

class _LiveState extends Fake implements cx.LiveData<cx.CameraState> {
  _LiveState({this.fail = false});
  final bool fail;
  @override
  Future<void> removeObservers() async {
    if (fail) throw StateError('remove_observers_failed');
  }
}

class _Provider extends Fake implements cx.ProcessCameraProvider {
  _Provider({this.fail = false});
  final bool fail;
  @override
  Future<void> unbindAll() async {
    if (fail) throw StateError('unbind_use_cases_failed');
  }

  @override
  Future<cx.Camera> bindToLifecycle(cx.CameraSelector selector, List<cx.UseCase> cases) async =>
      _Camera();
}

class _Camera extends Fake implements cx.Camera {
  @override
  Future<cx.CameraInfo> getCameraInfo() async => throw StateError('initialization_after_bind_failed');
}

class _Analysis extends Fake implements cx.ImageAnalysis {
  _Analysis({this.fail = false}) {
    manager.addDartCreatedInstance(this);
  }
  final bool fail;
  final manager = cx.PigeonInstanceManager(onWeakReferenceRemoved: (_) {});
  @override
  cx.PigeonInstanceManager get pigeon_instanceManager => manager;
  @override
  cx.ImageAnalysis pigeon_copy() => this;
  @override
  Future<void> clearAnalyzer() async {
    if (fail) throw StateError('clear_analyzer_failed');
  }
}

class _DeviceOrientation extends Fake implements cx.DeviceOrientationManager {
  @override
  Future<void> stopListeningForDeviceOrientationChange() async {}
}

class _Selector extends Fake implements cx.CameraSelector {}
class _Capture extends Fake implements cx.ImageCapture {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('vrlizate/camera_analysis_budget');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    cx.PigeonOverrides.pigeon_reset();
    cx.PigeonOverrides.deviceOrientationManager_new =
        ({required void Function(cx.DeviceOrientationManager, String) onDeviceOrientationChanged}) =>
            _DeviceOrientation();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    cx.PigeonOverrides.pigeon_reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final stage in ['surface', 'observers', 'use_cases', 'analyzer']) {
    test('dispose unregisters owner even when $stage cleanup fails', () async {
      final camera = AndroidCameraCameraX()
        ..preview = _Preview(fail: stage == 'surface')
        ..liveCameraState = _LiveState(fail: stage == 'observers')
        ..processCameraProvider = _Provider(fail: stage == 'use_cases')
        ..imageAnalysis = _Analysis(fail: stage == 'analyzer');
      await expectLater(camera.dispose(17), throwsStateError);
      expect(calls.map((c) => c.method), ['unbindOwner']);
      expect(calls.single.arguments, {'cameraId': 17});
    });
  }

  test('failed initialization unregisters its already-bound owner', () async {
    final analysis = _Analysis();
    cx.PigeonOverrides.imageAnalysis_new = ({
      cx.ResolutionSelector? resolutionSelector,
      int? outputImageFormat,
      int? targetRotation,
      cx.CameraIntegerRange? targetFpsRange,
    }) => analysis;
    final camera = AndroidCameraCameraX()
      ..preview = _Preview()
      ..imageCapture = _Capture()
      ..cameraSelector = _Selector()
      ..processCameraProvider = _Provider();
    // Both an incomplete initialization fixture and a camera-info failure are
    // Errors after bindOwner. Cleanup must run for either, not just Exceptions.
    await expectLater(camera.initializeCamera(23), throwsA(isA<Error>()));
    expect(calls.map((c) => c.method), ['bindOwner', 'unbindOwner']);
    expect((calls.first.arguments as Map)['cameraId'], 23);
    expect((calls.first.arguments as Map)['imageAnalysisId'], isA<int>());
    expect(calls.last.arguments, {'cameraId': 23});
  });

  test('normal disposal unregisters once and preserves upstream state reset', () async {
    final camera = AndroidCameraCameraX()
      ..preview = _Preview()
      ..liveCameraState = _LiveState()
      ..processCameraProvider = _Provider()
      ..imageAnalysis = _Analysis()
      ..videoOutputPath = 'pending.mp4';
    await camera.dispose(31);
    expect(calls.map((c) => c.method), ['unbindOwner']);
    expect(camera.videoOutputPath, isNull);
  });

  test('missing optional channel does not break normal upstream disposal', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await AndroidCameraCameraX().dispose(41);
  });
}
