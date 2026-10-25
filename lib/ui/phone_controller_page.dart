import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';
import 'package:wordsphere/wordsphere.dart';

import '../domain/models/vr_controller_connection_exception.dart';
import '../domain/models/vr_controller_connection_target.dart';
import '../domain/models/vr_joystick_geometry.dart';
import '../domain/models/vr_steering_state.dart';
import '../domain/models/vr_tracking_marker_configuration.dart';
import '../domain/services/vr_auto_walk_lock_controller.dart';
import '../domain/services/vr_controller_link.dart';
import '../domain/services/vr_controller_mode_session.dart';
import '../domain/services/vr_controller_shake_detector.dart';
import '../domain/services/vr_controller_state_pacer.dart';
import '../domain/services/vr_flick_stick_controller.dart';
import '../domain/services/vr_inertial_trackball_controller.dart';
import '../domain/services/vr_joystick_camera_vision_service.dart';
import '../domain/services/vr_laser_steady_dwell_controller.dart';
import '../domain/services/vr_motion_look_controller.dart';
import '../domain/services/vr_one_handed_laser_detector.dart';
import '../domain/services/vr_passthrough_split_gesture_controller.dart';
import '../domain/services/vr_progressive_stick.dart';
import '../domain/services/vr_steering_controller.dart';
import '../domain/services/vr_web_socket_controller_link.dart';
import '../utils/constants/vr_joystick_constants.dart';
import '../utils/constants/vr_joystick_translation_constants.dart';
import '../utils/enums/remote_controller_mode.dart';
import '../utils/enums/vr_joystick_control.dart';
import '../utils/enums/vr_motion_capability.dart';
import '../utils/enums/vr_right_stick_look_mode.dart';
import 'nes_controller_layout.dart';
import 'virtual_thumbstick.dart';
import 'vr_breakthrough_curtain_bar.dart';
import 'vr_controller_region.dart';
import 'vr_driving_wheel_painter.dart';
import 'vr_laser_pointing_view.dart';
import 'vr_laser_slide_pad_painter.dart';
import 'vr_passthrough_curtain_overlay_painter.dart';
import 'vr_public_tracking_marker_page.dart';
import 'vr_wordsphere_search_sheet.dart';

/// Native Smartphone VR Controller & Joystick Screen.
///
/// Main modes:
/// 1. [RemoteControllerMode.joystick]: Virtual 2D analog thumbstick for smooth 3D walking/strafe
///    locomotion + ergonomic Gamepad button cluster (A, B, Trigger, Grip, Recenter).
/// 2. [RemoteControllerMode.driving]: Motion-only steering and inclination,
///    separate accelerator/brake pedals, and L/R camera-view buttons.
/// The smaller right control switches between vertical look and a laser pad.
/// The left stick owns walking and sustained-rim turning. A legacy laser initial mode is normalized
/// to joystick; the laser wire enum remains compatible with older controllers.
///
/// Roles:
/// - Supports [isChildRole] when paired via canonical deep link `vrlizate://pair?...`
///   from a Parent Visor.
class PhoneControllerPage extends StatefulWidget {
  final RemoteControllerMode initialMode;
  final String? targetHost;
  final int targetPort;
  final String? sessionToken;
  final VrTransportType transportType;
  final bool autoConnect;
  final bool isChildRole;

  /// Enables the built-in LAN discovery, socket connection and manual Wi-Fi
  /// override. Set false for a controller supplied exclusively by an external
  /// transport such as Bluetooth LE through [linkConnector].
  final bool allowWifiConnection;

  /// Optional provider-owned connection/authentication (for example BLE).
  /// On completion this page owns the link and closes it on disposal/retry.
  /// With no connector the existing authenticated WebSocket path is used.
  final Future<VrControllerLink> Function()? linkConnector;

  /// Human-readable transport/device label. Never put a token or URI here.
  final String? connectionLabel;
  final Duration connectionTimeout;

  /// Called after a connected/authenticated link is installed. Hosts may use
  /// this to remember the invitation in platform-backed secure storage. A null
  /// target identifies the external provider; otherwise it is the actual
  /// authenticated Wi-Fi destination, including a user-selected override.
  final ValueChanged<VrControllerConnectionTarget?>? onConnected;

  /// Credentials were explicitly rejected. The host should forget any saved
  /// invitation matching this target and offer a fresh QR, rather than retry an
  /// expired token. Null identifies the external provider, as in [onConnected].
  final ValueChanged<VrControllerConnectionTarget?>? onSessionExpired;

  const PhoneControllerPage({
    super.key,
    this.initialMode = RemoteControllerMode.joystick,
    this.targetHost,
    this.targetPort = VrJoystickConstants.defaultServerPort,
    this.sessionToken,
    this.transportType = VrTransportType.localSocket,
    this.autoConnect = false,
    this.isChildRole = false,
    this.allowWifiConnection = true,
    this.linkConnector,
    this.connectionLabel,
    this.connectionTimeout = const Duration(seconds: 4),
    this.onConnected,
    this.onSessionExpired,
  });

  @override
  State<PhoneControllerPage> createState() => _PhoneControllerPageState();
}

/// A separate, unmirrored diagnostic plot avoids claiming pixel registration
/// against device-specific mirrored GPU camera previews.
class _BodyLandmarkDiagnosticPainter extends CustomPainter {
  const _BodyLandmarkDiagnosticPainter(this.landmarks);
  final List<VrBodyLandmark> landmarks;

  static const _bones = <(int, int)>[
    (11, 12),
    (11, 13),
    (13, 15),
    (12, 14),
    (14, 16),
    (11, 23),
    (12, 24),
    (23, 24),
    (23, 25),
    (25, 27),
    (24, 26),
    (26, 28),
    (27, 29),
    (29, 31),
    (28, 30),
    (30, 32),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF080816),
    );
    final points = <int, VrBodyLandmark>{
      for (final landmark in landmarks)
        if (landmark.inFrameLikelihood >= .5 &&
            landmark.u >= 0 &&
            landmark.u <= 1 &&
            landmark.v >= 0 &&
            landmark.v <= 1)
          landmark.type: landmark,
    };
    Offset location(VrBodyLandmark point) =>
        Offset(point.u * size.width, point.v * size.height);
    final paint = Paint()
      ..color = const Color(0xFF10B981)
      ..strokeWidth = 1.5;
    for (final (start, end) in _bones) {
      final a = points[start];
      final b = points[end];
      if (a != null && b != null) {
        canvas.drawLine(location(a), location(b), paint);
      }
    }
    paint.color = const Color(0xFF7DD3FC);
    for (final point in points.values) {
      canvas.drawCircle(location(point), 2.5, paint);
    }
  }

  @override
  bool shouldRepaint(_BodyLandmarkDiagnosticPainter oldDelegate) =>
      !identical(landmarks, oldDelegate.landmarks);
}

class _PhoneControllerPageState extends State<PhoneControllerPage>
    with WidgetsBindingObserver {
  final TextEditingController _ipController = TextEditingController(
    text: VrJoystickConstants.defaultIpPrefix,
  );

  VrControllerLink? _socket;
  StreamSubscription<Object?>? _linkSubscription;
  RawDatagramSocket? _udpListener;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  Timer? _streamTimer;
  Timer? _connectionTimeout;
  Timer? _reconnectTimer;
  Timer? _recenterResetTimer;
  Timer? _drivingActionTimer;
  Completer<VrControllerLink>? _pendingConnection;

  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isForeground = true;
  bool _targetEdited = false;
  bool _useWifiOverride = false;
  String? _discoveredHost;
  late int _targetPort;
  int _connectionGeneration = 0;
  bool _reconnectEnabled = false;
  int _reconnectAttempt = 0;
  static const _reconnectDelays = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 10),
  ];
  int _socketGeneration = 0;
  int _effectivePassthroughRevision = -1;
  bool _hasEffectivePassthroughState = false;
  double _reportedPassthroughMix = 0;
  double? _pendingPassthroughMix;
  final _passthroughSettingsRevision = ValueNotifier<int>(0);
  final Set<int> _exclusiveControlPointers = {};
  int _surfaceEpoch = 0;
  // mounted remains true while descendants dispose their gesture recognizers.
  // Those recognizers can synchronously call onTapCancel under the tree lock.
  bool _surfaceMounted = true;
  final _hostModeSession = VrControllerModeSession();
  RemoteControllerMode? _lastHostMode;

  /// Per-button captions sent by the host for the active experience; empty
  /// means the generic role labels. Keyed A/B/X/Y/L/R/GRIP.
  Map<String, String> _hostActions = const {};
  Uri? _castOffer;
  bool _castAutoEnabled = true;
  final ValueNotifier<Uri?> _castPreview = ValueNotifier(null);
  int _castGeneration = 0;
  bool _castDialogOpen = false;

  /// Generic role of each button, shown until a host captions it. Must match
  /// the host runner: X cycles modes, Y is the special action, L utility, R
  /// the game trigger.
  static const _defaultActions = {
    VrJoystickConstants.actionKeyA: VrJoystickTranslationConstants.actionSelect,
    VrJoystickConstants.actionKeyB:
        VrJoystickTranslationConstants.actionBackCancel,
    VrJoystickConstants.actionKeyX:
        VrJoystickTranslationConstants.actionChangeMode,
    VrJoystickConstants.actionKeyY:
        VrJoystickTranslationConstants.actionSpecial,
    VrJoystickConstants.actionKeyL:
        VrJoystickTranslationConstants.actionUtility,
    VrJoystickConstants.actionKeyR:
        VrJoystickTranslationConstants.actionTrigger,
    VrJoystickConstants.actionKeyGrip:
        VrJoystickTranslationConstants.actionGrip,
  };

  String _actionLabel(String key) =>
      _hostActions[key] ?? _defaultActions[key] ?? key;
  Size? _joystickSize;
  Size? _nesSize;
  EdgeInsets? _nesInsets;
  EdgeInsets? _joystickInsets;
  bool _settingsOpen = false;
  VrJoystickGeometry? _joystickGeometry;
  final Map<VrJoystickControl, Path> _joystickLocalPaths = {};
  VrControllerConnectionTarget? _lastTarget;
  VrControllerConnectionTarget? _socketTarget;
  String _status = VrJoystickTranslationConstants.statusSearchingWifi;

  late RemoteControllerMode _activeMode;
  final VrSteeringController _steering = VrSteeringController();
  final Stopwatch _controllerClock = Stopwatch()..start();
  VrMotionCapability _motionCapability = VrMotionCapability.checking;
  int? _lastMotionUs;
  int _lastDrivingTickUs = 0;
  int _lastDrivingPaintUs = 0;
  VrSteeringState? _lastPaintedDrivingState;
  bool _throttlePedalHeld = false;
  bool _brakePedalHeld = false;
  final _statePacer = VrControllerStatePacer();

  // Dual Joystick state
  double _stickX = 0.0;
  double _stickY = 0.0;
  bool _moveAtEdge = false;
  bool _rightLaser = false;
  // Horizontal + vertical right-stick look enabled by default so the right
  // thumbstick on the Joystick smartphone can turn left/right as well as pitch.
  bool _horizontalLookEnabled = true;
  double _lookX = 0.0; // Horizontal turn rate from the right thumbstick.
  double _lookY = 0.0; // 180° Vertical tilt (pitch)
  final _moveResponse = VrProgressiveStick();
  final _lookResponse = VrProgressiveStick(initialGain: .45, maxGain: .8);
  final _motionLook = VrMotionLookController();
  bool _lookStickHeld = false;
  bool _motionLookEnabled = true;
  double _laserStickX = 0.0; // Laser pointer horizontal steering
  double _laserStickY = 0.0; // Laser pointer vertical steering
  double _laserYaw = 0.0;
  double _laserPitch = 0.0;
  bool _isLaserSlideActive = false;
  int? _laserSlidePointer;
  double _laserSlideNormX = 0.0;
  double _laserSlideNormY = 0.0;
  bool _recenterTriggered = false;

  // Haptic feedback / vibration state
  bool _hapticsEnabled = true;
  Timer? _connectionHapticTimer;

  void _hapticClick() {
    if (_hapticsEnabled) HapticFeedback.selectionClick();
  }

  void _hapticLight() {
    if (_hapticsEnabled) HapticFeedback.lightImpact();
  }

  void _hapticMedium() {
    if (_hapticsEnabled) HapticFeedback.mediumImpact();
  }

  void _hapticDoublePulse() {
    _connectionHapticTimer?.cancel();
    _connectionHapticTimer = null;
    if (_hapticsEnabled) {
      HapticFeedback.heavyImpact();
      _connectionHapticTimer = Timer(const Duration(milliseconds: 140), () {
        _connectionHapticTimer = null;
        if (mounted && _isForeground && _isConnected && _hapticsEnabled) {
          HapticFeedback.heavyImpact();
        }
      });
    }
  }

  // Shake & One-Handed Laser detection state
  bool _shakeToToggleEnabled = true;
  bool _controllerVisible = true;
  final _shakeDetector = VrControllerShakeDetector();
  final _oneHandedLaserDetector = VrOneHandedLaserDetector();
  final _laserSteadyDwell = VrLaserSteadyDwellController();
  final _passthroughGesture = VrPassthroughSplitGestureController();
  final _visionService = VrJoystickCameraVisionService();
  VrTrackingMarkerConfiguration? _trackingMarkerConfiguration;
  bool _cameraSettingsBusy = false;
  bool _showAuxiliaryCameraPreview = false;
  int _lastVisionTelemetryUs = 0;
  int _lastPassthroughHapticBucket = 0;
  bool _spatialHudVisible = false;
  double _lastSentPassthroughMix = 0.0;
  bool _lastSentSpatialHudVisible = false;
  final TextEditingController _wordsphereTextController =
      TextEditingController();
  late final WordsphereController _wordsphereController = WordsphereController(
    textController: _wordsphereTextController,
  );
  bool _wordsphereSearchSheetVisible = false;
  String? _activeSearchQuery;
  bool _searchSubmittedPulse = false;
  Timer? _laserClickPulseTimer;
  Timer? _searchSubmitPulseTimer;
  double _lastGyroOmegaMag = 0.0;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  // Buttons state
  bool _triggerActive = false;
  bool _actionActive = false;
  bool _btnAActive = false;
  bool _btnBActive = false;
  bool _btnXActive = false;
  bool _btnYActive = false;
  bool _btnLActive = false;
  bool _btnRActive = false;
  bool _btnGripActive = false;
  bool _stickClickActive = false;
  Timer? _gripHoldTimer;
  Timer? _stickClickPulseTimer;

  // Open-source inspired ergonomics & look controllers
  bool _dynamicTouchOriginEnabled = true;
  bool _cardinalDetentsEnabled = true;
  bool _autoWalkLockEnabled = true;
  VrRightStickLookMode _rightStickLookMode =
      VrRightStickLookMode.smoothDualAxis;
  final VrAutoWalkLockController _leftAutoWalkController =
      VrAutoWalkLockController();
  final VrAutoWalkLockController _rightStickClickDetector =
      VrAutoWalkLockController();
  final VrFlickStickController _flickStickController = VrFlickStickController();
  final VrInertialTrackballController _inertialTrackballController =
      VrInertialTrackballController();
  double _rawLookX = 0.0;
  double _rawLookY = 0.0;

  // Laser aim belongs to touch; wheel motion must never rotate the pointer.
  vm.Quaternion _orientation = vm.Quaternion.identity();
  vm.Quaternion _wheelOrientation = vm.Quaternion.identity();
  final vm.Vector3 _angularVelocity = vm.Vector3.zero();
  DateTime? _lastGyroTime;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _isForeground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _reconnectEnabled =
        widget.autoConnect &&
        (widget.linkConnector != null ||
            (widget.allowWifiConnection &&
                widget.targetHost?.isNotEmpty == true));
    _activeMode = widget.initialMode == RemoteControllerMode.laser
        ? RemoteControllerMode.joystick
        : widget.initialMode;
    _targetPort = widget.targetPort;
    _loadSavedHaptics();
    if (widget.linkConnector != null) {
      _status =
          '${VrJoystickTranslationConstants.statusUnpairedPrefix}$_externalConnectionLabel';
    } else if (!widget.allowWifiConnection) {
      _status = _bluetoothPairingNotice;
    } else if (widget.targetHost != null && widget.targetHost!.isNotEmpty) {
      _ipController.text = widget.targetHost!;
      _status =
          '${VrJoystickTranslationConstants.statusUnpairedPrefix}${widget.targetHost}${VrJoystickConstants.colonSeparator}$_targetPort';
    } else {
      _loadSavedIp();
    }
    if (widget.allowWifiConnection &&
        widget.linkConnector == null &&
        (widget.targetHost == null || widget.targetHost!.isEmpty)) {
      _startUdpAutoDiscovery();
    }
    _startGyroTracking();
    _startShakeDetection();
    _visionService.addListener(_onVisionServiceUpdated);
    unawaited(_visionService.start());

    // Lock to horizontal (landscape) mode for ergonomic dual-hand controller gameplay
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    if (widget.autoConnect &&
        (widget.linkConnector != null ||
            (widget.allowWifiConnection &&
                widget.targetHost != null &&
                widget.targetHost!.isNotEmpty))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isConnected && !_isConnecting) {
          _connect();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant PhoneControllerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.targetHost != widget.targetHost ||
        oldWidget.targetPort != widget.targetPort ||
        oldWidget.sessionToken != widget.sessionToken ||
        oldWidget.linkConnector != widget.linkConnector) {
      _clearCast();
    }
    if (oldWidget.allowWifiConnection && !widget.allowWifiConnection) {
      final wasWifi =
          _useWifiOverride ||
          _socketTarget != null ||
          (oldWidget.linkConnector == null && _isConnecting);
      _udpListener?.close();
      _udpListener = null;
      _useWifiOverride = false;
      _lastTarget = null;
      _discoveredHost = null;
      _ipController.clear();
      if (!_usesExternalLink) _stopAutomaticReconnect();
      if (wasWifi) {
        _stopAutomaticReconnect();
        _cancelPendingConnection();
        _releaseInputs(send: true);
        final socket = _socket;
        _socket = null;
        _socketTarget = null;
        _linkSubscription?.cancel();
        _linkSubscription = null;
        _isConnected = false;
        _isConnecting = false;
        if (socket != null) unawaited(_closeLink(socket));
        _status = _bluetoothPairingNotice;
      }
      if (!_isConnected && !_isConnecting) {
        _status = _usesExternalLink
            ? '${VrJoystickTranslationConstants.statusUnpairedPrefix}$_externalConnectionLabel'
            : _bluetoothPairingNotice;
      }
    }
  }

  bool get _hasDualHandTouchActive =>
      _stickX.abs() > 0.05 ||
      _stickY.abs() > 0.05 ||
      _lookStickHeld ||
      _isLaserSlideActive ||
      _btnAActive ||
      _btnBActive ||
      _btnXActive ||
      _btnYActive ||
      _btnLActive ||
      _btnRActive ||
      _btnGripActive;

  void _startShakeDetection() {
    try {
      _accelSub =
          accelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 20),
          ).listen(
            (AccelerometerEvent event) {
              if (!mounted || !_isForeground) return;
              final nowUs = _controllerClock.elapsedMicroseconds;
              // Driving tilt remains available when shake-to-hide is disabled.
              _steering.updateGravity(event.x, event.y, event.z, nowUs);
              _motionLook.updateGravity(event.x, event.y, event.z, nowUs);
              _visionService.updateImuGravity(event.x, event.y, event.z);
              if (!_settingsOpen && !_castDialogOpen) {
                final sensorTimeUs = event.timestamp.microsecondsSinceEpoch;
                final effectiveUs = sensorTimeUs > 0 ? sensorTimeUs : nowUs;
                if (_activeMode == RemoteControllerMode.joystick &&
                    _oneHandedLaserDetector.shouldSwitchToLaser(
                      gx: event.x,
                      gy: event.y,
                      gz: event.z,
                      omegaMagnitude: _lastGyroOmegaMag,
                      dualTouchActive: _hasDualHandTouchActive,
                      timestampUs: effectiveUs,
                    )) {
                  setState(() {
                    _releaseInputs();
                    _surfaceEpoch++;
                    _activeMode = RemoteControllerMode.laser;
                    _laserSteadyDwell.reset();
                    _status =
                        VrJoystickTranslationConstants.statusLaserOneHandReady;
                  });
                  _hapticMedium();
                  _sendState(force: true);
                  return;
                }
              }
              if (_lookStickHeld) {
                _shakeDetector.reset();
                return;
              }
              if (_settingsOpen || !_shakeToToggleEnabled) return;
              if (_shakeDetector.addSample(event.x, event.y, event.z, nowUs)) {
                _onShakeDetected();
              }
            },
            onError: (_) {
              _steering.clearGravity();
              _motionLook.reset();
            },
          );
    } catch (_) {}
  }

  void _onShakeDetected() {
    _hapticDoublePulse();
    _setControllerVisible(!_controllerVisible);
  }

  void _setControllerVisible(bool visible) {
    setState(() => _controllerVisible = visible);
    _sendState();
  }

  Future<void> _loadSavedHaptics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedHaptics = prefs.getBool(
        VrJoystickConstants.prefKeyHapticsEnabled,
      );
      final savedMotionLook = prefs.getBool(
        VrJoystickConstants.prefKeyMotionLookEnabled,
      );
      final savedDynamicOrigin = prefs.getBool(
        VrJoystickConstants.prefKeyDynamicTouchOrigin,
      );
      final savedCardinalDetents = prefs.getBool(
        VrJoystickConstants.prefKeyCardinalDetentsEnabled,
      );
      final savedAutoWalkLock = prefs.getBool(
        VrJoystickConstants.prefKeyAutoWalkLockEnabled,
      );
      final savedLookModeName = prefs.getString(
        VrJoystickConstants.prefKeyRightStickLookMode,
      );
      if (mounted) {
        setState(() {
          if (savedHaptics != null) _hapticsEnabled = savedHaptics;
          if (savedMotionLook != null) _motionLookEnabled = savedMotionLook;
          if (savedDynamicOrigin != null) {
            _dynamicTouchOriginEnabled = savedDynamicOrigin;
          }
          if (savedCardinalDetents != null) {
            _cardinalDetentsEnabled = savedCardinalDetents;
          }
          if (savedAutoWalkLock != null) {
            _autoWalkLockEnabled = savedAutoWalkLock;
            if (!_autoWalkLockEnabled) _leftAutoWalkController.reset();
          }
          if (savedLookModeName != null) {
            for (final mode in VrRightStickLookMode.values) {
              if (mode.name == savedLookModeName) {
                _rightStickLookMode = mode;
                break;
              }
            }
          }
          // Preference loading must never activate a gesture already held.
          if (!_motionLookEnabled) {
            _motionLook.setActive(false, _controllerClock.elapsedMicroseconds);
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _persistHaptics(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(VrJoystickConstants.prefKeyHapticsEnabled, enabled);
    } catch (_) {}
  }

  Future<void> _persistMotionLook(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        VrJoystickConstants.prefKeyMotionLookEnabled,
        enabled,
      );
    } catch (_) {}
  }

  Future<void> _persistBoolPref(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _persistRightStickLookMode(VrRightStickLookMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        VrJoystickConstants.prefKeyRightStickLookMode,
        mode.name,
      );
    } catch (_) {}
  }

  void _pulseStickClick() {
    _stickClickPulseTimer?.cancel();
    setState(() {
      _stickClickActive = true;
    });
    _hapticMedium();
    _sendState(force: true);
    _stickClickPulseTimer = Timer(
      const Duration(
        milliseconds: VrJoystickConstants.stickClickPulseDurationMs,
      ),
      () {
        if (!mounted) return;
        setState(() {
          _stickClickActive = false;
        });
        _sendState(force: true);
      },
    );
  }

  Future<void> _loadSavedIp() async {
    if (!widget.allowWifiConnection) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString(VrJoystickConstants.prefKeyHostIp);
      if (mounted &&
          widget.allowWifiConnection &&
          !_targetEdited &&
          _discoveredHost == null &&
          savedIp != null &&
          savedIp.isNotEmpty) {
        setState(() {
          _ipController.text = savedIp;
        });
      }
    } catch (_) {}
  }

  void _startUdpAutoDiscovery() async {
    if (!widget.allowWifiConnection) return;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        VrJoystickConstants.udpDiscoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      if (!mounted || !widget.allowWifiConnection) {
        socket.close();
        return;
      }
      _udpListener = socket;
      socket.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (mounted &&
              _isForeground &&
              datagram != null &&
              datagram.data.length <= 2048 &&
              !_isConnected &&
              !_isConnecting &&
              !_targetEdited &&
              _discoveredHost == null) {
            try {
              final msg = utf8.decode(datagram.data);
              final json = jsonDecode(msg);
              if (json is Map<String, dynamic> &&
                  json[VrJoystickConstants.fieldService] ==
                      VrJoystickConstants.udpServiceId) {
                final port = json[VrJoystickConstants.fieldPort];
                if (port is! int || port < 1 || port > 65535) return;
                // Discovery is an unauthenticated hint. Trust the datagram's
                // actual source for display, never its advertised IP/token.
                final hostIp = datagram.address.address;
                setState(() {
                  _discoveredHost = hostIp;
                  _targetPort = port;
                  _ipController.text = hostIp;
                  _status =
                      '${VrJoystickTranslationConstants.statusVisorDetectedPrefix}$hostIp${VrJoystickConstants.colonSeparator}$port${VrJoystickTranslationConstants.statusVisorDetectedSuffix}';
                });
              }
            } catch (_) {}
          }
        }
      });
    } catch (e) {
      debugPrint('${VrJoystickConstants.udpListenerLogPrefix}$e');
    }
  }

  void _startGyroTracking() {
    try {
      _gyroSub =
          gyroscopeEventStream(
            samplingPeriod: const Duration(milliseconds: 16),
          ).listen(
            (GyroscopeEvent event) {
              if (!mounted || !_isForeground) return;
              if (!event.x.isFinite ||
                  !event.y.isFinite ||
                  !event.z.isFinite ||
                  event.x.abs() > 100 ||
                  event.y.abs() > 100 ||
                  event.z.abs() > 100) {
                _lastGyroOmegaMag = 0.0;
                // Rejecting a sample must not leave the previous turn rate
                // alive until the sensor watchdog expires. Keep thumb input.
                if (_activeMode == RemoteControllerMode.joystick) {
                  _motionLook.reset();
                  _updateJoystick();
                  _sendState(force: true);
                }
                return;
              }
              _lastMotionUs = _controllerClock.elapsedMicroseconds;
              _lastGyroOmegaMag = math.sqrt(
                event.x * event.x + event.y * event.y + event.z * event.z,
              );
              _setMotionCapability(VrMotionCapability.available);
              if (_activeMode == RemoteControllerMode.joystick &&
                  _lookStickHeld &&
                  _motionLookEnabled &&
                  !_settingsOpen) {
                _motionLook.updateGyroscope(
                  event.x,
                  event.y,
                  event.z,
                  _lastMotionUs!,
                  sensorTimeUs: event.timestamp.microsecondsSinceEpoch,
                );
              }
              if (_activeMode == RemoteControllerMode.laser) {
                final now = event.timestamp;
                if (_lastGyroTime != null) {
                  final dt =
                      (now.difference(_lastGyroTime!).inMicroseconds) / 1e6;
                  if (dt > 0 && dt < 0.25) {
                    _angularVelocity.setValues(event.x, event.y, event.z);
                    final deltaYaw =
                        (-event.z -
                            event.y *
                                VrJoystickConstants.laserGyroYawRollCoupling) *
                        dt;
                    final deltaPitch = event.x * dt;
                    setState(() {
                      _laserYaw = (_laserYaw + deltaYaw).clamp(
                        -VrJoystickConstants.laserMaxYawRadians,
                        VrJoystickConstants.laserMaxYawRadians,
                      );
                      _laserPitch = (_laserPitch + deltaPitch).clamp(
                        -VrJoystickConstants.laserMaxPitchRadians,
                        VrJoystickConstants.laserMaxPitchRadians,
                      );
                      _laserStickX =
                          (_laserYaw / VrJoystickConstants.laserMaxYawRadians)
                              .clamp(-1.0, 1.0);
                      _laserStickY =
                          (_laserPitch /
                                  VrJoystickConstants.laserMaxPitchRadians)
                              .clamp(-1.0, 1.0);
                      _laserSlideNormX = _laserStickX;
                      _laserSlideNormY = -_laserStickY;
                      final qYaw = vm.Quaternion.axisAngle(
                        vm.Vector3(0, 1, 0),
                        -_laserYaw,
                      );
                      final qPitch = vm.Quaternion.axisAngle(
                        vm.Vector3(1, 0, 0),
                        _laserPitch,
                      );
                      _orientation = (qYaw * qPitch).normalized();
                    });
                    _sendState();
                  }
                }
                _lastGyroTime = now;
                return;
              }
              if (_activeMode != RemoteControllerMode.driving) {
                // Only the touch pad owns laser aim, including after release.
                // Relative phone deflection requests a sustained look rate
                // through lookX/Y; it never owns the pointer pose.
                _angularVelocity.setZero();
                _lastGyroTime = null;
                return;
              }
              final now = event.timestamp;
              if (_lastGyroTime != null) {
                final dt =
                    (now.difference(_lastGyroTime!).inMicroseconds) / 1e6;
                if (dt > 0 && dt < 0.2) {
                  final omega = vm.Vector3(event.x, event.y, event.z);
                  final angle = omega.length * dt;
                  if (angle > 1e-4) {
                    final axis = omega.normalized();
                    final deltaQ = vm.Quaternion.axisAngle(axis, angle);
                    _wheelOrientation = (_wheelOrientation * deltaQ)
                        .normalized();
                  }
                }
              }
              _lastGyroTime = now;
              _steering.updateOrientation(_wheelOrientation);
            },
            onError: (_) {
              _lastGyroOmegaMag = 0.0;
              _motionLook.reset();
              _angularVelocity.setZero();
              _lastGyroTime = null;
              _setMotionCapability(VrMotionCapability.unavailable);
            },
          );
    } catch (_) {
      _setMotionCapability(VrMotionCapability.unavailable);
    }

    // Sample controls at 60 Hz. The sender paces analog updates and keeps idle
    // links alive without serializing/transmitting identical state each tick.
    _streamTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || !_isForeground) return;
      final now = _controllerClock.elapsedMicroseconds;
      final dtSeconds = (now - _lastDrivingTickUs) / 1e6;
      if (_activeMode == RemoteControllerMode.joystick) {
        _updateJoystick(elapsed: dtSeconds, nowUs: now);
      }
      if (now - (_lastMotionUs ?? 0) > 2000000) {
        _lastGyroOmegaMag = 0.0;
        _setMotionCapability(VrMotionCapability.unavailable);
      }
      if (_activeMode == RemoteControllerMode.laser) {
        final triggered = _laserSteadyDwell.update(
          angularSpeedRadiansPerSec: _lastGyroOmegaMag,
          dtSeconds: math.max(dtSeconds, 0.016),
          paused: _wordsphereSearchSheetVisible || _settingsOpen,
        );
        if (triggered) {
          _pulseLaserClick();
        } else if (now - _lastDrivingPaintUs >= 33333) {
          _lastDrivingPaintUs = now;
          setState(() {});
        }
      }
      if (_activeMode == RemoteControllerMode.driving) {
        _steering.setPedals(
          throttlePressed: _throttlePedalHeld,
          brakePressed: _brakePedalHeld,
        );
        _steering.advance(dtSeconds);
        final driving = _steering.state;
        final painted = _lastPaintedDrivingState;
        if (now - _lastDrivingPaintUs >= 33333 &&
            (painted == null ||
                driving.steering != painted.steering ||
                driving.throttle != painted.throttle ||
                driving.brake != painted.brake ||
                driving.paused != painted.paused)) {
          _lastDrivingPaintUs = now;
          _lastPaintedDrivingState = driving;
          setState(() {});
        }
      }
      _lastDrivingTickUs = now;
      _visionService.tick();
      _sendVisionTelemetryMessageIfDue(now);
      _sendState();
    });
  }

  /// One conditioned output for BLE and socket clients. The thumbstick remains
  /// visually tied to the finger; only transmitted intent follows the ramp.
  void _updateJoystick({double elapsed = 0, int? nowUs}) {
    if (_activeMode != RemoteControllerMode.joystick) return;
    _moveResponse.advance(elapsed);
    _lookResponse.advance(elapsed);
    final move = _moveResponse.output;
    final look = _lookResponse.output;
    final motion = _motionLook.sample(
      nowUs ?? _controllerClock.elapsedMicroseconds,
    );
    if (_leftAutoWalkController.isAutoWalkLocked) {
      _stickX = 0.0;
      _stickY = math.max(move.y, 1.0);
      _moveAtEdge = true;
    } else {
      _stickX = move.x;
      _stickY = move.y;
    }
    // Right thumbstick horizontal deflection turns left/right according to
    // the active look mode; relative phone tilt while holding the look stick
    // contributes vertical pitch only.
    double x;
    double y;
    switch (_rightStickLookMode) {
      case VrRightStickLookMode.smoothDualAxis:
        x = _horizontalLookEnabled ? look.x : 0.0;
        y = look.y + motion.y;
      case VrRightStickLookMode.comfortSnapTurn:
        x = _horizontalLookEnabled
            ? _flickStickController.update(
                mode: _rightStickLookMode,
                x: _rawLookX,
                y: _rawLookY,
                dtSeconds: elapsed,
              )
            : 0.0;
        y = look.y + motion.y;
      case VrRightStickLookMode.flickStick:
        x = _horizontalLookEnabled
            ? _flickStickController.update(
                mode: _rightStickLookMode,
                x: _rawLookX,
                y: _rawLookY,
                dtSeconds: elapsed,
              )
            : 0.0;
        y = motion.y;
      case VrRightStickLookMode.inertialTrackball:
        if (_lookStickHeld) {
          x = _horizontalLookEnabled ? look.x : 0.0;
          y = look.y + motion.y;
        } else if (_inertialTrackballController.isCoasting) {
          final coast = _inertialTrackballController.advance(elapsed);
          x = _horizontalLookEnabled ? coast.x : 0.0;
          y = coast.y;
        } else {
          x = 0.0;
          y = 0.0;
        }
    }
    final magnitude = math.sqrt(x * x + y * y);
    if (magnitude > 1) {
      x /= magnitude;
      y /= magnitude;
    }
    _lookX = _rightLaser ? 0 : x;
    _lookY = _rightLaser ? 0 : y;
  }

  void _selectRightControl(bool laser) {
    if (_rightLaser == laser || _activeMode != RemoteControllerMode.joystick) {
      return;
    }
    setState(() {
      _releaseInputs();
      _surfaceEpoch++;
      _rightLaser = laser;
    });
    _hapticClick();
    _sendState(force: true);
  }

  void _setMotionCapability(VrMotionCapability capability) {
    if (!mounted || _motionCapability == capability) return;
    setState(() {
      final wasDrivingWithMotion =
          _activeMode == RemoteControllerMode.driving &&
          _steering.motionAvailable;
      _motionCapability = capability;
      _steering.setMotionAvailable(capability == VrMotionCapability.available);
      if (capability == VrMotionCapability.unavailable) {
        _motionLook.reset();
        _angularVelocity.setZero();
        _lastGyroTime = null;
        if (wasDrivingWithMotion) {
          _steering.setPaused(true);
          _releaseInputs(send: true);
        }
      }
    });
  }

  void _selectMode(RemoteControllerMode mode) {
    setState(() {
      _releaseInputs();
      _surfaceEpoch++;
      _activeMode = mode;
      _oneHandedLaserDetector.setModeActive(mode == RemoteControllerMode.laser);
      _laserSteadyDwell.reset();
      _wordsphereSearchSheetVisible = false;
      if (mode == RemoteControllerMode.laser) {
        _status = VrJoystickTranslationConstants.statusLaserOneHandReady;
      }
      _steering.setPaused(false);
      _steering.calibrate(_wheelOrientation);
      _lastDrivingTickUs = _controllerClock.elapsedMicroseconds;
    });
    _hapticClick();
    _sendState(force: true);
  }

  void _centerSteering() {
    setState(() => _steering.calibrate(_wheelOrientation));
    _hapticClick();
    _sendState();
  }

  void _toggleDrivingPause() {
    final paused = !_steering.state.paused;
    setState(() {
      _releaseInputs();
      _surfaceEpoch++;
      _steering.setPaused(paused);
    });
    if (paused) {
      _sendState();
    } else {
      _pulseDrivingAction();
    }
  }

  void _pulseDrivingAction({bool reset = false}) {
    _drivingActionTimer?.cancel();
    setState(() {
      _btnAActive = !reset;
      _btnXActive = reset;
    });
    _sendState();
    _drivingActionTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() {
        _btnAActive = false;
        _btnXActive = false;
      });
      _sendState();
    });
  }

  void _selectDrivingMenu() {
    setState(() {
      _releaseInputs();
      // Drop old pedal gestures, including a pending tap-down, before making
      // the controller ready. Choosing a menu must never restore held throttle.
      _surfaceEpoch++;
      _steering.setPaused(false);
    });
    _pulseDrivingAction();
  }

  void _updateLaserSlide(double nx, double ny) {
    setState(() {
      _laserSlideNormX = nx.clamp(-1.0, 1.0);
      _laserSlideNormY = ny.clamp(-1.0, 1.0);
      _laserStickX = _laserSlideNormX;
      _laserStickY = -_laserSlideNormY;

      // 180° frontal hemisphere: horizontal yaw clamped to [-pi/2, +pi/2] (-90° to +90°)
      _laserYaw = (_laserSlideNormX * (math.pi / 2)).clamp(
        -math.pi / 2,
        math.pi / 2,
      );
      // Vertical pitch clamped to [-1.25, 1.25] (~ -71° to +71°)
      _laserPitch = (-_laserSlideNormY * 1.25).clamp(-1.25, 1.25);

      // In VR coordinate system, positive elevation requires positive pitch around X,
      // and rightward heading requires negative yaw around Y.
      final qYaw = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), -_laserYaw);
      final qPitch = vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), _laserPitch);
      _orientation = (qYaw * qPitch).normalized();
      _angularVelocity.setZero();
    });
    _sendState();
  }

  void _pulseLaserClick() {
    _laserClickPulseTimer?.cancel();
    _laserSteadyDwell.reset();
    setState(() {
      _triggerActive = true;
      _btnAActive = true;
    });
    _hapticMedium();
    _sendState(force: true);
    _laserClickPulseTimer = Timer(
      const Duration(
        milliseconds: VrJoystickConstants.laserClickPulseDurationMs,
      ),
      () {
        if (!mounted) return;
        setState(() {
          _triggerActive = false;
          _btnAActive = false;
        });
        _sendState(force: true);
      },
    );
  }

  void _nudgeLaserAimByPan(Offset delta) {
    if (_activeMode != RemoteControllerMode.laser) return;
    _laserSteadyDwell.reset();
    final nx = (_laserStickX + delta.dx / 180.0).clamp(-1.0, 1.0);
    final ny = (_laserStickY - delta.dy / 140.0).clamp(-1.0, 1.0);
    _updateLaserSlide(nx, -ny);
  }

  void _openWordsphereSearchSheet() {
    _laserSteadyDwell.reset();
    setState(() {
      _wordsphereSearchSheetVisible = true;
    });
    _hapticMedium();
    _sendState(force: true);
  }

  void _closeWordsphereSearchSheet() {
    setState(() {
      _wordsphereSearchSheetVisible = false;
    });
    _hapticLight();
    _sendState(force: true);
  }

  void _onWordsphereQueryChanged(String query) {
    final trimmed = query.trim();
    setState(() {
      _activeSearchQuery = trimmed.isEmpty
          ? null
          : trimmed.substring(
              0,
              math.min(
                trimmed.length,
                VrJoystickConstants.maxSearchQueryLength,
              ),
            );
    });
    _sendState(force: true);
  }

  void _submitWordsphereSearch(String rawQuery) {
    final trimmed = rawQuery.trim();
    if (trimmed.isEmpty) {
      _closeWordsphereSearchSheet();
      return;
    }
    final normalized = trimmed.substring(
      0,
      math.min(trimmed.length, VrJoystickConstants.maxSearchQueryLength),
    );
    _searchSubmitPulseTimer?.cancel();
    setState(() {
      _activeSearchQuery = normalized;
      _searchSubmittedPulse = true;
      _wordsphereSearchSheetVisible = false;
    });
    _hapticDoublePulse();
    _sendState(force: true);
    _searchSubmitPulseTimer = Timer(
      const Duration(
        milliseconds: VrJoystickConstants.laserClickPulseDurationMs,
      ),
      () {
        if (!mounted) return;
        setState(() {
          _searchSubmittedPulse = false;
        });
        _sendState(force: true);
      },
    );
  }

  String get _transportLabel {
    if (_usesExternalLink) {
      return _externalConnectionLabel;
    }
    if (!widget.allowWifiConnection) {
      return VrJoystickTranslationConstants.transportBluetoothLe;
    }
    if (_lastTarget != null) {
      return VrJoystickTranslationConstants.transportDirectSocket;
    }
    switch (widget.transportType) {
      case VrTransportType.bluetoothLe:
        return _useWifiOverride
            ? VrJoystickTranslationConstants.transportDirectSocket
            : VrJoystickTranslationConstants.transportBluetoothLePending;
      case VrTransportType.wifiDirect:
        return VrJoystickTranslationConstants.transportWifiDirectPending;
      case VrTransportType.localSocket:
        return VrJoystickTranslationConstants.transportDirectSocket;
    }
  }

  String get _externalConnectionLabel =>
      widget.connectionLabel?.trim().isNotEmpty == true
      ? widget.connectionLabel!.trim()
      : widget.transportType == VrTransportType.bluetoothLe ||
            !widget.allowWifiConnection
      ? VrJoystickTranslationConstants.transportBluetoothLe
      : VrJoystickTranslationConstants.transportExternalLink;

  static const _bluetoothPairingNotice =
      VrJoystickTranslationConstants.statusBluetoothPairingNotice;

  bool get _usesExternalLink =>
      widget.linkConnector != null &&
      (!widget.allowWifiConnection || !_useWifiOverride);

  bool get _showsBluetooth => !widget.allowWifiConnection || _usesExternalLink;

  bool get _hasConnectionTarget =>
      _usesExternalLink || widget.allowWifiConnection;

  String get _targetDescription => _showsBluetooth
      ? _externalConnectionLabel
      : '${_lastTarget?.host ?? widget.targetHost ?? _discoveredHost ?? VrJoystickTranslationConstants.statusUnpairedLabel}${VrJoystickConstants.colonSeparator}$_targetPort${VrJoystickConstants.spaceOpenParen}$_transportLabel${VrJoystickConstants.closeParen}';

  static Future<void> _closeLink(VrControllerLink link) async {
    try {
      await link.close();
    } catch (_) {
      // A failed transport teardown must not interfere with another session.
    }
  }

  bool get _canReconnect =>
      mounted &&
      _surfaceMounted &&
      _isForeground &&
      _reconnectEnabled &&
      !_isConnected &&
      !_isConnecting;

  void _scheduleReconnect({bool immediately = false}) {
    if (!_canReconnect || _reconnectTimer != null) return;
    // A visor can stay asleep/out of range longer than the initial backoff.
    // Keep trying at the capped interval while this controller is foreground;
    // explicit rejection, editing the target or leaving still cancels recovery.
    final delay = immediately
        ? Duration.zero
        : _reconnectDelays[_reconnectAttempt];
    if (!immediately && _reconnectAttempt < _reconnectDelays.length - 1) {
      _reconnectAttempt++;
    }
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_canReconnect) unawaited(_connect(automatic: true));
    });
  }

  void _stopAutomaticReconnect() {
    _reconnectEnabled = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _editConnectionTarget() {
    _stopAutomaticReconnect();
    if (_isConnecting) {
      _cancelPendingConnection();
      _isConnecting = false;
    }
  }

  static bool _isSessionExpired(Object error) =>
      (error is VrControllerConnectionException && error.isSessionExpired) ||
      (error is WebSocketException &&
          (error.httpStatusCode == HttpStatus.unauthorized ||
              error.httpStatusCode == HttpStatus.forbidden));

  static bool _canRetryConnection(Object error) {
    if (_isSessionExpired(error)) return false;
    if (error is VrControllerConnectionException) return error.canRetry;
    if (error is TimeoutException || error is SocketException) return true;
    if (error is WebSocketException) {
      final status = error.httpStatusCode;
      return status == null ||
          status == HttpStatus.requestTimeout ||
          status == HttpStatus.tooManyRequests ||
          status >= 500;
    }
    // Unknown provider failures may be permission/configuration errors. The
    // provider must classify them before we repeat a platform prompt.
    return false;
  }

  Future<void> _connect({bool automatic = false}) async {
    if (!mounted || !_surfaceMounted || !_isForeground || _isConnecting) {
      return;
    }
    if (automatic && !_canReconnect) return;
    if (!_hasConnectionTarget) {
      _stopAutomaticReconnect();
      setState(() => _status = _bluetoothPairingNotice);
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    VrControllerConnectionTarget? target;
    try {
      if (!_usesExternalLink) {
        target = VrControllerConnectionTarget.parse(
          _ipController.text,
          pairedHost: _lastTarget?.host ?? widget.targetHost,
          pairedPort: _lastTarget?.port ?? _targetPort,
          sessionToken: _lastTarget?.token ?? widget.sessionToken,
          transportType: _lastTarget == null
              ? (_useWifiOverride
                    ? VrTransportType.localSocket
                    : widget.transportType)
              : VrTransportType.localSocket,
        );
      }
    } on FormatException catch (error) {
      _stopAutomaticReconnect();
      setState(() => _status = error.message);
      return;
    } on UnsupportedError catch (error) {
      _stopAutomaticReconnect();
      setState(
        () => _status =
            error.message ?? VrJoystickTranslationConstants.transportPending,
      );
      return;
    }
    if (!automatic) _reconnectAttempt = 0;
    _reconnectEnabled = true;
    final generation = ++_connectionGeneration;
    _clearCast();
    _releaseInputs(send: true);
    final previous = _socket;
    _socket = null;
    _linkSubscription?.cancel();
    _linkSubscription = null;
    if (previous != null) unawaited(_closeLink(previous));
    setState(() {
      _isConnecting = true;
      _isConnected = false;
      _status = target == null
          ? '${VrJoystickTranslationConstants.statusConnectingPrefix}$_externalConnectionLabel${VrJoystickTranslationConstants.statusEllipsis}'
          : '${VrJoystickTranslationConstants.statusConnectingToVisorPrefix}${target.host}${VrJoystickConstants.colonSeparator}${target.port}${VrJoystickTranslationConstants.statusEllipsis}';
    });

    try {
      final socket = await _openLink(target?.webSocketUri, generation);
      if (!mounted || generation != _connectionGeneration) {
        unawaited(_closeLink(socket));
        return;
      }
      _socket = socket;
      _socketTarget = target;
      _socketGeneration = generation;
      _hostModeSession.reset();
      _effectivePassthroughRevision = -1;
      _hasEffectivePassthroughState = false;
      _pendingPassthroughMix = null;
      _lastHostMode = null;
      _hostActions = const {};
      _reconnectAttempt = 0;
      if (target != null) {
        _lastTarget = target;
        _targetPort = target.port;
      }
      _sequence = 0;
      _statePacer.reset();
      _releaseInputs();
      _surfaceEpoch++;
      if (_activeMode == RemoteControllerMode.driving) {
        _steering.setPaused(true);
      }
      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _status = target == null
            ? '${VrJoystickTranslationConstants.statusLinkedExternalPrefix}$_externalConnectionLabel'
            : widget.isChildRole
            ? '${VrJoystickTranslationConstants.statusLinkedParentVisorPrefix}${target.host}${VrJoystickConstants.colonSeparator}${target.port}${VrJoystickConstants.closeParen}'
            : VrJoystickTranslationConstants.statusConnectedToVisor;
      });
      _notifyPassthroughSettings();
      if (target != null) unawaited(_rememberHost(target.host));
      _hapticDoublePulse();
      _linkSubscription = socket.messages.listen(
        (data) => _onHostMessage(data, socket, generation),
        onDone: () => _onDisconnected(socket),
        onError: (Object error) => _onDisconnected(socket, error: error),
        cancelOnError: true,
      );
      _sendState();
      _sendPublicTrackingMarker();
      // The callback is observational; a host storage failure must not tear
      // down the authenticated controller transport.
      if (_isConnected && identical(_socket, socket)) {
        _notifySessionCallback(() => widget.onConnected?.call(target));
      }
    } catch (e) {
      if (mounted && generation == _connectionGeneration) {
        _connectionGeneration++;
        final failedLink = _socket;
        _socket = null;
        _linkSubscription?.cancel();
        _linkSubscription = null;
        if (failedLink != null) unawaited(_closeLink(failedLink));
        final expired = _isSessionExpired(e);
        if (!_canRetryConnection(e)) _stopAutomaticReconnect();
        setState(() {
          _isConnected = false;
          _isConnecting = false;
          // Exceptions can contain the authenticated URL; don't echo secrets.
          _status = expired
              ? VrJoystickTranslationConstants.statusLinkExpired
              : _usesExternalLink
              ? '${VrJoystickTranslationConstants.statusExternalConnectFailedPrefix}$_externalConnectionLabel${VrJoystickTranslationConstants.statusExternalConnectFailedSuffix}'
              : VrJoystickTranslationConstants.statusWifiConnectFailed;
        });
        if (expired) {
          _notifySessionCallback(() => widget.onSessionExpired?.call(target));
        }
        _scheduleReconnect();
      }
    }
  }

  void _notifySessionCallback(VoidCallback? callback) {
    try {
      callback?.call();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          context: ErrorDescription(
            VrJoystickTranslationConstants.errorWhileUpdatingSavedSession,
          ),
        ),
      );
    }
  }

  void _clearCast({bool forgetOffer = true}) {
    _castGeneration++;
    if (forgetOffer) {
      _castOffer = null;
      _castAutoEnabled = true;
    }
    _castPreview.value = null;
  }

  bool _acceptCastOffer(Object? data) {
    if (data is! String || data.length > 2048) return false;
    Object? message;
    try {
      message = jsonDecode(data);
    } catch (_) {
      return false;
    }
    if (message is! Map<String, dynamic> ||
        message[VrJoystickConstants.fieldType] !=
            VrJoystickConstants.castPreviewMessageType) {
      return false;
    }
    if (!message.containsKey(VrJoystickConstants.fieldUrl)) return true;
    final raw = message[VrJoystickConstants.fieldUrl];
    if (raw != null && raw is! String) return true;
    final uri = raw is String ? VrCastSession.tryParse(raw)?.viewerUri : null;
    if (raw != null && uri == null) return true;
    if (uri != _castOffer) {
      _clearCast();
      _castOffer = uri;
      if (_isForeground && _castAutoEnabled) _castPreview.value = uri;
      if (mounted) setState(() {});
    }
    return true;
  }

  bool _acceptEffectivePassthroughState(Object? data) {
    if (data is! String || data.length > 1023) return false;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return false;
    }
    if (decoded is! Map<String, dynamic> ||
        decoded[VrJoystickConstants.fieldType] !=
            VrJoystickConstants.passthroughStateMessageType) {
      return false;
    }
    final revision = decoded[VrJoystickConstants.fieldRevision];
    final mix = decoded[VrJoystickConstants.fieldPassthroughMix];
    final enabled = decoded['cameraEnabled'];
    if (revision is! int ||
        revision < 0 ||
        revision > 0x7fffffff ||
        revision <= _effectivePassthroughRevision ||
        mix is! num ||
        !mix.isFinite ||
        mix < 0 ||
        mix > 1 ||
        enabled is! bool) {
      return true;
    }
    _effectivePassthroughRevision = revision;
    final effective = enabled ? mix.toDouble() : 0.0;
    setState(() {
      _hasEffectivePassthroughState = true;
      _reportedPassthroughMix = effective;
      if (_pendingPassthroughMix case final pending?) {
        if ((pending - effective).abs() < .005) _pendingPassthroughMix = null;
      }
      if (_pendingPassthroughMix == null) {
        _passthroughGesture.setPassthroughMix(effective);
      }
      _lastSentPassthroughMix = _passthroughGesture.passthroughMix;
      _lastPassthroughHapticBucket = (_passthroughGesture.passthroughMix * 4)
          .round();
    });
    _notifyPassthroughSettings();
    // Do not echo this observation as an input, command, ACK or haptic. Only
    // an explicit local slider/tap/gesture may request a camera change.
    return true;
  }

  Future<void> _openCast() async {
    if (!mounted || _castDialogOpen) return;
    final generation = _castGeneration;
    final input = TextEditingController();
    String? validation;
    Uri? selected;
    setState(() {
      _castDialogOpen = true;
      _releaseInputs(send: true);
      _surfaceEpoch++;
    });
    try {
      selected = await showDialog<Uri>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, update) => AlertDialog(
            title: const Text(VrJoystickTranslationConstants.castWifiTitle),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      VrJoystickTranslationConstants.castWifiDescription,
                    ),
                    if (_castOffer != null) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        key: const ValueKey(
                          VrJoystickConstants.keyCastUseOffer,
                        ),
                        onPressed: () => Navigator.of(ctx).pop(_castOffer),
                        icon: const Icon(Icons.cast_connected),
                        label: const Text(
                          VrJoystickTranslationConstants.castViewLinkedVisor,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey(VrJoystickConstants.keyCastManualUri),
                      controller: input,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText:
                            VrJoystickTranslationConstants.castPasteLinkLabel,
                        errorText: validation,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      VrJoystickTranslationConstants.castLowFpsNotice,
                      style: TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text(VrJoystickTranslationConstants.castCancel),
              ),
              TextButton(
                onPressed: () {
                  final session = VrCastSession.tryParse(input.text);
                  if (session == null) {
                    update(
                      () => validation =
                          VrJoystickTranslationConstants.castPasteFullLocalLink,
                    );
                    return;
                  }
                  Navigator.of(ctx).pop(session.viewerUri);
                },
                child: const Text(VrJoystickTranslationConstants.castViewLink),
              ),
            ],
          ),
        ),
      );
    } finally {
      // Dialog transitions can still use its controller for one frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => input.dispose());
      if (mounted) setState(() => _castDialogOpen = false);
    }
    if (!mounted ||
        !_isForeground ||
        generation != _castGeneration ||
        selected == null) {
      return;
    }
    _castAutoEnabled = true;
    _castPreview.value = selected;
  }

  Future<void> _projectCast(Uri uri) async {
    if (_castDialogOpen || !mounted) return;
    setState(() {
      _castDialogOpen = true;
      _releaseInputs(send: true);
      _surfaceEpoch++;
    });
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text(VrJoystickTranslationConstants.castProjectTitle),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    VrJoystickTranslationConstants.castProjectDescription,
                  ),
                  const SizedBox(height: 12),
                  QrImageView(
                    data: uri.toString(),
                    size: 168,
                    backgroundColor: Colors.white,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    VrJoystickTranslationConstants.castProjectHdmiHint,
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: uri.toString()));
              },
              icon: const Icon(Icons.copy),
              label: const Text(VrJoystickTranslationConstants.castCopyLink),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                VrJoystickTranslationConstants.castBackToController,
              ),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _castDialogOpen = false);
    }
  }

  void _onHostMessage(Object? data, VrControllerLink socket, int generation) {
    if (!mounted ||
        !_surfaceMounted ||
        generation != _socketGeneration ||
        !identical(_socket, socket)) {
      return;
    }
    if (_acceptEffectivePassthroughState(data) || _acceptCastOffer(data)) {
      return;
    }
    final hadHostRequest = _hostModeSession.revision != null;
    final previousHostMode = _lastHostMode;
    final request = _hostModeSession.accept(data);
    if (request == null) return;
    _lastHostMode = request.mode;
    if (hadHostRequest &&
        previousHostMode == request.mode &&
        request.mode == _activeMode &&
        request.horizontalLook == _horizontalLookEnabled) {
      // An acknowledged host mode gets captions without dropping held inputs.
      setState(() => _hostActions = request.actions);
      _sendState(force: true);
      return;
    }
    final preservePause = request.mode == _activeMode && _steering.state.paused;
    // Mode requests are scoped to this authenticated socket. Send no packet
    // between accepting its revision and installing a completely neutral mode.
    setState(() {
      _hostActions = request.actions;
      _releaseInputs();
      _surfaceEpoch++;
      _activeMode = request.mode;
      _horizontalLookEnabled = request.horizontalLook;
      // A genuinely new experience opens ready, with all controls released.
      // A fresh socket or manually matching layout still needs a neutral ACK.
      // Matching layouts preserve a prior pause, including after reconnect.
      _steering.setPaused(
        request.mode == RemoteControllerMode.driving &&
            (!_isForeground || preservePause),
      );
      _lastDrivingTickUs = _controllerClock.elapsedMicroseconds;
      _status = request.mode == RemoteControllerMode.driving
          ? VrJoystickTranslationConstants.statusDrivingReady
          : request.mode == RemoteControllerMode.nes
          ? VrJoystickTranslationConstants.statusNesReady
          : VrJoystickTranslationConstants.statusJoystickReady;
    });
    // Even while backgrounded the host must receive a neutral mode ACK.
    _sendState(force: true);
  }

  Future<VrControllerLink> _openLink(Uri? uri, int generation) {
    final completion = Completer<VrControllerLink>();
    _pendingConnection = completion;
    _connectionTimeout = Timer(widget.connectionTimeout, () {
      if (!completion.isCompleted) {
        _pendingConnection = null;
        _connectionTimeout = null;
        completion.completeError(
          TimeoutException(
            VrJoystickTranslationConstants.errorConnectionTimedOut,
          ),
        );
      }
    });
    unawaited(
      Future<VrControllerLink>.sync(() {
        final connector = _usesExternalLink ? widget.linkConnector : null;
        if (connector != null) return connector();
        if (!widget.allowWifiConnection) {
          throw UnsupportedError(_bluetoothPairingNotice);
        }
        return WebSocket.connect(
          uri!.toString(),
        ).then(VrWebSocketControllerLink.new);
      }).then<void>(
        (socket) {
          // Dart cannot cancel the underlying upgrade: close any late arrival.
          if (!mounted ||
              generation != _connectionGeneration ||
              completion.isCompleted) {
            unawaited(_closeLink(socket));
            return;
          }
          _connectionTimeout?.cancel();
          _connectionTimeout = null;
          _pendingConnection = null;
          if (!socket.isOpen) {
            unawaited(_closeLink(socket));
            completion.completeError(
              const VrControllerConnectionException(
                VrJoystickTranslationConstants.errorControllerLinkClosed,
              ),
            );
            return;
          }
          completion.complete(socket);
        },
        onError: (Object error, StackTrace stack) {
          if (completion.isCompleted) return;
          _connectionTimeout?.cancel();
          _connectionTimeout = null;
          _pendingConnection = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return completion.future;
  }

  void _cancelPendingConnection() {
    _connectionGeneration++;
    _connectionTimeout?.cancel();
    _connectionTimeout = null;
    final completion = _pendingConnection;
    _pendingConnection = null;
    if (completion != null && !completion.isCompleted) {
      completion.completeError(
        StateError(VrJoystickTranslationConstants.errorConnectionCancelled),
      );
    }
  }

  Future<void> _rememberHost(String host) async {
    if (!widget.allowWifiConnection) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!widget.allowWifiConnection) return;
      await prefs.setString(VrJoystickConstants.prefKeyHostIp, host);
    } catch (_) {}
  }

  void _onDisconnected(VrControllerLink socket, {Object? error}) {
    if (!mounted || !_surfaceMounted || !identical(_socket, socket)) return;
    _connectionHapticTimer?.cancel();
    _connectionHapticTimer = null;
    final target = _socketTarget;
    final expired = error != null && _isSessionExpired(error);
    final permanent =
        (error is VrControllerConnectionException && !error.canRetry) ||
        (socket is VrWebSocketControllerLink &&
            socket.socket.closeCode == WebSocketStatus.policyViolation);
    if (expired || permanent) _stopAutomaticReconnect();
    _socket = null;
    _socketTarget = null;
    _linkSubscription?.cancel();
    _linkSubscription = null;
    unawaited(_closeLink(socket));
    _socketGeneration = 0;
    _hostModeSession.reset();
    _lastHostMode = null;
    _hostActions = const {};
    _clearCast();
    _statePacer.reset();
    if (_activeMode == RemoteControllerMode.driving) {
      _steering.setPaused(true);
    }
    _releaseInputs();
    setState(() {
      _surfaceEpoch++;
      _isConnected = false;
      _hasEffectivePassthroughState = false;
      _pendingPassthroughMix = null;
      _isConnecting = false;
      _status = expired
          ? VrJoystickTranslationConstants.statusLinkExpired
          : !_reconnectEnabled
          ? VrJoystickTranslationConstants.statusDisconnectedManual
          : VrJoystickTranslationConstants.statusDisconnectedReconnecting;
    });
    _notifyPassthroughSettings();
    if (expired) {
      _notifySessionCallback(() => widget.onSessionExpired?.call(target));
    }
    _scheduleReconnect();
  }

  void _releaseInputs({bool send = false}) {
    _moveResponse.reset();
    _lookResponse.reset();
    _motionLook.reset();
    _lookStickHeld = false;
    _lastDrivingTickUs = _controllerClock.elapsedMicroseconds;
    _drivingActionTimer?.cancel();
    _drivingActionTimer = null;
    _laserClickPulseTimer?.cancel();
    _laserClickPulseTimer = null;
    _searchSubmitPulseTimer?.cancel();
    _searchSubmitPulseTimer = null;
    _recenterResetTimer?.cancel();
    _recenterResetTimer = null;
    _stickClickPulseTimer?.cancel();
    _stickClickPulseTimer = null;
    _leftAutoWalkController.reset();
    _rightStickClickDetector.reset();
    _flickStickController.reset();
    _inertialTrackballController.reset();
    _rawLookX = 0;
    _rawLookY = 0;
    _stickX = 0;
    _stickY = 0;
    _moveAtEdge = false;
    _lookX = 0;
    _lookY = 0;
    _laserStickX = 0;
    _laserStickY = 0;
    _isLaserSlideActive = false;
    _laserSlidePointer = null;
    _laserSlideNormX = 0;
    _laserSlideNormY = 0;
    _recenterTriggered = false;
    _triggerActive = false;
    _actionActive = false;
    _btnAActive = false;
    _btnBActive = false;
    _btnXActive = false;
    _btnYActive = false;
    _btnLActive = false;
    _btnRActive = false;
    _btnGripActive = false;
    _stickClickActive = false;
    _searchSubmittedPulse = false;
    _passthroughGesture.cancelGesture();
    _exclusiveControlPointers.clear();
    _throttlePedalHeld = false;
    _brakePedalHeld = false;
    _gripHoldTimer?.cancel();
    _gripHoldTimer = null;
    _angularVelocity.setZero();
    _lastGyroTime = null;
    _steering.release();
    if (send) _sendState(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _shakeDetector.reset();
    _isForeground = state == AppLifecycleState.resumed;
    if (!_isForeground) {
      _clearCast(forgetOffer: false);
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _cancelPendingConnection();
      setState(() {
        if (_activeMode == RemoteControllerMode.driving) {
          _steering.setPaused(true);
        }
        _releaseInputs(send: true);
        // Discard held thumbstick/pad gestures across suspension as well.
        _surfaceEpoch++;
        _isConnecting = false;
      });
    } else {
      _lastGyroTime = null;
      if (_castAutoEnabled) _castPreview.value = _castOffer;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      final socket = _socket;
      if (socket != null && !socket.isOpen) _onDisconnected(socket);
      _reconnectAttempt = 0;
      // A surviving link receives neutral state immediately. A suspended or
      // lost link gets one fresh retry cycle using the same in-memory pairing.
      _sendState(force: true);
      _scheduleReconnect(immediately: true);
    }
  }

  void _notifyPassthroughSettings() {
    if (mounted && _surfaceMounted) {
      _passthroughSettingsRevision.value++;
    }
  }

  bool get _canControlPassthrough =>
      _isConnected &&
      (_socket?.isOpen ?? false) &&
      _hasEffectivePassthroughState;

  String get _passthroughStatus => !_isConnected
      ? 'Sin conexión · reconectar'
      : !_hasEffectivePassthroughState
      ? 'Sincronizando visor'
      : _pendingPassthroughMix != null
      ? 'Esperando visor'
      : '${(_reportedPassthroughMix * 100).round()}${VrJoystickTranslationConstants.passthroughPercentSuffix}';

  void _setBreakthroughMix(double mix) {
    if (!mix.isFinite || !_canControlPassthrough) return;
    final clamped = mix.clamp(0.0, 1.0);
    setState(() {
      _passthroughGesture.setPassthroughMix(clamped);
    });
    final bucket = (clamped * 4).round();
    if (bucket != _lastPassthroughHapticBucket) {
      _lastPassthroughHapticBucket = bucket;
      _hapticClick();
    }
    _sendPassthroughControlMessage(force: true, userCommand: true);
    _sendState();
  }

  Widget _exclusivePassthroughControl(Widget child) => Listener(
    onPointerDown: (event) => _exclusiveControlPointers.add(event.pointer),
    child: child,
  );

  void _toggleBreakthroughMix() {
    if (!_canControlPassthrough) return;
    final current = _passthroughGesture.passthroughMix;
    final next = current < 0.25 ? 0.65 : (current < 0.85 ? 1.0 : 0.0);
    setState(() {
      _passthroughGesture.setPassthroughMix(next);
    });
    _hapticMedium();
    _sendPassthroughControlMessage(force: true, userCommand: true);
    _sendState(force: true);
  }

  void _toggleSpatialHud([bool? value]) {
    if (!_canControlPassthrough) return;
    final next = value ?? !_spatialHudVisible;
    setState(() {
      _spatialHudVisible = next;
    });
    _hapticClick();
    _sendPassthroughControlMessage(force: true);
    _sendState(force: true);
  }

  void _sendPassthroughControlMessage({
    bool force = false,
    bool userCommand = false,
  }) {
    final ws = _socket;
    if (ws == null || !ws.isOpen || !_isConnected) return;
    final mix = _passthroughGesture.passthroughMix;
    if (userCommand) {
      if (!_canControlPassthrough) return;
      _pendingPassthroughMix = (mix - _reportedPassthroughMix).abs() > .005
          ? mix
          : null;
      _notifyPassthroughSettings();
    }
    if (!force &&
        (mix - _lastSentPassthroughMix).abs() < 0.015 &&
        _spatialHudVisible == _lastSentSpatialHudVisible) {
      return;
    }
    _lastSentPassthroughMix = mix;
    _lastSentSpatialHudVisible = _spatialHudVisible;
    final controlPayload = jsonEncode({
      VrJoystickConstants.fieldType: VrJoystickConstants.passthroughControlType,
      if (userCommand) VrJoystickConstants.fieldPassthroughCommand: true,
      VrJoystickConstants.fieldPassthroughMix: mix,
      VrJoystickConstants.fieldPassthroughActive:
          _passthroughGesture.passthroughActive,
      VrJoystickConstants.fieldSpatialHudVisible: _spatialHudVisible,
    });
    try {
      ws.add(controlPayload);
    } catch (_) {
      _onDisconnected(ws);
    }
  }

  void _sendGesturePassthroughChange(double previousMix) {
    if ((_passthroughGesture.passthroughMix - previousMix).abs() > 0.000001) {
      _sendPassthroughControlMessage(force: true, userCommand: true);
    }
  }

  void _onVisionServiceUpdated() {
    if (!mounted || !_isForeground || !_isConnected) return;
    _sendVisionTelemetryMessageIfDue(_controllerClock.elapsedMicroseconds);
  }

  void _sendVisionTelemetryMessageIfDue(int nowUs) {
    final ws = _socket;
    if (ws == null || !ws.isOpen || !_isConnected || !_isForeground) return;
    final minIntervalUs = _showsBluetooth ? 1500000 : 500000;
    if (nowUs - _lastVisionTelemetryUs < minIntervalUs) return;
    final payloadMap = _visionService.buildVisionTelemetryPayload(
      includeMiniFrame: !_showsBluetooth,
    );
    if (payloadMap == null) return;
    _lastVisionTelemetryUs = nowUs;
    try {
      ws.add(jsonEncode(payloadMap));
    } catch (_) {
      _onDisconnected(ws);
    }
  }

  void _sendState({bool force = false}) {
    final ws = _socket;
    if (ws != null && ws.isOpen && _isConnected && (_isForeground || force)) {
      _sendPassthroughControlMessage();
      final driving = _steering.state;
      final isDriving = _activeMode == RemoteControllerMode.driving;
      final isLaserOverBle =
          _showsBluetooth && _activeMode == RemoteControllerMode.laser;
      final wireModeName = isLaserOverBle
          ? RemoteControllerMode.joystick.name
          : _activeMode.name;
      final measuredRangeMeters = _visionService.currentRangeMeters;
      final liveRangeMeters = measuredRangeMeters == null
          ? null
          : (measuredRangeMeters * 100.0).round() / 100.0;
      final state = <String, Object?>{
        VrJoystickConstants.fieldHostModeRevision: _hostModeSession.revision,
        VrJoystickConstants.fieldQx: _orientation.x,
        VrJoystickConstants.fieldQy: _orientation.y,
        VrJoystickConstants.fieldQz: _orientation.z,
        VrJoystickConstants.fieldQw: _orientation.w,
        VrJoystickConstants.fieldWx: _angularVelocity.x,
        VrJoystickConstants.fieldWy: _angularVelocity.y,
        VrJoystickConstants.fieldWz: _angularVelocity.z,
        VrJoystickConstants.fieldStickX: isDriving ? 0.0 : _stickX,
        VrJoystickConstants.fieldStickY: isDriving ? 0.0 : _stickY,
        VrJoystickConstants.fieldMoveAtEdge:
            _activeMode == RemoteControllerMode.joystick && _moveAtEdge,
        VrJoystickConstants.fieldTx: isDriving ? 0.0 : _stickX,
        VrJoystickConstants.fieldTy: isDriving ? 0.0 : _stickY,
        VrJoystickConstants.fieldLookX: isDriving ? 0.0 : _lookX,
        VrJoystickConstants.fieldLookY: isDriving ? 0.0 : _lookY,
        VrJoystickConstants.fieldTurn: isDriving ? 0.0 : _lookX,
        VrJoystickConstants.fieldTurnRate: isDriving ? 0.0 : _lookX,
        VrJoystickConstants.fieldPitchRate: isDriving ? 0.0 : _lookY,
        VrJoystickConstants.fieldLookPitch: isDriving ? 0.0 : _lookY,
        VrJoystickConstants.fieldLaserX: _laserStickX,
        VrJoystickConstants.fieldLaserY: _laserStickY,
        VrJoystickConstants.fieldLaserSlideActive:
            _isLaserSlideActive || isLaserOverBle,
        VrJoystickConstants.fieldAimX: _laserStickX,
        VrJoystickConstants.fieldAimY: _laserStickY,
        VrJoystickConstants.fieldRecenter: _recenterTriggered,
        VrJoystickConstants.fieldControllerVisible: _controllerVisible,
        VrJoystickConstants.fieldRangeMeters: liveRangeMeters,
        VrJoystickConstants.fieldTrigger:
            _triggerActive || (!isDriving && _btnRActive),
        VrJoystickConstants.fieldAction: _actionActive || _btnBActive,
        VrJoystickConstants.fieldBtnA: _btnAActive,
        VrJoystickConstants.fieldBtnB: _btnBActive,
        VrJoystickConstants.fieldBtnX: _btnXActive,
        VrJoystickConstants.fieldBtnY: _btnYActive,
        VrJoystickConstants.fieldBtnL: _btnLActive,
        VrJoystickConstants.fieldBtnR: _btnRActive,
        VrJoystickConstants.fieldBtnGrip: _btnGripActive,
        VrJoystickConstants.fieldStickClick: _stickClickActive,
        VrJoystickConstants.fieldMode: wireModeName,
        VrJoystickConstants.fieldSteering:
            _activeMode == RemoteControllerMode.driving
            ? driving.steering
            : 0.0,
        VrJoystickConstants.fieldDrivingTilt:
            _activeMode == RemoteControllerMode.driving
            ? _steering.drivingTiltAt(_controllerClock.elapsedMicroseconds)
            : 0.0,
        VrJoystickConstants.fieldThrottle:
            _activeMode == RemoteControllerMode.driving
            ? driving.throttle
            : 0.0,
        VrJoystickConstants.fieldBrake:
            _activeMode == RemoteControllerMode.driving ? driving.brake : 0.0,
        VrJoystickConstants.fieldDrivingPaused:
            _activeMode == RemoteControllerMode.driving && driving.paused,
        VrJoystickConstants.fieldMotionAvailable:
            _motionCapability == VrMotionCapability.available,
        VrJoystickConstants.fieldSearchQuery: _activeSearchQuery,
        VrJoystickConstants.fieldSearchSubmitted: _searchSubmittedPulse,
        VrJoystickConstants.fieldPassthroughMix:
            _passthroughGesture.passthroughMix,
        VrJoystickConstants.fieldPassthroughActive:
            _passthroughGesture.passthroughActive,
        VrJoystickConstants.fieldSpatialHudVisible: _spatialHudVisible,
      };
      if (!_statePacer.shouldSend(
        state,
        nowUs: _controllerClock.elapsedMicroseconds,
        bluetooth:
            widget.transportType == VrTransportType.bluetoothLe &&
            !_useWifiOverride,
        force: force,
      )) {
        return;
      }
      final payload = jsonEncode({
        ...state,
        VrJoystickConstants.fieldSequence: _sequence++,
        VrJoystickConstants.fieldTimestampUs:
            DateTime.now().microsecondsSinceEpoch,
      });

      try {
        ws.add(payload);
      } catch (_) {
        _onDisconnected(ws);
      }
    }
  }

  void _recenterController() {
    _laserSteadyDwell.reset();
    setState(() {
      _orientation = vm.Quaternion.identity();
      _angularVelocity.setZero();
      _laserYaw = 0.0;
      _laserPitch = 0.0;
      _laserStickX = 0.0;
      _laserStickY = 0.0;
      _laserSlideNormX = 0.0;
      _laserSlideNormY = 0.0;
      _lastGyroTime = null;
      _steering.calibrate(_wheelOrientation);
      _recenterTriggered = true;
    });
    _hapticMedium();
    _sendState(force: true);
    _recenterResetTimer?.cancel();
    _recenterResetTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() {
          _recenterTriggered = false;
        });
        _sendState();
      }
    });
  }

  @override
  void deactivate() {
    // Descendant gesture cancellation happens before this State.dispose, when
    // mounted alone cannot distinguish a closing controller from a live one.
    _surfaceMounted = false;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _surfaceMounted = true;
  }

  bool _acceptsSurfaceInput(int epoch) =>
      mounted &&
      _surfaceMounted &&
      _isForeground &&
      !_settingsOpen &&
      !_castDialogOpen &&
      epoch == _surfaceEpoch;

  @override
  void dispose() {
    _connectionHapticTimer?.cancel();
    _connectionHapticTimer = null;
    _surfaceMounted = false;
    _passthroughSettingsRevision.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _stopAutomaticReconnect();
    _cancelPendingConnection();
    _releaseInputs(send: true);
    _isForeground = false;
    _clearCast();
    _castPreview.dispose();
    _udpListener?.close();
    _gyroSub?.cancel();
    _accelSub?.cancel();
    _streamTimer?.cancel();
    _recenterResetTimer?.cancel();
    _laserClickPulseTimer?.cancel();
    _searchSubmitPulseTimer?.cancel();
    _gripHoldTimer?.cancel();
    _stickClickPulseTimer?.cancel();
    _visionService.removeListener(_onVisionServiceUpdated);
    _visionService.dispose();
    final socket = _socket;
    _socket = null;
    _linkSubscription?.cancel();
    _linkSubscription = null;
    if (socket != null) {
      Zone.root.run(() {
        unawaited(_closeLink(socket));
      });
    }
    _wordsphereController.dispose();
    _wordsphereTextController.dispose();
    _ipController.dispose();
    // The next/current route owns orientation. During replacement this dispose
    // runs after that route mounted and must not overwrite its portrait lock.
    super.dispose();
  }

  void _showIpConfigDialog() => _openSettings();

  void _openSettings() {
    if (_settingsOpen) return;
    setState(() {
      _settingsOpen = true;
      _releaseInputs(send: true);
      _surfaceEpoch++;
    });
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101528),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF00E5FF), width: 1.5),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return SafeArea(
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.90,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        key: const ValueKey(
                          VrJoystickConstants.keySettingsCastPreview,
                        ),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) _openCast();
                          });
                        },
                        icon: const Icon(Icons.cast),
                        label: const Text(
                          VrJoystickTranslationConstants.castWifiTitle,
                        ),
                      ),
                      // Header
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.tune_rounded,
                                color: Color(0xFF00E5FF),
                                size: 22,
                              ),
                              SizedBox(width: 8),
                              Text(
                                VrJoystickTranslationConstants.settingsTitle,
                                style: TextStyle(
                                  color: Color(0xFF00E5FF),
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white70,
                            ),
                            onPressed: () => Navigator.of(ctx).pop(),
                          ),
                        ],
                      ),
                      const Divider(color: Color(0xFF00E5FF), thickness: 0.5),
                      Text(
                        '${VrJoystickTranslationConstants.settingsVisorPrefix}$_targetDescription',
                        key: const ValueKey(
                          VrJoystickConstants.keyControllerPairingTarget,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 6),

                      // Section 1: Modo del Mando
                      const Text(
                        VrJoystickTranslationConstants
                            .settingsControlModeSection,
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildSettingsModeCard(
                        title: VrJoystickTranslationConstants
                            .settingsDualJoystickTitle,
                        subtitle: VrJoystickTranslationConstants
                            .settingsDualJoystickSubtitle,
                        icon: Icons.gamepad_rounded,
                        isSelected:
                            _activeMode == RemoteControllerMode.joystick,
                        onTap: () {
                          _selectMode(RemoteControllerMode.joystick);
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(height: 8),
                      _buildSettingsModeCard(
                        title: VrJoystickTranslationConstants.laserOneHandBadge,
                        subtitle: VrJoystickTranslationConstants
                            .statusLaserOneHandReady,
                        icon: Icons.bolt_rounded,
                        isSelected: _activeMode == RemoteControllerMode.laser,
                        onTap: () {
                          _selectMode(RemoteControllerMode.laser);
                          setModalState(() {});
                          Navigator.of(ctx).pop();
                        },
                      ),
                      const SizedBox(height: 8),
                      _buildSettingsModeCard(
                        title:
                            VrJoystickTranslationConstants.settingsDrivingTitle,
                        subtitle: VrJoystickTranslationConstants
                            .settingsDrivingSubtitle,
                        icon: Icons.sports_motorsports_rounded,
                        isSelected: _activeMode == RemoteControllerMode.driving,
                        onTap: () {
                          _selectMode(RemoteControllerMode.driving);
                          setModalState(() {});
                          Navigator.of(ctx).pop();
                        },
                      ),
                      const SizedBox(height: 12),

                      // Section 2: Conexión con Visor Padre
                      const Text(
                        VrJoystickTranslationConstants
                            .settingsParentConnectionSection,
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF080816),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.allowWifiConnection &&
                                widget.linkConnector != null) ...[
                              SegmentedButton<bool>(
                                key: const ValueKey(
                                  VrJoystickConstants
                                      .keyControllerTransportSelector,
                                ),
                                segments: const [
                                  ButtonSegment(
                                    value: false,
                                    icon: Icon(
                                      Icons.bluetooth_rounded,
                                      size: 16,
                                    ),
                                    label: Text(
                                      VrJoystickTranslationConstants
                                          .transportBluetoothLe,
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  ButtonSegment(
                                    value: true,
                                    icon: Icon(Icons.wifi_rounded, size: 16),
                                    label: Text(
                                      VrJoystickTranslationConstants
                                          .transportWifiLocal,
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                                selected: {_useWifiOverride},
                                onSelectionChanged: (val) {
                                  if (!widget.allowWifiConnection) return;
                                  final next = val.single;
                                  _editConnectionTarget();
                                  setModalState(() => _useWifiOverride = next);
                                  setState(() => _useWifiOverride = next);
                                },
                              ),
                              const SizedBox(height: 8),
                            ],
                            Row(
                              children: [
                                Expanded(
                                  child: _showsBluetooth
                                      ? Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _externalConnectionLabel,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              _usesExternalLink
                                                  ? VrJoystickTranslationConstants
                                                        .settingsDirectBleSubtitle
                                                  : _bluetoothPairingNotice,
                                              style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 10,
                                              ),
                                            ),
                                          ],
                                        )
                                      : TextField(
                                          controller: _ipController,
                                          onChanged: (_) {
                                            _editConnectionTarget();
                                            setState(
                                              () => _targetEdited = true,
                                            );
                                          },
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                          ),
                                          decoration: InputDecoration(
                                            isDense: true,
                                            filled: true,
                                            fillColor: const Color(0xFF101528),
                                            hintText:
                                                VrJoystickTranslationConstants
                                                    .settingsIpHint,
                                            hintStyle: const TextStyle(
                                              color: Colors.white30,
                                              fontSize: 11,
                                            ),
                                            border: OutlineInputBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              borderSide: const BorderSide(
                                                color: Color(0xFF00E5FF),
                                              ),
                                            ),
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton(
                                  onPressed:
                                      _isConnecting || !_hasConnectionTarget
                                      ? null
                                      : () {
                                          Navigator.of(ctx).pop();
                                          _connect();
                                        },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _isConnected
                                        ? const Color(0xFF10B981)
                                        : const Color(0xFF00E5FF),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                  ),
                                  child: Text(
                                    _isConnected
                                        ? VrJoystickTranslationConstants
                                              .buttonReconnect
                                        : VrJoystickTranslationConstants
                                              .buttonConnect,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '${VrJoystickTranslationConstants.settingsStatusPrefix}$_status${VrJoystickTranslationConstants.settingsTransportMiddle}$_transportLabel${VrJoystickTranslationConstants.settingsRoleMiddle}${widget.isChildRole ? VrJoystickTranslationConstants.roleChildDirect : VrJoystickTranslationConstants.roleStandalone}',
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 9.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Section 3: Gestos & Recentrado
                      const Text(
                        VrJoystickTranslationConstants.settingsGesturesSection,
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (_activeMode == RemoteControllerMode.joystick)
                        SwitchListTile(
                          key: const ValueKey(
                            VrJoystickConstants.keyControllerMotionLookToggle,
                          ),
                          contentPadding: EdgeInsets.zero,
                          value: _motionLookEnabled,
                          activeThumbColor: const Color(0xFFFF9100),
                          title: const Text(
                            VrJoystickTranslationConstants
                                .settingsMotionLookTitle,
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                          subtitle: const Text(
                            VrJoystickTranslationConstants
                                .settingsMotionLookSubtitle,
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 10,
                            ),
                          ),
                          onChanged: (enabled) {
                            setState(() {
                              _motionLookEnabled = enabled;
                              _motionLook.reset();
                              _updateJoystick();
                            });
                            unawaited(_persistMotionLook(enabled));
                            _sendState(force: true);
                            setModalState(() {});
                          },
                        ),
                      SwitchListTile(
                        key: const ValueKey(
                          VrJoystickConstants.keyControllerVisibilityToggle,
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: _controllerVisible,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsShowInVisorTitle,
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsShowInVisorSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          _setControllerVisible(val);
                          setModalState(() {});
                        },
                      ),
                      SwitchListTile(
                        key: const ValueKey(
                          VrJoystickConstants.keyControllerShakeToggle,
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: _shakeToToggleEnabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsShakeToggleTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsShakeToggleSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          setState(() => _shakeToToggleEnabled = val);
                          _shakeDetector.reset();
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _hapticsEnabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          VrJoystickTranslationConstants.settingsHapticsTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsHapticsSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          setState(() => _hapticsEnabled = val);
                          setModalState(() {});
                          _persistHaptics(val);
                          if (val) {
                            _hapticLight();
                          }
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _spatialHudVisible,
                        activeThumbColor: const Color(0xFF10B981),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsSpatialHudTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsSpatialHudSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          _toggleSpatialHud(val);
                          setModalState(() {});
                        },
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey(
                          'controller-public-tracking-marker',
                        ),
                        onPressed: _openPublicTrackingMarker,
                        icon: const Icon(Icons.qr_code_2, size: 16),
                        label: const Text('Marcador de calibración'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF7DD3FC),
                        ),
                      ),
                      ListenableBuilder(
                        listenable: _visionService,
                        builder: (context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SwitchListTile(
                              key: const ValueKey(
                                'controller-auxiliary-camera',
                              ),
                              contentPadding: EdgeInsets.zero,
                              value: _visionService.enableHardwareCameraStream,
                              activeThumbColor: const Color(0xFF10B981),
                              title: const Text(
                                'Cámara auxiliar',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              subtitle: const Text(
                                'Usa una lente de este mando. '
                                'Permanece activa aunque ocultes el HUD; la cámara del visor es independiente.',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                ),
                              ),
                              onChanged: _cameraSettingsBusy
                                  ? null
                                  : (enabled) async {
                                      setModalState(
                                        () => _cameraSettingsBusy = true,
                                      );
                                      _visionService
                                              .enableHardwareCameraStream =
                                          enabled;
                                      try {
                                        if (enabled) {
                                          await _visionService.start();
                                        } else {
                                          await _visionService.stop();
                                        }
                                      } finally {
                                        if (ctx.mounted) {
                                          setModalState(
                                            () => _cameraSettingsBusy = false,
                                          );
                                        } else {
                                          _cameraSettingsBusy = false;
                                        }
                                      }
                                    },
                            ),
                            if (_visionService.enableHardwareCameraStream) ...[
                              SwitchListTile(
                                key: const ValueKey(
                                  'controller-body-detection',
                                ),
                                contentPadding: EdgeInsets.zero,
                                value: _visionService.bodyDetectionEnabled,
                                activeThumbColor: const Color(0xFF10B981),
                                title: const Text(
                                  'Detección corporal',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                subtitle: const Text(
                                  'Modelo local de 33 puntos, una persona. Usa resolución media '
                                  'y hasta 2 análisis/s con presupuesto adaptativo sobre esta misma cámara. No mide distancia.',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 10,
                                  ),
                                ),
                                onChanged: _cameraSettingsBusy
                                    ? null
                                    : (enabled) async {
                                        setModalState(
                                          () => _cameraSettingsBusy = true,
                                        );
                                        try {
                                          await _visionService
                                              .setBodyDetectionEnabled(enabled);
                                        } finally {
                                          if (ctx.mounted) {
                                            setModalState(
                                              () => _cameraSettingsBusy = false,
                                            );
                                          } else {
                                            _cameraSettingsBusy = false;
                                          }
                                        }
                                      },
                              ),
                              if (_visionService.bodyDetectionEnabled)
                                _buildBodyInferenceDiagnostic(),
                              DropdownButton<String>(
                                key: const ValueKey(
                                  'controller-auxiliary-lens',
                                ),
                                isExpanded: true,
                                dropdownColor: const Color(0xFF101528),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                                value: _visionService.autoMultiplexLenses
                                    ? 'auto'
                                    : _visionService.activeRole,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'rear',
                                    child: Text('Lente trasera · estable'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'front',
                                    child: Text('Lente frontal · estable'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'auto',
                                    child: Text(
                                      'Auto · alterna lentes; no simultáneas',
                                    ),
                                  ),
                                ],
                                onChanged: _cameraSettingsBusy
                                    ? null
                                    : (mode) async {
                                        if (mode == null) return;
                                        setModalState(
                                          () => _cameraSettingsBusy = true,
                                        );
                                        try {
                                          await _visionService
                                              .setCameraLensMode(mode);
                                        } finally {
                                          if (ctx.mounted) {
                                            setModalState(
                                              () => _cameraSettingsBusy = false,
                                            );
                                          } else {
                                            _cameraSettingsBusy = false;
                                          }
                                        }
                                      },
                              ),
                              Text(
                                _cameraSettingsBusy
                                    ? 'Preparando cámara…'
                                    : _visionService.isCameraStreaming
                                    ? 'Activa · ${_visionService.cameraFramesProcessed} analizados · '
                                          '${_visionService.cameraFramesDropped} descartados · '
                                          'análisis ${(_visionService.lastCameraProcessingMicroseconds / 1000).toStringAsFixed(2)} ms'
                                    : _visionService.lastCameraError != null
                                    ? 'Cámara no disponible: ${_visionService.lastCameraError}'
                                    : 'Sin captura. Comprueba el permiso de cámara.',
                                key: const ValueKey(
                                  'controller-camera-performance',
                                ),
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                ),
                              ),
                              SwitchListTile(
                                key: const ValueKey(
                                  'controller-auxiliary-preview-toggle',
                                ),
                                contentPadding: EdgeInsets.zero,
                                value: _showAuxiliaryCameraPreview,
                                activeThumbColor: const Color(0xFF10B981),
                                title: const Text(
                                  'Ver cámara auxiliar',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                subtitle: const Text(
                                  'Vista local para orientar la lente seleccionada, '
                                  'compartiendo su captura activa.',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 10,
                                  ),
                                ),
                                onChanged: (value) => setModalState(
                                  () => _showAuxiliaryCameraPreview = value,
                                ),
                              ),
                              if (_showAuxiliaryCameraPreview)
                                _buildAuxiliaryCameraPreview(),
                            ],
                            SwitchListTile(
                              key: const ValueKey(
                                'controller-experimental-sonar',
                              ),
                              contentPadding: EdgeInsets.zero,
                              value: _visionService.enableUltrasonicRanging,
                              activeThumbColor: const Color(0xFFFF9100),
                              title: const Text(
                                'Sondeo acústico experimental',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              subtitle: Text(
                                _visionService.ultrasonicUnavailable
                                    ? 'Sin medición calibrada disponible. Desactiva y activa para reintentar.'
                                    : 'Usa micrófono y altavoz. Sólo informa distancia con una medición calibrada; '
                                          'no es sensado por Wi-Fi o Bluetooth.',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                ),
                              ),
                              onChanged: (enabled) {
                                _visionService.enableUltrasonicRanging =
                                    enabled;
                                setModalState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                      SwitchListTile(
                        key: const ValueKey(
                          VrJoystickConstants.keyControllerDynamicOriginToggle,
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: _dynamicTouchOriginEnabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsDynamicOriginTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsDynamicOriginSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          setState(() => _dynamicTouchOriginEnabled = val);
                          setModalState(() {});
                          unawaited(
                            _persistBoolPref(
                              VrJoystickConstants.prefKeyDynamicTouchOrigin,
                              val,
                            ),
                          );
                        },
                      ),
                      SwitchListTile(
                        key: const ValueKey(
                          VrJoystickConstants
                              .keyControllerCardinalDetentsToggle,
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: _cardinalDetentsEnabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsCardinalDetentsTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsCardinalDetentsSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          setState(() => _cardinalDetentsEnabled = val);
                          setModalState(() {});
                          unawaited(
                            _persistBoolPref(
                              VrJoystickConstants.prefKeyCardinalDetentsEnabled,
                              val,
                            ),
                          );
                        },
                      ),
                      SwitchListTile(
                        key: const ValueKey(
                          VrJoystickConstants.keyControllerAutoWalkToggle,
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: _autoWalkLockEnabled,
                        activeThumbColor: const Color(0xFF10B981),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsAutoWalkLockTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsAutoWalkLockSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          setState(() {
                            _autoWalkLockEnabled = val;
                            if (!val) {
                              _leftAutoWalkController.reset();
                              _moveAtEdge = false;
                              _moveResponse.reset();
                              _updateJoystick();
                            }
                          });
                          setModalState(() {});
                          unawaited(
                            _persistBoolPref(
                              VrJoystickConstants.prefKeyAutoWalkLockEnabled,
                              val,
                            ),
                          );
                          _sendState(force: true);
                        },
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        VrJoystickTranslationConstants
                            .settingsRightLookModeTitle,
                        style: TextStyle(
                          color: Color(0xFFFF9100),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SegmentedButton<VrRightStickLookMode>(
                        key: const ValueKey(
                          VrJoystickConstants
                              .keyControllerRightLookModeSelector,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: VrRightStickLookMode.smoothDualAxis,
                            label: Text(
                              VrJoystickTranslationConstants
                                  .rightLookModeSmoothLabel,
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                          ButtonSegment(
                            value: VrRightStickLookMode.comfortSnapTurn,
                            label: Text(
                              VrJoystickTranslationConstants
                                  .rightLookModeSnapLabel,
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                          ButtonSegment(
                            value: VrRightStickLookMode.flickStick,
                            label: Text(
                              VrJoystickTranslationConstants
                                  .rightLookModeFlickLabel,
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                          ButtonSegment(
                            value: VrRightStickLookMode.inertialTrackball,
                            label: Text(
                              VrJoystickTranslationConstants
                                  .rightLookModeTrackballLabel,
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                        selected: {_rightStickLookMode},
                        onSelectionChanged: (selection) {
                          final next = selection.first;
                          setState(() {
                            _rightStickLookMode = next;
                            _flickStickController.reset();
                            _inertialTrackballController.reset();
                            _updateJoystick();
                          });
                          setModalState(() {});
                          unawaited(_persistRightStickLookMode(next));
                          _hapticClick();
                          _sendState(force: true);
                        },
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<int>(
                        valueListenable: _passthroughSettingsRevision,
                        builder: (context, revision, child) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF080816),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _passthroughGesture.passthroughActive
                                  ? const Color(0xFF00E5FF)
                                  : Colors.white12,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Expanded(
                                    child: Text(
                                      VrJoystickTranslationConstants
                                          .settingsBreakthroughTitle,
                                      style: TextStyle(
                                        color: Color(0xFF00E5FF),
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _passthroughStatus,
                                    key: const ValueKey(
                                      'joystick_passthrough_settings_status',
                                    ),
                                    style: const TextStyle(
                                      color: Color(0xFF10B981),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                VrJoystickTranslationConstants
                                    .settingsBreakthroughSubtitle,
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 9.5,
                                ),
                              ),
                              Slider(
                                key: const ValueKey(
                                  'joystick_passthrough_settings_slider',
                                ),
                                value: _passthroughGesture.passthroughMix,
                                min: 0.0,
                                max: 1.0,
                                activeColor: const Color(0xFF00E5FF),
                                inactiveColor: Colors.white24,
                                onChanged: !_canControlPassthrough
                                    ? null
                                    : (val) {
                                        _setBreakthroughMix(val);
                                        setModalState(() {});
                                      },
                                // A deliberate release also reapplies the same
                                // chosen mix after the visor was switched OFF.
                                onChangeEnd: _canControlPassthrough
                                    ? _setBreakthroughMix
                                    : null,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: () {
                          _recenterController();
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(
                          Icons.filter_center_focus_rounded,
                          size: 16,
                        ),
                        label: const Text(
                          VrJoystickTranslationConstants.settingsRecenterNow,
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF00E5FF),
                          side: const BorderSide(color: Color(0xFF00E5FF)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      if (mounted) setState(() => _settingsOpen = false);
    });
  }

  Widget _buildAuxiliaryCameraPreview() {
    final controller = _visionService.previewController;
    if (controller == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Esperando la captura de la lente seleccionada…',
          style: TextStyle(color: Colors.white60, fontSize: 10),
        ),
      );
    }
    final lens = switch (controller.description.lensDirection) {
      CameraLensDirection.front => 'Frontal del mando',
      CameraLensDirection.back => 'Trasera del mando',
      CameraLensDirection.external => 'Lente externa del mando',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$lens · vista local',
          key: const ValueKey('controller-auxiliary-preview-lens'),
          style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 11),
        ),
        const SizedBox(height: 6),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, maxHeight: 220),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              // CameraPreview uses the active controller's native texture and
              // applies device orientation/aspect ratio without a YUV copy.
              child: CameraPreview(controller, key: ObjectKey(controller)),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  void _sendPublicTrackingMarker() {
    final configuration = _trackingMarkerConfiguration;
    final socket = _socket;
    if (!_isConnected ||
        socket == null ||
        !socket.isOpen ||
        configuration == null) {
      return;
    }
    try {
      socket.add(jsonEncode(configuration.toMessage()));
    } catch (_) {
      _onDisconnected(socket);
    }
  }

  Future<void> _openPublicTrackingMarker() async {
    final resend = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _sendPublicTrackingMarker(),
    );
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => VrPublicTrackingMarkerPage(
            initialConfiguration: _trackingMarkerConfiguration,
            onConfiguration: (configuration) {
              _trackingMarkerConfiguration = configuration;
              _sendPublicTrackingMarker();
            },
          ),
        ),
      );
    } finally {
      resend.cancel();
    }
  }

  Widget _buildBodyInferenceDiagnostic() {
    final joints = _visionService.bodyLandmarks;
    final reliable = joints
        .where((joint) => joint.inFrameLikelihood >= .5)
        .length;
    final state = switch (_visionService.bodyStatus) {
      'ready' =>
        'Esqueleto estimado · $reliable/${joints.length} puntos con visibilidad ≥50%',
      'no_person' => 'Modelo activo · sin propuesta corporal',
      'thermal_backoff' =>
        'Análisis pausado por temperatura · nivel ${_visionService.bodyThermalStatus ?? '—'}',
      'confirming_pose' =>
        'Propuesta en comprobación · ${_visionService.bodyStableFrames} imágenes estables',
      'rejected_pose' => 'Propuesta descartada por visibilidad o geometría',
      'stale' => 'Detección caducada · esperando imagen reciente',
      'waiting_for_camera' ||
      'waiting_for_frame' => 'Preparando captura para el modelo…',
      'unsupported_resolution' =>
        'Resolución insuficiente: requiere al menos 480×360',
      'unavailable' => 'Modelo no disponible en esta plataforma',
      _ => 'Estado del modelo: ${_visionService.bodyStatus}',
    };
    final latency = _visionService.bodyInferenceMs;
    final roundTrip = _visionService.bodyRoundTripMs;
    final du = _visionService.bodyDisplacementU;
    final dv = _visionService.bodyDisplacementV;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        key: const ValueKey('controller-body-diagnostic'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            state,
            style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 10),
          ),
          if (_visionService.bodyStatus == 'thermal_backoff')
            Text(
              'Reintento en al menos ${((_visionService.bodyRetryAfterMs ?? 2000) / 1000).toStringAsFixed(0)} s. '
              'Sin puntos corporales vigentes durante la pausa.',
              style: const TextStyle(color: Colors.white60, fontSize: 10),
            ),
          if (latency != null || roundTrip != null)
            Text(
              'ML Kit local · inferencia ${latency?.toStringAsFixed(1) ?? '—'} ms · '
              'total ${roundTrip?.toStringAsFixed(1) ?? '—'} ms · '
              'máximo ${_visionService.bodyInferenceMaxHz.toStringAsFixed(1)} análisis/s · '
              '${_visionService.bodyInferenceFramesDropped} imágenes omitidas',
              style: const TextStyle(color: Colors.white60, fontSize: 10),
            ),
          Text(
            '${_visionService.bodyRawLandmarkCount} puntos propuestos · '
            'filtro: ${_visionService.bodyGateReason}. Una propuesta aceptada todavía puede ser incorrecta.',
            style: const TextStyle(color: Colors.white60, fontSize: 10),
          ),
          if (du != null && dv != null)
            Text(
              'Cambio 2D desde la referencia: X ${(du * 100).toStringAsFixed(1)}%, '
              'Y ${(dv * 100).toStringAsFixed(1)}% de la imagen. '
              'Incluye movimiento de la cámara; no identifica personas ni acciones.',
              style: const TextStyle(color: Colors.white60, fontSize: 10),
            ),
          if (_showAuxiliaryCameraPreview && joints.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              'Mapa 2D del modelo · imagen orientada, sin espejo',
              style: TextStyle(color: Colors.white60, fontSize: 10),
            ),
            SizedBox(
              height: 120,
              child: CustomPaint(
                painter: _BodyLandmarkDiagnosticPainter(joints),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSettingsModeCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF00E5FF).withValues(alpha: 0.15)
              : const Color(0xFF080816),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFF00E5FF) : Colors.white12,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? const Color(0xFF00E5FF) : Colors.white60,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isSelected
                          ? const Color(0xFF00E5FF)
                          : Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 8.5,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF00E5FF),
                size: 16,
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_activeMode == RemoteControllerMode.nes) {
        final insets = MediaQuery.viewPaddingOf(context);
        if (_nesSize != null &&
            (_nesSize != constraints.biggest || _nesInsets != insets)) {
          _releaseInputs(send: true);
          _surfaceEpoch++;
        }
        _nesSize = constraints.biggest;
        _nesInsets = insets;
      } else if (_activeMode == RemoteControllerMode.joystick) {
        final insets = MediaQuery.viewPaddingOf(context);
        if (_joystickSize != null &&
            (_joystickSize != constraints.biggest ||
                _joystickInsets != insets)) {
          _releaseInputs(send: true);
          _surfaceEpoch++;
        }
      }
      // Geometry invalidation precedes the keyed surface. Its first new press
      // must not trigger another subtree replacement with the same epoch.
      return _buildControllerBody(context);
    },
  );

  Widget _buildControllerBody(BuildContext context) {
    if (_activeMode != RemoteControllerMode.laser) {
      // Bands reach the available display edges. Insets protect labels and
      // central settings only, never add a dead footer beneath X/A.
      return Scaffold(
        backgroundColor: const Color(0xFF080816),
        body: KeyedSubtree(
          key: ValueKey(
            '${VrJoystickConstants.keyControllerSurfacePrefix}$_surfaceEpoch',
          ),
          child: _activeMode == RemoteControllerMode.driving
              ? _buildDrivingLayout()
              : _activeMode == RemoteControllerMode.nes
              ? _buildNesLayout()
              : _buildJoystickLayout(),
        ),
      );
    }
    return Scaffold(
      backgroundColor: const Color(0xFF080816),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101528),
        toolbarHeight: 40,
        titleSpacing: 10,
        title: const FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.sports_esports_rounded,
                color: Color(0xFF00E5FF),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                VrJoystickTranslationConstants.appBar3DofTitle,
                style: TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
        ),
        actions: [
          _buildConnectionPill(),
          const SizedBox(width: 2),
          IconButton(
            icon: const Icon(
              Icons.filter_center_focus_rounded,
              color: Color(0xFF00E5FF),
              size: 19,
            ),
            tooltip: VrJoystickTranslationConstants.tooltipRecenterView,
            onPressed: _recenterController,
          ),
          IconButton(
            icon: const Icon(
              Icons.settings_rounded,
              color: Color(0xFF00E5FF),
              size: 19,
            ),
            tooltip: VrJoystickTranslationConstants.tooltipSettingsAndMode,
            onPressed: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.isChildRole &&
                  MediaQuery.sizeOf(context).height >= 340) ...[
                _buildChildRoleBanner(),
                const SizedBox(height: 4),
              ],

              // Active Controller Surface (Dual Joystick vs Laser)
              Expanded(
                child: KeyedSubtree(
                  key: ValueKey(
                    '${VrJoystickConstants.keyControllerSurfacePrefix}$_surfaceEpoch',
                  ),
                  child: switch (_activeMode) {
                    RemoteControllerMode.joystick => _buildJoystickLayout(),
                    RemoteControllerMode.laser => _buildLaserPointerLayout(),
                    RemoteControllerMode.driving => _buildDrivingLayout(),
                    RemoteControllerMode.nes => _buildNesLayout(),
                  },
                ),
              ),

              const SizedBox(height: 3),

              // Real-time Telemetry Bar
              _buildTelemetryBar(),
              if (_motionCapability != VrMotionCapability.available)
                Text(
                  _motionCapability == VrMotionCapability.checking
                      ? VrJoystickTranslationConstants.gyroCheckingNotice
                      : VrJoystickTranslationConstants.gyroUnavailableNotice,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.amber, fontSize: 10),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChildRoleBanner() {
    final syncing = _isConnecting && !_isConnected;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: syncing ? 5 : 3),
      decoration: BoxDecoration(
        color: const Color(0xFF00E5FF).withValues(alpha: syncing ? 0.20 : 0.08),
        borderRadius: BorderRadius.circular(8),
        border: syncing
            ? Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.65))
            : null,
      ),
      child: Row(
        children: [
          Icon(
            syncing ? Icons.sync_rounded : Icons.link_rounded,
            color: const Color(0xFF00E5FF),
            size: 14,
          ),
          const SizedBox(width: 6),
          Text(
            syncing
                ? VrJoystickTranslationConstants.childRoleSyncingBannerTitle
                : VrJoystickTranslationConstants.childRoleBannerTitle,
            style: const TextStyle(
              color: Color(0xFF00E5FF),
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${VrJoystickTranslationConstants.childRoleParentPrefix}$_targetDescription',
              style: const TextStyle(color: Colors.white54, fontSize: 9),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionPill() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _showIpConfigDialog,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isConnected
                    ? const Color(0xFF10B981).withValues(alpha: 0.5)
                    : Colors.white12,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _showsBluetooth
                      ? Icons.bluetooth_rounded
                      : (_isConnected
                            ? Icons.wifi_rounded
                            : Icons.wifi_off_rounded),
                  color: _isConnected
                      ? const Color(0xFF10B981)
                      : const Color(0xFFFF9100),
                  size: 13,
                ),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    _showsBluetooth
                        ? _externalConnectionLabel
                        : (_lastTarget?.host ??
                              (_ipController.text.isNotEmpty
                                  ? _ipController.text
                                  : VrJoystickTranslationConstants
                                        .configIpFallback)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(Icons.edit_rounded, color: Colors.white38, size: 11),
              ],
            ),
          ),
        ),
        const SizedBox(width: 6),
        ElevatedButton(
          onPressed: _isConnecting || !_hasConnectionTarget ? null : _connect,
          style: ElevatedButton.styleFrom(
            backgroundColor: _isConnected
                ? const Color(0xFF10B981)
                : const Color(0xFF00E5FF),
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: const Size(0, 30),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: Text(
            _isConnected
                ? VrJoystickTranslationConstants.buttonReconnect
                : VrJoystickTranslationConstants.buttonConnect,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 10.5,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNesLayout() => ValueListenableBuilder<Uri?>(
    valueListenable: _castPreview,
    builder: (_, uri, _) => _buildNesControls(uri),
  );

  Widget _buildNesControls(Uri? castUri) => LayoutBuilder(
    builder: (context, constraints) {
      final epoch = _surfaceEpoch;
      bool accepts() =>
          _activeMode == RemoteControllerMode.nes &&
          _acceptsSurfaceInput(epoch);
      return NesControllerLayout(
        key: ValueKey('${VrJoystickConstants.keyNesControlsPrefix}$epoch'),
        preview: castUri == null ? null : _castImagePanel(castUri),
        connected: _isConnected,
        onConnect: _isConnecting || !_hasConnectionTarget ? null : _connect,
        onSettings: _openSettings,
        captions: {
          VrJoystickConstants.actionKeyA:
              _hostActions[VrJoystickConstants.actionKeyA] ??
              VrJoystickTranslationConstants.nesCaptionA,
          VrJoystickConstants.actionKeyB:
              _hostActions[VrJoystickConstants.actionKeyX] ??
              VrJoystickTranslationConstants.nesCaptionB,
          VrJoystickConstants.nesKeyStart:
              _hostActions[VrJoystickConstants.actionKeyY] ??
              VrJoystickTranslationConstants.nesCaptionStart,
          VrJoystickConstants.nesKeySelect:
              _hostActions[VrJoystickConstants.actionKeyL] ??
              VrJoystickTranslationConstants.nesCaptionSelect,
          VrJoystickConstants.nesKeyHome:
              _hostActions[VrJoystickConstants.actionKeyB] ??
              VrJoystickTranslationConstants.nesCaptionHome,
        },
        pressed: {
          if (_btnAActive) VrJoystickConstants.actionKeyA,
          if (_btnXActive) VrJoystickConstants.actionKeyB,
          if (_btnYActive) VrJoystickConstants.nesKeyStart,
          if (_btnLActive) VrJoystickConstants.nesKeySelect,
          if (_btnBActive) VrJoystickConstants.nesKeyHome,
        },
        onDirection: (x, y) {
          if (!accepts()) return;
          setState(() {
            _stickX = x;
            _stickY = y;
          });
          _sendState(force: true);
        },
        onButton: (button, down) {
          if (!accepts()) return;
          setState(() {
            switch (button) {
              case VrJoystickConstants.actionKeyA:
                _btnAActive = down;
              case VrJoystickConstants.actionKeyB:
                _btnXActive = down;
              case VrJoystickConstants.nesKeyStart:
                _btnYActive = down;
              case VrJoystickConstants.nesKeySelect:
                _btnLActive = down;
              case VrJoystickConstants.nesKeyHome:
                _btnBActive = down;
            }
          });
          if (down) _hapticClick();
          _sendState(force: true);
        },
      );
    },
  );

  Widget _buildDrivingLayout() {
    Widget control(
      String letter,
      String caption,
      bool active,
      VoidCallback onDown,
      VoidCallback onUp,
    ) => _buildButton(
      key: ValueKey('${VrJoystickConstants.keyJoystickButtonPrefix}$letter'),
      title: letter,
      subtitle: caption,
      icon: Icons.sports_motorsports_rounded,
      isActive: active,
      emphasizeTitle: true,
      colors: const [Color(0xFF20364D), Color(0xFF142135)],
      onDown: onDown,
      onUp: onUp,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            SizedBox(
              height: 32,
              child: Row(
                children: [
                  IconButton(
                    tooltip:
                        VrJoystickTranslationConstants.tooltipExitController,
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        VrJoystickTranslationConstants.drivingHeaderTitle,
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _isConnecting || !_hasConnectionTarget
                        ? null
                        : _connect,
                    child: Text(
                      _isConnected
                          ? VrJoystickTranslationConstants.buttonReconnect
                          : VrJoystickTranslationConstants.buttonConnect,
                    ),
                  ),
                  IconButton(
                    tooltip:
                        VrJoystickTranslationConstants.tooltipSettingsAndMode,
                    padding: EdgeInsets.zero,
                    icon: const Icon(
                      Icons.settings_rounded,
                      color: Color(0xFF00E5FF),
                    ),
                    onPressed: _openSettings,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: _buildButton(
                      key: const ValueKey(
                        VrJoystickConstants.keyDrivingBrakePedal,
                      ),
                      title: VrJoystickTranslationConstants.drivingBrakeTitle,
                      subtitle:
                          VrJoystickTranslationConstants.drivingBrakeSubtitle,
                      icon: Icons.arrow_downward_rounded,
                      emphasizeTitle: true,
                      isActive: _brakePedalHeld,
                      colors: const [Color(0xFFDD4848), Color(0xFF7E2547)],
                      onDown: () => setState(
                        () => _brakePedalHeld = !_steering.state.paused,
                      ),
                      onUp: () => setState(() => _brakePedalHeld = false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 4,
                    child: Column(
                      children: [
                        SizedBox(
                          height: 36,
                          child: Row(
                            children: [
                              Expanded(
                                child: control(
                                  VrJoystickConstants.actionKeyL,
                                  VrJoystickTranslationConstants
                                      .drivingViewMinus,
                                  _btnLActive,
                                  () => setState(() => _btnLActive = true),
                                  () => setState(() => _btnLActive = false),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: control(
                                  VrJoystickConstants.actionKeyR,
                                  VrJoystickTranslationConstants
                                      .drivingViewPlus,
                                  _btnRActive,
                                  () => setState(() => _btnRActive = true),
                                  () => setState(() => _btnRActive = false),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ValueListenableBuilder<Uri?>(
                            valueListenable: _castPreview,
                            builder: (_, uri, child) =>
                                uri == null ? child! : _castImagePanel(uri),
                            child: Semantics(
                              label: VrJoystickTranslationConstants
                                  .drivingWheelSemantics,
                              child: IgnorePointer(
                                key: const ValueKey(
                                  VrJoystickConstants.keyDrivingWheel,
                                ),
                                child: CustomPaint(
                                  painter: VrDrivingWheelPainter(
                                    angle:
                                        _steering.state.steering *
                                        _steering.rangeRadians,
                                    available: _steering.motionAvailable,
                                  ),
                                  child: const SizedBox.expand(),
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 34,
                          width: double.infinity,
                          child: _buildButton(
                            key: const ValueKey(
                              VrJoystickConstants.keyJoystickRecenter,
                            ),
                            title: VrJoystickTranslationConstants
                                .drivingCenterWheelTitle,
                            subtitle: VrJoystickTranslationConstants
                                .drivingCenterWheelSubtitle,
                            icon: Icons.filter_center_focus_rounded,
                            isActive: false,
                            colors: const [
                              Color(0xFF1F5765),
                              Color(0xFF20364D),
                            ],
                            onDown: _centerSteering,
                            onUp: () {},
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: _buildButton(
                      key: const ValueKey(
                        VrJoystickConstants.keyDrivingThrottlePedal,
                      ),
                      title:
                          VrJoystickTranslationConstants.drivingThrottleTitle,
                      subtitle: VrJoystickTranslationConstants
                          .drivingThrottleSubtitle,
                      icon: Icons.arrow_upward_rounded,
                      emphasizeTitle: true,
                      isActive: _throttlePedalHeld,
                      colors: const [Color(0xFF119D78), Color(0xFF096249)],
                      onDown: () => setState(
                        () => _throttlePedalHeld = !_steering.state.paused,
                      ),
                      onUp: () => setState(() => _throttlePedalHeld = false),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  Expanded(
                    child: control(
                      VrJoystickConstants.actionKeyX,
                      _actionLabel(VrJoystickConstants.actionKeyX),
                      _btnXActive,
                      () {
                        setState(() {
                          _steering.setPaused(true);
                          _releaseInputs();
                          _surfaceEpoch++;
                        });
                        _pulseDrivingAction(reset: true);
                      },
                      () => setState(() => _btnXActive = false),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: control(
                      VrJoystickConstants.actionKeyY,
                      _actionLabel(VrJoystickConstants.actionKeyY),
                      _btnYActive,
                      () => setState(() => _btnYActive = true),
                      () => setState(() => _btnYActive = false),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: control(
                      VrJoystickConstants.actionKeyA,
                      VrJoystickTranslationConstants.drivingPauseResumeCaption,
                      _btnAActive,
                      _toggleDrivingPause,
                      () {},
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: control(
                      VrJoystickConstants.actionKeyB,
                      _actionLabel(VrJoystickConstants.actionKeyB),
                      _btnBActive,
                      () => setState(() {
                        _steering.setPaused(true);
                        _releaseInputs();
                        _btnBActive = true;
                      }),
                      () => setState(() => _btnBActive = false),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 38, child: _buildDrivingStatus()),
          ],
        ),
      ),
    );
  }

  // ─── Modo Joystick Virtual Layout ────────────────────────────────────────

  Widget _buildJoystickLayout() {
    final driving = _activeMode == RemoteControllerMode.driving;
    final surfaceEpoch = _surfaceEpoch;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        final insets = MediaQuery.viewPaddingOf(context);
        if (_joystickSize != constraints.biggest || _joystickInsets != insets) {
          _joystickSize = constraints.biggest;
          _joystickInsets = insets;
          _joystickGeometry = VrJoystickGeometry.fit(
            constraints.biggest,
            leftInset: insets.left,
            rightInset: insets.right,
          );
          _joystickLocalPaths.clear();
          for (final control in VrJoystickControl.values) {
            _joystickLocalPaths[control] = _joystickGeometry!
                .shape(control)
                .shift(-_joystickGeometry![control].topLeft);
          }
        }
        final geometry = _joystickGeometry!;

        Widget button(
          VrJoystickControl control, {
          required String title,
          required String subtitle,
          required bool active,
          required List<Color> colors,
          required VoidCallback onDown,
          required VoidCallback onUp,
          Color textColor = Colors.white,
        }) {
          final rect = geometry[control];
          var label = geometry.labels[control]!;
          // A notch can cover an outer edge. Keep the full touch/paint band,
          // but move its letter into the solid area that remains visible.
          if (control == VrJoystickControl.y) {
            label = Offset(
              math.min(rect.right - 14, math.max(label.dx, insets.left + 16)),
              label.dy,
            );
          } else if (control == VrJoystickControl.b) {
            label = Offset(
              math.max(
                rect.left + 14,
                math.min(label.dx, constraints.maxWidth - insets.right - 16),
              ),
              label.dy,
            );
          }
          label = Offset(
            label.dx,
            label.dy.clamp(
              insets.top + 20,
              math.max(
                insets.top + 20,
                constraints.maxHeight - insets.bottom - 20,
              ),
            ),
          );
          return Positioned.fromRect(
            rect: rect,
            child: _exclusivePassthroughControl(
              VrControllerRegion(
                key: ValueKey(
                  '${VrJoystickConstants.keyJoystickButtonPrefix}$title',
                ),
                path: _joystickLocalPaths[control]!,
                labelPosition: label - rect.topLeft,
                label: title,
                active: active,
                colors: colors,
                textColor: textColor,
                onDown: () {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  onDown();
                  _hapticMedium();
                  _sendState();
                },
                onUp: () {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  onUp();
                  _hapticLight();
                  _sendState();
                },
              ),
            ),
          );
        }

        Widget stick(VrJoystickControl control, bool movement) {
          final rect = geometry[control];
          return Positioned.fromRect(
            rect: rect,
            child: ClipOval(
              child: VirtualThumbstick(
                key: ValueKey(
                  movement
                      ? VrJoystickConstants.keyJoystickMoveStick
                      : VrJoystickConstants.keyJoystickLookStick,
                ),
                size: rect.width,
                knobRadius: rect.width * .19,
                // The radial response applies one continuous deadzone.
                deadzone: 0,
                horizontalEnabled: movement || _horizontalLookEnabled,
                accentColor: movement
                    ? const Color(0xFF00E5FF)
                    : const Color(0xFFFF9100),
                hapticsEnabled: _hapticsEnabled,
                dynamicTouchOrigin: _dynamicTouchOriginEnabled,
                enableCardinalDetents: _cardinalDetentsEnabled,
                isAutoWalkLocked:
                    movement && _leftAutoWalkController.isAutoWalkLocked,
                onPressed: (pressed) {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  final nowUs = _controllerClock.elapsedMicroseconds;
                  if (movement) {
                    if (pressed) {
                      final doubleTapped = _leftAutoWalkController
                          .onPointerDown(nowUs);
                      if (doubleTapped) {
                        _pulseStickClick();
                      }
                      if (!_leftAutoWalkController.isAutoWalkLocked) {
                        _moveAtEdge = false;
                        _moveResponse.reset();
                      }
                      _updateJoystick(nowUs: nowUs);
                      _sendState(force: true);
                    }
                  } else {
                    _lookStickHeld = pressed;
                    if (pressed) {
                      _inertialTrackballController.onTouchDown(nowUs);
                      final doubleTapped = _rightStickClickDetector
                          .onPointerDown(nowUs);
                      if (doubleTapped) {
                        _pulseStickClick();
                      }
                    }
                    _motionLook.setActive(pressed && _motionLookEnabled, nowUs);
                    if (!pressed) _lookResponse.reset();
                    _updateJoystick(nowUs: nowUs);
                    _sendState(force: true);
                  }
                },
                onChanged: (x, y) {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  final nowUs = _controllerClock.elapsedMicroseconds;
                  if (movement) {
                    final justLocked = _leftAutoWalkController.onStickChanged(
                      x,
                      y,
                      timestampUs: nowUs,
                      autoWalkEnabled: _autoWalkLockEnabled,
                    );
                    if (justLocked) {
                      _hapticMedium();
                    }
                    // Preserve rim intent before the progressive speed ramp.
                    // Hysteresis prevents tiny finger drift from rearming it.
                    final radiusSquared = x * x + y * y;
                    _moveAtEdge =
                        _leftAutoWalkController.isAutoWalkLocked ||
                        (radiusSquared.isFinite &&
                            radiusSquared >=
                                (_moveAtEdge ? .84 * .84 : .92 * .92));
                    _moveResponse.setInput(x, y);
                  } else {
                    _rawLookX = _horizontalLookEnabled ? x : 0.0;
                    _rawLookY = y;
                    _rightStickClickDetector.onStickChanged(
                      x,
                      y,
                      timestampUs: nowUs,
                      autoWalkEnabled: false,
                    );
                    if (_rightStickLookMode ==
                        VrRightStickLookMode.inertialTrackball) {
                      _inertialTrackballController.onTouchMove(
                        _rawLookX,
                        _rawLookY,
                        timestampUs: nowUs,
                      );
                    }
                    _lookResponse.setInput(_rawLookX, _rawLookY);
                  }
                  _updateJoystick(nowUs: nowUs);
                  _sendState();
                },
                onRelease: () {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  final nowUs = _controllerClock.elapsedMicroseconds;
                  if (movement) {
                    final locked = _leftAutoWalkController.onPointerUp(
                      nowUs,
                      autoWalkEnabled: _autoWalkLockEnabled,
                    );
                    if (locked) {
                      _moveAtEdge = true;
                      _moveResponse.setInput(0.0, 1.0);
                      setState(() {});
                    } else {
                      _moveAtEdge = false;
                      _moveResponse.reset();
                    }
                  } else {
                    _rightStickClickDetector.onPointerUp(
                      nowUs,
                      autoWalkEnabled: false,
                    );
                    _rawLookX = 0.0;
                    _rawLookY = 0.0;
                    _lookResponse.reset();
                    _lookStickHeld = false;
                    _motionLook.setActive(false, nowUs);
                    if (_rightStickLookMode ==
                        VrRightStickLookMode.inertialTrackball) {
                      _inertialTrackballController.onTouchUp();
                    } else {
                      _flickStickController.reset();
                    }
                  }
                  _updateJoystick(nowUs: nowUs);
                  _sendState(force: true);
                },
              ),
            ),
          );
        }

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) {
            if (!_acceptsSurfaceInput(surfaceEpoch)) return;
            if (!_canControlPassthrough) return;
            if (_exclusiveControlPointers.contains(event.pointer)) return;
            final normX = event.localPosition.dx / constraints.maxWidth;
            final normY = event.localPosition.dy / constraints.maxHeight;
            final previousMix = _passthroughGesture.passthroughMix;
            final changed = _passthroughGesture.onPointerDown(
              pointerId: event.pointer,
              normX: normX,
              normY: normY,
              timestampUs: _controllerClock.elapsedMicroseconds,
            );
            if (changed) {
              _sendGesturePassthroughChange(previousMix);
              _lastPassthroughHapticBucket =
                  (_passthroughGesture.passthroughMix * 4).round();
              _hapticLight();
              setState(() {});
            }
          },
          onPointerMove: (event) {
            if (!_acceptsSurfaceInput(surfaceEpoch)) return;
            if (!_canControlPassthrough) return;
            if (_exclusiveControlPointers.contains(event.pointer)) return;
            final normX = event.localPosition.dx / constraints.maxWidth;
            final normY = event.localPosition.dy / constraints.maxHeight;
            final previousMix = _passthroughGesture.passthroughMix;
            final changed = _passthroughGesture.onPointerMove(
              pointerId: event.pointer,
              normX: normX,
              normY: normY,
              timestampUs: _controllerClock.elapsedMicroseconds,
            );
            if (changed) {
              _sendGesturePassthroughChange(previousMix);
              final bucket = (_passthroughGesture.passthroughMix * 4).round();
              if (bucket != _lastPassthroughHapticBucket) {
                _lastPassthroughHapticBucket = bucket;
                _hapticClick();
              }
              setState(() {});
              _sendState();
            }
          },
          onPointerUp: (event) {
            if (_exclusiveControlPointers.remove(event.pointer)) return;
            final previousMix = _passthroughGesture.passthroughMix;
            final changed = _passthroughGesture.onPointerUpOrCancel(
              pointerId: event.pointer,
              timestampUs: _controllerClock.elapsedMicroseconds,
            );
            if (changed && mounted) {
              _sendGesturePassthroughChange(previousMix);
              _hapticMedium();
              setState(() {});
              _sendState(force: true);
            }
          },
          onPointerCancel: (event) {
            if (_exclusiveControlPointers.remove(event.pointer)) return;
            final previousMix = _passthroughGesture.passthroughMix;
            final changed = _passthroughGesture.onPointerUpOrCancel(
              pointerId: event.pointer,
              timestampUs: _controllerClock.elapsedMicroseconds,
            );
            if (changed && mounted) {
              _sendGesturePassthroughChange(previousMix);
              setState(() {});
              _sendState(force: true);
            }
          },
          child: Stack(
            key: const ValueKey(VrJoystickConstants.keyJoystickSurface),
            children: [
              Positioned.fromRect(
                rect: geometry.centerPanel,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF101528),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color:
                            (_btnGripActive
                                    ? const Color(0xFFFF9100)
                                    : const Color(0xFF10B981))
                                .withValues(alpha: .35),
                      ),
                    ),
                  ),
                ),
              ),
              button(
                VrJoystickControl.l,
                title: VrJoystickConstants.actionKeyL,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyL),
                active: _btnLActive,
                colors: const [Color(0xFF00A7B5), Color(0xFF395AB5)],
                onDown: () => setState(
                  () => _btnLActive = !driving || !_steering.state.paused,
                ),
                onUp: () => setState(() => _btnLActive = false),
              ),
              button(
                VrJoystickControl.r,
                title: VrJoystickConstants.actionKeyR,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyR),
                active: _btnRActive,
                colors: const [Color(0xFFFF9100), Color(0xFFD64D18)],
                onDown: () => setState(
                  () => _btnRActive = !driving || !_steering.state.paused,
                ),
                onUp: () => setState(() => _btnRActive = false),
              ),
              button(
                VrJoystickControl.y,
                title: VrJoystickConstants.actionKeyY,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyY),
                active: _btnYActive,
                colors: const [Color(0xFFFFD54F), Color(0xFFF59E0B)],
                textColor: const Color(0xFF211500),
                onDown: () => setState(() => _btnYActive = true),
                onUp: () => setState(() => _btnYActive = false),
              ),
              button(
                VrJoystickControl.x,
                title: VrJoystickConstants.actionKeyX,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyX),
                active: _btnXActive,
                colors: const [Color(0xFF2979FF), Color(0xFF1555BA)],
                onDown: () {
                  if (driving) {
                    setState(() {
                      _steering.setPaused(true);
                      _releaseInputs();
                      _surfaceEpoch++;
                    });
                    _pulseDrivingAction(reset: true);
                  } else {
                    setState(() => _btnXActive = true);
                  }
                },
                onUp: () => setState(() => _btnXActive = false),
              ),
              button(
                VrJoystickControl.b,
                title: VrJoystickConstants.actionKeyB,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyB),
                active: _btnBActive,
                colors: const [Color(0xFFFF5252), Color(0xFFB71C45)],
                onDown: () => setState(() {
                  if (driving) {
                    _steering.setPaused(true);
                    _releaseInputs();
                  }
                  _btnBActive = true;
                }),
                onUp: () => setState(() => _btnBActive = false),
              ),
              button(
                VrJoystickControl.a,
                title: VrJoystickConstants.actionKeyA,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyA),
                active: _btnAActive,
                colors: const [Color(0xFF10B981), Color(0xFF087848)],
                onDown: driving
                    ? _selectDrivingMenu
                    : () => setState(() => _btnAActive = true),
                onUp: () => setState(() => _btnAActive = false),
              ),
              stick(VrJoystickControl.moveStick, true),
              if (_rightLaser)
                Positioned.fromRect(
                  rect: geometry[VrJoystickControl.lookStick],
                  child: ClipOval(child: _buildLaserSlidePad()),
                )
              else
                stick(VrJoystickControl.lookStick, false),
              Positioned(
                left: geometry.centerPanel.left + 6,
                width: geometry.centerPanel.width - 12,
                top: 0,
                height: geometry[VrJoystickControl.recenter].top - 4,
                child: _buildJoystickChrome(),
              ),
              Positioned.fromRect(
                rect: geometry[VrJoystickControl.recenter],
                child: _buildButton(
                  key: const ValueKey(VrJoystickConstants.keyJoystickRecenter),
                  title: driving
                      ? VrJoystickTranslationConstants.drivingCenterWheelTitle
                      : VrJoystickTranslationConstants.joystickRecenterTitle,
                  subtitle: driving
                      ? VrJoystickTranslationConstants
                            .drivingCenterWheelLongSubtitle
                      : VrJoystickTranslationConstants.joystickRecenterSubtitle,
                  icon: Icons.filter_center_focus_rounded,
                  isActive: _recenterTriggered,
                  colors: const [Color(0xFFE17815), Color(0xFFB43A77)],
                  onDown: driving ? _centerSteering : _recenterController,
                  onUp: () {},
                ),
              ),
              Positioned.fromRect(
                rect: geometry.previewPanel,
                child: _buildJoystickCenter(),
              ),
              Positioned(
                left: geometry.centerPanel.left + 6,
                right: constraints.maxWidth - geometry.centerPanel.right + 6,
                bottom: 0,
                height: geometry.footerHeight,
                child: driving ? _buildDrivingStatus() : _buildJoystickStatus(),
              ),
              if (_canControlPassthrough &&
                  _pendingPassthroughMix == null &&
                  (_passthroughGesture.isGestureActive ||
                      _reportedPassthroughMix > .01))
                Positioned.fill(
                  child: IgnorePointer(
                    key: const ValueKey(
                      VrJoystickConstants.keyPassthroughCurtainOverlay,
                    ),
                    child: CustomPaint(
                      painter: VrPassthroughCurtainOverlayPainter(
                        mode: _passthroughGesture.mode,
                        passthroughMix: _reportedPassthroughMix,
                        spread: _passthroughGesture.currentSpread,
                        leftThumbNormX: _passthroughGesture.leftThumbNormX,
                        rightThumbNormX: _passthroughGesture.rightThumbNormX,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _castImagePanel(Uri uri) => Stack(
    fit: StackFit.expand,
    children: [
      VrCastPreview(uri: uri),
      Align(
        alignment: Alignment.topRight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: VrJoystickTranslationConstants.castProjectTooltip,
              onPressed: () => _projectCast(uri),
              icon: const Icon(Icons.connected_tv, size: 18),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
            ),
            IconButton(
              tooltip: VrJoystickTranslationConstants.castClosePreviewTooltip,
              onPressed: () {
                _castAutoEnabled = false;
                _castPreview.value = null;
              },
              icon: const Icon(Icons.close, size: 18),
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _buildJoystickCenter() => LayoutBuilder(
    key: const ValueKey(VrJoystickConstants.keyControllerCenterPanel),
    builder: (context, constraints) => ValueListenableBuilder<Uri?>(
      valueListenable: _castPreview,
      builder: (context, uri, _) => Column(
        children: [
          if (constraints.maxHeight >= 100)
            Expanded(
              child: uri == null
                  ? _buildCenterGuide()
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          VrCastPreview(
                            key: const ValueKey(
                              VrJoystickConstants.keyControllerCastPreview,
                            ),
                            uri: uri,
                          ),
                          Align(
                            alignment: Alignment.topRight,
                            child: IconButton(
                              key: const ValueKey(
                                VrJoystickConstants.keyControllerProjectCast,
                              ),
                              tooltip: VrJoystickTranslationConstants
                                  .castProjectTooltip,
                              onPressed: () => _projectCast(uri),
                              icon: const Icon(Icons.connected_tv, size: 20),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black54,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          if (constraints.maxHeight >= 76)
            SizedBox(
              height: 30,
              child: TextButton.icon(
                key: const ValueKey(
                  VrJoystickConstants.keyControllerCastToggle,
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                ),
                onPressed: () {
                  if (uri == null) {
                    _openCast();
                  } else {
                    _castAutoEnabled = false;
                    _castPreview.value = null;
                  }
                },
                icon: Icon(uri == null ? Icons.cast : Icons.close, size: 14),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    uri == null
                        ? VrJoystickTranslationConstants.castOpenPreviewButton
                        : VrJoystickTranslationConstants
                              .castClosePreviewTooltip,
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
            ),
          if (constraints.maxHeight >= 112) ...[
            _exclusivePassthroughControl(
              VrBreakthroughCurtainBar(
                passthroughMix: _reportedPassthroughMix,
                connected: _isConnected,
                synchronized: _hasEffectivePassthroughState,
                pending: _pendingPassthroughMix != null,
                spatialHudVisible: _spatialHudVisible,
                onMixChanged: _setBreakthroughMix,
                onToggleMix: _toggleBreakthroughMix,
                onToggleSpatialHud: () => _toggleSpatialHud(),
              ),
            ),
            const SizedBox(height: 4),
          ],
          SizedBox(
            height: math.min(44, constraints.maxHeight),
            child: Row(
              children: [
                for (final laser in [false, true])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Semantics(
                        selected: _rightLaser == laser,
                        child: TextButton.icon(
                          key: ValueKey(
                            laser
                                ? VrJoystickConstants.keyRightModeLaser
                                : VrJoystickConstants.keyRightModeView,
                          ),
                          onPressed: () => _selectRightControl(laser),
                          icon: Icon(
                            laser
                                ? Icons.near_me_outlined
                                : Icons.swap_vert_rounded,
                            size: 17,
                          ),
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              laser
                                  ? VrJoystickTranslationConstants
                                        .rightModeLaser
                                  : VrJoystickTranslationConstants
                                        .rightModeView,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            foregroundColor: _rightLaser == laser
                                ? const Color(0xFF080D1A)
                                : Colors.white70,
                            backgroundColor: _rightLaser == laser
                                ? (laser
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFFFF9100))
                                : const Color(0xFF202A3B),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildCenterGuide() => FittedBox(
    fit: BoxFit.scaleDown,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _horizontalLookEnabled
              ? VrJoystickTranslationConstants.centerGuideWalkOnly
              : VrJoystickTranslationConstants.centerGuideWalkAndTurn,
          style: const TextStyle(
            color: Color(0xFF00E5FF),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _horizontalLookEnabled
              ? VrJoystickTranslationConstants.centerGuideHorizontalLook
              : VrJoystickTranslationConstants.centerGuideEdgeTurn,
          style: const TextStyle(color: Colors.white60, fontSize: 10),
        ),
        const SizedBox(height: 10),
        Text(
          '${VrJoystickConstants.actionKeyA}${VrJoystickConstants.centerGuideBullet}${_actionLabel(VrJoystickConstants.actionKeyA)}${VrJoystickConstants.centerGuideSpacer}${VrJoystickConstants.actionKeyB}${VrJoystickConstants.centerGuideBullet}${_actionLabel(VrJoystickConstants.actionKeyB)}',
          style: const TextStyle(color: Colors.white, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          '${VrJoystickConstants.actionKeyX}${VrJoystickConstants.centerGuideBullet}${_actionLabel(VrJoystickConstants.actionKeyX)}${VrJoystickConstants.centerGuideSpacer}${VrJoystickConstants.actionKeyY}${VrJoystickConstants.centerGuideBullet}${_actionLabel(VrJoystickConstants.actionKeyY)}',
          style: const TextStyle(color: Colors.white70, fontSize: 10),
        ),
      ],
    ),
  );

  Widget _buildJoystickChrome() => Material(
    type: MaterialType.transparency,
    child: SafeArea(
      left: false,
      right: false,
      bottom: false,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                IconButton(
                  tooltip: VrJoystickTranslationConstants.tooltipExitController,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  icon: const Icon(
                    Icons.arrow_back,
                    size: 18,
                    color: Colors.white70,
                  ),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      VrJoystickTranslationConstants.appBar3DofTitle,
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip:
                      VrJoystickTranslationConstants.tooltipSettingsAndMode,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  icon: const Icon(
                    Icons.settings_rounded,
                    size: 19,
                    color: Color(0xFF00E5FF),
                  ),
                  onPressed: _openSettings,
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                IconButton(
                  tooltip: VrJoystickTranslationConstants.tooltipConfigureVisor,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  icon: Icon(
                    _showsBluetooth
                        ? Icons.bluetooth_rounded
                        : (_isConnected ? Icons.wifi : Icons.wifi_off),
                    size: 17,
                    color: _isConnected ? Colors.greenAccent : Colors.amber,
                  ),
                  onPressed: _showIpConfigDialog,
                ),
                Expanded(
                  child: TextButton(
                    onPressed: _isConnecting || !_hasConnectionTarget
                        ? null
                        : _connect,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF00E5FF),
                      disabledForegroundColor: Colors.white38,
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _isConnected
                            ? VrJoystickTranslationConstants.buttonReconnect
                            : VrJoystickTranslationConstants.buttonConnect,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _buildDrivingStatus() => Row(
    children: [
      Expanded(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _motionCapability == VrMotionCapability.checking
                    ? VrJoystickTranslationConstants.drivingStatusCheckingGyro
                    : _steering.motionAvailable
                    ? VrJoystickTranslationConstants.drivingStatusTurnPhone
                    : VrJoystickTranslationConstants.drivingStatusNoGyro,
                style: TextStyle(
                  color: _steering.motionAvailable
                      ? const Color(0xFF10B981)
                      : Colors.amber,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                _steering.state.paused
                    ? VrJoystickTranslationConstants.drivingStatusPaused
                    : _steering.motionAvailable
                    ? VrJoystickTranslationConstants
                          .drivingStatusTiltInstructions
                    : VrJoystickTranslationConstants.drivingStatusPedalsOnly,
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(width: 8),
      TextButton(
        onPressed: _toggleDrivingPause,
        child: Text(
          _steering.state.paused
              ? VrJoystickTranslationConstants.drivingButtonContinue
              : VrJoystickTranslationConstants.drivingButtonPause,
        ),
      ),
    ],
  );

  Widget _buildJoystickStatus() => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) => FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: constraints.maxWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _btnGripActive
                      ? VrJoystickTranslationConstants.statusGripActive
                      : _rightLaser
                      ? VrJoystickTranslationConstants.statusRightAimHoldGrip
                      : _horizontalLookEnabled
                      ? VrJoystickTranslationConstants
                            .statusRightViewVerticalAndTurn
                      : VrJoystickTranslationConstants
                            .statusRightViewVerticalOnly,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF10B981), fontSize: 8),
                ),
                Text(
                  _status,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60, fontSize: 9),
                ),
                if (_motionCapability != VrMotionCapability.available)
                  Text(
                    _motionCapability == VrMotionCapability.checking
                        ? VrJoystickTranslationConstants.gyroCheckingNotice
                        : VrJoystickTranslationConstants.gyroUnavailableNotice,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.amber, fontSize: 9),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildLaserSlidePad() {
    final surfaceEpoch = _surfaceEpoch;
    return LayoutBuilder(
      builder: (context, constraints) {
        final padWidth = constraints.maxWidth;
        final padHeight = constraints.maxHeight;
        final compact = padWidth < 220 || padHeight < 140;

        void handleTouch(Offset localPos) {
          final nx = ((localPos.dx - padWidth / 2) / (padWidth / 2)).clamp(
            -1.0,
            1.0,
          );
          final ny = ((localPos.dy - padHeight / 2) / (padHeight / 2)).clamp(
            -1.0,
            1.0,
          );
          _updateLaserSlide(nx, ny);
        }

        void startTouch(PointerDownEvent event) {
          if (!_acceptsSurfaceInput(surfaceEpoch)) return;
          if (_laserSlidePointer != null) return;
          _laserSlidePointer = event.pointer;
          setState(() => _isLaserSlideActive = true);
          if (_hapticsEnabled) HapticFeedback.selectionClick();
          handleTouch(event.localPosition);
          _gripHoldTimer?.cancel();
          _gripHoldTimer = Timer(const Duration(milliseconds: 280), () {
            if (_acceptsSurfaceInput(surfaceEpoch) && _isLaserSlideActive) {
              setState(() => _btnGripActive = true);
              if (_hapticsEnabled) HapticFeedback.heavyImpact();
              _sendState();
            }
          });
        }

        void updateTouch(PointerMoveEvent event) {
          if (!_acceptsSurfaceInput(surfaceEpoch)) return;
          if (event.pointer != _laserSlidePointer) return;
          handleTouch(event.localPosition);
        }

        void endTouch(PointerEvent event) {
          if (!_acceptsSurfaceInput(surfaceEpoch)) return;
          if (event.pointer != _laserSlidePointer) return;
          _laserSlidePointer = null;
          _gripHoldTimer?.cancel();
          _gripHoldTimer = null;
          final hadGrip = _btnGripActive;
          setState(() {
            _isLaserSlideActive = false;
            _btnGripActive = false;
            _angularVelocity.setZero();
          });
          if (hadGrip && _hapticsEnabled) {
            HapticFeedback.mediumImpact();
          } else if (_hapticsEnabled) {
            HapticFeedback.lightImpact();
          }
          _sendState();
        }

        return Listener(
          key: const ValueKey(VrJoystickConstants.keyLaserSlidePad),
          behavior: HitTestBehavior.opaque,
          onPointerDown: startTouch,
          onPointerMove: updateTouch,
          onPointerUp: endTouch,
          onPointerCancel: endTouch,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTap: () {
              if (!_acceptsSurfaceInput(surfaceEpoch)) return;
              _gripHoldTimer?.cancel();
              _gripHoldTimer = null;
              _btnGripActive = false;
              _updateLaserSlide(0.0, 0.0);
              if (_hapticsEnabled) HapticFeedback.mediumImpact();
            },
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF101E2E).withValues(alpha: 0.85),
                    const Color(0xFF080D1A).withValues(alpha: 0.95),
                  ],
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _btnGripActive
                      ? const Color(0xFFFF9100)
                      : (_isLaserSlideActive
                            ? const Color(0xFF10B981)
                            : const Color(0xFF10B981).withValues(alpha: 0.4)),
                  width: _btnGripActive
                      ? 2.5
                      : (_isLaserSlideActive ? 1.8 : 1.2),
                ),
                boxShadow: [
                  BoxShadow(
                    color:
                        (_btnGripActive
                                ? const Color(0xFFFF9100)
                                : const Color(0xFF10B981))
                            .withValues(
                              alpha: _btnGripActive
                                  ? 0.40
                                  : (_isLaserSlideActive ? 0.25 : 0.08),
                            ),
                    blurRadius: _btnGripActive
                        ? 20
                        : (_isLaserSlideActive ? 14 : 6),
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // Custom radar / 180° grid painter
                  Positioned.fill(
                    child: CustomPaint(
                      painter: VrLaserSlidePadPainter(
                        normX: _laserSlideNormX,
                        normY: _laserSlideNormY,
                        isActive: _isLaserSlideActive,
                        isGrip: _btnGripActive,
                      ),
                    ),
                  ),

                  // Center forward indicator
                  Positioned(
                    top: 5,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _btnGripActive
                                ? const Color(0xFFFF9100).withValues(alpha: 0.5)
                                : const Color(
                                    0xFF10B981,
                                  ).withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _btnGripActive
                                  ? Icons.pan_tool_alt_rounded
                                  : Icons.radar_rounded,
                              size: 11,
                              color: _btnGripActive
                                  ? const Color(0xFFFF9100)
                                  : const Color(0xFF10B981),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                _btnGripActive
                                    ? VrJoystickTranslationConstants
                                          .laserBadgeGripActive
                                    : (compact
                                          ? VrJoystickTranslationConstants
                                                .laserBadgeCompact
                                          : VrJoystickTranslationConstants
                                                .laserBadgeFrontal),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: _btnGripActive
                                      ? const Color(0xFFFF9100)
                                      : const Color(0xFF10B981),
                                  fontSize: 9.0,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Bottom label
                  Positioned(
                    bottom: 5,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Text(
                        compact
                            ? (_btnGripActive
                                  ? VrJoystickTranslationConstants
                                        .laserBottomCompactGrip
                                  : VrJoystickTranslationConstants
                                        .laserBottomCompactSlide)
                            : _btnGripActive
                            ? VrJoystickTranslationConstants.laserBottomFullGrip
                            : (_isLaserSlideActive
                                  ? '${VrJoystickTranslationConstants.laserAimingPrefix}${(_laserSlideNormX * 90).toStringAsFixed(0)}${VrJoystickTranslationConstants.laserAimingDegreeComma}${(-_laserSlideNormY * 71).toStringAsFixed(0)}${VrJoystickTranslationConstants.laserAimingDegreeEnd}'
                                  : VrJoystickTranslationConstants
                                        .laserBottomFullIdle),
                        style: TextStyle(
                          color: _btnGripActive
                              ? const Color(0xFFFF9100)
                              : (_isLaserSlideActive
                                    ? const Color(0xFF10B981)
                                    : Colors.white60),
                          fontSize: 8.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildButton({
    Key? key,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isActive,
    required List<Color> colors,
    Color textColor = Colors.white,
    BorderRadius? borderRadius,
    bool emphasizeTitle = false,
    required VoidCallback onDown,
    required VoidCallback onUp,
  }) {
    final surfaceEpoch = _surfaceEpoch;
    return GestureDetector(
      key: key,
      onTapDown: (_) {
        if (!_acceptsSurfaceInput(surfaceEpoch)) return;
        onDown();
        _hapticMedium();
        _sendState();
      },
      onTapUp: (_) {
        if (!_acceptsSurfaceInput(surfaceEpoch)) return;
        onUp();
        _hapticLight();
        _sendState();
      },
      onTapCancel: () {
        if (!_acceptsSurfaceInput(surfaceEpoch)) return;
        onUp();
        _sendState();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: borderRadius ?? BorderRadius.circular(14),
          border: isActive
              ? Border.all(color: Colors.white, width: 2.2)
              : Border.all(color: Colors.white12, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: colors.first.withValues(alpha: isActive ? 0.65 : 0.28),
              blurRadius: isActive ? 16 : 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!emphasizeTitle) ...[
                    Icon(icon, color: textColor, size: 22),
                    const SizedBox(height: 3),
                  ],
                  Text(
                    title,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w900,
                      fontSize: emphasizeTitle ? 32 : 13,
                      height: emphasizeTitle ? 1.05 : null,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.8),
                      fontSize: 9.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─── Modo Puntero Láser 3DoF Layout (1 Mano + Tap/5s Clic + Long-Press Wordsphere) ───

  Widget _buildLaserPointerLayout() {
    return ValueListenableBuilder<Uri?>(
      valueListenable: _castPreview,
      builder: (context, castUri, _) {
        final yawDeg = _laserYaw * (180.0 / math.pi);
        final pitchDeg = _laserPitch * (180.0 / math.pi);
        return Stack(
          fit: StackFit.expand,
          children: [
            VrLaserPointingView(
              aimX: _laserStickX,
              aimY: _laserStickY,
              yawDegrees: yawDeg,
              pitchDegrees: pitchDeg,
              dwellProgress: _laserSteadyDwell.progress,
              dwellRemainingSeconds: _laserSteadyDwell.remainingSeconds,
              clickActive: _triggerActive || _btnAActive,
              activeSearchQuery: _activeSearchQuery,
              previewWidget: castUri == null ? null : _castImagePanel(castUri),
              onTapClick: _pulseLaserClick,
              onLongPressSearch: _openWordsphereSearchSheet,
              onPanAimDelta: _nudgeLaserAimByPan,
              onPanAimEnd: () {},
              onRecenter: _recenterController,
              onReturnToJoystick: () =>
                  _selectMode(RemoteControllerMode.joystick),
            ),
            if (_wordsphereSearchSheetVisible)
              Positioned.fill(
                child: VrWordsphereSearchSheet(
                  wordsphereController: _wordsphereController,
                  textController: _wordsphereTextController,
                  onQueryChanged: _onWordsphereQueryChanged,
                  onSubmitted: _submitWordsphereSearch,
                  onClose: _closeWordsphereSearchSheet,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildTelemetryBar() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: _activeMode == RemoteControllerMode.driving
          ? _centerSteering
          : _recenterController,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF101528),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isConnected
                          ? const Color(0xFF10B981)
                          : const Color(0xFFFF007F),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _isConnected
                            ? const Color(0xFF10B981)
                            : Colors.white70,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (MediaQuery.sizeOf(context).width >= 740) ...[
              const SizedBox(width: 8),
              Text(
                '${VrJoystickTranslationConstants.telemetryNavPrefix}${_stickX.toStringAsFixed(1)}${VrJoystickTranslationConstants.telemetryCommaSpace}${_stickY.toStringAsFixed(1)}${VrJoystickTranslationConstants.telemetryVistaMiddle}${_lookX.toStringAsFixed(1)}${VrJoystickTranslationConstants.telemetryCommaSpace}${_lookY.toStringAsFixed(1)}${VrJoystickTranslationConstants.telemetryLaserMiddle}${_laserStickX.toStringAsFixed(1)}${VrJoystickTranslationConstants.telemetryCommaSpace}${_laserStickY.toStringAsFixed(1)}${VrJoystickTranslationConstants.telemetryEndParen}',
                style: const TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 8.5,
                  fontFamily: VrJoystickConstants.courierFontFamily,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
