import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../utils/constants/vr_joystick_constants.dart';
import 'vr_body_pose_gate.dart';
import 'vr_camera_analysis_budget.dart';
import 'vr_vision_inference_budget.dart';
import 'vr_vision_inference_client.dart';

export 'vr_body_pose_gate.dart' show VrBodyLandmark;

/// Low-rate optical heuristics on the controller phone, independent of the
/// headset camera. Rear/front cameras are multiplexed, never claimed concurrent.
/// Acoustic ranging is optional and requires a real native implementation.
class VrJoystickCameraVisionService extends ChangeNotifier
    with WidgetsBindingObserver {
  VrJoystickCameraVisionService({
    @visibleForTesting int Function()? monotonicMicroseconds,
    @visibleForTesting VrVisionInferenceClient? inferenceClient,
  }) : _inferenceClient = inferenceClient ?? VrVisionInferenceClient() {
    _nowMicroseconds =
        monotonicMicroseconds ?? () => _clock.elapsedMicroseconds;
  }

  static const int _frameIntervalUs = 150000;
  static const int _sampleFreshnessUs = 2000000;
  static const int _ultrasonicFreshnessUs = 1600000;
  static const Duration _ultrasonicTimeout = Duration(seconds: 2);
  final Stopwatch _clock = Stopwatch()..start();
  late final int Function() _nowMicroseconds;
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
  bool _enableHardwareCameraStream = false;
  bool _enableUltrasonicRanging = false;
  bool _ultrasonicPermissionGranted = false;
  bool _ultrasonicUnavailable = false;
  bool _configuringUltrasonic = false;
  bool _observingLifecycle = false;
  bool _suspended = false;
  bool _wantsCameraRunning = false;
  int _cameraGeneration = 0;
  Future<void> _cameraOperation = Future<void>.value();
  bool _autoMultiplexLenses = false;
  String _activeRole = VrJoystickConstants.cameraRoleRear;

  int? _lastFrameProcessedUs;
  int? _lastRearFrameUs;
  int? _lastFrontFrameUs;
  int _lastLensSwitchUs = 0;
  int? _lastUltrasonicPingUs;
  int? _lastUltrasonicSampleUs;
  bool _ultrasonicPingInFlight = false;
  int _ultrasonicGeneration = 0;
  int _cameraFramesReceived = 0;
  int _cameraFramesProcessed = 0;
  int _cameraFramesDropped = 0;
  int _lastCameraProcessingUs = 0;
  int _maxCameraProcessingUs = 0;
  int _lastMetricsLogUs = 0;
  String? _lastCameraError;
  bool _cameraBudgetStatusInFlight = false;
  final VrVisionInferenceClient _inferenceClient;
  final VrBodyPoseGate _bodyPoseGate = VrBodyPoseGate();
  final VrVisionInferenceBudget _inferenceBudget = VrVisionInferenceBudget();
  bool _bodyDetectionEnabled = false;
  bool _bodyUnavailable = false;
  int _bodyEpoch = 0;
  int? _lastBodySampleUs;
  int _inferenceSequence = 0;
  int _inferenceFramesDropped = 0;
  int _lastBodyMetricsLogUs = 0;
  String _bodyStatus = 'disabled';
  String _bodyGateReason = 'no_pose';
  int _bodyRawLandmarkCount = 0;
  int _bodyStableFrames = 0;
  int? _bodyThermalStatus;
  int? _bodyRetryAfterMs;
  String? _bodySourceId;
  String? _bodyBaselineSource;
  int? _bodyBaselineRotation;
  double? _bodyInferenceMs;
  double? _bodyRoundTripMs;
  List<VrBodyLandmark> _bodyLandmarks = const [];
  Map<int, VrBodyLandmark>? _bodyBaseline;
  double? _bodyDisplacementU;
  double? _bodyDisplacementV;
  double? _bodyJointDisplacement;
  List<Map<String, Object?>> _publicMarkers = const [];

  Uint8List? _rearMiniFrame;
  Uint8List? _frontMiniFrame;
  String? _latestMiniFrameBase64;
  Uint8List? _latestMiniFrame;

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
  bool _hasOpticalVisor = false;

  // Only a calibrated acoustic backend can supply metres. Chroma silhouettes
  // and IMU posture have no calibrated scale and cannot create a range.
  double? _currentRangeMeters;
  double? _ultrasonicEchoMeters;
  double _ultrasonicSnrDb = 0.0;
  bool _ultrasonicActive = false;
  bool _hasLiveSensorSample = false;
  double _imuPitchRadians = 0.0;
  double _imuRollRadians = 0.0;

  bool get enabled => _enabled;
  bool get hasLiveSensorSample => _hasLiveSensorSample;
  double get imuPitchRadians => _imuPitchRadians;
  double get imuRollRadians => _imuRollRadians;
  bool get isCameraStreaming => _controller?.value.isStreamingImages ?? false;

  /// Borrowed texture controller for a diagnostic [CameraPreview]. Ownership
  /// stays here: consumers must not initialize, stop, or dispose this controller.
  /// Reading the getter never opens a camera or starts another image stream.
  CameraController? get previewController =>
      isCameraStreaming ? _controller : null;
  bool get enableHardwareCameraStream => _enableHardwareCameraStream;
  set enableHardwareCameraStream(bool value) {
    _enableHardwareCameraStream = value;
    if (!value) unawaited(stop());
  }

  /// Microphone permission is requested only after explicit acoustic opt-in.
  bool get enableUltrasonicRanging => _enableUltrasonicRanging;
  set enableUltrasonicRanging(bool value) {
    if (_enableUltrasonicRanging == value || _disposed) return;
    _enableUltrasonicRanging = value;
    _ultrasonicGeneration++;
    _ultrasonicActive = false;
    _ultrasonicSnrDb = 0;
    _ultrasonicUnavailable = false;
    _lastUltrasonicPingUs = null;
    if (value) {
      _observeLifecycle();
      unawaited(_configureUltrasonic());
    }
  }

  bool get hasCameraSample =>
      _lastRearFrameUs != null || _lastFrontFrameUs != null;
  bool get hasFreshRearCameraSample => _isFresh(_lastRearFrameUs);
  bool get hasFreshFrontCameraSample => _isFresh(_lastFrontFrameUs);
  bool get hasFreshCameraSample =>
      hasFreshRearCameraSample || hasFreshFrontCameraSample;
  bool get hasFreshVisorEstimate =>
      _hasOpticalVisor && hasFreshFrontCameraSample;
  Duration? get cameraSampleAge {
    final last = _lastRearFrameUs == null
        ? _lastFrontFrameUs
        : _lastFrontFrameUs == null
        ? _lastRearFrameUs
        : math.max(_lastRearFrameUs!, _lastFrontFrameUs!);
    return last == null
        ? null
        : Duration(microseconds: math.max(0, _nowMicroseconds() - last));
  }

  int get cameraFramesReceived => _cameraFramesReceived;
  int get cameraFramesProcessed => _cameraFramesProcessed;
  int get cameraFramesDropped => _cameraFramesDropped;
  int get lastCameraProcessingMicroseconds => _lastCameraProcessingUs;
  int get maxCameraProcessingMicroseconds => _maxCameraProcessingUs;
  String? get lastCameraError => _lastCameraError;
  bool get bodyDetectionEnabled => _bodyDetectionEnabled;
  bool get bodyInferenceInFlight => _inferenceClient.isBusy;
  String get bodyStatus =>
      (_bodyStatus == 'ready' ||
              _bodyStatus == 'no_person' ||
              _bodyStatus == 'confirming_pose' ||
              _bodyStatus == 'rejected_pose') &&
          !hasFreshBodySample
      ? 'stale'
      : _bodyStatus;
  bool get hasFreshBodySample => _isFresh(_lastBodySampleUs);
  bool get bodyPresent => hasFreshBodySample && _bodyLandmarks.isNotEmpty;
  List<VrBodyLandmark> get bodyLandmarks =>
      hasFreshBodySample ? _bodyLandmarks : const [];
  String? get bodySourceId => _bodySourceId;
  double? get bodyInferenceMs => _bodyInferenceMs;
  double? get bodyRoundTripMs => _bodyRoundTripMs;
  int get bodyInferenceFramesDropped => _inferenceFramesDropped;
  int get bodyRawLandmarkCount =>
      hasFreshBodySample ? _bodyRawLandmarkCount : 0;
  int get bodyStableFrames => hasFreshBodySample ? _bodyStableFrames : 0;
  String get bodyGateReason => _bodyGateReason;
  double get bodyInferenceMaxHz => _inferenceBudget.effectiveMaxHz;
  int? get bodyThermalStatus => _bodyThermalStatus;
  int? get bodyRetryAfterMs => _bodyRetryAfterMs;
  double? get bodyDisplacementU => bodyPresent ? _bodyDisplacementU : null;
  double? get bodyDisplacementV => bodyPresent ? _bodyDisplacementV : null;
  double? get bodyJointDisplacement =>
      bodyPresent ? _bodyJointDisplacement : null;
  List<Map<String, Object?>> get publicMarkers =>
      hasFreshBodySample ? _publicMarkers : const [];

  /// Explicit opt-in raises this same camera to medium resolution. It does not
  /// create another camera session. Model absence remains unavailable.
  Future<void> setBodyDetectionEnabled(bool enabled) async {
    if (_disposed || _bodyDetectionEnabled == enabled) return;
    _bodyDetectionEnabled = enabled;
    _bodyUnavailable = false;
    _invalidateBody(enabled ? 'waiting_for_camera' : 'disabled');
    notifyListeners();
    if (_wantsCameraRunning && _cameras.isNotEmpty && !_suspended) {
      await _queueLensOpen(_activeRole, ++_cameraGeneration);
    }
  }

  void _invalidateBody(String status) {
    _bodyEpoch++;
    _inferenceClient.cancelPendingResults();
    _bodyStatus = status;
    _bodyPoseGate.reset();
    _inferenceBudget.reset();
    _bodyGateReason = 'no_pose';
    _bodyRawLandmarkCount = 0;
    _bodyStableFrames = 0;
    _bodyThermalStatus = null;
    _bodyRetryAfterMs = null;
    _lastBodySampleUs = null;
    _bodyLandmarks = const [];
    _bodyBaseline = null;
    _bodyBaselineSource = null;
    _bodyBaselineRotation = null;
    _bodyDisplacementU = null;
    _bodyDisplacementV = null;
    _bodyJointDisplacement = null;
    _publicMarkers = const [];
    _bodyInferenceMs = null;
    _bodyRoundTripMs = null;
  }

  bool get ultrasonicUnavailable => _ultrasonicUnavailable;
  bool get autoMultiplexLenses => _autoMultiplexLenses;
  String get activeRole => _activeRole;
  Uint8List? get rearMiniFrame => _rearMiniFrame;
  Uint8List? get frontMiniFrame => _frontMiniFrame;
  double get leftFootU => _leftFootU;
  double get leftFootV => _leftFootV;
  double get rightFootU => _rightFootU;
  double get rightFootV => _rightFootV;
  double get feetConfidence => hasFreshRearCameraSample ? _feetConfidence : 0;
  double get handU => _handU;
  double get handV => _handV;
  double get handConfidence => hasFreshFrontCameraSample ? _handConfidence : 0;
  double get visorU => _visorU;
  double get visorV => _visorV;
  double get visorWidth => _visorWidth;
  double? get currentRangeMeters =>
      ultrasonicActive ? _currentRangeMeters : null;
  bool get hasValidMetricRange => currentRangeMeters != null;
  double get ultrasonicSnrDb => _ultrasonicSnrDb;
  bool get ultrasonicActive =>
      _ultrasonicActive &&
      _isFresh(_lastUltrasonicSampleUs, _ultrasonicFreshnessUs);

  bool _isFresh(int? sampledAt, [int maxAgeUs = _sampleFreshnessUs]) =>
      sampledAt != null &&
      _nowMicroseconds() - sampledAt >= 0 &&
      _nowMicroseconds() - sampledAt <= maxAgeUs;

  static final bool _testEnvironment = _detectFlutterTestEnvironment();
  bool get _isFlutterTestEnvironment => _testEnvironment;

  static bool _detectFlutterTestEnvironment() {
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey(
        VrJoystickConstants.envKeyFlutterTest,
      );
    } catch (_) {
      return false;
    }
  }

  /// Starts one low-resolution camera. Calls are idempotent; stale permission
  /// or initialization completions cannot resurrect a stopped service.
  Future<void> start() async {
    if (_disposed || _starting || _isFlutterTestEnvironment) return;
    if (!enableHardwareCameraStream) return;
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    _wantsCameraRunning = true;
    _observeLifecycle();
    if (_suspended || isCameraStreaming) return;
    _starting = true;
    final generation = ++_cameraGeneration;
    try {
      var status = await Permission.camera.status;
      if (!status.isGranted) status = await Permission.camera.request();
      if (!status.isGranted || !_canOpen(generation)) return;
      _cameras = await availableCameras();
      if (_cameras.isEmpty || !_canOpen(generation)) return;
      await _queueLensOpen(_activeRole, generation);
    } catch (error) {
      _lastCameraError = error is CameraException
          ? error.code
          : error.runtimeType.toString();
    } finally {
      _starting = false;
      if (!_disposed &&
          !_suspended &&
          _wantsCameraRunning &&
          enableHardwareCameraStream &&
          generation != _cameraGeneration &&
          !isCameraStreaming) {
        unawaited(start());
      }
    }
  }

  bool _canOpen(int generation) =>
      !_disposed &&
      !_suspended &&
      enableHardwareCameraStream &&
      _wantsCameraRunning &&
      generation == _cameraGeneration;

  void _observeLifecycle() {
    if (_observingLifecycle || _isFlutterTestEnvironment) return;
    WidgetsBinding.instance.addObserver(this);
    _observingLifecycle = true;
  }

  /// Releases camera hardware without affecting the controller or IMU stream.
  Future<void> stop() => _stopCamera(clearIntent: true);

  Future<void> _stopCamera({required bool clearIntent}) {
    if (clearIntent) _wantsCameraRunning = false;
    _cameraGeneration++;
    _invalidateBody(_bodyDetectionEnabled ? 'waiting_for_camera' : 'disabled');
    _cameraOperation = _cameraOperation.then((_) async {
      final controller = _controller;
      _controller = null;
      if (!_disposed) notifyListeners();
      await _releaseController(controller);
    });
    return _cameraOperation;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _suspended = state != AppLifecycleState.resumed;
    if (_suspended) {
      unawaited(_stopCamera(clearIntent: false));
      _ultrasonicActive = false;
      _ultrasonicGeneration++;
    } else if (_wantsCameraRunning && enableHardwareCameraStream) {
      unawaited(start());
    }
  }

  Future<void> _configureUltrasonic() async {
    if (_configuringUltrasonic || _disposed || _isFlutterTestEnvironment) {
      return;
    }
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    _configuringUltrasonic = true;
    try {
      var status = await Permission.microphone.status;
      if (!status.isGranted) status = await Permission.microphone.request();
      _ultrasonicPermissionGranted = status.isGranted;
    } catch (_) {
      _ultrasonicPermissionGranted = false;
    } finally {
      _configuringUltrasonic = false;
    }
  }

  /// Cycles between Rear (`Cám 2 Piso`), Front (`Cám 3 Manos`), and Auto-Multiplex.
  Future<void> cycleCameraLensMode() async {
    await setCameraLensMode(
      _autoMultiplexLenses
          ? VrJoystickConstants.cameraRoleRear
          : _activeRole == VrJoystickConstants.cameraRoleRear
          ? VrJoystickConstants.cameraRoleFront
          : 'auto',
    );
  }

  /// Selects a stable rear/front lens or explicit sequential auto-multiplexing.
  Future<void> setCameraLensMode(String mode) async {
    if (_disposed) return;
    _autoMultiplexLenses = mode == 'auto';
    await switchLens(
      mode == VrJoystickConstants.cameraRoleFront
          ? VrJoystickConstants.cameraRoleFront
          : VrJoystickConstants.cameraRoleRear,
    );
    if (_disposed) return;
    notifyListeners();
  }

  /// Switches one physical lens. The plugin does not expose a portable
  /// concurrent front/rear capture capability, so camera operations are serial.
  Future<void> switchLens(String role) async {
    if (_disposed) return;
    final normalized = role == VrJoystickConstants.cameraRoleFront
        ? VrJoystickConstants.cameraRoleFront
        : VrJoystickConstants.cameraRoleRear;
    final direction = normalized == VrJoystickConstants.cameraRoleFront
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    if (_cameras.isNotEmpty &&
        !_cameras.any((camera) => camera.lensDirection == direction)) {
      _lastCameraError = 'CameraLensUnavailable';
      notifyListeners();
      return;
    }
    if (_activeRole == normalized && isCameraStreaming) return;
    _activeRole = normalized;
    _lastLensSwitchUs = _nowMicroseconds();
    if (_cameras.isEmpty || !_wantsCameraRunning) return;
    await _queueLensOpen(normalized, ++_cameraGeneration);
  }

  Future<void> _queueLensOpen(String role, int generation) {
    _cameraOperation = _cameraOperation.then((_) async {
      if (!_canOpen(generation)) return;
      await _openLens(role, generation);
    });
    return _cameraOperation;
  }

  Future<void> _releaseController(CameraController? controller) async {
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // Disposal must still run when the stream was interrupted by the OS.
    }
    try {
      await controller.dispose();
    } catch (_) {
      // A disconnected camera may already have been released by the platform.
    }
  }

  Future<void> _openLens(String role, int generation) async {
    if (!_canOpen(generation) || _cameras.isEmpty) return;
    final direction = role == VrJoystickConstants.cameraRoleFront
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    final matching = _cameras.where(
      (camera) => camera.lensDirection == direction,
    );
    if (matching.isEmpty) return;
    final selected = matching.first;
    final resolution = _bodyDetectionEnabled
        ? ResolutionPreset.medium
        : ResolutionPreset.low;
    if (_controller?.description.name == selected.name &&
        _controller?.resolutionPreset == resolution &&
        isCameraStreaming) {
      return;
    }
    _invalidateBody(_bodyDetectionEnabled ? 'waiting_for_frame' : 'disabled');
    final previous = _controller;
    _controller = null;
    if (!_disposed) notifyListeners();
    await _releaseController(previous);
    if (!_canOpen(generation)) return;

    final controller = CameraController(
      selected,
      resolution,
      enableAudio: false,
      fps: 12,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await controller.initialize();
      if (!_canOpen(generation)) {
        await _releaseController(controller);
        return;
      }
      _controller = controller;
      _lastFrameProcessedUs = null;
      final analysisConfigured = await VrCameraAnalysisBudget.configure(
        controller,
        intervalMs: 140,
      );
      if (!kReleaseMode) {
        debugPrint(
          '[VrCameraAnalysisBudget] role=$role cameraId=${controller.cameraId} configured=$analysisConfigured intervalMs=140',
        );
      }
      if (!_canOpen(generation)) {
        _controller = null;
        await _releaseController(controller);
        return;
      }
      await controller.startImageStream((image) {
        if (_canOpen(generation) && identical(_controller, controller)) {
          unawaited(
            _maybeAnalyzeBody(
              image,
              camera: selected,
              orientation: controller.value.deviceOrientation,
            ),
          );
          _onCameraImage(image, role: role);
        }
      });
      if (!_canOpen(generation)) {
        _controller = null;
        await _releaseController(controller);
        return;
      }
      _lastLensSwitchUs = _nowMicroseconds();
      _lastCameraError = null;
      notifyListeners();
    } catch (error) {
      if (identical(_controller, controller)) _controller = null;
      _lastCameraError = error is CameraException
          ? error.code
          : error.runtimeType.toString();
      await _releaseController(controller);
    }
  }

  /// Updates the IMU gravity vector so optical + ultrasonic ranging can fuse
  /// arm inclination ergonomics in real time.
  void updateImuGravity(double gx, double gy, double gz) {
    if (_disposed || !gx.isFinite || !gy.isFinite || !gz.isFinite) return;
    final norm = math.sqrt(gx * gx + gy * gy + gz * gz);
    if (norm < 1.0) return;
    // Estimate pitch and roll inclination of the held landscape phone
    _imuPitchRadians = math.asin((gz / norm).clamp(-1.0, 1.0));
    _imuRollRadians = math.asin((gy / norm).clamp(-1.0, 1.0));
    // IMU orientation is not optical evidence: leave hand/foot confidence at
    // zero until a recent camera frame was actually analyzed.
    if (!_isFlutterTestEnvironment) _hasLiveSensorSample = true;
    _recomputeFusedRange();
  }

  /// Triggers an ultrasonic 18.6–20.1 kHz chirp ToF measurement if due, and
  /// multiplexes between Rear (C2) and Front (C3) cameras when auto mode is on.
  void tick() {
    if (_disposed || !_enabled || _suspended || _isFlutterTestEnvironment) {
      return;
    }
    final now = _nowMicroseconds();

    if (enableUltrasonicRanging &&
        _ultrasonicPermissionGranted &&
        !_ultrasonicUnavailable &&
        !_ultrasonicPingInFlight &&
        (_lastUltrasonicPingUs == null ||
            now - _lastUltrasonicPingUs! >=
                VrJoystickConstants.ultrasonicPingIntervalMs * 1000)) {
      _lastUltrasonicPingUs = now;
      _ultrasonicPingInFlight = true;
      final generation = _ultrasonicGeneration;
      _ultrasonicChannel
          .invokeMapMethod<String, dynamic>(
            VrJoystickConstants.ultrasonicPingMethod,
          )
          .timeout(_ultrasonicTimeout)
          .then((result) {
            if (_disposed ||
                generation != _ultrasonicGeneration ||
                result == null) {
              return;
            }
            _acceptUltrasonicResult(result);
          })
          .catchError((Object error) {
            if (_disposed || generation != _ultrasonicGeneration) return;
            _ultrasonicActive = false;
            // Missing/blocked native probes must not compete with every control
            // tick. Explicit off/on opt-in is required to retry after failure.
            _ultrasonicUnavailable = true;
          })
          .whenComplete(() => _ultrasonicPingInFlight = false);
    }

    final hasBothDirections =
        _cameras.any(
          (camera) => camera.lensDirection == CameraLensDirection.back,
        ) &&
        _cameras.any(
          (camera) => camera.lensDirection == CameraLensDirection.front,
        );
    if (_autoMultiplexLenses &&
        hasBothDirections &&
        isCameraStreaming &&
        !_starting &&
        now - _lastLensSwitchUs >=
            VrJoystickConstants.cameraLensMultiplexIntervalMs * 1000) {
      _lastLensSwitchUs = now;
      final nextRole = _activeRole == VrJoystickConstants.cameraRoleRear
          ? VrJoystickConstants.cameraRoleFront
          : VrJoystickConstants.cameraRoleRear;
      unawaited(switchLens(nextRole));
    }
  }

  @visibleForTesting
  void ingestUltrasonicResult(Map<String, dynamic> result) {
    if (!_disposed) _acceptUltrasonicResult(result);
  }

  void _acceptUltrasonicResult(Map<String, dynamic> result) {
    final distance =
        (result[VrJoystickConstants.ultrasonicFieldEchoDistanceMeters] as num?)
            ?.toDouble();
    final snrDb =
        (result[VrJoystickConstants.ultrasonicFieldSnrDb] as num?)
            ?.toDouble() ??
        0.0;
    _ultrasonicSnrDb = snrDb.isFinite ? snrDb : 0;
    final calibrated = result['calibrated'] == true;
    final analyzed = result['micAnalyzed'] == true;
    final emitted = result['emitted'] == true;
    // An uncalibrated/emitter-only implementation cannot become a range sensor
    // through repeated polling. Retry only after an explicit off/on request.
    _ultrasonicUnavailable = !calibrated || !analyzed || !emitted;
    if (result['measurementValid'] == true &&
        calibrated &&
        analyzed &&
        emitted &&
        distance != null &&
        distance.isFinite &&
        distance >= VrJoystickConstants.minUltrasonicEchoMeters &&
        distance <= VrJoystickConstants.maxUltrasonicEchoMeters &&
        snrDb.isFinite &&
        snrDb >= VrJoystickConstants.minValidUltrasonicSnrDb) {
      _ultrasonicActive = true;
      _lastUltrasonicSampleUs = _nowMicroseconds();
      _ultrasonicEchoMeters = distance;
    } else {
      _ultrasonicActive = false;
    }
    _recomputeFusedRange();
    notifyListeners();
  }

  void _recomputeFusedRange() {
    // Do not mix an acoustic measurement with invented ergonomic baselines or
    // apparent silhouette width. Echo distance also does not establish the
    // relative pose of the phones or identify the reflecting object.
    _currentRangeMeters = ultrasonicActive ? _ultrasonicEchoMeters : null;
  }

  /// Uses the exact hardware-frame sampling path without requiring permissions.
  @visibleForTesting
  void ingestCameraImage(CameraImage image, {String? role}) =>
      _onCameraImage(image, role: role);

  @visibleForTesting
  Future<void> ingestInferenceCameraImage(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation orientation,
  }) => _maybeAnalyzeBody(image, camera: camera, orientation: orientation);

  Future<void> _maybeAnalyzeBody(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation orientation,
  }) async {
    if (_disposed || _suspended || !_bodyDetectionEnabled || _bodyUnavailable) {
      return;
    }
    final now = _nowMicroseconds();
    if (_inferenceClient.isBusy || !_inferenceBudget.tryStart(now)) {
      _inferenceFramesDropped++;
      return;
    }
    final epoch = _bodyEpoch;
    final sourceId = 'joystick:${camera.lensDirection.name}:${camera.name}';
    final startedAt = _clock.elapsedMicroseconds;
    try {
      final result = await _inferenceClient.analyzeFrame(
        image,
        camera: camera,
        orientation: orientation,
        sourceId: sourceId,
        sequence: ++_inferenceSequence,
        detectPose: true,
        detectMarker: false,
      );
      if (_disposed || _suspended || epoch != _bodyEpoch) return;
      _bodyRoundTripMs = (_clock.elapsedMicroseconds - startedAt) / 1000;
      _acceptBodyResult(result, sourceId, now);
    } finally {
      _inferenceBudget.recordCompletion(
        startedUs: now,
        finishedUs: _nowMicroseconds(),
        confirmedBody: bodyPresent,
      );
    }
    if (!kReleaseMode && now - _lastBodyMetricsLogUs >= 5000000) {
      _lastBodyMetricsLogUs = now;
      debugPrint(
        '[JoystickInference] source=$sourceId status=$bodyStatus '
        'sequence=$_inferenceSequence joints=${bodyLandmarks.length} '
        'raw=$bodyRawLandmarkCount accepted=$bodyPresent reason=$bodyGateReason '
        'intervalUs=${_inferenceBudget.intervalUs} '
        'inferenceMs=$_bodyInferenceMs totalMs=$_bodyRoundTripMs '
        'dropped=$_inferenceFramesDropped',
      );
    }
    notifyListeners();
  }

  void _acceptBodyResult(
    Map<String, dynamic> result,
    String sourceId,
    int capturedAt,
  ) {
    final status = result['status'];
    _bodySourceId = sourceId;
    _bodyThermalStatus = null;
    _bodyRetryAfterMs = null;
    if (status != 'ok' && status != 'partial') {
      _bodyStatus = status is String ? status : 'unavailable';
      _bodyGateReason = _bodyStatus;
      _bodyLandmarks = const [];
      _lastBodySampleUs = null;
      _bodyBaseline = null;
      _publicMarkers = const [];
      _bodyInferenceMs = null;
      _bodyUnavailable = status == 'unavailable';
      _bodyPoseGate.reset();
      _bodyRawLandmarkCount = 0;
      _bodyStableFrames = 0;
      if (status == 'thermal_backoff') {
        final thermal = result['thermalStatus'];
        final rawRetry = result['retryAfterMs'];
        _bodyThermalStatus = thermal is int && thermal >= 0 && thermal <= 6
            ? thermal
            : null;
        _bodyRetryAfterMs = rawRetry is num && rawRetry.isFinite
            ? rawRetry.toInt().clamp(2000, 60000)
            : 2000;
        _bodyRoundTripMs = null; // A refused request did not execute inference.
        _bodyDisplacementU = null;
        _bodyDisplacementV = null;
        _bodyJointDisplacement = null;
        _inferenceBudget.deferFor(
          _nowMicroseconds(),
          retryAfterUs: _bodyRetryAfterMs! * 1000,
        );
      }
      return;
    }
    final inferenceMs = result['inferenceMs'];
    _bodyInferenceMs = inferenceMs is num && inferenceMs.isFinite
        ? inferenceMs.toDouble()
        : null;
    final imageWidth = result['imageWidth'];
    final imageHeight = result['imageHeight'];
    final pose = result['pose'];
    if (imageWidth is! num ||
        imageHeight is! num ||
        imageWidth <= 0 ||
        imageHeight <= 0 ||
        pose is! Map ||
        pose['status'] != 'ok') {
      _bodyStatus = 'unavailable';
      _bodyLandmarks = const [];
      _lastBodySampleUs = null;
      _bodyBaseline = null;
      _bodyPoseGate.reset();
      _bodyRawLandmarkCount = 0;
      _bodyStableFrames = 0;
      return;
    }
    final rawPoints = VrBodyLandmark.fromNative(
      pose['landmarks'],
      imageWidth: imageWidth.toInt(),
      imageHeight: imageHeight.toInt(),
    );
    final gate = _bodyPoseGate.evaluate(
      landmarks: rawPoints,
      present: pose['present'] == true,
      sourceId: sourceId,
      rotationDegrees: result['rotationDegrees'] as int,
      capturedAtUs: capturedAt,
      imageWidth: imageWidth.toInt(),
      imageHeight: imageHeight.toInt(),
    );
    _bodyGateReason = gate.reason;
    _bodyRawLandmarkCount = gate.rawCount;
    _bodyStableFrames = gate.stableFrames;
    final byType = <int, VrBodyLandmark>{
      if (gate.accepted)
        for (final point in rawPoints) point.type: point,
    };
    if (_lastBodySampleUs == null ||
        capturedAt - _lastBodySampleUs! > _sampleFreshnessUs) {
      _bodyBaseline = null;
    }
    _lastBodySampleUs = capturedAt;
    _bodyLandmarks = List.unmodifiable(byType.values);
    _bodyStatus = gate.accepted
        ? 'ready'
        : !(pose['present'] == true) || rawPoints.isEmpty
        ? 'no_person'
        : gate.stableFrames > 0
        ? 'confirming_pose'
        : 'rejected_pose';
    _publicMarkers = const []; // Body inference never requests marker scanning.
    if (byType.isEmpty) {
      _bodyBaseline = null;
      _bodyDisplacementU = null;
      _bodyDisplacementV = null;
      _bodyJointDisplacement = null;
      return;
    }
    final rotation = result['rotationDegrees'] as int?;
    if (_bodyBaselineSource != sourceId || _bodyBaselineRotation != rotation) {
      _bodyBaseline = null;
    }
    final reliable = <int, VrBodyLandmark>{
      for (final entry in byType.entries)
        if (entry.value.inFrameLikelihood >= .5) entry.key: entry.value,
    };
    _bodyBaseline ??= reliable.length >= 3 ? reliable : null;
    _bodyBaselineSource = sourceId;
    _bodyBaselineRotation = rotation;
    final baseline = _bodyBaseline;
    var du = 0.0;
    var dv = 0.0;
    var squaredDisplacement = 0.0;
    var count = 0;
    if (baseline != null) {
      for (final entry in reliable.entries) {
        final prior = baseline[entry.key];
        if (prior == null) continue;
        final dx = entry.value.u - prior.u;
        final dy = entry.value.v - prior.v;
        du += dx;
        dv += dy;
        squaredDisplacement += dx * dx + dy * dy;
        count++;
      }
    }
    _bodyDisplacementU = count >= 3 ? du / count : null;
    _bodyDisplacementV = count >= 3 ? dv / count : null;
    _bodyJointDisplacement = count >= 3
        ? math.sqrt(squaredDisplacement / count)
        : null;
  }

  void _onCameraImage(CameraImage image, {String? role}) {
    if (_disposed || !_enabled || _suspended) return;
    _cameraFramesReceived++;
    final now = _nowMicroseconds();
    // Drop before allocating, downsampling, or encoding. There is deliberately
    // no async full-frame queue: the next accepted callback is the latest frame.
    if (_lastFrameProcessedUs != null &&
        now - _lastFrameProcessedUs! < _frameIntervalUs) {
      _cameraFramesDropped++;
      return;
    }
    final width = image.width;
    final height = image.height;
    if (width <= 8 || height <= 8 || image.planes.isEmpty) {
      _cameraFramesDropped++;
      return;
    }
    final plane = image.planes.first;
    final bgra = image.format.group == ImageFormatGroup.bgra8888;
    final yuv =
        image.format.group == ImageFormatGroup.yuv420 ||
        image.format.group == ImageFormatGroup.nv21;
    if ((!bgra && !yuv) || plane.bytes.isEmpty || plane.bytesPerRow <= 0) {
      _cameraFramesDropped++;
      return;
    }
    final pixelStride = bgra ? 4 : (plane.bytesPerPixel ?? 1);
    final requiredRowBytes = (width - 1) * pixelStride + (bgra ? 4 : 1);
    if (pixelStride <= 0 ||
        plane.bytesPerRow < requiredRowBytes ||
        plane.bytes.length <
            (height - 1) * plane.bytesPerRow + requiredRowBytes) {
      _cameraFramesDropped++;
      return;
    }
    final startedAt = _clock.elapsedMicroseconds;
    final mini = Uint8List(gridWidth * gridHeight);
    var lumaSum = 0.0;
    for (var gy = 0; gy < gridHeight; gy++) {
      final py = ((gy + 0.5) * height / gridHeight).floor();
      final rowOffset = py * plane.bytesPerRow;
      for (var gx = 0; gx < gridWidth; gx++) {
        final px = ((gx + 0.5) * width / gridWidth).floor();
        final index = rowOffset + px * pixelStride;
        final luma = bgra
            ? (plane.bytes[index + 2] * 77 +
                      plane.bytes[index + 1] * 150 +
                      plane.bytes[index] * 29) >>
                  8
            : plane.bytes[index];
        mini[gy * gridWidth + gx] = luma;
        lumaSum += luma;
      }
    }
    _lastFrameProcessedUs = now;
    _cameraFramesProcessed++;
    _activeRole = role == VrJoystickConstants.cameraRoleFront
        ? VrJoystickConstants.cameraRoleFront
        : role == VrJoystickConstants.cameraRoleRear
        ? VrJoystickConstants.cameraRoleRear
        : _activeRole;
    _acceptMiniFrame(
      mini,
      lumaSum / mini.length,
      now,
      width: width,
      height: height,
      uPlane: yuv && image.planes.length >= 3 ? image.planes[1] : null,
      vPlane: yuv && image.planes.length >= 3 ? image.planes[2] : null,
    );
    _lastCameraProcessingUs = _clock.elapsedMicroseconds - startedAt;
    _maxCameraProcessingUs = math.max(
      _maxCameraProcessingUs,
      _lastCameraProcessingUs,
    );
    if (!kReleaseMode && now - _lastMetricsLogUs >= 5000000) {
      _lastMetricsLogUs = now;
      debugPrint(
        '[JoystickVision] role=$_activeRole '
        'received=$_cameraFramesReceived analyzed=$_cameraFramesProcessed '
        'dropped=$_cameraFramesDropped cpuUs=$_lastCameraProcessingUs '
        'maxCpuUs=$_maxCameraProcessingUs',
      );
      final camera = _controller;
      if (camera != null && !_cameraBudgetStatusInFlight) {
        unawaited(_logCameraBudgetStatus(camera));
      }
    }
    notifyListeners();
  }

  Future<void> _logCameraBudgetStatus(CameraController camera) async {
    _cameraBudgetStatusInFlight = true;
    try {
      final status = await VrCameraAnalysisBudget.status(camera);
      if (!_disposed && identical(camera, _controller) && status != null) {
        debugPrint(
          '[VrCameraAnalysisBudget] role=$_activeRole ${jsonEncode(status)}',
        );
      }
    } finally {
      _cameraBudgetStatusInFlight = false;
    }
  }

  void _acceptMiniFrame(
    Uint8List mini,
    double meanLuma,
    int sampledAt, {
    required int width,
    required int height,
    Plane? uPlane,
    Plane? vPlane,
  }) {
    _latestMiniFrame = mini;
    _latestMiniFrameBase64 = null;
    if (_activeRole == VrJoystickConstants.cameraRoleRear) {
      _rearMiniFrame = mini;
      _lastRearFrameUs = sampledAt;
      _analyzeRearFloorAndFeet(mini, meanLuma);
    } else {
      _frontMiniFrame = mini;
      _lastFrontFrameUs = sampledAt;
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
  }

  /// Processes a pre-downsampled 24x18 grayscale mini-frame (432 bytes).
  /// Legacy acoustic arguments do not grant calibrated measurement provenance;
  /// test a native result explicitly with [ingestUltrasonicResult] instead.
  @visibleForTesting
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
    // Own the small buffer: callers may reuse or mutate their source image.
    final owned = Uint8List.fromList(mini.sublist(0, gridWidth * gridHeight));
    var lumaSum = 0.0;
    for (final value in owned) {
      lumaSum += value;
    }
    _acceptMiniFrame(
      owned,
      lumaSum / owned.length,
      _nowMicroseconds(),
      width: gridWidth,
      height: gridHeight,
    );
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
    // Heuristic score, not an ML probability or semantic foot identification.
    _feetConfidence = combinedEnergy.clamp(0.0, 0.35);
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
          final uIndex =
              uvY * uPlane.bytesPerRow + uvX * (uPlane.bytesPerPixel ?? 1);
          final vIndex =
              uvY * vPlane.bytesPerRow + uvX * (vPlane.bytesPerPixel ?? 1);
          if (uIndex >= 0 &&
              uIndex < uPlane.bytes.length &&
              vIndex >= 0 &&
              vIndex < vPlane.bytes.length) {
            final cb = uPlane.bytes[uIndex];
            final cr = vPlane.bytes[vIndex];
            if (c > 42 && cb >= 77 && cb <= 129 && cr >= 131 && cr <= 176) {
              skinBoost = 42.0;
            }
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
      // Heuristic score, not an ML probability or articulated hand tracking.
      _handConfidence = (handWeightSum / 950.0).clamp(0.0, 0.35);
    } else {
      _handConfidence = 0;
    }

    _hasOpticalVisor = visorWeightSum > 35.0;
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

  /// Builds optional vision telemetry; the caller budgets transport cadence.
  /// Optical coordinates are estimated heuristics. Metric range is absent
  /// unless the acoustic backend reports a valid, calibrated, fresh sample.
  ///
  /// When [includeMiniFrame] is false, no base64 encoding is performed. BLE
  /// still fragments the scalar JSON packet according to its negotiated MTU.
  Map<String, Object?>? buildVisionTelemetryPayload({
    bool includeMiniFrame = true,
  }) {
    if (_disposed ||
        (!hasFreshCameraSample && !ultrasonicActive && !_hasLiveSensorSample)) {
      return null;
    }
    final latestRoleIsFresh = _activeRole == VrJoystickConstants.cameraRoleRear
        ? hasFreshRearCameraSample
        : hasFreshFrontCameraSample;
    if (includeMiniFrame && latestRoleIsFresh && _latestMiniFrame != null) {
      _latestMiniFrameBase64 ??= base64Encode(_latestMiniFrame!);
    }
    final metricRange = currentRangeMeters;
    return <String, Object?>{
      VrJoystickConstants.fieldType:
          VrJoystickConstants.visionTelemetryMessageType,
      VrJoystickConstants.fieldRangeMeters: metricRange == null
          ? null
          : _round3(metricRange),
      'rangeSource': metricRange == null ? null : 'calibrated_acoustic_echo',
      'opticalEstimated': true,
      'opticalSource': 'heuristic_edges_chroma',
      VrJoystickConstants.fieldLeftFootU: _round3(_leftFootU),
      VrJoystickConstants.fieldLeftFootV: _round3(_leftFootV),
      VrJoystickConstants.fieldRightFootU: _round3(_rightFootU),
      VrJoystickConstants.fieldRightFootV: _round3(_rightFootV),
      VrJoystickConstants.fieldFeetConfidence: _round3(feetConfidence),
      VrJoystickConstants.fieldHandU: _round3(_handU),
      VrJoystickConstants.fieldHandV: _round3(_handV),
      VrJoystickConstants.fieldHandConfidence: _round3(handConfidence),
      VrJoystickConstants.fieldVisorU: _round3(_visorU),
      VrJoystickConstants.fieldVisorV: _round3(_visorV),
      VrJoystickConstants.fieldVisorWidth: _round3(_visorWidth),
      VrJoystickConstants.fieldJoystickCameraRole: _activeRole,
      if (includeMiniFrame &&
          latestRoleIsFresh &&
          _latestMiniFrameBase64 != null)
        VrJoystickConstants.fieldJoystickMiniFrame: _latestMiniFrameBase64,
    };
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ultrasonicGeneration++;
    _inferenceClient.dispose();
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    unawaited(_stopCamera(clearIntent: true));
    super.dispose();
  }
}
