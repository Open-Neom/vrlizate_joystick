import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';

import '../domain/models/vr_controller_connection_exception.dart';
import '../domain/models/vr_controller_connection_target.dart';
import '../domain/models/vr_controller_link_quality.dart';
import '../domain/models/vr_desktop_bridge_state.dart';
import '../domain/models/vr_joystick_ai_coprocessor.dart';
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

part 'phone_controller/phone_controller_sensors_and_vision.dart';
part 'phone_controller/phone_controller_connection_parts.dart';
part 'phone_controller/phone_controller_settings_dialogs.dart';
part 'phone_controller/phone_controller_nes_driving_layouts.dart';
part 'phone_controller/phone_controller_joystick_layout.dart';
part 'phone_controller/phone_controller_laser_layout.dart';

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

  /// Optional layout shortcut. Posture still gates the pointer when false.
  /// Gravity cannot distinguish one hand from two, so normal gamepad users
  /// keep their chosen Vista/Laser controls unless a host opts into this.
  final bool autoSwitchToOneHandedLaser;
  final bool isChildRole;

  /// Enables the built-in LAN discovery, socket connection and manual Wi-Fi
  /// override. Set false for a controller supplied exclusively by an external
  /// transport such as Bluetooth LE through [linkConnector].
  final bool allowWifiConnection;

  /// Marks an external [linkConnector] as a Wi-Fi LAN link (such as Estación
  /// Faro UDP coordination) rather than Bluetooth LE, so transport icons,
  /// status labels, and 120 Hz pacing never masquerade as BLE.
  final bool externalLinkOverWifi;

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

  /// Optional monotonic microsecond clock override for deterministic pacing tests.
  final int Function()? monotonicMicroseconds;

  /// Optional embedded AI co-processor allowing this Joystick smartphone (`2D`)
  /// to run local SAIA/GGUF inference on behalf of the Visor smartphone.
  final VrJoystickAiCoProcessor? aiCoProcessor;

  const PhoneControllerPage({
    super.key,
    this.initialMode = RemoteControllerMode.joystick,
    this.targetHost,
    this.targetPort = VrJoystickConstants.defaultServerPort,
    this.sessionToken,
    this.transportType = VrTransportType.localSocket,
    this.autoConnect = false,
    this.autoSwitchToOneHandedLaser = false,
    this.isChildRole = false,
    this.allowWifiConnection = true,
    this.externalLinkOverWifi = false,
    this.linkConnector,
    this.connectionLabel,
    this.connectionTimeout = const Duration(seconds: 4),
    this.onConnected,
    this.onSessionExpired,
    this.monotonicMicroseconds,
    this.aiCoProcessor,
  });

  @override
  State<PhoneControllerPage> createState() => _PhoneControllerPageState();
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
  VrDesktopBridgeState? _desktopBridge;
  int _desktopBridgeRevision = -1;
  bool? _deviceHasHardwareGyroscope;
  bool? _deviceHasConcurrentCameras;
  bool _deviceIsLowRam = false;
  VrObservableControllerLink? _observableLink;
  VrControllerLinkQuality? _linkQuality;
  String? _dismissedAdvisoryCode;
  int _streamIntervalMs = 16;
  double _lastPaintedLaserDwellProgress = -1.0;

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
  final Stopwatch _rawStopwatch = Stopwatch()..start();
  int get _nowUs =>
      widget.monotonicMicroseconds?.call() ?? _rawStopwatch.elapsedMicroseconds;
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
  double _dpadX = 0.0;
  double _dpadY = 0.0;
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
  bool _lastPaintedPointerPoseReady = false;
  bool get _pointerPoseReady =>
      _isForeground &&
      !_settingsOpen &&
      !_castDialogOpen &&
      !_wordsphereSearchSheetVisible &&
      _oneHandedLaserDetector.posture.isReadyAt(_nowUs);
  bool get _laserInteractionReady => _pointerPoseReady && _controllerVisible;
  final _laserSteadyDwell = VrLaserSteadyDwellController();
  final ValueNotifier<int> _laserAimViewRevision = ValueNotifier<int>(0);
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
  late final VrSearchPadController _wordsphereController =
      VrSearchPadController.create(textController: _wordsphereTextController);
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
  bool _btnZLActive = false;
  bool _btnZRActive = false;
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
    _syncImuSubscriptions();
    unawaited(_probeLocalHardwareCapabilities());
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

  void _refresh(VoidCallback fn) => setState(fn);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _shakeDetector.reset();
    _oneHandedLaserDetector.posture.reset();
    _isForeground = state == AppLifecycleState.resumed;
    _syncImuSubscriptions();
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
      if (_castAutoEnabled &&
          _canDisplayCastUi &&
          !(_desktopBridge?.castOffloadedToDesktop ?? false)) {
        _castPreview.value = _castOffer;
      }
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
    _detachLinkQuality(notify: false);
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
    _laserAimViewRevision.dispose();
    _ipController.dispose();
    // The next/current route owns orientation. During replacement this dispose
    // runs after that route mounted and must not overwrite its portrait lock.
    super.dispose();
  }

  EdgeInsets _joystickSafeInsets(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final gestures = MediaQuery.systemGestureInsetsOf(context);
    return EdgeInsets.fromLTRB(
      math.max(padding.left, gestures.left),
      math.max(padding.top, gestures.top),
      math.max(padding.right, gestures.right),
      math.max(padding.bottom, gestures.bottom),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (_activeMode == RemoteControllerMode.nes) {
        final insets = _joystickSafeInsets(context);
        if (_nesSize != null &&
            (_nesSize != constraints.biggest || _nesInsets != insets)) {
          _releaseInputs(send: true);
          _surfaceEpoch++;
        }
        _nesSize = constraints.biggest;
        _nesInsets = insets;
      } else if (_activeMode == RemoteControllerMode.joystick) {
        final insets = _joystickSafeInsets(context);
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

              if (_isConnected &&
                  _linkQuality?.advisory != null &&
                  _dismissedAdvisoryCode != _linkQuality!.advisory!.code &&
                  MediaQuery.sizeOf(context).height >= 360) ...[
                _buildLinkAdvisoryBanner(_linkQuality!.advisory!),
                const SizedBox(height: 2),
              ],

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
}
