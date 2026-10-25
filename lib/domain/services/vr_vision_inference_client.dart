import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Inference on an existing camera stream. This class never owns a camera.
///
/// Native x/y landmarks and marker corners use pixels of the image AFTER
/// [rotationDegreesFor] has been applied. Android dimensions swap at 90/270.
/// AVFoundation already orients its buffers, and its front buffer is mirrored;
/// iOS keeps those input pixels and explicitly reports that reflection.
/// These coordinates are not metric positions or VR coordinates.
class VrVisionInferenceClient {
  VrVisionInferenceClient({
    MethodChannel? channel,
    @visibleForTesting int Function()? monotonicMicroseconds,
  }) : _channel = channel ?? const MethodChannel('vrlizate/vision_inference') {
    _nowMicroseconds =
        monotonicMicroseconds ?? () => _clock.elapsedMicroseconds;
  }

  final MethodChannel _channel;
  bool _busy = false;
  bool _disposed = false;
  int _epoch = 0;
  bool? _supportsYuv420Planes;
  bool? _supportsNv12Planes;
  bool _imageAlreadyOriented = false;
  final Stopwatch _clock = Stopwatch()..start();
  late final int Function() _nowMicroseconds;
  int? _thermalRetryUntilUs;
  int? _thermalStatus;

  bool get isBusy => _busy;

  /// Invalidates pending output without opening a slot for a second request.
  void cancelPendingResults() {
    _epoch++;
    _thermalRetryUntilUs = null;
    _thermalStatus = null;
  }

  void dispose() {
    _disposed = true;
    cancelPendingResults();
  }

  static int rotationDegreesFor(
    CameraDescription camera,
    DeviceOrientation orientation,
  ) {
    // camera_avfoundation applies AVCaptureConnection.videoOrientation to the
    // delivered pixel buffer. Applying Android's sensor compensation again
    // rotates both the detector input and same-frame QR sampling incorrectly.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) return 0;
    final compensation = switch (orientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    return camera.lensDirection == CameraLensDirection.front
        ? (camera.sensorOrientation + compensation) % 360
        : (camera.sensorOrientation - compensation + 360) % 360;
  }

  /// One request at a time; incoming frames are dropped instead of queued.
  /// Android fallback YUV packing runs outside the UI isolate. iOS NV12 planes
  /// cross the channel directly; its native detector owns any required copy.
  Future<Map<String, dynamic>> analyzeFrame(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation orientation,
    required String sourceId,
    required int sequence,
    bool detectPose = true,
    bool detectMarker = false,
  }) async {
    if (_disposed) return {'status': 'disposed'};
    if (_busy) return {'status': 'busy'};
    final retryAt = _thermalRetryUntilUs;
    final now = _nowMicroseconds();
    if (retryAt != null && now < retryAt) {
      return {
        'status': 'thermal_backoff',
        'thermalStatus': _thermalStatus,
        'retryAfterMs': ((retryAt - now) / 1000).ceil(),
      };
    }
    final width = image.width;
    final height = image.height;
    final longSide = width > height ? width : height;
    final shortSide = width < height ? width : height;
    if (width <= 0 ||
        height <= 0 ||
        width.isOdd ||
        height.isOdd ||
        longSide > 1280 ||
        shortSide > 720 ||
        (detectPose && (longSide < 480 || shortSide < 360))) {
      return {'status': 'unsupported_resolution'};
    }
    if (image.format.group != ImageFormatGroup.yuv420 &&
        image.format.group != ImageFormatGroup.nv21) {
      return {'status': 'unsupported_format'};
    }
    _busy = true;
    final epoch = _epoch;
    try {
      final planes = <Map<String, Object>>[
        for (final plane in image.planes)
          <String, Object>{
            'bytes': plane.bytes,
            'rowStride': plane.bytesPerRow,
            'pixelStride': plane.bytesPerPixel ?? 1,
          },
      ];
      final iosNv12 =
          !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.iOS &&
          image.format.group == ImageFormatGroup.yuv420 &&
          image.planes.length == 2;
      if (iosNv12 && !_compatibleNv12Planes(planes, width, height)) {
        return {'status': 'invalid_frame'};
      }
      final canUseNativePlanes =
          image.format.group == ImageFormatGroup.yuv420 &&
          image.planes.every((plane) => plane.bytesPerPixel != null) &&
          _compatibleNativePlanes(planes, width, height);
      if ((canUseNativePlanes && _supportsYuv420Planes == null) ||
          (iosNv12 && _supportsNv12Planes == null)) {
        try {
          final capabilities = await _channel.invokeMapMethod<String, dynamic>(
            'capabilities',
          );
          _supportsYuv420Planes = capabilities?['supportsYuv420Planes'] == true;
          _supportsNv12Planes = capabilities?['supportsNv12Planes'] == true;
          _imageAlreadyOriented = capabilities?['imageAlreadyOriented'] == true;
        } catch (_) {
          _supportsYuv420Planes = false;
          _supportsNv12Planes = false;
        }
      }
      if (_disposed || epoch != _epoch) return {'status': 'cancelled'};
      // Never reinterpret two interleaved UV planes as Android's separate U/V
      // layout. An older/missing iOS backend remains explicitly unavailable.
      if (iosNv12 && (_supportsNv12Planes != true || !_imageAlreadyOriented)) {
        return {'status': 'unavailable', 'reason': 'nv12_backend_unavailable'};
      }
      final nativePlanes = canUseNativePlanes && _supportsYuv420Planes == true;
      final Uint8List? bytes = nativePlanes || iosNv12
          ? null
          : await compute(_packNv21, <String, Object>{
              'width': width,
              'height': height,
              'packedNv21': image.format.group == ImageFormatGroup.nv21,
              'planes': planes,
            });
      if (_disposed || epoch != _epoch) return {'status': 'cancelled'};
      if (!nativePlanes && !iosNv12 && bytes == null) {
        return {'status': 'invalid_frame'};
      }
      final rotation = rotationDegreesFor(camera, orientation);
      final response = await _channel.invokeMapMethod<String, dynamic>(
        iosNv12 ? 'analyzeNv12' : (nativePlanes ? 'analyzeYuv' : 'analyze'),
        {
          if (nativePlanes || iosNv12)
            'planes': [
              for (var i = 0; i < planes.length; i++)
                {
                  'bytes': planes[i]['bytes'],
                  'bytesPerRow': planes[i]['rowStride'],
                  // AVFoundation omits pixel stride; NV12 defines Y=1, UV=2.
                  'bytesPerPixel': iosNv12
                      ? (i == 0 ? 1 : 2)
                      : planes[i]['pixelStride'],
                },
            ]
          else
            'bytes': bytes,
          'width': width,
          'height': height,
          'rotationDegrees': rotation,
          'sourceId': sourceId,
          'captureSequence': sequence,
          'detectPose': detectPose,
          'detectMarker': detectMarker,
          if (iosNv12)
            'mirrored': camera.lensDirection == CameraLensDirection.front,
        },
      );
      if (_disposed || epoch != _epoch) return {'status': 'cancelled'};
      if (response?['status'] == 'thermal_backoff') {
        final rawRetry = response?['retryAfterMs'];
        final retryMs = rawRetry is num && rawRetry.isFinite
            ? rawRetry.toInt().clamp(2000, 60000)
            : 2000;
        final rawThermalStatus = response?['thermalStatus'];
        _thermalStatus =
            rawThermalStatus is int &&
                rawThermalStatus >= 0 &&
                rawThermalStatus <= 6
            ? rawThermalStatus
            : null;
        _thermalRetryUntilUs = _nowMicroseconds() + retryMs * 1000;
        return {
          ...?response,
          'status': 'thermal_backoff',
          'retryAfterMs': retryMs,
          'thermalStatus': _thermalStatus,
        };
      }
      _thermalRetryUntilUs = null;
      _thermalStatus = null;
      if (iosNv12) {
        return {
          ...?response,
          'sourceId': sourceId,
          'captureSequence': sequence,
          'rotationDegrees': 0,
          'imageWidth': response?['imageWidth'] ?? width,
          'imageHeight': response?['imageHeight'] ?? height,
          'imageAlreadyOriented': true,
          // Reflection describes the captured buffer, not a backend guess.
          'mirrored': camera.lensDirection == CameraLensDirection.front,
          if (response == null) 'status': 'unavailable',
        };
      }
      return {
        ...?response,
        'sourceId': sourceId,
        'captureSequence': sequence,
        'rotationDegrees': rotation,
        'imageWidth': rotation % 180 == 0 ? width : height,
        'imageHeight': rotation % 180 == 0 ? height : width,
        if (response == null) 'status': 'unavailable',
      };
    } on MissingPluginException {
      return {'status': 'unavailable'};
    } on PlatformException catch (error) {
      return {'status': 'unavailable', 'errorCode': error.code};
    } catch (_) {
      return {'status': 'inference_error'};
    } finally {
      _busy = false;
    }
  }
}

bool _compatibleNv12Planes(
  List<Map<String, Object>> planes,
  int width,
  int height,
) {
  if (planes.length != 2) return false;
  for (var i = 0; i < 2; i++) {
    final row = planes[i]['rowStride']! as int;
    final rows = i == 0 ? height : height ~/ 2;
    final bytes = planes[i]['bytes']! as Uint8List;
    // Each chroma row contains width/2 adjacent U,V byte pairs.
    if (row < width || bytes.length < (rows - 1) * row + width) return false;
  }
  return true;
}

bool _compatibleNativePlanes(
  List<Map<String, Object>> planes,
  int width,
  int height,
) {
  if (planes.length != 3 ||
      planes[0]['pixelStride'] != 1 ||
      planes[1]['pixelStride'] != planes[2]['pixelStride'] ||
      planes[1]['rowStride'] != planes[2]['rowStride']) {
    return false;
  }
  if (planes[1]['pixelStride'] != 1 && planes[1]['pixelStride'] != 2) {
    return false;
  }
  for (var i = 0; i < 3; i++) {
    final columns = i == 0 ? width : width ~/ 2;
    final rows = i == 0 ? height : height ~/ 2;
    final row = planes[i]['rowStride']! as int;
    final pixel = planes[i]['pixelStride']! as int;
    final bytes = planes[i]['bytes']! as Uint8List;
    if (row < (columns - 1) * pixel + 1 ||
        bytes.length < (rows - 1) * row + (columns - 1) * pixel + 1) {
      return false;
    }
  }
  return true;
}

/// Camera planes have independent row and pixel strides. Never assume that
/// U/V are contiguous or alias each other (Camera2 and CameraX differ).
Uint8List? _packNv21(Map<String, Object> frame) {
  final width = frame['width']! as int;
  final height = frame['height']! as int;
  final planes = frame['planes']! as List<Map<String, Object>>;
  final size = width * height;
  if (planes.length == 1 && frame['packedNv21'] == true) {
    final plane = planes.single;
    final bytes = plane['bytes']! as Uint8List;
    if (plane['rowStride'] != width || bytes.length < size * 3 ~/ 2) {
      return null;
    }
    return Uint8List.fromList(bytes.sublist(0, size * 3 ~/ 2));
  }
  if (planes.length < 3) return null;
  bool valid(Map<String, Object> plane, int columns, int rows) {
    final stride = plane['pixelStride']! as int;
    final row = plane['rowStride']! as int;
    final bytes = plane['bytes']! as Uint8List;
    return stride > 0 &&
        row >= (columns - 1) * stride + 1 &&
        bytes.length >= (rows - 1) * row + (columns - 1) * stride + 1;
  }

  if (!valid(planes[0], width, height) ||
      !valid(planes[1], width ~/ 2, height ~/ 2) ||
      !valid(planes[2], width ~/ 2, height ~/ 2)) {
    return null;
  }
  final output = Uint8List(size * 3 ~/ 2);
  final y = planes[0]['bytes']! as Uint8List;
  final yRow = planes[0]['rowStride']! as int;
  final yPixel = planes[0]['pixelStride']! as int;
  for (var row = 0; row < height; row++) {
    if (yPixel == 1) {
      output.setRange(row * width, (row + 1) * width, y, row * yRow);
    } else {
      for (var col = 0; col < width; col++) {
        output[row * width + col] = y[row * yRow + col * yPixel];
      }
    }
  }
  final u = planes[1]['bytes']! as Uint8List;
  final v = planes[2]['bytes']! as Uint8List;
  final uRow = planes[1]['rowStride']! as int;
  final vRow = planes[2]['rowStride']! as int;
  final uPixel = planes[1]['pixelStride']! as int;
  final vPixel = planes[2]['pixelStride']! as int;
  var offset = size;
  for (var row = 0; row < height ~/ 2; row++) {
    for (var col = 0; col < width ~/ 2; col++) {
      output[offset++] = v[row * vRow + col * vPixel];
      output[offset++] = u[row * uRow + col * uPixel];
    }
  }
  return output;
}
