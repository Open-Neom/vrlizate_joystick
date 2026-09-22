import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:vrlizate/vrlizate.dart';

import 'virtual_thumbstick.dart';
import 'vr_pairing_link.dart';
import 'vr_remote_controller_service.dart';
import 'vr_steering_controller.dart';
import 'vr_controller_mode_protocol.dart';
import 'vr_joystick_geometry.dart';
import 'vr_controller_region.dart';
import 'vr_controller_shake_detector.dart';
import 'vr_controller_link.dart';

/// Native Smartphone VR Controller & Joystick Screen.
///
/// Main modes:
/// 1. [RemoteControllerMode.joystick]: Virtual 2D analog thumbstick for smooth 3D walking/strafe
///    locomotion + ergonomic Gamepad button cluster (A, B, Trigger, Grip, Recenter).
/// 2. [RemoteControllerMode.driving]: Same controls, with calibrated gyro steering.
/// The joystick keeps its laser pad. A legacy laser initial mode is normalized
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
    this.targetPort = 8080,
    this.sessionToken,
    this.transportType = VrTransportType.localSocket,
    this.autoConnect = false,
    this.isChildRole = false,
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
    text: '192.168.1.',
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

  /// Per-button captions sent by the host for the active experience; empty
  /// means the generic role labels. Keyed A/B/X/Y/L/R/GRIP.
  Map<String, String> _hostActions = const {};

  /// Generic role of each button, shown until a host captions it. Must match
  /// the host runner: X cycles modes, Y is the special action, L utility, R
  /// the game trigger.
  static const _defaultActions = {
    'A': 'Seleccionar',
    'B': 'Atrás / Home',
    'X': 'Cambiar modo',
    'Y': 'Acción especial',
    'L': 'Utilidad',
    'R': 'Gatillo',
    'GRIP': 'Agarrar',
  };

  String _actionLabel(String key) =>
      _hostActions[key] ?? _defaultActions[key] ?? key;
  Size? _joystickSize;
  EdgeInsets? _joystickInsets;
  bool _settingsOpen = false;
  VrJoystickGeometry? _joystickGeometry;
  final Map<VrJoystickControl, Path> _joystickLocalPaths = {};
  VrControllerConnectionTarget? _lastTarget;
  VrControllerConnectionTarget? _socketTarget;
  String _status = 'Buscando visor en la red Wi-Fi...';

  late RemoteControllerMode _activeMode;
  final VrSteeringController _steering = VrSteeringController();
  final Stopwatch _controllerClock = Stopwatch()..start();
  VrMotionCapability _motionCapability = VrMotionCapability.checking;
  int? _lastMotionUs;
  int _lastDrivingTickUs = 0;

  // Dual Joystick state
  double _stickX = 0.0;
  double _stickY = 0.0;
  double _lookX = 0.0; // 360° Horizontal turn (yaw)
  double _lookY = 0.0; // 180° Vertical tilt (pitch)
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
        (widget.linkConnector != null || widget.targetHost?.isNotEmpty == true);
    _activeMode = widget.initialMode == RemoteControllerMode.laser
        ? RemoteControllerMode.joystick
        : widget.initialMode;
    _targetPort = widget.targetPort;
    _loadSavedHaptics();
    if (widget.linkConnector != null) {
      _status = 'Sin vincular · $_externalConnectionLabel';
    } else if (widget.targetHost != null && widget.targetHost!.isNotEmpty) {
      _ipController.text = widget.targetHost!;
      _status = 'Sin vincular · ${widget.targetHost}:$_targetPort';
    } else {
      _loadSavedIp();
    }
    if (widget.linkConnector == null &&
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
            (widget.targetHost != null && widget.targetHost!.isNotEmpty))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_isConnected && !_isConnecting) {
          _connect();
        }
      });
    }
  }

  void _startShakeDetection() {
    try {
      _accelSub = accelerometerEventStream().listen((AccelerometerEvent event) {
        if (!mounted ||
            !_isForeground ||
            _settingsOpen ||
            !_shakeToToggleEnabled) {
          return;
        }
        if (_shakeDetector.addSample(
          event.x,
          event.y,
          event.z,
          _controllerClock.elapsedMicroseconds,
        )) {
          _onShakeDetected();
        }
      }, onError: (_) {});
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
      final savedHaptics = prefs.getBool('vrlizate_haptics_enabled');
      if (mounted && savedHaptics != null) {
        setState(() => _hapticsEnabled = savedHaptics);
      }
    } catch (_) {}
  }

  Future<void> _persistHaptics(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('vrlizate_haptics_enabled', enabled);
    } catch (_) {}
  }

  Future<void> _loadSavedIp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedIp = prefs.getString('vrlizate_host_ip');
      if (mounted &&
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
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        8081,
        reuseAddress: true,
        reusePort: true,
      );
      if (!mounted) {
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
                  json['service'] == 'vrlizate_vr_host') {
                final port = json['port'];
                if (port is! int || port < 1 || port > 65535) return;
                // Discovery is an unauthenticated hint. Trust the datagram's
                // actual source for display, never its advertised IP/token.
                final hostIp = datagram.address.address;
                setState(() {
                  _discoveredHost = hostIp;
                  _targetPort = port;
                  _ipController.text = hostIp;
                  _status =
                      'Visor detectado ($hostIp:$port). Escanea su QR o pega su enlace para vincular.';
                });
              }
            } catch (_) {}
          }
        }
      });
    } catch (e) {
      debugPrint('[PhoneControllerPage] UDP listener notice: $e');
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
                return;
              }
              _lastMotionUs = _controllerClock.elapsedMicroseconds;
              _setMotionCapability(VrMotionCapability.available);
              if (_activeMode != RemoteControllerMode.driving) {
                // Only the touch pad owns laser aim, including after release.
                // Keep sensor capability detection alive for the wheel mode.
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
              _angularVelocity.setZero();
              _lastGyroTime = null;
              _setMotionCapability(VrMotionCapability.unavailable);
            },
          );
    } catch (_) {
      _setMotionCapability(VrMotionCapability.unavailable);
    }

    // Send state periodically at 60 FPS
    _streamTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || !_isForeground) return;
      final now = _controllerClock.elapsedMicroseconds;
      if (now - (_lastMotionUs ?? 0) > 2000000) {
        _setMotionCapability(VrMotionCapability.unavailable);
      }
      if (_activeMode == RemoteControllerMode.driving) {
        _steering.setPedals(
          throttlePressed: _btnRActive,
          brakePressed: _btnLActive,
        );
        _steering.advance((now - _lastDrivingTickUs) / 1e6);
        setState(() {});
      }
      _lastDrivingTickUs = now;
      _sendState();
    });
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
    if (widget.linkConnector != null && !_useWifiOverride) {
      return _externalConnectionLabel;
    }
    if (_lastTarget != null) return 'Conexión Directa (Socket)';
    switch (widget.transportType) {
      case VrTransportType.bluetoothLe:
        return _useWifiOverride
            ? 'Conexión Directa (Socket)'
            : 'Bluetooth LE (pendiente)';
      case VrTransportType.wifiDirect:
        return 'Wi-Fi Direct (pendiente)';
      case VrTransportType.localSocket:
        return 'Conexión Directa (Socket)';
    }
  }

  String get _externalConnectionLabel =>
      widget.connectionLabel?.trim().isNotEmpty == true
      ? widget.connectionLabel!.trim()
      : 'Enlace externo';

  String get _targetDescription =>
      (widget.linkConnector != null && !_useWifiOverride)
      ? _externalConnectionLabel
      : '${_lastTarget?.host ?? widget.targetHost ?? _discoveredHost ?? 'Sin vincular'}:$_targetPort ($_transportLabel)';

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
    if (!immediately && _reconnectAttempt >= _reconnectDelays.length) {
      setState(() {
        _status =
            'Visor no disponible. Vuelve a la app o pulsa CONECTAR para reintentar.';
      });
      return;
    }
    final delay = immediately
        ? Duration.zero
        : _reconnectDelays[_reconnectAttempt++];
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
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    VrControllerConnectionTarget? target;
    try {
      if (widget.linkConnector == null || _useWifiOverride) {
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
      setState(() => _status = error.message ?? 'Transporte pendiente.');
      return;
    }
    if (!automatic) _reconnectAttempt = 0;
    _reconnectEnabled = true;
    final generation = ++_connectionGeneration;
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
          ? 'Conectando · $_externalConnectionLabel...'
          : 'Conectando al visor ${target.host}:${target.port}...';
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
      _hostActions = const {};
      _reconnectAttempt = 0;
      if (target != null) {
        _lastTarget = target;
        _targetPort = target.port;
      }
      _sequence = 0;
      _releaseInputs();
      _surfaceEpoch++;
      if (_activeMode == RemoteControllerMode.driving) {
        _steering.setPaused(true);
      }
      setState(() {
        _isConnected = true;
        _isConnecting = false;
        _status = target == null
            ? '⚡ VINCULADO · $_externalConnectionLabel'
            : widget.isChildRole
            ? '⚡ VINCULADO AL VISOR PADRE (${target.host}:${target.port})'
            : '⚡ CONECTADO AL VISOR';
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
              ? 'El vínculo del visor caducó. Escanea un QR nuevo para conectar.'
              : widget.linkConnector != null && !_useWifiOverride
              ? 'No se pudo vincular por $_externalConnectionLabel. Revisa el visor, los permisos y vuelve a intentar.'
              : 'No se pudo vincular. Verifica el enlace del visor y la red Wi-Fi.';
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
            'while updating a saved controller session',
          ),
        ),
      );
    }
  }

  void _onHostMessage(Object? data, VrControllerLink socket, int generation) {
    if (!mounted ||
        !_surfaceMounted ||
        generation != _socketGeneration ||
        !identical(_socket, socket)) {
      return;
    }
    final request = _hostModeSession.accept(data);
    if (request == null) return;
    if (request.mode == _activeMode) {
      // Same layout, new captions: relabel without dropping held inputs.
      setState(() => _hostActions = request.actions);
      _sendState(force: true);
      return;
    }
    // Mode requests are scoped to this authenticated socket. Send no packet
    // between accepting its revision and installing a completely neutral mode.
    setState(() {
      _hostActions = request.actions;
      _releaseInputs();
      _surfaceEpoch++;
      _activeMode = request.mode;
      _steering.setPaused(request.mode == RemoteControllerMode.driving);
      _lastDrivingTickUs = _controllerClock.elapsedMicroseconds;
      _status = request.mode == RemoteControllerMode.driving
          ? 'Conducción lista · pulsa CONTINUAR para iniciar'
          : 'Joystick listo · puntero y botones disponibles';
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
          TimeoutException('Controller connection timed out'),
        );
      }
    });
    unawaited(
      Future<VrControllerLink>.sync(() {
        final connector = _useWifiOverride ? null : widget.linkConnector;
        if (connector != null) return connector();
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
                'Controller link is closed',
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
      completion.completeError(StateError('Connection cancelled'));
    }
  }

  Future<void> _rememberHost(String host) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('vrlizate_host_ip', host);
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
    _hostActions = const {};
    if (_activeMode == RemoteControllerMode.driving) {
      _steering.setPaused(true);
    }
    _releaseInputs();
    setState(() {
      _surfaceEpoch++;
      _isConnected = false;
      _isConnecting = false;
      _status = expired
          ? 'El vínculo del visor caducó. Escanea un QR nuevo para conectar.'
          : !_reconnectEnabled
          ? 'Desconectado del visor. Revisa el vínculo y pulsa CONECTAR.'
          : 'Desconectado del visor. Recuperando el vínculo...';
    });
    if (expired) {
      _notifySessionCallback(() => widget.onSessionExpired?.call(target));
    }
    _scheduleReconnect();
  }

  void _releaseInputs({bool send = false}) {
    _drivingActionTimer?.cancel();
    _drivingActionTimer = null;
    _recenterResetTimer?.cancel();
    _recenterResetTimer = null;
    _stickX = 0;
    _stickY = 0;
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
    final driving = _steering.state;
    if (ws != null && ws.isOpen && _isConnected && (_isForeground || force)) {
      final payload = jsonEncode({
        'sequence': _sequence++,
        'hostModeRevision': _hostModeSession.revision,
        'timestampUs': DateTime.now().microsecondsSinceEpoch,
        'qx': _orientation.x,
        'qy': _orientation.y,
        'qz': _orientation.z,
        'qw': _orientation.w,
        'wx': _angularVelocity.x,
        'wy': _angularVelocity.y,
        'wz': _angularVelocity.z,
        'stickX': _stickX,
        'stickY': _stickY,
        'tx': _stickX,
        'ty': _stickY,
        'lookX': _lookX,
        'lookY': _lookY,
        'turn': _lookX,
        'turnRate': _lookX,
        'pitchRate': _lookY,
        'lookPitch': _lookY,
        'laserX': _laserStickX,
        'laserY': _laserStickY,
        'laserSlideActive': _isLaserSlideActive,
        'aimX': _laserStickX,
        'aimY': _laserStickY,
        'recenter': _recenterTriggered,
        'controllerVisible': _controllerVisible,
        'rangeMeters': 0.55,
        'trigger': _triggerActive || _btnRActive,
        'action': _actionActive || _btnBActive,
        'btnA': _btnAActive,
        'btnB': _btnBActive,
        'btnX': _btnXActive,
        'btnY': _btnYActive,
        'btnL': _btnLActive,
        'btnR': _btnRActive,
        'btnGrip': _btnGripActive,
        'mode': _activeMode.name,
        'steering': _activeMode == RemoteControllerMode.driving
            ? driving.steering
            : 0.0,
        'throttle': _activeMode == RemoteControllerMode.driving
            ? driving.throttle
            : 0.0,
        'brake': _activeMode == RemoteControllerMode.driving
            ? driving.brake
            : 0.0,
        'drivingPaused':
            _activeMode == RemoteControllerMode.driving && driving.paused,
        'motionAvailable': _motionCapability == VrMotionCapability.available,
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
      epoch == _surfaceEpoch;

  @override
  void dispose() {
    _surfaceMounted = false;
    WidgetsBinding.instance.removeObserver(this);
    _stopAutomaticReconnect();
    _cancelPendingConnection();
    _releaseInputs(send: true);
    _isForeground = false;
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
                                'AJUSTES DEL MANDO VR',
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
                        'Visor: $_targetDescription',
                        key: const ValueKey('controller_pairing_target'),
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
                        'MODO DE CONTROL',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _buildSettingsModeCard(
                        title: 'JOYSTICK DUAL',
                        subtitle: 'Navegación + Vista + Puntero integrado',
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
                        title: 'CONDUCCIÓN',
                        subtitle:
                            'Mismos botones + giro del teléfono · L frena / R acelera',
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
                        'CONEXIÓN CON EL VISOR PADRE',
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
                            if (widget.linkConnector != null) ...[
                              SegmentedButton<bool>(
                                key: const ValueKey(
                                  'controller_transport_selector',
                                ),
                                segments: const [
                                  ButtonSegment(
                                    value: false,
                                    icon: Icon(
                                      Icons.bluetooth_rounded,
                                      size: 16,
                                    ),
                                    label: Text(
                                      'Bluetooth LE',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  ButtonSegment(
                                    value: true,
                                    icon: Icon(Icons.wifi_rounded, size: 16),
                                    label: Text(
                                      'Wi-Fi local',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                                selected: {_useWifiOverride},
                                onSelectionChanged: (val) {
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
                                  child:
                                      (widget.linkConnector != null &&
                                          !_useWifiOverride)
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
                                            const Text(
                                              'Vínculo directo BLE sin router ni contraseña.',
                                              style: TextStyle(
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
                                                '192.168.1.XX:8080 o vrlizate://pair?...',
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
                                  onPressed: _isConnecting
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
                                    _isConnected ? 'RECONECTAR' : 'CONECTAR',
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
                              'Estado: $_status\nTransporte: $_transportLabel | Rol: ${widget.isChildRole ? "Mando Hijo (Enlace Directo)" : "Mando Independiente"}',
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
                        'GESTOS Y RECENTRADO',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        key: const ValueKey('controller_visibility_toggle'),
                        contentPadding: EdgeInsets.zero,
                        value: _controllerVisible,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          'Mostrar mando en visor',
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        subtitle: const Text(
                          'Muestra los botones y sticks pulsados dentro del VR.',
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          _setControllerVisible(val);
                          setModalState(() {});
                        },
                      ),
                      SwitchListTile(
                        key: const ValueKey('controller_shake_toggle'),
                        contentPadding: EdgeInsets.zero,
                        value: _shakeToToggleEnabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          'Sacudir para mostrar/ocultar el mando',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'Sacude el control en cualquier dirección. No cambia la mira ni recentra el visor; también funciona en conducción.',
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
                          'Vibración háptica del mando',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          'Respuesta táctil al pulsar botones, límites del joystick, sacudir o recentrar.',
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
                        label: const Text('Recentrar Vista y Mandos Ahora'),
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
  Widget build(BuildContext context) {
    if (_activeMode != RemoteControllerMode.laser) {
      // Bands reach the available display edges. Insets protect labels and
      // central settings only, never add a dead footer beneath X/A.
      return Scaffold(
        backgroundColor: const Color(0xFF080816),
        body: KeyedSubtree(
          key: ValueKey('controller_surface_$_surfaceEpoch'),
          child: _buildJoystickLayout(),
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
                'MANDO 3DoF VRLIZATE',
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
            tooltip: 'Recentrar vista',
            onPressed: _recenterController,
          ),
          IconButton(
            icon: const Icon(
              Icons.settings_rounded,
              color: Color(0xFF00E5FF),
              size: 19,
            ),
            tooltip: 'Ajustes y Modo',
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
                  key: ValueKey('controller_surface_$_surfaceEpoch'),
                  child: switch (_activeMode) {
                    RemoteControllerMode.joystick => _buildJoystickLayout(),
                    RemoteControllerMode.laser => _buildLaserPointerLayout(),
                    RemoteControllerMode.driving => _buildJoystickLayout(),
                  },
                ),
              ),

              const SizedBox(height: 3),

              // Real-time Telemetry Bar
              _buildTelemetryBar(),
              if (_motionCapability != VrMotionCapability.available)
                Text(
                  _motionCapability == VrMotionCapability.checking
                      ? 'Comprobando giroscopio · controles táctiles disponibles'
                      : 'Sin giroscopio disponible · usa los controles táctiles',
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
            'ROL: MANDO HIJO',
            style: TextStyle(
              color: Color(0xFF00E5FF),
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Visor Padre: $_targetDescription',
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
                  (widget.linkConnector != null && !_useWifiOverride)
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
                    (widget.linkConnector != null && !_useWifiOverride)
                        ? _externalConnectionLabel
                        : (_lastTarget?.host ??
                              (_ipController.text.isNotEmpty
                                  ? _ipController.text
                                  : 'Config IP')),
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
          onPressed: _isConnecting ? null : _connect,
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
            _isConnected ? 'RECONECTAR' : 'CONECTAR',
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
              key: ValueKey('joystick_button_$title'),
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
                  movement ? 'joystick_move_stick' : 'joystick_look_stick',
                ),
                size: rect.width,
                knobRadius: rect.width * .19,
                accentColor: movement
                    ? const Color(0xFF00E5FF)
                    : const Color(0xFFFF9100),
                hapticsEnabled: _hapticsEnabled,
                onChanged: (x, y) {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  if (movement) {
                    _stickX = x;
                    _stickY = y;
                    if (driving && !_steering.motionAvailable) {
                      _steering.setTouchSteering(x);
                    }
                  } else {
                    _lookX = x;
                    _lookY = y;
                  }
                  _sendState();
                },
                onRelease: () {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  if (movement) {
                    _stickX = 0;
                    _stickY = 0;
                    if (driving) _steering.setTouchSteering(null);
                  } else {
                    _lookX = 0;
                    _lookY = 0;
                  }
                  _sendState();
                },
              ),
            ),
          );
        }

        return Stack(
          key: const ValueKey('joystick_surface'),
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
              title: 'L',
              subtitle: _actionLabel('L'),
              active: _btnLActive,
              colors: const [Color(0xFF00A7B5), Color(0xFF395AB5)],
              onDown: () => setState(
                () => _btnLActive = !driving || !_steering.state.paused,
              ),
              onUp: () => setState(() => _btnLActive = false),
            ),
            button(
              VrJoystickControl.r,
              title: 'R',
              subtitle: _actionLabel('R'),
              active: _btnRActive,
              colors: const [Color(0xFFFF9100), Color(0xFFD64D18)],
              onDown: () => setState(
                () => _btnRActive = !driving || !_steering.state.paused,
              ),
              onUp: () => setState(() => _btnRActive = false),
            ),
            button(
              VrJoystickControl.y,
              title: 'Y',
              subtitle: _actionLabel('Y'),
              active: _btnYActive,
              colors: const [Color(0xFFFFD54F), Color(0xFFF59E0B)],
              textColor: const Color(0xFF211500),
              onDown: () => setState(() => _btnYActive = true),
              onUp: () => setState(() => _btnYActive = false),
            ),
            button(
              VrJoystickControl.x,
              title: 'X',
              subtitle: _actionLabel('X'),
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
              title: 'B',
              subtitle: _actionLabel('B'),
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
              title: 'A',
              subtitle: _actionLabel('A'),
              active: _btnAActive,
              colors: const [Color(0xFF10B981), Color(0xFF087848)],
              onDown: driving
                  ? _selectDrivingMenu
                  : () => setState(() => _btnAActive = true),
              onUp: () => setState(() => _btnAActive = false),
            ),
            stick(VrJoystickControl.moveStick, true),
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
                key: const ValueKey('joystick_recenter'),
                title: driving ? 'CENTRAR VOLANTE' : 'RECENTRAR VISTA',
                subtitle: driving
                    ? 'Teléfono recto = dirección al centro'
                    : 'Centrar horizonte y mira',
                icon: Icons.filter_center_focus_rounded,
                isActive: _recenterTriggered,
                colors: const [Color(0xFFE17815), Color(0xFFB43A77)],
                onDown: driving ? _centerSteering : _recenterController,
                onUp: () {},
              ),
            ),
            Positioned.fromRect(
              rect: geometry[VrJoystickControl.laserPad],
              child: _buildLaserSlidePad(),
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
                  tooltip: 'Salir del mando',
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
                      'MANDO 3DoF VRLIZATE',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Ajustes y Modo',
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
                  tooltip: 'Configurar visor',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 28,
                    height: 28,
                  ),
                  icon: Icon(
                    widget.linkConnector != null
                        ? Icons.link
                        : (_isConnected ? Icons.wifi : Icons.wifi_off),
                    size: 17,
                    color: _isConnected ? Colors.greenAccent : Colors.amber,
                  ),
                  onPressed: _showIpConfigDialog,
                ),
                Expanded(
                  child: TextButton(
                    onPressed: _isConnecting ? null : _connect,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF00E5FF),
                      padding: EdgeInsets.zero,
                      minimumSize: Size.zero,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _isConnected ? 'RECONECTAR' : 'CONECTAR',
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

  Widget _buildDrivingStatus() => Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          'L · FRENO    R · ACELERAR    A · ELEGIR',
          style: TextStyle(color: Colors.white70, fontSize: 9),
        ),
      ),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          _steering.state.paused
              ? 'PAUSA · pedales liberados'
              : _steering.motionAvailable
              ? 'Gira el teléfono para mover el volante'
              : 'DIRECCIÓN TÁCTIL · joystick izquierdo',
          style: const TextStyle(color: Color(0xFF10B981), fontSize: 9),
        ),
      ),
      SizedBox(
        height: 30,
        child: TextButton(
          onPressed: _toggleDrivingPause,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            _steering.state.paused ? 'CONTINUAR' : 'PAUSAR',
            style: const TextStyle(fontSize: 10),
          ),
        ),
      ),
    ],
  );

  Widget _buildJoystickStatus() => IgnorePointer(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _btnGripActive
                  ? '✊ GRIP (AGARRE) ACTIVO'
                  : 'PUNTERO LÁSER (SLIDE 180° · HOLD GRIP)',
              style: const TextStyle(color: Color(0xFF10B981), fontSize: 8),
            ),
          ),
          Text(
            _status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60, fontSize: 9),
          ),
          if (_motionCapability != VrMotionCapability.available)
            Flexible(
              child: Text(
                _motionCapability == VrMotionCapability.checking
                    ? 'Comprobando giroscopio · controles táctiles disponibles'
                    : 'Sin giroscopio disponible · usa los controles táctiles',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.amber, fontSize: 9),
              ),
            ),
        ],
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
          key: const ValueKey('laser_slide_pad'),
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
                      painter: _LaserSlidePadPainter(
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
                                    ? 'GRIP ACTIVO'
                                    : (compact ? 'LÁSER' : '180° FRONTAL'),
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
                                  ? 'AGARRANDO'
                                  : 'DESLIZA · MANTÉN')
                            : _btnGripActive
                            ? '✊ GRIP (AGARRE) ACTIVO · ARRASTRA PARA MOVER'
                            : (_isLaserSlideActive
                                  ? 'APUNTANDO: (${(_laserSlideNormX * 90).toStringAsFixed(0)}°, ${(-_laserSlideNormY * 71).toStringAsFixed(0)}°)'
                                  : 'DESLIZA LÁSER · MANTÉN PRESIONADO PARA GRIP'),
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
                      'PUNTERO LÁSER 3D ACTIVO',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Mueve este teléfono en tu mano para apuntar en VR',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _recenterController,
                      icon: const Icon(Icons.gps_fixed_rounded, size: 14),
                      label: const Text(
                        'Recentrar Mira',
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
                  title: 'ATRÁS / HOME',
                  subtitle: 'Cerrar panel o volver',
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
                  title: 'GATILLO (CLIC)',
                  subtitle: 'Seleccionar pedestal',
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
                'NAV: (${_stickX.toStringAsFixed(1)}, ${_stickY.toStringAsFixed(1)}) | '
                'VISTA: (${_lookX.toStringAsFixed(1)}, ${_lookY.toStringAsFixed(1)}) | '
                'LÁSER: (${_laserStickX.toStringAsFixed(1)}, ${_laserStickY.toStringAsFixed(1)})',
                style: const TextStyle(
                  color: Color(0xFF00E5FF),
                  fontSize: 8.5,
                  fontFamily: 'Courier',
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

class _LaserSlidePadPainter extends CustomPainter {
  const _LaserSlidePadPainter({
    required this.normX,
    required this.normY,
    required this.isActive,
    this.isGrip = false,
  });

  final double normX;
  final double normY;
  final bool isActive;
  final bool isGrip;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.42;

    final baseColor = isGrip
        ? const Color(0xFFFF9100)
        : (isActive ? const Color(0xFF10B981) : const Color(0xFF00E5FF));

    final gridPaint = Paint()
      ..color = (isGrip ? const Color(0xFFFF9100) : const Color(0xFF10B981))
          .withValues(alpha: isGrip ? 0.25 : 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Concentric 180° / full radar circles
    canvas.drawCircle(center, radius * 0.33, gridPaint);
    canvas.drawCircle(center, radius * 0.66, gridPaint);
    canvas.drawCircle(center, radius, gridPaint);

    // Crosshairs
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      gridPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      gridPaint,
    );

    // Target reticle position
    final targetX = center.dx + normX * (size.width * 0.45);
    final targetY = center.dy + normY * (size.height * 0.45);
    final targetOffset = Offset(targetX, targetY);

    // Aiming beam line from center to touch point
    if (isActive || normX.abs() > 0.01 || normY.abs() > 0.01) {
      final beamPaint = Paint()
        ..color = baseColor.withValues(alpha: isActive ? 0.7 : 0.25)
        ..strokeWidth = isGrip ? 3.0 : 2.0
        ..style = PaintingStyle.stroke;
      canvas.drawLine(center, targetOffset, beamPaint);

      // Glow halo around reticle
      final glowPaint = Paint()
        ..color = baseColor.withValues(
          alpha: isGrip ? 0.5 : (isActive ? 0.35 : 0.15),
        )
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, isGrip ? 12 : 8);
      canvas.drawCircle(targetOffset, isGrip ? 18 : 14, glowPaint);

      // Reticle circle
      final reticlePaint = Paint()
        ..color = baseColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = isGrip ? 3.2 : 2.5;
      canvas.drawCircle(targetOffset, isGrip ? 10 : 8, reticlePaint);

      // Reticle center dot
      final dotPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill;
      canvas.drawCircle(targetOffset, isGrip ? 4 : 3, dotPaint);
    } else {
      // Resting center dot
      final restPaint = Paint()
        ..color = const Color(0xFF10B981).withValues(alpha: 0.5)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, 4, restPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _LaserSlidePadPainter oldDelegate) {
    return oldDelegate.normX != normX ||
        oldDelegate.normY != normY ||
        oldDelegate.isActive != isActive ||
        oldDelegate.isGrip != isGrip;
  }
}
