import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../utils/constants/vr_joystick_constants.dart';

/// Real-time dual-camera Computer Vision (Cám 2 Piso/Pies + Cám 3 Manos/Visor)
/// and High-Frequency Ultrasonic ToF (18.6–20.1 kHz) ranging service running on
/// the Joystick smartphone.
class VrJoystickCameraVisionService extends ChangeNotifier {
  static const MethodChannel _ultrasonicChannel = MethodChannel(
    VrJoystickConstants.ultrasonicSonarChannelName,
  );

  static const int gridWidth = VrJoystickConstants.visionMiniFrameGridWidth;
  static const int gridHeight = VrJoystickConstants.visionMiniFrameGridHeight;

  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  bool _starting = false;
  bool _disposed = false;
  final bool _enabled = true;
  bool enableHardwareCameraStream = false;
  bool _autoMultiplexLenses = true;
  String _activeRole = VrJoystickConstants.cameraRoleRear;

  DateTime _lastFrameProcessedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLensSwitchAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastUltrasonicPingAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _ultrasonicPingInFlight = false;

  Uint8List? _rearMiniFrame;
  Uint8List? _frontMiniFrame;
  String? _latestMiniFrameBase64;

  // Real-time Cám 2 (Rear / Floor) CV landmarks: left & right feet UV
  double _leftFootU = VrJoystickConstants.defaultLeftFootU;
  double _leftFootV = VrJoystickConstants.defaultLeftFootV;
  double _rightFootU = VrJoystickConstants.defaultRightFootU;
  double _rightFootV = VrJoystickConstants.defaultRightFootV;
  double _feetConfidence = 0.0;

  // Real-time Cám 3 (Front / Upward) CV landmarks: hands & visor UV
  double _handU = VrJoystickConstants.defaultHandU;
  double _handV = VrJoystickConstants.defaultHandV;
  double _handConfidence = 0.0;
  double _visorU = VrJoystickConstants.defaultVisorU;
  double _visorV = VrJoystickConstants.defaultVisorV;
  double _visorWidth = VrJoystickConstants.defaultVisorWidth;

  // High-frequency ultrasonic + optical + IMU fused distance d_VJ (meters)
  double _currentRangeMeters = VrJoystickConstants.defaultRangeMeters;
  double _ultrasonicEchoMeters = VrJoystickConstants.defaultRangeMeters;
  double _ultrasonicSnrDb = 0.0;
  bool _ultrasonicActive = false;
  double _imuPitchRadians = 0.0;

  bool get enabled => _enabled;
  bool get isCameraStreaming =>
      _controller != null && (_controller?.value.isInitialized ?? false);
  bool get autoMultiplexLenses => _autoMultiplexLenses;
  String get activeRole => _activeRole;
  Uint8List? get rearMiniFrame => _rearMiniFrame;
  Uint8List? get frontMiniFrame => _frontMiniFrame;
  double get leftFootU => _leftFootU;
  double get leftFootV => _leftFootV;
  double get rightFootU => _rightFootU;
  double get rightFootV => _rightFootV;
  double get feetConfidence => _feetConfidence;
  double get handU => _handU;
  double get handV => _handV;
  double get handConfidence => _handConfidence;
  double get visorU => _visorU;
  double get visorV => _visorV;
  double get visorWidth => _visorWidth;
  double get currentRangeMeters => _currentRangeMeters;
  double get ultrasonicSnrDb => _ultrasonicSnrDb;
  bool get ultrasonicActive => _ultrasonicActive;

  bool get _isFlutterTestEnvironment {
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey(
        VrJoystickConstants.envKeyFlutterTest,
      );
    } catch (_) {
      return false;
    }
  }

  /// Starts real-time camera CV and ultrasonic ToF ranging on mobile devices.
  Future<void> start() async {
    if (_disposed || _starting || _isFlutterTestEnvironment) return;
    if (!enableHardwareCameraStream) {
      notifyListeners();
      return;
    }
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    _starting = true;
    try {
      final camStatus = await Permission.camera.status;
      if (!camStatus.isGranted) {
        await Permission.camera.request();
      }
      final micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        await Permission.microphone.request();
      }
      _cameras = await availableCameras();
      if (_cameras.isEmpty || _disposed) return;
      await _openLens(_activeRole);
    } catch (_) {
      // Safe fallback if camera hardware is unavailable in test/emulator.
    } finally {
      _starting = false;
    }
  }

  /// Cycles between Rear (`Cám 2 Piso`), Front (`Cám 3 Manos`), and Auto-Multiplex.
  Future<void> cycleCameraLensMode() async {
    if (_autoMultiplexLenses) {
      _autoMultiplexLenses = false;
      await switchLens(VrJoystickConstants.cameraRoleRear);
    } else if (_activeRole == VrJoystickConstants.cameraRoleRear) {
      await switchLens(VrJoystickConstants.cameraRoleFront);
    } else {
      _autoMultiplexLenses = true;
      await switchLens(VrJoystickConstants.cameraRoleRear);
    }
    notifyListeners();
  }

  /// Switches the active physical camera lens to `'rear'` (Cám 2) or `'front'` (Cám 3).
  Future<void> switchLens(String role) async {
    if (_disposed || _isFlutterTestEnvironment) return;
    final normalized = role == VrJoystickConstants.cameraRoleFront
        ? VrJoystickConstants.cameraRoleFront
        : VrJoystickConstants.cameraRoleRear;
    _activeRole = normalized;
    _lastLensSwitchAt = DateTime.now();
    if (_cameras.isEmpty) return;
    await _openLens(normalized);
  }

  Future<void> _openLens(String role) async {
    if (_disposed || _cameras.isEmpty) return;
    final desiredDirection = role == VrJoystickConstants.cameraRoleFront
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    CameraDescription selected = _cameras.first;
    for (final cam in _cameras) {
      if (cam.lensDirection == desiredDirection) {
        selected = cam;
        break;
      }
    }

    final previous = _controller;
    _controller = null;
    if (previous != null) {
      try {
        if (previous.value.isStreamingImages) {
          await previous.stopImageStream();
        }
      } catch (_) {}
      try {
        await previous.dispose();
      } catch (_) {}
    }
    if (_disposed) return;

    final controller = CameraController(
      selected,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await controller.initialize();
      if (_disposed) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _lastLensSwitchAt = DateTime.now();
      await controller.startImageStream(_onCameraImage);
      notifyListeners();
    } catch (_) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  /// Updates the IMU gravity vector so optical + ultrasonic ranging can fuse
  /// arm inclination ergonomics in real time.
  void updateImuGravity(double gx, double gy, double gz) {
    final norm = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (norm < 1.0) return;
    // Estimate pitch inclination of the held phone
    _imuPitchRadians = math.asin((gz / norm).clamp(-1.0, 1.0));
    _recomputeFusedRange();
  }

  /// Triggers an ultrasonic 18.6–20.1 kHz chirp ToF measurement if due, and
  /// multiplexes between Rear (C2) and Front (C3) cameras when auto mode is on.
  void tick() {
    if (_disposed || !_enabled || _isFlutterTestEnvironment) return;
    final now = DateTime.now();

    if (!_ultrasonicPingInFlight &&
        now.difference(_lastUltrasonicPingAt).inMilliseconds >=
            VrJoystickConstants.ultrasonicPingIntervalMs) {
      _lastUltrasonicPingAt = now;
      _ultrasonicPingInFlight = true;
      _ultrasonicChannel
          .invokeMapMethod<String, dynamic>(
            VrJoystickConstants.ultrasonicPingMethod,
          )
          .then((result) {
            _ultrasonicPingInFlight = false;
            if (_disposed || result == null) return;
            final distance =
                (result[VrJoystickConstants.ultrasonicFieldEchoDistanceMeters]
                        as num?)
                    ?.toDouble();
            final snrDb =
                (result[VrJoystickConstants.ultrasonicFieldSnrDb] as num?)
                    ?.toDouble() ??
                0.0;
            _ultrasonicSnrDb = snrDb;
            if (distance != null &&
                distance.isFinite &&
                snrDb >= VrJoystickConstants.minValidUltrasonicSnrDb) {
              _ultrasonicActive = true;
              _ultrasonicEchoMeters = distance.clamp(
                VrJoystickConstants.minUltrasonicEchoMeters,
                VrJoystickConstants.maxUltrasonicEchoMeters,
              );
              _recomputeFusedRange();
            }
          })
          .catchError((_) {
            _ultrasonicPingInFlight = false;
          });
    }

    // Time-multiplex between Cám 2 (Rear Floor) and Cám 3 (Front Hands/Visor)
    // every 3.4 seconds when both cameras exist so both monitors stay fresh.
    if (_autoMultiplexLenses &&
        _cameras.length >= 2 &&
        !_starting &&
        now.difference(_lastLensSwitchAt).inMilliseconds >=
            VrJoystickConstants.cameraLensMultiplexIntervalMs) {
      _lastLensSwitchAt = now;
      final nextRole = _activeRole == VrJoystickConstants.cameraRoleRear
          ? VrJoystickConstants.cameraRoleFront
          : VrJoystickConstants.cameraRoleRear;
      unawaited(switchLens(nextRole));
    }
  }

  void _recomputeFusedRange() {
    // 1. Ergonomic arm-posture baseline from IMU pitch
    final imuBaseline = (0.53 - _imuPitchRadians * 0.11).clamp(0.26, 0.88);
    // 2. Optical Cám 3 visor angular width estimate (d ≈ W_real / W_uv)
    final opticalEstimate = (0.105 / _visorWidth.clamp(0.11, 0.45)).clamp(
      0.24,
      0.95,
    );
    // 3. Fuse ultrasonic ToF echo when acoustic SNR is strong
    final double targetRange;
    if (_ultrasonicActive && _ultrasonicSnrDb >= 4.0) {
      targetRange =
          _ultrasonicEchoMeters * 0.62 +
          opticalEstimate * 0.23 +
          imuBaseline * 0.15;
    } else {
      targetRange = opticalEstimate * 0.55 + imuBaseline * 0.45;
    }
    _currentRangeMeters =
        (_currentRangeMeters * 0.72 + targetRange * 0.28).clamp(0.22, 1.10);
  }

  void _onCameraImage(CameraImage image) {
    if (_disposed || !_enabled || image.planes.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(_lastFrameProcessedAt).inMilliseconds < 150) {
      return;
    }
    _lastFrameProcessedAt = now;

    final yPlane = image.planes.first;
    final yBytes = yPlane.bytes;
    final width = image.width;
    final height = image.height;
    final rowStride = yPlane.bytesPerRow;
    if (width <= 8 || height <= 8 || yBytes.isEmpty) return;

    final hasChroma = image.planes.length >= 3;
    final uPlane = hasChroma ? image.planes[1] : null;
    final vPlane = hasChroma ? image.planes[2] : null;

    // 1. Extract 24x18 luminance thumbnail for live HUD monitor streaming
    final mini = Uint8List(gridWidth * gridHeight);
    var lumaSum = 0.0;
    for (var gy = 0; gy < gridHeight; gy++) {
      final py = ((gy + 0.5) * height / gridHeight).floor().clamp(
        0,
        height - 1,
      );
      final rowOffset = py * rowStride;
      for (var gx = 0; gx < gridWidth; gx++) {
        final px = ((gx + 0.5) * width / gridWidth).floor().clamp(0, width - 1);
        final idx = (rowOffset + px).clamp(0, yBytes.length - 1);
        final luma = yBytes[idx];
        mini[gy * gridWidth + gx] = luma;
        lumaSum += luma;
      }
    }
    final meanLuma = lumaSum / (gridWidth * gridHeight);

    _latestMiniFrameBase64 = base64Encode(mini);
    if (_activeRole == VrJoystickConstants.cameraRoleRear) {
      _rearMiniFrame = mini;
      _analyzeRearFloorAndFeet(mini, meanLuma);
    } else {
      _frontMiniFrame = mini;
      _analyzeFrontHandsAndVisor(
        mini: mini,
        meanLuma: meanLuma,
        width: width,
        height: height,
        uPlane: uPlane,
        vPlane: vPlane,
      );
    }
    _recomputeFusedRange();
    notifyListeners();
  }

  /// Processes a pre-downsampled 24x18 grayscale mini-frame (432 bytes) and
  /// optional ultrasonic echo for unit tests and on-device CV verification.
  void ingestSyntheticMiniFrame(
    Uint8List mini, {
    String role = VrJoystickConstants.cameraRoleRear,
    double? ultrasonicEchoMeters,
    double ultrasonicSnrDb = 8.5,
  }) {
    if (_disposed || mini.length < gridWidth * gridHeight) return;
    _activeRole = role == VrJoystickConstants.cameraRoleFront
        ? VrJoystickConstants.cameraRoleFront
        : VrJoystickConstants.cameraRoleRear;
    var lumaSum = 0.0;
    for (var i = 0; i < gridWidth * gridHeight; i++) {
      lumaSum += mini[i];
    }
    final meanLuma = lumaSum / (gridWidth * gridHeight);
    _latestMiniFrameBase64 = base64Encode(
      mini.sublist(0, gridWidth * gridHeight),
    );
    if (_activeRole == VrJoystickConstants.cameraRoleRear) {
      _rearMiniFrame = mini;
      _analyzeRearFloorAndFeet(mini, meanLuma);
    } else {
      _frontMiniFrame = mini;
      _analyzeFrontHandsAndVisor(
        mini: mini,
        meanLuma: meanLuma,
        width: gridWidth,
        height: gridHeight,
        uPlane: null,
        vPlane: null,
      );
    }
    if (ultrasonicEchoMeters != null && ultrasonicEchoMeters.isFinite) {
      _ultrasonicActive = true;
      _ultrasonicSnrDb = ultrasonicSnrDb;
      _ultrasonicEchoMeters = ultrasonicEchoMeters.clamp(
        VrJoystickConstants.minUltrasonicEchoMeters,
        VrJoystickConstants.maxUltrasonicEchoMeters,
      );
    }
    _recomputeFusedRange();
    notifyListeners();
  }

  /// Real-time Cám 2 (Rear downward camera) Sobel + floor contrast segmentation
  /// to detect the user's left and right feet from the camera downward.
  void _analyzeRearFloorAndFeet(Uint8List mini, double meanLuma) {
    var leftWeightSum = 0.0;
    var leftUSum = 0.0;
    var leftVSum = 0.0;

    var rightWeightSum = 0.0;
    var rightUSum = 0.0;
    var rightVSum = 0.0;

    // Scan lower 70% of the downward frame where shoes/feet stand on the floor
    for (var gy = 5; gy < gridHeight - 1; gy++) {
      for (var gx = 1; gx < gridWidth - 1; gx++) {
        final c = mini[gy * gridWidth + gx].toDouble();
        final l = mini[gy * gridWidth + (gx - 1)].toDouble();
        final r = mini[gy * gridWidth + (gx + 1)].toDouble();
        final u = mini[(gy - 1) * gridWidth + gx].toDouble();
        final d = mini[(gy + 1) * gridWidth + gx].toDouble();

        final grad = ((r - l).abs() + (d - u).abs()) * 0.5;
        final contrast = (c - meanLuma).abs();
        final score = grad * 0.65 + contrast * 0.35;
        if (score < 16.0) continue;

        final normU = (gx + 0.5) / gridWidth;
        final normV = (gy + 0.5) / gridHeight;
        if (gx < gridWidth ~/ 2) {
          leftWeightSum += score;
          leftUSum += normU * score;
          leftVSum += normV * score;
        } else {
          rightWeightSum += score;
          rightUSum += normU * score;
          rightVSum += normV * score;
        }
      }
    }

    if (leftWeightSum > 45.0) {
      final targetU = (leftUSum / leftWeightSum).clamp(0.14, 0.48);
      final targetV = (leftVSum / leftWeightSum).clamp(0.35, 0.92);
      _leftFootU = _leftFootU * 0.62 + targetU * 0.38;
      _leftFootV = _leftFootV * 0.62 + targetV * 0.38;
    }
    if (rightWeightSum > 45.0) {
      final targetU = (rightUSum / rightWeightSum).clamp(0.52, 0.86);
      final targetV = (rightVSum / rightWeightSum).clamp(0.35, 0.92);
      _rightFootU = _rightFootU * 0.62 + targetU * 0.38;
      _rightFootV = _rightFootV * 0.62 + targetV * 0.38;
    }
    final combinedEnergy = (leftWeightSum + rightWeightSum) / 950.0;
    _feetConfidence = combinedEnergy.clamp(0.25, 0.99);
  }

  /// Real-time Cám 3 (Front upward camera) YCbCr skin-chroma + Sobel edge
  /// segmentation to detect the user's hands from bottom-up and the Visor above.
  void _analyzeFrontHandsAndVisor({
    required Uint8List mini,
    required double meanLuma,
    required int width,
    required int height,
    required Plane? uPlane,
    required Plane? vPlane,
  }) {
    var handWeightSum = 0.0;
    var handUSum = 0.0;
    var handVSum = 0.0;

    var visorWeightSum = 0.0;
    var visorUSum = 0.0;
    var visorVSum = 0.0;
    var visorMinX = gridWidth;
    var visorMaxX = 0;

    for (var gy = 1; gy < gridHeight - 1; gy++) {
      for (var gx = 1; gx < gridWidth - 1; gx++) {
        final c = mini[gy * gridWidth + gx].toDouble();
        final l = mini[gy * gridWidth + (gx - 1)].toDouble();
        final r = mini[gy * gridWidth + (gx + 1)].toDouble();
        final u = mini[(gy - 1) * gridWidth + gx].toDouble();
        final d = mini[(gy + 1) * gridWidth + gx].toDouble();
        final grad = ((r - l).abs() + (d - u).abs()) * 0.5;

        var skinBoost = 0.0;
        if (uPlane != null && vPlane != null) {
          final uvX = ((gx + 0.5) * (width ~/ 2) / gridWidth).floor().clamp(
            0,
            (width ~/ 2) - 1,
          );
          final uvY = ((gy + 0.5) * (height ~/ 2) / gridHeight).floor().clamp(
            0,
            (height ~/ 2) - 1,
          );
          final uvStride = uPlane.bytesPerRow;
          final uvPixelStride = uPlane.bytesPerPixel ?? 1;
          final uvIdx = (uvY * uvStride + uvX * uvPixelStride).clamp(
            0,
            math.min(uPlane.bytes.length, vPlane.bytes.length) - 1,
          );
          final cb = uPlane.bytes[uvIdx];
          final cr = vPlane.bytes[uvIdx];
          if (c > 42 && cb >= 77 && cb <= 129 && cr >= 131 && cr <= 176) {
            skinBoost = 42.0;
          }
        }

        final normU = (gx + 0.5) / gridWidth;
        final normV = (gy + 0.5) / gridHeight;

        // Lower/middle region (bottom-up view): hands & fingers holding/hovering
        if (gy >= 6) {
          final handScore =
              skinBoost + grad * 0.65 + (c - meanLuma).abs() * 0.30;
          if (handScore > 22.0) {
            handWeightSum += handScore;
            handUSum += normU * handScore;
            handVSum += normV * handScore;
          }
        } else {
          // Upper region: head / visor silhouette
          final visorScore = grad * 0.75 + (meanLuma - c).abs() * 0.40;
          if (visorScore > 18.0) {
            visorWeightSum += visorScore;
            visorUSum += normU * visorScore;
            visorVSum += normV * visorScore;
            if (gx < visorMinX) visorMinX = gx;
            if (gx > visorMaxX) visorMaxX = gx;
          }
        }
      }
    }

    if (handWeightSum > 50.0) {
      final targetU = (handUSum / handWeightSum).clamp(0.15, 0.85);
      final targetV = (handVSum / handWeightSum).clamp(0.32, 0.90);
      _handU = _handU * 0.58 + targetU * 0.42;
      _handV = _handV * 0.58 + targetV * 0.42;
      _handConfidence = (handWeightSum / 950.0).clamp(0.30, 0.99);
    }

    if (visorWeightSum > 35.0) {
      final targetU = (visorUSum / visorWeightSum).clamp(0.20, 0.80);
      final targetV = (visorVSum / visorWeightSum).clamp(0.10, 0.45);
      _visorU = _visorU * 0.65 + targetU * 0.35;
      _visorV = _visorV * 0.65 + targetV * 0.35;
      if (visorMaxX > visorMinX) {
        final span = ((visorMaxX - visorMinX + 1) / gridWidth).clamp(
          0.12,
          0.44,
        );
        _visorWidth = _visorWidth * 0.70 + span * 0.30;
      }
    }
  }

  static double _round3(double v) => (v * 1000.0).round() / 1000.0;

  /// Builds the dedicated `vrlizate.visionTelemetry` packet (~3 Hz) containing
  /// the live 24x18 camera thumbnail, CV landmarks, and ultrasonic range.
  ///
  /// When [includeMiniFrame] is false (e.g. over 20-byte ATT Bluetooth LE),
  /// omits the 576-byte base64 thumbnail so the packet fits in ~185 bytes.
  Map<String, Object?>? buildVisionTelemetryPayload({
    bool includeMiniFrame = true,
  }) {
    if (_latestMiniFrameBase64 == null && !_ultrasonicActive) {
      return null;
    }
    return <String, Object?>{
      VrJoystickConstants.fieldType:
          VrJoystickConstants.visionTelemetryMessageType,
      VrJoystickConstants.fieldRangeMeters: _round3(_currentRangeMeters),
      VrJoystickConstants.fieldLeftFootU: _round3(_leftFootU),
      VrJoystickConstants.fieldLeftFootV: _round3(_leftFootV),
      VrJoystickConstants.fieldRightFootU: _round3(_rightFootU),
      VrJoystickConstants.fieldRightFootV: _round3(_rightFootV),
      VrJoystickConstants.fieldFeetConfidence: _round3(_feetConfidence),
      VrJoystickConstants.fieldHandU: _round3(_handU),
      VrJoystickConstants.fieldHandV: _round3(_handV),
      VrJoystickConstants.fieldHandConfidence: _round3(_handConfidence),
      VrJoystickConstants.fieldVisorU: _round3(_visorU),
      VrJoystickConstants.fieldVisorV: _round3(_visorV),
      VrJoystickConstants.fieldVisorWidth: _round3(_visorWidth),
      VrJoystickConstants.fieldJoystickCameraRole: _activeRole,
      if (includeMiniFrame && _latestMiniFrameBase64 != null)
        VrJoystickConstants.fieldJoystickMiniFrame: _latestMiniFrameBase64,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      unawaited(
        Future<void>(() async {
          try {
            if (controller.value.isStreamingImages) {
              await controller.stopImageStream();
            }
          } catch (_) {}
          try {
            await controller.dispose();
          } catch (_) {}
        }),
      );
    }
    super.dispose();
  }
}
