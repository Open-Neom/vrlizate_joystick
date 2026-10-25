import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// Best-effort admission before CameraX copies image planes to Dart. GPU
/// preview remains independent; older camera plugins retain their default.
class VrCameraAnalysisBudget {
  static const _channel = MethodChannel('vrlizate/camera_analysis_budget');

  static Future<bool> configure(
    CameraController camera, {
    required int intervalMs,
  }) async {
    if (!camera.value.isInitialized || intervalMs < 0) return false;
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'setIntervalMs',
        {'cameraId': camera.cameraId, 'intervalMs': intervalMs},
      );
      return response?['configured'] == true || response?['supported'] == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<Map<String, dynamic>?> status(CameraController camera) async {
    if (!camera.value.isInitialized) return null;
    try {
      return await _channel.invokeMapMethod<String, dynamic>('getStatus', {
        'cameraId': camera.cameraId,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
