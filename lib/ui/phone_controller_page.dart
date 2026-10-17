import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
import '../domain/models/vr_joystick_geometry.dart';
import '../domain/models/vr_steering_state.dart';
import '../domain/services/vr_controller_link.dart';
import '../domain/services/vr_controller_mode_session.dart';
import '../domain/services/vr_controller_shake_detector.dart';
import '../domain/services/vr_controller_state_pacer.dart';
import '../domain/services/vr_motion_look_controller.dart';
import '../domain/services/vr_progressive_stick.dart';
import '../domain/services/vr_steering_controller.dart';
import '../domain/services/vr_web_socket_controller_link.dart';
import '../utils/constants/vr_joystick_constants.dart';
import '../utils/constants/vr_joystick_translation_constants.dart';
import '../utils/enums/remote_controller_mode.dart';
import '../utils/enums/vr_joystick_control.dart';
import '../utils/enums/vr_motion_capability.dart';
import 'nes_controller_layout.dart';
import 'virtual_thumbstick.dart';
import 'vr_controller_region.dart';
import 'vr_driving_wheel_painter.dart';
import 'vr_laser_slide_pad_painter.dart';

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
  // Native games can explicitly retain both view axes. Walking hosts request
  // vertical-only view, while old mode messages keep their original contract.
  bool _horizontalLookEnabled = false;
  double _lookX =
      0.0; // Reserved for legacy/full-look clients; this UI uses pitch.
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
    if (_hapticsEnabled) {
      HapticFeedback.heavyImpact();
      Future.delayed(const Duration(milliseconds: 140), () {
        HapticFeedback.heavyImpact();
      });
    }
  }

  // Shake detection state
  bool _shakeToToggleEnabled = true;
  bool _controllerVisible = true;
  final _shakeDetector = VrControllerShakeDetector();
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
  Timer? _gripHoldTimer;

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

  void _startShakeDetection() {
    try {
      _accelSub =
          accelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 20),
          ).listen(
            (AccelerometerEvent event) {
              if (!mounted || !_isForeground) return;
              // Driving tilt remains available when shake-to-hide is disabled.
              _steering.updateGravity(
                event.x,
                event.y,
                event.z,
                _controllerClock.elapsedMicroseconds,
              );
              _motionLook.updateGravity(
                event.x,
                event.y,
                event.z,
                _controllerClock.elapsedMicroseconds,
              );
              if (_lookStickHeld) {
                _shakeDetector.reset();
                return;
              }
              if (_settingsOpen || !_shakeToToggleEnabled) return;
              if (_shakeDetector.addSample(
                event.x,
                event.y,
                event.z,
                _controllerClock.elapsedMicroseconds,
              )) {
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
      if (mounted) {
        setState(() {
          if (savedHaptics != null) _hapticsEnabled = savedHaptics;
          if (savedMotionLook != null) _motionLookEnabled = savedMotionLook;
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
      if (_activeMode == RemoteControllerMode.joystick) {
        _updateJoystick(elapsed: (now - _lastDrivingTickUs) / 1e6, nowUs: now);
      }
      if (now - (_lastMotionUs ?? 0) > 2000000) {
        _setMotionCapability(VrMotionCapability.unavailable);
      }
      if (_activeMode == RemoteControllerMode.driving) {
        _steering.setPedals(
          throttlePressed: _throttlePedalHeld,
          brakePressed: _brakePedalHeld,
        );
        _steering.advance((now - _lastDrivingTickUs) / 1e6);
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
    _stickX = move.x;
    _stickY = move.y;
    // Heading belongs to the left stick. In laser mode neither thumb nor
    // phone inclination can move the camera while the user is aiming.
    var x = _horizontalLookEnabled ? look.x + motion.x : 0.0;
    var y = look.y + motion.y;
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
        if (_activeMode == RemoteControllerMode.laser) {
          _activeMode = RemoteControllerMode.joystick;
          _releaseInputs(send: true);
        }
      }
    });
  }

  void _selectMode(RemoteControllerMode mode) {
    setState(() {
      _releaseInputs();
      _surfaceEpoch++;
      _activeMode =
          mode == RemoteControllerMode.laser &&
              _motionCapability == VrMotionCapability.unavailable
          ? RemoteControllerMode.joystick
          : mode;
      _steering.setPaused(false);
      _steering.calibrate(_wheelOrientation);
      _lastDrivingTickUs = _controllerClock.elapsedMicroseconds;
    });
    _hapticClick();
    _sendState();
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
      if (target != null) unawaited(_rememberHost(target.host));
      _hapticDoublePulse();
      _linkSubscription = socket.messages.listen(
        (data) => _onHostMessage(data, socket, generation),
        onDone: () => _onDisconnected(socket),
        onError: (Object error) => _onDisconnected(socket, error: error),
        cancelOnError: true,
      );
      _sendState();
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
                      () => validation = VrJoystickTranslationConstants
                          .castPasteFullLocalLink,
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
    if (_acceptCastOffer(data)) return;
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
      _isConnecting = false;
      _status = expired
          ? VrJoystickTranslationConstants.statusLinkExpired
          : !_reconnectEnabled
          ? VrJoystickTranslationConstants.statusDisconnectedManual
          : VrJoystickTranslationConstants.statusDisconnectedReconnecting;
    });
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
    _recenterResetTimer?.cancel();
    _recenterResetTimer = null;
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

  void _sendState({bool force = false}) {
    final ws = _socket;
    if (ws != null && ws.isOpen && _isConnected && (_isForeground || force)) {
      final driving = _steering.state;
      final isDriving = _activeMode == RemoteControllerMode.driving;
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
        VrJoystickConstants.fieldLaserSlideActive: _isLaserSlideActive,
        VrJoystickConstants.fieldAimX: _laserStickX,
        VrJoystickConstants.fieldAimY: _laserStickY,
        VrJoystickConstants.fieldRecenter: _recenterTriggered,
        VrJoystickConstants.fieldControllerVisible: _controllerVisible,
        VrJoystickConstants.fieldRangeMeters: 0.55,
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
        VrJoystickConstants.fieldMode: _activeMode.name,
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
    _surfaceMounted = false;
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
    _gripHoldTimer?.cancel();
    final socket = _socket;
    _socket = null;
    _linkSubscription?.cancel();
    _linkSubscription = null;
    if (socket != null) {
      Zone.root.run(() {
        unawaited(_closeLink(socket));
      });
    }
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF00E5FF).withValues(alpha: .08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.link_rounded, color: Color(0xFF00E5FF), size: 14),
          const SizedBox(width: 6),
          const Text(
            VrJoystickTranslationConstants.childRoleBannerTitle,
            style: TextStyle(
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
            child: VrControllerRegion(
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
                onPressed: (pressed) {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  if (!movement) {
                    _lookStickHeld = pressed;
                    _motionLook.setActive(
                      pressed && _motionLookEnabled,
                      _controllerClock.elapsedMicroseconds,
                    );
                    if (!pressed) _lookResponse.reset();
                    _updateJoystick();
                    _sendState(force: true);
                  }
                },
                onChanged: (x, y) {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  if (movement) {
                    // Preserve rim intent before the progressive speed ramp.
                    // Hysteresis prevents tiny finger drift from rearming it.
                    final radiusSquared = x * x + y * y;
                    _moveAtEdge =
                        radiusSquared.isFinite &&
                        radiusSquared >= (_moveAtEdge ? .84 * .84 : .92 * .92);
                    _moveResponse.setInput(x, y);
                  } else {
                    _lookResponse.setInput(_horizontalLookEnabled ? x : 0, y);
                  }
                  _updateJoystick();
                  _sendState();
                },
                onRelease: () {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  if (movement) {
                    _moveAtEdge = false;
                    _moveResponse.reset();
                  } else {
                    _lookResponse.reset();
                    _lookStickHeld = false;
                    _motionLook.setActive(
                      false,
                      _controllerClock.elapsedMicroseconds,
                    );
                  }
                  _updateJoystick();
                  _sendState(force: true);
                },
              ),
            ),
          );
        }

        return Stack(
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
          ],
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

  // ─── Modo Puntero Láser 3DoF Layout ──────────────────────────────────────

  Widget _buildLaserPointerLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left Side: Gyro Aiming Virtual Canvas
        Expanded(
          flex: 6,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF101528),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF00E5FF).withValues(alpha: 0.5),
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.screen_rotation_rounded,
                      size: 36,
                      color: Color(0xFF00E5FF),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      VrJoystickTranslationConstants.laserPointer3DActive,
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      VrJoystickTranslationConstants.laserPointer3DSubtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _recenterController,
                      icon: const Icon(Icons.gps_fixed_rounded, size: 14),
                      label: const Text(
                        VrJoystickTranslationConstants.laserRecenterSight,
                        style: TextStyle(fontSize: 11),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF00E5FF),
                        side: const BorderSide(color: Color(0xFF00E5FF)),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        minimumSize: const Size(0, 30),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        const SizedBox(width: 10),

        // Right Side: Action Buttons (Back / Trigger)
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _buildButton(
                  title: VrJoystickTranslationConstants.laserBackHomeTitle,
                  subtitle:
                      VrJoystickTranslationConstants.laserBackHomeSubtitle,
                  icon: Icons.navigation_rounded,
                  isActive: _actionActive,
                  colors: const [Color(0xFFFF007F), Color(0xFFFF9100)],
                  onDown: () => setState(() => _actionActive = true),
                  onUp: () => setState(() => _actionActive = false),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                flex: 2,
                child: _buildButton(
                  title: VrJoystickTranslationConstants.laserTriggerClickTitle,
                  subtitle:
                      VrJoystickTranslationConstants.laserTriggerClickSubtitle,
                  icon: Icons.touch_app_rounded,
                  isActive: _triggerActive,
                  colors: const [Color(0xFF00E5FF), Color(0xFF7C4DFF)],
                  onDown: () => setState(() => _triggerActive = true),
                  onUp: () => setState(() => _triggerActive = false),
                ),
              ),
            ],
          ),
        ),
      ],
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
