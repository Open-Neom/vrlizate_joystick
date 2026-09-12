import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate/vrlizate.dart'
    show
        VrRangeSource,
        VrRemoteBinaryCodec,
        VrRemotePoseFrame,
        VrRemotePosePredictor;

/// Controller operation mode.
enum RemoteControllerMode { joystick, laser }

/// Orientation, analog thumbstick and button state emitted by the remote smartphone controller.
class RemoteControllerState {
  final vm.Quaternion orientation;
  final vm.Vector3 angularVelocity;
  final bool isTriggerPressed;
  final bool isActionPressed;
  final bool btnA;
  final bool btnB;
  final bool btnX;
  final bool btnY;
  final bool btnL;
  final bool btnR;
  final bool btnGrip;
  final bool stickClick;
  final double stickX;
  final double stickY;
  final double touchX;
  final double touchY;
  final double turnRate;
  final double pitchRate;
  final double laserX;
  final double laserY;
  final bool recenter;
  final double? rangeMeters;
  final RemoteControllerMode mode;
  final DateTime timestamp;

  RemoteControllerState({
    required this.orientation,
    vm.Vector3? angularVelocity,
    this.isTriggerPressed = false,
    this.isActionPressed = false,
    this.btnA = false,
    this.btnB = false,
    this.btnX = false,
    this.btnY = false,
    this.btnL = false,
    this.btnR = false,
    this.btnGrip = false,
    this.stickClick = false,
    this.stickX = 0.0,
    this.stickY = 0.0,
    this.touchX = 0.0,
    this.touchY = 0.0,
    double turnRate = 0.0,
    double pitchRate = 0.0,
    double? lookX,
    double? lookY,
    this.laserX = 0.0,
    this.laserY = 0.0,
    this.recenter = false,
    this.rangeMeters,
    this.mode = RemoteControllerMode.joystick,
    DateTime? timestamp,
  }) : turnRate = lookX ?? turnRate,
       pitchRate = lookY ?? pitchRate,
       angularVelocity = angularVelocity ?? vm.Vector3.zero(),
       timestamp = timestamp ?? DateTime.now();

  double get lookX => turnRate;
  double get lookY => pitchRate;

  @override
  String toString() =>
      'RemoteControllerState(mode: ${mode.name}, stick: ($stickX, $stickY), '
      'turn: $turnRate, pitch: $pitchRate, laser: ($laserX, $laserY), recenter: $recenter, range: $rangeMeters, '
      'btnA: $btnA, btnB: $btnB, btnX: $btnX, btnY: $btnY, btnL: $btnL, btnR: $btnR, trigger: $isTriggerPressed, grip: $btnGrip)';
}

/// Server running inside VRlizate that turns any 2nd smartphone into a full VR Gamepad / 3DoF Controller.
///
/// Features:
/// 1. Hosts a local high-speed WebSocket & Web Controller portal on port 8080.
/// 2. Announces the visor on UDP 8081; pairing uses the secret in its QR/link.
/// 3. Accepts continuous 2D analog thumbstick deflection $(X, Y)$ for smooth 3D walking locomotion.
/// 4. Accepts 3DoF gyroscope orientation for laser raycast aiming.
/// 5. Ergonomic tactile buttons (Trigger, Action, A, B, Grip, Recenter).
///
/// The token prevents other LAN clients from injecting input without pairing.
/// HTTP/WebSocket are not encrypted: use a trusted local network. UDP discovery
/// is only a hint and never conveys authority or the pairing secret.
class VrRemoteControllerService {
  /// Silence releases held inputs even when Wi-Fi has not closed the socket.
  final Duration inputTimeout;
  final Duration watchdogInterval;

  /// Bearer secret shared by the QR and browser URL, never by UDP discovery.
  final String sessionToken;

  HttpServer? _server;
  RawDatagramSocket? _beaconSocket;
  Timer? _beaconTimer;
  Timer? _inputWatchdog;
  WebSocket? _client;
  final Stopwatch _clock = Stopwatch()..start();
  Future<bool>? _startOperation;
  bool _isRunning = false;
  bool _disposed = false;
  int _lifecycleGeneration = 0;
  String? _localIp;
  int _fallbackSequence = 0;
  int? _lastSequence;
  int? _lastStateReceivedUs;
  int _rateWindowStartUs = 0;
  int _rateWindowCount = 0;

  static const int _maxMessageCharacters = 4096;
  static const int _maxMessagesPerSecond = 240;

  VrRemoteControllerService({
    this.inputTimeout = const Duration(milliseconds: 500),
    this.watchdogInterval = const Duration(milliseconds: 100),
    String? sessionToken,
  }) : sessionToken = sessionToken ?? _createSessionToken() {
    if (inputTimeout <= Duration.zero || watchdogInterval <= Duration.zero) {
      throw ArgumentError(
        'Input timeout and watchdog interval must be positive.',
      );
    }
    if (this.sessionToken.isEmpty) {
      throw ArgumentError.value(
        sessionToken,
        'sessionToken',
        'Must not be empty.',
      );
    }
  }

  static String _createSessionToken() {
    final random = math.Random.secure();
    return base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256)));
  }

  final VrRemotePosePredictor _posePredictor = VrRemotePosePredictor();
  final vm.Quaternion _predictedOrientation = vm.Quaternion.identity();

  RemoteControllerState _latestState = RemoteControllerState(
    orientation: vm.Quaternion.identity(),
  );

  final StreamController<RemoteControllerState> _stateController =
      StreamController<RemoteControllerState>.broadcast();

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  Stream<RemoteControllerState> get onState => _stateController.stream;
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  bool get isConnected => _client != null;
  bool get isRunning => _isRunning;
  int? get serverPort => _server?.port;
  String? get serverUrl => _isRunning && _localIp != null
      ? Uri(
          scheme: 'http',
          host: _localIp,
          port: _server!.port,
          path: '/',
          queryParameters: {'token': sessionToken},
        ).toString()
      : null;
  String? get localIp => _localIp;
  RemoteControllerState get latestState => _latestState;

  /// Writes the latest latency-compensated controller pose into [out].
  ///
  /// Native controllers provide angular velocity for prediction. Browser
  /// controllers remain compatible and fall back to the received pose.
  bool predictOrientationTo(vm.Quaternion out) {
    if (!_posePredictor.predictTo(_predictedOrientation)) return false;
    out.setFrom(_predictedOrientation);
    return true;
  }

  /// Starts the local HTTP & WebSocket server and auto-discovery UDP beacon.
  Future<bool> startServer({int port = 8080}) {
    if (_disposed) return Future.value(false);
    if (_isRunning) return Future.value(true);
    final pending = _startOperation;
    if (pending != null) return pending;
    final operation = _startServer(port, _lifecycleGeneration);
    _startOperation = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_startOperation, operation)) _startOperation = null;
      }),
    );
    return operation;
  }

  Future<bool> _startServer(int port, int generation) async {
    try {
      // Find local Wi-Fi IP address
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            _localIp = addr.address;
            break;
          }
        }
        if (_localIp != null) break;
      }

      _localIp ??= '127.0.0.1';

      final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      if (_disposed || generation != _lifecycleGeneration) {
        await server.close(force: true);
        return false;
      }
      _server = server;
      _isRunning = true;
      debugPrint(
        '[VrRemoteControllerService] Server started on $_localIp:${server.port}',
      );

      server.listen(_handleHttpRequest);
      _inputWatchdog = Timer.periodic(watchdogInterval, (_) {
        final received = _lastStateReceivedUs;
        if (received != null &&
            _clock.elapsedMicroseconds - received >=
                inputTimeout.inMicroseconds) {
          _lastStateReceivedUs = null;
          _releaseInputs();
        }
      });

      // Start UDP auto-discovery beacon
      _startUdpBeacon(server.port, generation);

      return true;
    } catch (e) {
      debugPrint('[VrRemoteControllerService] Start error: $e');
      return false;
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    try {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final tokens = request.uri.queryParametersAll['token'];
        if (tokens == null ||
            tokens.length != 1 ||
            !_matchesToken(tokens.single)) {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        final generation = _lifecycleGeneration;
        final socket = await WebSocketTransformer.upgrade(request);
        if (!_isRunning || _disposed || generation != _lifecycleGeneration) {
          await socket.close(WebSocketStatus.goingAway);
          return;
        }
        _handleWebSocket(socket);
      } else {
        _serveWebController(request);
      }
    } catch (error) {
      debugPrint('[VrRemoteControllerService] Request failed: $error');
      await request.response.close();
    }
  }

  bool _matchesToken(String supplied) {
    var difference = supplied.length ^ sessionToken.length;
    for (var i = 0; i < sessionToken.length; i++) {
      difference |=
          sessionToken.codeUnitAt(i) ^
          (i < supplied.length ? supplied.codeUnitAt(i) : 0);
    }
    return difference == 0;
  }

  void _startUdpBeacon(int wsPort, int generation) {
    try {
      RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
          .then((socket) {
            if (!_isRunning || generation != _lifecycleGeneration) {
              socket.close();
              return;
            }
            _beaconSocket = socket;
            socket.broadcastEnabled = true;

            _beaconTimer = Timer.periodic(const Duration(milliseconds: 1500), (
              _,
            ) {
              if (!_isRunning || _localIp == null) return;
              try {
                final beaconData = jsonEncode({
                  'service': 'vrlizate_vr_host',
                  'port': wsPort,
                  'ip': _localIp,
                  'name': 'VRlizate Visor',
                  'requiresPairingToken': true,
                  'timestamp': DateTime.now().millisecondsSinceEpoch,
                });
                final bytes = utf8.encode(beaconData);
                socket.send(bytes, InternetAddress('255.255.255.255'), 8081);
              } catch (_) {}
            });
          })
          .catchError((e) {
            debugPrint('[VrRemoteControllerService] UDP Beacon bind error: $e');
          });
    } catch (e) {
      debugPrint('[VrRemoteControllerService] UDP Beacon setup error: $e');
    }
  }

  void _handleWebSocket(WebSocket socket) {
    // One controller owns the input state. A reconnect replaces it atomically;
    // late onDone/onError callbacks from the old socket cannot clear the new one.
    final previous = _client;
    _client = socket;
    _lastSequence = null;
    _fallbackSequence = 0;
    _lastStateReceivedUs = null;
    _rateWindowStartUs = _clock.elapsedMicroseconds;
    _rateWindowCount = 0;
    _releaseInputs();
    if (previous == null) _connectionController.add(true);
    unawaited(
      previous?.close(WebSocketStatus.normalClosure, 'Replaced by controller'),
    );
    socket.pingInterval = const Duration(seconds: 3);
    HapticFeedback.mediumImpact();
    debugPrint(
      '[VrRemoteControllerService] 2nd Smartphone controller connected!',
    );

    socket.listen(
      (data) {
        if (!identical(socket, _client) || _disposed) return;
        final now = _clock.elapsedMicroseconds;
        if (now - _rateWindowStartUs >= Duration.microsecondsPerSecond) {
          _rateWindowStartUs = now;
          _rateWindowCount = 0;
        }
        final bool isBinary =
            data is List<int> && VrRemoteBinaryCodec.isBinaryPacket(data);
        if (++_rateWindowCount > _maxMessagesPerSecond ||
            (!isBinary &&
                (data is! String || data.length > _maxMessageCharacters))) {
          _disconnectClient(socket);
          unawaited(
            socket.close(
              WebSocketStatus.policyViolation,
              'Input limit exceeded',
            ),
          );
          return;
        }
        if (isBinary) {
          try {
            final bytes =
                data is Uint8List ? data : Uint8List.fromList(data);
            final pose = const VrRemoteBinaryCodec().decodePose(bytes);
            if (_lastSequence != null && pose.sequence <= _lastSequence!) {
              return;
            }
            final buttons = pose.buttonsBitset;
            final bool trigger = (buttons & 0x0001) != 0;
            final bool action = (buttons & 0x0002) != 0;
            final bool btnA = (buttons & 0x0004) != 0 || trigger;
            final bool btnB = (buttons & 0x0008) != 0 || action;
            final bool btnGrip = (buttons & 0x0010) != 0;
            final bool stickClick = (buttons & 0x0020) != 0;

            double stickX = pose.touchX != null
                ? ((pose.touchX! * 2.0) - 1.0).clamp(-1.0, 1.0)
                : 0.0;
            double stickY = pose.touchY != null
                ? ((pose.touchY! * 2.0) - 1.0).clamp(-1.0, 1.0)
                : 0.0;
            if (stickX.abs() < 0.001) stickX = 0.0;
            if (stickY.abs() < 0.001) stickY = 0.0;

            _posePredictor.pushFrame(pose);
            _posePredictor.predictTo(_predictedOrientation);
            _lastSequence = pose.sequence;
            _lastStateReceivedUs = now;

            _latestState = RemoteControllerState(
              orientation: _predictedOrientation.clone(),
              angularVelocity: pose.angularVelocity,
              isTriggerPressed: trigger || btnA,
              isActionPressed: action || btnB,
              btnA: btnA,
              btnB: btnB,
              btnGrip: btnGrip,
              stickClick: stickClick,
              stickX: stickX,
              stickY: stickY,
              touchX: stickX,
              touchY: stickY,
              rangeMeters: pose.rangeMeters,
              mode: RemoteControllerMode.joystick,
            );

            _stateController.add(_latestState);
          } catch (_) {}
          return;
        }
        try {
          final decoded = jsonDecode(data as String);
          if (decoded is! Map<String, dynamic>) return;
          final json = decoded;
          final sequence = _optionalCounter(json, 'sequence');
          if (_lastSequence != null &&
              (sequence == null || sequence <= _lastSequence!)) {
            return;
          }
          final timestampUs = _optionalCounter(json, 'timestampUs');
          for (final key in const [
            'qx',
            'qy',
            'qz',
            'qw',
            'wx',
            'wy',
            'wz',
            'stickX',
            'stickY',
            'tx',
            'ty',
          ]) {
            final value = json[key];
            if (value != null && (value is! num || !value.isFinite)) {
              throw FormatException('Non-finite controller field: $key');
            }
          }
          for (final key in const ['wx', 'wy', 'wz']) {
            final value = json[key] as num?;
            // Far above a normal hand movement; protects prediction from
            // finite but physically implausible sensor spikes.
            if (value != null && value.abs() > 100) {
              throw FormatException('Angular velocity out of range: $key');
            }
          }
          final double qx = (json['qx'] as num?)?.toDouble() ?? 0.0;
          final double qy = (json['qy'] as num?)?.toDouble() ?? 0.0;
          final double qz = (json['qz'] as num?)?.toDouble() ?? 0.0;
          final double qw = (json['qw'] as num?)?.toDouble() ?? 1.0;
          final angularVelocity = vm.Vector3(
            (json['wx'] as num?)?.toDouble() ?? 0.0,
            (json['wy'] as num?)?.toDouble() ?? 0.0,
            (json['wz'] as num?)?.toDouble() ?? 0.0,
          );

          final bool trigger = json['trigger'] == true;
          final bool action = json['action'] == true;
          final bool btnA = json['btnA'] == true || trigger;
          final bool btnB = json['btnB'] == true || action;
          final bool btnX = json['btnX'] == true;
          final bool btnY = json['btnY'] == true;
          final bool btnL = json['btnL'] == true;
          final bool btnR = json['btnR'] == true;
          final bool btnGrip = json['btnGrip'] == true;
          final bool stickClick = json['stickClick'] == true;

          final double stickX = (json['stickX'] as num?)?.toDouble() ?? 0.0;
          final double stickY = (json['stickY'] as num?)?.toDouble() ?? 0.0;
          final double tx = (json['tx'] as num?)?.toDouble() ?? stickX;
          final double ty = (json['ty'] as num?)?.toDouble() ?? stickY;
          final double turnRate = (json['turn'] as num?)?.toDouble() ??
              (json['turnRate'] as num?)?.toDouble() ??
              (json['lookX'] as num?)?.toDouble() ??
              0.0;
          final double pitchRate = (json['pitchRate'] as num?)?.toDouble() ??
              (json['lookPitch'] as num?)?.toDouble() ??
              (json['lookY'] as num?)?.toDouble() ??
              0.0;
          final double laserX = (json['laserX'] as num?)?.toDouble() ??
              (json['aimX'] as num?)?.toDouble() ??
              0.0;
          final double laserY = (json['laserY'] as num?)?.toDouble() ??
              (json['aimY'] as num?)?.toDouble() ??
              0.0;
          final bool recenter = json['recenter'] == true;
          final double? rangeMeters = (json['rangeMeters'] as num?)?.toDouble() ??
              (json['range'] as num?)?.toDouble();

          final String modeStr = json['mode'] as String? ?? 'joystick';
          final mode = modeStr == 'laser'
              ? RemoteControllerMode.laser
              : RemoteControllerMode.joystick;

          final pose = VrRemotePoseFrame(
            sequence: sequence ?? _fallbackSequence++,
            senderTimestampMicroseconds:
                timestampUs ?? DateTime.now().microsecondsSinceEpoch,
            orientation: vm.Quaternion(qx, qy, qz, qw),
            angularVelocity: angularVelocity,
            rangeMeters: rangeMeters,
            rangeSource: rangeMeters != null ? VrRangeSource.fixed : null,
          );
          _posePredictor.pushFrame(pose);
          _posePredictor.predictTo(_predictedOrientation);
          _lastSequence = sequence ?? _lastSequence;
          _lastStateReceivedUs = now;

          _latestState = RemoteControllerState(
            orientation: _predictedOrientation.clone(),
            angularVelocity: angularVelocity,
            isTriggerPressed: trigger || btnA || btnL || btnR,
            isActionPressed: action || btnB,
            btnA: btnA,
            btnB: btnB,
            btnX: btnX,
            btnY: btnY,
            btnL: btnL,
            btnR: btnR,
            btnGrip: btnGrip,
            stickClick: stickClick,
            stickX: stickX.clamp(-1.0, 1.0),
            stickY: stickY.clamp(-1.0, 1.0),
            touchX: tx.clamp(-1.0, 1.0),
            touchY: ty.clamp(-1.0, 1.0),
            turnRate: turnRate.clamp(-1.0, 1.0),
            pitchRate: pitchRate.clamp(-1.0, 1.0),
            laserX: laserX.clamp(-1.0, 1.0),
            laserY: laserY.clamp(-1.0, 1.0),
            recenter: recenter,
            rangeMeters: rangeMeters,
            mode: mode,
          );

          _stateController.add(_latestState);
        } catch (_) {}
      },
      onDone: () => _disconnectClient(socket),
      onError: (_) => _disconnectClient(socket),
      cancelOnError: true,
    );
  }

  static int? _optionalCounter(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int || value < 0) throw FormatException('Invalid $key');
    return value;
  }

  void _disconnectClient(WebSocket socket) {
    if (!identical(socket, _client)) return;
    _client = null;
    _lastStateReceivedUs = null;
    _releaseInputs();
    if (!_disposed) _connectionController.add(false);
  }

  void _releaseInputs() {
    _posePredictor.reset();
    _latestState = RemoteControllerState(
      orientation: _latestState.orientation.clone(),
      mode: _latestState.mode,
    );
    if (!_disposed) _stateController.add(_latestState);
  }

  /// Serves the interactive Web Controller interface to any browser on the 2nd phone.
  void _serveWebController(HttpRequest request) {
    const html = '''<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>VRlizate Mando & Joystick VR</title>
  <style>
    * { box-sizing: border-box; touch-action: none; user-select: none; -webkit-user-select: none; }
    body {
      background: #080816;
      color: #00E5FF;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      margin: 0;
      padding: 12px;
      display: flex;
      flex-direction: column;
      height: 100vh;
      overflow: hidden;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-bottom: 8px;
      border-bottom: 1px solid rgba(0, 229, 255, 0.2);
    }
    .title { font-size: 16px; font-weight: bold; color: #00E5FF; letter-spacing: 1px; }
    .status { font-size: 11px; color: #10B981; font-weight: bold; }
    .tabs { display: flex; gap: 8px; margin: 10px 0; }
    .tab {
      flex: 1;
      padding: 8px;
      border-radius: 10px;
      border: 1px solid #00E5FF;
      background: #101528;
      color: #00E5FF;
      font-size: 12px;
      font-weight: bold;
      text-align: center;
      cursor: pointer;
    }
    .tab.active {
      background: #00E5FF;
      color: #080816;
    }
    .main-area {
      flex: 1;
      display: flex;
      gap: 12px;
      align-items: center;
      justify-content: space-around;
    }
    /* Joystick canvas */
    .stick-container {
      position: relative;
      width: 170px;
      height: 170px;
      background: #101528;
      border: 2px solid #00E5FF;
      border-radius: 50%;
      box-shadow: 0 0 20px rgba(0, 229, 255, 0.25);
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .stick-knob {
      position: absolute;
      width: 60px;
      height: 60px;
      border-radius: 50%;
      background: linear-gradient(135deg, #00E5FF, #7C4DFF);
      box-shadow: 0 0 15px #00E5FF;
      pointer-events: none;
      transform: translate(0px, 0px);
      transition: transform 0.05s ease-out;
    }
    /* Buttons cluster */
    .btn-cluster {
      display: flex;
      flex-direction: column;
      gap: 10px;
      width: 140px;
    }
    .game-btn {
      height: 52px;
      border-radius: 14px;
      border: none;
      font-size: 15px;
      font-weight: bold;
      color: white;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      box-shadow: 0 4px 12px rgba(0,0,0,0.5);
    }
    .btn-a { background: linear-gradient(135deg, #00E5FF, #7C4DFF); }
    .btn-b { background: linear-gradient(135deg, #FF007F, #FF9100); }
    .btn-grip { background: #1F293D; border: 1px solid #00E5FF; color: #00E5FF; }
    .game-btn:active { transform: scale(0.94); filter: brightness(1.3); }
    .telemetry {
      font-size: 11px;
      color: rgba(0, 229, 255, 0.6);
      text-align: center;
      padding: 6px;
    }
  </style>
</head>
<body>
  <div class="header">
    <div class="title">🎮 VRLIZATE MANDO</div>
    <div id="status" class="status">⚡ Conectando...</div>
  </div>

  <div class="tabs">
    <div id="tabJoy" class="tab active" onclick="setMode('joystick')">🕹️ JOYSTICK ANALÓGICO</div>
    <div id="tabLaser" class="tab" onclick="setMode('laser')">🎯 PUNTERO LÁSER 3D</div>
  </div>

  <div class="main-area">
    <!-- Joystick left side -->
    <div class="stick-container" id="stickBase">
      <div class="stick-knob" id="stickKnob"></div>
    </div>

    <!-- Buttons right side -->
    <div class="btn-cluster">
      <button id="btnA" class="game-btn btn-a">A · GATILLO</button>
      <button id="btnB" class="game-btn btn-b">B · ATRÁS / HOME</button>
      <button id="btnGrip" class="game-btn btn-grip">AGARRE / MENÚ</button>
    </div>
  </div>

  <div id="telemetry" class="telemetry">X: 0.00 | Y: 0.00 · Modo: Joystick</div>

  <script>
    let ws;
    let mode = 'joystick';
    let stickX = 0, stickY = 0;
    let btnA = false, btnB = false, btnGrip = false;
    let qx = 0, qy = 0, qz = 0, qw = 1;
    let sequence = 0;
    let lastPoseSentAt = 0;

    function setMode(newMode) {
      mode = newMode;
      document.getElementById('tabJoy').className = mode === 'joystick' ? 'tab active' : 'tab';
      document.getElementById('tabLaser').className = mode === 'laser' ? 'tab active' : 'tab';
      sendState();
    }

    function connect() {
      const token = new URLSearchParams(location.search).get('token');
      if (!token) {
        document.getElementById('status').innerText = 'Abre el enlace o QR del visor para vincular';
        document.getElementById('status').style.color = '#FF9100';
        return;
      }
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      ws = new WebSocket(proto + '//' + location.host + '/?token=' + encodeURIComponent(token));

      ws.onopen = () => {
        document.getElementById('status').innerText = '✅ CONECTADO AL VISOR';
        document.getElementById('status').style.color = '#10B981';
        sendState();
      };

      ws.onclose = () => {
        document.getElementById('status').innerText = '❌ Desconectado. Reconectando...';
        document.getElementById('status').style.color = '#FF007F';
        setTimeout(connect, 1000);
      };
    }
    connect();

    // Virtual Touch Joystick Handling
    const base = document.getElementById('stickBase');
    const knob = document.getElementById('stickKnob');
    const maxRadius = 55;
    let isTouching = false;

    function handleTouch(e) {
      e.preventDefault();
      const rect = base.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;
      const touch = e.touches ? e.touches[0] : e;
      const dx = touch.clientX - centerX;
      const dy = touch.clientY - centerY;
      const dist = Math.hypot(dx, dy);

      let clampedDx = dx, clampedDy = dy;
      if (dist > maxRadius) {
        clampedDx = (dx / dist) * maxRadius;
        clampedDy = (dy / dist) * maxRadius;
      }

      knob.style.transform = `translate(\${clampedDx}px, \${clampedDy}px)`;
      stickX = parseFloat((clampedDx / maxRadius).toFixed(2));
      stickY = parseFloat((-clampedDy / maxRadius).toFixed(2)); // Up is positive

      updateTelemetry();
      sendState();
    }

    function resetStick() {
      knob.style.transform = 'translate(0px, 0px)';
      stickX = 0; stickY = 0;
      updateTelemetry();
      sendState();
    }

    base.addEventListener('touchstart', (e) => { isTouching = true; handleTouch(e); if (navigator.vibrate) navigator.vibrate(15); });
    base.addEventListener('touchmove', (e) => { if (isTouching) handleTouch(e); });
    base.addEventListener('touchend', () => { isTouching = false; resetStick(); });
    base.addEventListener('touchcancel', () => { isTouching = false; resetStick(); });

    // Buttons
    function bindBtn(id, setVar) {
      const el = document.getElementById(id);
      el.addEventListener('pointerdown', (e) => { el.setPointerCapture(e.pointerId); setVar(true); sendState(); if (navigator.vibrate) navigator.vibrate(25); });
      el.addEventListener('pointerup', () => { setVar(false); sendState(); });
      el.addEventListener('pointercancel', () => { setVar(false); sendState(); });
      el.addEventListener('lostpointercapture', () => { setVar(false); sendState(); });
    }
    bindBtn('btnA', (v) => btnA = v);
    bindBtn('btnB', (v) => btnB = v);
    bindBtn('btnGrip', (v) => btnGrip = v);

    // Gyroscope
    if (window.DeviceOrientationEvent) {
      window.addEventListener('deviceorientation', (e) => {
        const alpha = (e.alpha || 0) * Math.PI / 180;
        const beta = (e.beta || 0) * Math.PI / 180;
        const gamma = (e.gamma || 0) * Math.PI / 180;

        const c1 = Math.cos(alpha / 2), s1 = Math.sin(alpha / 2);
        const c2 = Math.cos(beta / 2), s2 = Math.sin(beta / 2);
        const c3 = Math.cos(gamma / 2), s3 = Math.sin(gamma / 2);

        qw = c1 * c2 * c3 - s1 * s2 * s3;
        qx = s1 * s2 * c3 + c1 * c2 * s3;
        qy = s1 * c2 * c3 + c1 * s2 * s3;
        qz = c1 * s2 * c3 - s1 * c2 * s3;

        const now = performance.now();
        if (mode === 'laser' && now - lastPoseSentAt >= 16) {
          lastPoseSentAt = now;
          sendState();
        }
      });
    }

    function updateTelemetry() {
      document.getElementById('telemetry').innerText =
        `X: \${stickX > 0 ? '+' : ''}\${stickX.toFixed(2)} | Y: \${stickY > 0 ? '+' : ''}\${stickY.toFixed(2)} · Modo: \${mode}`;
    }

    function sendState() {
      if (ws && ws.readyState === WebSocket.OPEN && ws.bufferedAmount < 4096) {
        ws.send(JSON.stringify({
          mode,
          stickX,
          stickY,
          btnA,
          btnB,
          btnGrip,
          trigger: btnA,
          action: btnB,
          qx, qy, qz, qw,
          wx: 0, wy: 0, wz: 0,
          sequence: sequence++,
          timestampUs: Date.now() * 1000,
        }));
      }
    }

    function releaseInputs() {
      btnA = false; btnB = false; btnGrip = false;
      isTouching = false;
      resetStick();
    }
    window.addEventListener('blur', releaseInputs);
    window.addEventListener('pagehide', releaseInputs);
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) releaseInputs();
    });
    // Refresh held state without depending on motion events. If this page is
    // suspended, the visor's independent watchdog releases movement/buttons.
    setInterval(() => { if (!document.hidden) sendState(); }, 100);
  </script>
</body>
</html>''';

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set(HttpHeaders.cacheControlHeader, 'no-store')
      ..headers.set('Referrer-Policy', 'no-referrer')
      ..write(html)
      ..close();
  }

  void stop() {
    _lifecycleGeneration++;
    _startOperation = null;
    _isRunning = false;
    _inputWatchdog?.cancel();
    _inputWatchdog = null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _beaconSocket?.close();
    _beaconSocket = null;
    final client = _client;
    if (client != null) {
      _disconnectClient(client);
      unawaited(client.close(WebSocketStatus.goingAway));
    }
    unawaited(_server?.close(force: true));
    _server = null;
    _localIp = null;
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    _clock.stop();
    _stateController.close();
    _connectionController.close();
  }
}
