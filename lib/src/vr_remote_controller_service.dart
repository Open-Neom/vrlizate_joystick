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

import 'vr_controller_mode.dart';
import 'vr_controller_mode_protocol.dart';
import 'vr_local_network_address.dart';
import 'vr_controller_link.dart';

export 'vr_controller_mode.dart';

enum _ControllerWireFormat { json, binaryPose }

/// Local reasons only; never contains transport URLs, tokens or error text.
enum VrControllerDisconnectReason {
  connectionClosed,
  transportError,
  inputLimitExceeded,
  replaced,
  serviceStopped,
}

/// A cheap, immutable snapshot of receiver-side controller health.
///
/// Counters accumulate for the service's lifetime, including reconnects.
/// [inputAge] uses only the visor's monotonic clock: it is time since the last
/// accepted state on the current link, not network latency or remote clock age.
@immutable
class VrControllerTelemetry {
  const VrControllerTelemetry({
    required this.isConnected,
    required this.inputAge,
    required this.acceptedStates,
    required this.rejectedStates,
    required this.watchdogNeutralizations,
    required this.lastDisconnectReason,
  });

  final bool isConnected;
  final Duration? inputAge;
  final int acceptedStates;
  final int rejectedStates;
  final int watchdogNeutralizations;
  final VrControllerDisconnectReason? lastDisconnectReason;
}

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

  /// True only while a finger owns the head-relative touch aiming pad.
  final bool laserSlideActive;
  final bool recenter;

  /// Desired visibility of the viewer's controller feedback, not a toggle edge.
  /// Defaults visible for older clients. Safety releases preserve this setting;
  /// a new connection starts visible until its first complete JSON snapshot.
  final bool controllerVisible;

  /// Driving-only controls; positive steering turns right. Legacy defaults 0.
  final double steering;
  final double throttle;
  final double brake;
  final bool drivingPaused;

  /// Reports recent valid gyro samples, not whether the user chose gyro input.
  /// Legacy clients and released/timed-out states report false.
  final bool motionAvailable;

  /// Receiver-generated safety release (timeout, disconnect or replacement).
  /// Never accepted from the wire; hosts should require fresh neutral input.
  final bool isNeutralized;
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
    this.laserSlideActive = false,
    this.recenter = false,
    this.controllerVisible = true,
    this.steering = 0,
    this.throttle = 0,
    this.brake = 0,
    this.drivingPaused = false,
    this.motionAvailable = false,
    this.isNeutralized = false,
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
      'turn: $turnRate, pitch: $pitchRate, laser: ($laserX, $laserY), slide: $laserSlideActive, recenter: $recenter, range: $rangeMeters, '
      'btnA: $btnA, btnB: $btnB, btnX: $btnX, btnY: $btnY, btnL: $btnL, btnR: $btnR, trigger: $isTriggerPressed, grip: $btnGrip)';
}

/// Server for a compatible secondary smartphone's touch or 3DoF controller.
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
  VrControllerLink? _client;
  StreamSubscription<Object?>? _clientSubscription;
  final Stopwatch _clock = Stopwatch()..start();
  final int Function()? _nowMicroseconds;
  Future<bool>? _startOperation;
  bool _isRunning = false;
  bool _disposed = false;
  int _lifecycleGeneration = 0;
  String? _localIp;
  int _addressRefreshGeneration = 0;
  final Future<Iterable<VrLocalAddressCandidate>> Function()
  _localAddressCandidates;
  int _fallbackSequence = 0;
  int? _lastSequence;
  _ControllerWireFormat? _wireFormat;
  int? _lastStateReceivedUs;
  int? _lastAcceptedStateUs;
  int _acceptedStates = 0;
  int _rejectedStates = 0;
  int _watchdogNeutralizations = 0;
  VrControllerDisconnectReason? _lastDisconnectReason;
  int _rateWindowStartUs = 0;
  int _rateWindowCount = 0;
  VrControllerModeRequest _modeRequest = const VrControllerModeRequest(
    mode: RemoteControllerMode.joystick,
    revision: 0,
  );
  int? _acceptedModeRevision;
  bool _modeControlSupported = false;

  static const int _maxMessageCharacters = 4096;
  static const int _maxMessagesPerSecond = 240;

  VrRemoteControllerService({
    this.inputTimeout = const Duration(milliseconds: 500),
    this.watchdogInterval = const Duration(milliseconds: 100),
    String? sessionToken,
    @visibleForTesting
    Future<Iterable<VrLocalAddressCandidate>> Function()?
    localAddressCandidates,
    @visibleForTesting int Function()? nowMicroseconds,
  }) : sessionToken = sessionToken ?? _createSessionToken(),
       _nowMicroseconds = nowMicroseconds,
       _localAddressCandidates =
           localAddressCandidates ?? _systemLocalAddressCandidates {
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

  int get _nowUs => _nowMicroseconds?.call() ?? _clock.elapsedMicroseconds;

  VrControllerTelemetry get telemetry {
    final received = _lastAcceptedStateUs;
    return VrControllerTelemetry(
      isConnected: isConnected,
      inputAge: received == null
          ? null
          : Duration(microseconds: math.max(0, _nowUs - received)),
      acceptedStates: _acceptedStates,
      rejectedStates: _rejectedStates,
      watchdogNeutralizations: _watchdogNeutralizations,
      lastDisconnectReason: _lastDisconnectReason,
    );
  }

  RemoteControllerMode get recommendedMode => _modeRequest.mode;

  /// Requests a controller layout for the active app, optionally with what
  /// each button does there ([actions], keyed `A`/`B`/`X`/`Y`/`L`/`R`/`GRIP`)
  /// so the phone can caption its keys. Reconnecting receives the current
  /// recommendation again. Older clients may ignore this message; modern
  /// clients acknowledge a neutral full state before controls resume.
  ///
  /// A caption-only change (same mode, new actions) is sent without releasing
  /// held inputs: it is a relabel, not a layout swap.
  void requestControllerMode(
    RemoteControllerMode mode, {
    Map<String, String> actions = const {},
  }) {
    if (mode == RemoteControllerMode.laser) {
      throw ArgumentError.value(
        mode,
        'mode',
        'Use joystick with its aiming pad.',
      );
    }
    if (_disposed) return;
    final clean = VrControllerModeRequest.sanitizeActions(actions);
    final sameMode = mode == _modeRequest.mode;
    if (sameMode && _sameActions(clean, _modeRequest.actions)) return;
    _modeRequest = VrControllerModeRequest(
      mode: mode,
      revision: _modeRequest.revision + 1,
      actions: clean,
    );
    if (!sameMode) _releaseInputs();
    _sendControllerMode();
  }

  static bool _sameActions(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _sendControllerMode() {
    final client = _client;
    if (client == null || _disposed) return;
    try {
      client.add(jsonEncode(_modeRequest.toJson()));
    } catch (_) {
      _disconnectClient(
        client,
        reason: VrControllerDisconnectReason.transportError,
      );
    }
  }

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
      await refreshLocalAddress();
      if (_disposed || generation != _lifecycleGeneration) return false;

      final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      if (_disposed || generation != _lifecycleGeneration) {
        await server.close(force: true);
        return false;
      }
      _server = server;
      _isRunning = true;
      debugPrint(
        '[VrRemoteControllerService] Server started on '
        '${_localIp ?? "no suitable LAN address"}:${server.port}',
      );

      server.listen(_handleHttpRequest);
      _ensureInputWatchdog();

      // Start UDP auto-discovery beacon
      _startUdpBeacon(server.port, generation);

      return true;
    } catch (e) {
      debugPrint('[VrRemoteControllerService] Start error: $e');
      return false;
    }
  }

  /// Refreshes the address advertised by QR/UDP without replacing the server,
  /// session token or connected controller. Call before showing a fresh QR.
  ///
  /// Returns whether a suitable local address was found. On failure [localIp]
  /// and [serverUrl] become null: never advertise loopback, cellular or VPN as
  /// a phone-to-phone destination. A running socket can remain available while
  /// Wi-Fi reconnects; this method does not restart it or claim reachability.
  Future<bool> refreshLocalAddress() async {
    if (_disposed) return false;
    final lifecycle = _lifecycleGeneration;
    final refresh = ++_addressRefreshGeneration;
    String? selected;
    try {
      selected = VrLocalNetworkAddress.select(await _localAddressCandidates());
    } catch (_) {
      // Fail closed; retaining an old address would generate a misleading QR.
    }
    if (_disposed ||
        lifecycle != _lifecycleGeneration ||
        refresh != _addressRefreshGeneration) {
      return false;
    }
    _localIp = selected;
    return selected != null;
  }

  static Future<Iterable<VrLocalAddressCandidate>>
  _systemLocalAddressCandidates() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          VrLocalAddressCandidate(interface.name, address.address),
    ];
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
        socket.pingInterval = const Duration(seconds: 3);
        final link = VrWebSocketControllerLink(socket);
        if (!attachControllerLink(link, sessionToken: tokens.single)) {
          await link.close(WebSocketStatus.goingAway);
        }
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

  /// Attaches a connected duplex channel using this visor's pairing secret.
  ///
  /// Returns false without taking ownership when authentication fails, the
  /// link is closed, or this service is disposed. On true the service owns the
  /// link, replacing/closing the previous controller. Reattaching the same link
  /// is idempotent. HTTP startup is not required for BLE/external transports.
  /// The link feeds the same validated protocol, watchdog and mode handshake
  /// as WebSocket. The external provider still owns secure peer negotiation.
  bool attachControllerLink(
    VrControllerLink link, {
    required String sessionToken,
  }) {
    if (_disposed || !link.isOpen || !_matchesToken(sessionToken)) return false;
    if (identical(link, _client)) return true;
    _handleControllerLink(link);
    return true;
  }

  void _ensureInputWatchdog() {
    _inputWatchdog ??= Timer.periodic(watchdogInterval, (_) {
      final received = _lastStateReceivedUs;
      if (received != null &&
          _nowUs - received >= inputTimeout.inMicroseconds) {
        _lastStateReceivedUs = null;
        _watchdogNeutralizations++;
        _releaseInputs();
      }
    });
  }

  static Future<void> _closeLink(
    VrControllerLink link, [
    int? code,
    String? reason,
  ]) async {
    try {
      await link.close(code, reason);
    } catch (_) {
      // Transport teardown errors must not revive or poison another session.
    }
  }

  void _handleControllerLink(VrControllerLink socket) {
    // One controller owns the input state. A reconnect replaces it atomically;
    // late onDone/onError callbacks from the old socket cannot clear the new one.
    final previous = _client;
    _clientSubscription?.cancel();
    _clientSubscription = null;
    _client = socket;
    _ensureInputWatchdog();
    _lastSequence = null;
    _wireFormat = null;
    _fallbackSequence = 0;
    _lastStateReceivedUs = null;
    _lastAcceptedStateUs = null;
    _rateWindowStartUs = _nowUs;
    _rateWindowCount = 0;
    _acceptedModeRevision = null;
    _modeControlSupported = false;
    _releaseInputs(controllerVisible: true);
    if (previous == null) _connectionController.add(true);
    if (previous != null) {
      _lastDisconnectReason = VrControllerDisconnectReason.replaced;
      unawaited(
        _closeLink(
          previous,
          WebSocketStatus.normalClosure,
          'Replaced by controller',
        ),
      );
    }
    HapticFeedback.mediumImpact();
    debugPrint(
      '[VrRemoteControllerService] 2nd Smartphone controller connected!',
    );

    _clientSubscription = socket.messages.listen(
      (data) {
        if (!identical(socket, _client) || _disposed) return;
        final now = _nowUs;
        if (now - _rateWindowStartUs >= Duration.microsecondsPerSecond) {
          _rateWindowStartUs = now;
          _rateWindowCount = 0;
        }
        final bool isBinary =
            data is List<int> && VrRemoteBinaryCodec.isBinaryPacket(data);
        if (++_rateWindowCount > _maxMessagesPerSecond ||
            (isBinary
                ? data.length > VrRemoteBinaryCodec.posePacketLength
                : (data is! String || data.length > _maxMessageCharacters))) {
          _rejectedStates++;
          _disconnectClient(
            socket,
            closeCode: WebSocketStatus.policyViolation,
            closeReason: 'Input limit exceeded',
            reason: VrControllerDisconnectReason.inputLimitExceeded,
          );
          return;
        }
        if (isBinary) {
          if (_wireFormat == _ControllerWireFormat.json) {
            _rejectedStates++;
            return;
          }
          try {
            final bytes = data is Uint8List ? data : Uint8List.fromList(data);
            final pose = const VrRemoteBinaryCodec().decodePose(bytes);
            if (_lastSequence != null) {
              // Serial-number arithmetic: duplicates, stale frames and the
              // ambiguous half-range are rejected, including around 65535→0.
              final advance = (pose.sequence - _lastSequence!) & 0xFFFF;
              if (advance == 0 || advance >= 0x8000) {
                _rejectedStates++;
                return;
              }
            }
            final buttons = pose.buttonsBitset;
            final bool trigger = (buttons & 0x0001) != 0;
            final bool action = (buttons & 0x0002) != 0;
            final bool btnA = (buttons & 0x0004) != 0;
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
            _wireFormat = _ControllerWireFormat.binaryPose;
            _lastStateReceivedUs = now;

            _latestState = RemoteControllerState(
              orientation: _predictedOrientation.clone(),
              angularVelocity: pose.angularVelocity,
              isTriggerPressed: trigger,
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

            _lastAcceptedStateUs = now;
            _acceptedStates++;
            _stateController.add(_latestState);
          } catch (_) {
            _rejectedStates++;
          }
          return;
        }
        if (_wireFormat == _ControllerWireFormat.binaryPose) {
          _rejectedStates++;
          return;
        }
        try {
          final decoded = jsonDecode(data as String);
          if (decoded is! Map<String, dynamic>) {
            _rejectedStates++;
            return;
          }
          final json = decoded;
          final sequence = _optionalCounter(json, 'sequence');
          if (_lastSequence != null &&
              (sequence == null || sequence <= _lastSequence!)) {
            _rejectedStates++;
            return;
          }
          final timestampUs = _optionalCounter(json, 'timestampUs');
          for (final key in const [
            'laserSlideActive',
            'drivingPaused',
            'motionAvailable',
            'controllerVisible',
          ]) {
            if (json.containsKey(key) && json[key] is! bool) {
              throw FormatException('$key must be a boolean.');
            }
          }
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
            'turn',
            'turnRate',
            'lookX',
            'pitchRate',
            'lookPitch',
            'lookY',
            'laserX',
            'laserY',
            'aimX',
            'aimY',
            'steering',
            'throttle',
            'brake',
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
          final bool btnA = json['btnA'] == true;
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
          final double turnRate =
              (json['turn'] as num?)?.toDouble() ??
              (json['turnRate'] as num?)?.toDouble() ??
              (json['lookX'] as num?)?.toDouble() ??
              0.0;
          final double pitchRate =
              (json['pitchRate'] as num?)?.toDouble() ??
              (json['lookPitch'] as num?)?.toDouble() ??
              (json['lookY'] as num?)?.toDouble() ??
              0.0;
          final double laserX =
              (json['laserX'] as num?)?.toDouble() ??
              (json['aimX'] as num?)?.toDouble() ??
              0.0;
          final double laserY =
              (json['laserY'] as num?)?.toDouble() ??
              (json['aimY'] as num?)?.toDouble() ??
              0.0;
          final bool recenter = json['recenter'] == true;
          final double? rangeMeters =
              (json['rangeMeters'] as num?)?.toDouble() ??
              (json['range'] as num?)?.toDouble();

          final String modeStr = json['mode'] as String? ?? 'joystick';
          final mode = switch (modeStr) {
            'laser' => RemoteControllerMode.laser,
            'driving' => RemoteControllerMode.driving,
            _ => RemoteControllerMode.joystick,
          };
          final drivingPaused = json['drivingPaused'] == true;
          final hostModeRevision = _optionalCounter(json, 'hostModeRevision');
          if (!_acceptsModeState(json, hostModeRevision, mode)) {
            _rejectedStates++;
            return;
          }
          final drivingActive =
              mode == RemoteControllerMode.driving && !drivingPaused;
          double drivingAxis(String key, double min) => drivingActive
              ? ((json[key] as num?)?.toDouble() ?? 0).clamp(min, 1.0)
              : 0;

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
          _wireFormat = _ControllerWireFormat.json;
          _lastStateReceivedUs = now;
          if (hostModeRevision != null) {
            _modeControlSupported = true;
            _acceptedModeRevision = hostModeRevision;
          }

          _latestState = RemoteControllerState(
            orientation: _predictedOrientation.clone(),
            angularVelocity: angularVelocity,
            isTriggerPressed: trigger || btnR,
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
            laserSlideActive: json['laserSlideActive'] == true,
            recenter: recenter,
            controllerVisible: json['controllerVisible'] as bool? ?? true,
            steering: drivingAxis('steering', -1),
            throttle: drivingAxis('throttle', 0),
            brake: drivingAxis('brake', 0),
            drivingPaused: drivingPaused,
            motionAvailable: json['motionAvailable'] == true,
            rangeMeters: rangeMeters,
            mode: mode,
          );

          _lastAcceptedStateUs = now;
          _acceptedStates++;
          _stateController.add(_latestState);
        } catch (_) {
          _rejectedStates++;
        }
      },
      onDone: () => _disconnectClient(socket),
      onError: (_) => _disconnectClient(
        socket,
        reason: VrControllerDisconnectReason.transportError,
      ),
      cancelOnError: true,
    );
    _sendControllerMode();
  }

  bool _acceptsModeState(
    Map<String, dynamic> json,
    int? revision,
    RemoteControllerMode mode,
  ) {
    // Legacy controller states retain compatibility until this socket opts in.
    if (revision == null) return !_modeControlSupported;
    if (revision != _modeRequest.revision) return false;
    if (_acceptedModeRevision == revision) return true;
    if (mode != _modeRequest.mode) return false;
    if (mode == RemoteControllerMode.driving && json['drivingPaused'] != true) {
      return false;
    }
    for (final key in const [
      'trigger',
      'action',
      'btnA',
      'btnB',
      'btnX',
      'btnY',
      'btnL',
      'btnR',
      'btnGrip',
      'stickClick',
      'laserSlideActive',
      'recenter',
    ]) {
      if (json[key] == true) return false;
    }
    for (final key in const [
      'stickX',
      'stickY',
      'tx',
      'ty',
      'turn',
      'turnRate',
      'lookX',
      'pitchRate',
      'lookPitch',
      'lookY',
      'laserX',
      'laserY',
      'aimX',
      'aimY',
      'steering',
      'throttle',
      'brake',
    ]) {
      if (json[key] != null && json[key] != 0) return false;
    }
    return true;
  }

  static int? _optionalCounter(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int || value < 0) throw FormatException('Invalid $key');
    return value;
  }

  void _disconnectClient(
    VrControllerLink socket, {
    int? closeCode,
    String? closeReason,
    VrControllerDisconnectReason reason =
        VrControllerDisconnectReason.connectionClosed,
  }) {
    if (!identical(socket, _client)) return;
    _lastDisconnectReason = reason;
    _client = null;
    _clientSubscription?.cancel();
    _clientSubscription = null;
    unawaited(_closeLink(socket, closeCode, closeReason));
    _lastStateReceivedUs = null;
    _lastAcceptedStateUs = null;
    _releaseInputs();
    if (!_disposed) _connectionController.add(false);
  }

  void _releaseInputs({bool? controllerVisible}) {
    _posePredictor.reset();
    _latestState = RemoteControllerState(
      orientation: _latestState.orientation.clone(),
      mode: _latestState.mode,
      drivingPaused: _latestState.mode == RemoteControllerMode.driving,
      isNeutralized: true,
      controllerVisible: controllerVisible ?? _latestState.controllerVisible,
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
    <button id="feedbackToggle" class="tab" aria-pressed="true">Ocultar mando en visor</button>
    <div id="status" class="status">⚡ Conectando...</div>
  </div>

  <div class="tabs">
    <div id="tabJoy" class="tab active" onclick="setMode('joystick')">🕹️ JOYSTICK ANALÓGICO</div>
    <div id="modeHint" class="tab">La app activa el volante</div>
  </div>

  <div class="main-area">
    <!-- Joystick left side -->
    <div class="stick-container" id="stickBase">
      <div class="stick-knob" id="stickKnob"></div>
    </div>

    <!-- Buttons right side -->
    <div class="btn-cluster">
      <button id="btnA" class="game-btn btn-a">A · ELEGIR / OK</button>
      <button id="btnB" class="game-btn btn-b">B · ATRÁS / HOME</button>
      <button id="btnGrip" class="game-btn btn-grip">AGARRE / MENÚ</button>
      <div id="driveControls" style="display:none">
        <button id="driveToggle" class="game-btn btn-a">CONTINUAR (A)</button>
        <button id="btnThrottle" class="game-btn btn-a">R · ACELERAR</button>
        <button id="btnBrake" class="game-btn btn-b">L · FRENAR</button>
      </div>
    </div>
  </div>

  <div id="telemetry" class="telemetry">X: 0.00 | Y: 0.00 · Modo: Joystick</div>

  <script>
    let ws;
    let mode = 'joystick';
    let stickX = 0, stickY = 0;
    let btnA = false, btnB = false, btnGrip = false;
    const qx = 0, qy = 0, qz = 0, qw = 1;
    let controllerVisible = true;
    let sequence = 0;
    let hostModeRevision = null;
    let drivingPaused = true, throttleHeld = false, brakeHeld = false;
    let drivePulse = null;
    const buttonPointers = new Map();

    // Host captions for the buttons this layout has (A, B, grip). Text only
    // via innerText, known keys only, capped like the native client.
    const defaultCaptions = { A: 'ELEGIR / OK', B: 'ATRÁS / HOME', GRIP: 'AGARRE / MENÚ' };
    function applyActions(actions) {
      const clean = {};
      if (actions && typeof actions === 'object') {
        for (const key of ['A', 'B', 'GRIP']) {
          const value = actions[key];
          if (typeof value === 'string' && value.trim()) clean[key] = value.trim().slice(0, 24);
        }
      }
      document.getElementById('btnA').innerText = 'A · ' + (clean.A || defaultCaptions.A).toUpperCase();
      document.getElementById('btnB').innerText = 'B · ' + (clean.B || defaultCaptions.B).toUpperCase();
      document.getElementById('btnGrip').innerText = (clean.GRIP || defaultCaptions.GRIP).toUpperCase();
    }
    function setMode(newMode) {
      if (newMode !== 'joystick' && newMode !== 'driving') return;
      releaseInputs(false);
      mode = newMode;
      updateModeUi();
      sendState();
    }

    function updateModeUi() {
      const driving = mode === 'driving';
      document.getElementById('tabJoy').className = mode === 'joystick' ? 'tab active' : 'tab';
      document.getElementById('modeHint').innerText = driving ? 'Volante táctil · desliza izquierda/derecha' : 'La app activa el volante';
      document.getElementById('driveControls').style.display = driving ? 'block' : 'none';
      document.getElementById('btnA').style.display = 'flex';
      document.getElementById('btnGrip').style.display = driving ? 'none' : 'flex';
      document.getElementById('driveToggle').innerText = drivingPaused ? 'CONTINUAR (A)' : 'PAUSA';
      updateTelemetry();
    }

    function connect() {
      const token = new URLSearchParams(location.search).get('token');
      if (!token) {
        document.getElementById('status').innerText = 'Abre el enlace o QR del visor para vincular';
        document.getElementById('status').style.color = '#FF9100';
        return;
      }
      const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const socket = new WebSocket(proto + '//' + location.host + '/?token=' + encodeURIComponent(token));
      ws = socket;
      hostModeRevision = null;

      socket.onopen = () => {
        if (ws !== socket) return;
        setMode('joystick');
        document.getElementById('status').innerText = '✅ CONECTADO AL VISOR';
        document.getElementById('status').style.color = '#10B981';
        sendState();
      };

      socket.onmessage = (event) => {
        if (ws !== socket || typeof event.data !== 'string' || event.data.length > 4096) return;
        let request;
        try { request = JSON.parse(event.data); } catch (_) { return; }
        if (!request || request.type !== 'vrlizate.controllerMode' || request.version !== 1 ||
            !Number.isSafeInteger(request.revision) || request.revision < 0 ||
            (request.mode !== 'joystick' && request.mode !== 'driving') ||
            (hostModeRevision !== null && request.revision <= hostModeRevision)) return;
        hostModeRevision = request.revision;
        setMode(request.mode); // First ACK is always fully released/paused.
        applyActions(request.actions);
      };

      socket.onclose = () => {
        if (ws !== socket) return;
        releaseInputs(false);
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

    function resetStick(send = true) {
      knob.style.transform = 'translate(0px, 0px)';
      stickX = 0; stickY = 0;
      updateTelemetry();
      if (send) sendState();
    }

    base.addEventListener('touchstart', (e) => { isTouching = true; handleTouch(e); if (navigator.vibrate) navigator.vibrate(15); });
    base.addEventListener('touchmove', (e) => { if (isTouching) handleTouch(e); });
    base.addEventListener('touchend', () => { isTouching = false; resetStick(); });
    base.addEventListener('touchcancel', () => { isTouching = false; resetStick(); });

    // Buttons
    function bindBtn(id, setVar) {
      const el = document.getElementById(id);
      el.addEventListener('pointerdown', (e) => {
        if (buttonPointers.has(id)) return;
        buttonPointers.set(id, e.pointerId);
        el.setPointerCapture(e.pointerId); setVar(true); sendState();
        if (navigator.vibrate) navigator.vibrate(25);
      });
      function release(e) {
        if (buttonPointers.get(id) !== e.pointerId) return;
        buttonPointers.delete(id); setVar(false); sendState();
      }
      el.addEventListener('pointerup', release);
      el.addEventListener('pointercancel', release);
      el.addEventListener('lostpointercapture', release);
    }
    bindBtn('btnA', (v) => {
      btnA = v;
      if (v && mode === 'driving') {
        throttleHeld = false; brakeHeld = false; drivingPaused = false;
        updateModeUi();
      }
    });
    bindBtn('btnB', (v) => btnB = v);
    bindBtn('btnGrip', (v) => btnGrip = v);
    bindBtn('btnThrottle', (v) => throttleHeld = v && mode === 'driving' && !drivingPaused);
    bindBtn('btnBrake', (v) => brakeHeld = v && mode === 'driving' && !drivingPaused);
    document.getElementById('driveToggle').addEventListener('click', () => {
      if (mode !== 'driving') return;
      if (!drivingPaused) { releaseInputs(); return; }
      releaseInputs(false);
      drivingPaused = false; btnA = true;
      updateModeUi(); sendState();
      drivePulse = setTimeout(() => { btnA = false; drivePulse = null; sendState(); }, 150);
    });

    // Browser fallback is touch-only; do not turn device pose into laser aim.
    document.getElementById('feedbackToggle').addEventListener('click', () => {
      controllerVisible = !controllerVisible;
      const button = document.getElementById('feedbackToggle');
      button.innerText = controllerVisible ? 'Ocultar mando en visor' : 'Mostrar mando en visor';
      button.setAttribute('aria-pressed', String(controllerVisible));
      sendState();
    });

    function updateTelemetry() {
      document.getElementById('telemetry').innerText =
        `X: \${stickX > 0 ? '+' : ''}\${stickX.toFixed(2)} | Y: \${stickY > 0 ? '+' : ''}\${stickY.toFixed(2)} · Modo: \${mode}`;
    }

    function sendState() {
      if (ws && ws.readyState === WebSocket.OPEN && ws.bufferedAmount < 4096) {
        ws.send(JSON.stringify({
          mode,
          hostModeRevision,
          stickX: mode === 'driving' ? 0 : stickX,
          stickY: mode === 'driving' ? 0 : stickY,
          btnA,
          btnB,
          btnGrip,
          btnR: throttleHeld,
          btnL: brakeHeld,
          controllerVisible,
          trigger: throttleHeld,
          action: btnB,
          steering: mode === 'driving' && !drivingPaused ? stickX : 0,
          throttle: mode === 'driving' && !drivingPaused && throttleHeld && !brakeHeld ? 1 : 0,
          brake: mode === 'driving' && !drivingPaused && brakeHeld ? 1 : 0,
          drivingPaused: mode === 'driving' && drivingPaused,
          qx, qy, qz, qw,
          wx: 0, wy: 0, wz: 0,
          sequence: sequence++,
          timestampUs: Date.now() * 1000,
        }));
      }
    }

    function releaseInputs(send = true) {
      btnA = false; btnB = false; btnGrip = false;
      throttleHeld = false; brakeHeld = false; drivingPaused = true;
      if (drivePulse !== null) clearTimeout(drivePulse);
      drivePulse = null; buttonPointers.clear();
      isTouching = false;
      resetStick(false);
      updateModeUi();
      if (send) sendState();
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
      _disconnectClient(
        client,
        closeCode: WebSocketStatus.goingAway,
        reason: VrControllerDisconnectReason.serviceStopped,
      );
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
