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

import '../../utils/constants/vr_joystick_constants.dart';
import '../../utils/constants/vr_joystick_translation_constants.dart';
import '../../utils/enums/remote_controller_mode.dart';
import '../../utils/enums/vr_controller_disconnect_reason.dart';
import '../../utils/enums/vr_controller_wire_format.dart';
import '../models/remote_controller_state.dart';
import '../models/vr_controller_mode_request.dart';
import '../models/vr_controller_telemetry.dart';
import '../models/vr_local_address_candidate.dart';
import 'vr_controller_link.dart';
import 'vr_local_network_address.dart';
import 'vr_web_socket_controller_link.dart';

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
  VrControllerWireFormat? _wireFormat;
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

  // Only a caption update on an acknowledged, unchanged layout may carry
  // held controls into its ACK. This permission belongs to the current link.
  int? _heldCaptionAckRevision;
  bool _modeControlSupported = false;
  Uri? _castPreviewUri;

  static const int _maxMessageCharacters = 4096;
  static const int _maxMessagesPerSecond = 240;
  // BLE carries a one-byte tag plus up to 1023 UTF-8 bytes per control message.
  static const int _maxCastPreviewMessageBytes = 1023;

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
        VrJoystickTranslationConstants.errorPositiveTimeouts,
      );
    }
    if (this.sessionToken.isEmpty) {
      throw ArgumentError.value(
        sessionToken,
        'sessionToken',
        VrJoystickTranslationConstants.errorEmptySessionToken,
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

  bool _localHandheldActive = false;

  bool get isConnected => _client != null || _localHandheldActive;
  bool get isLocalHandheldActive => _localHandheldActive;
  bool get isRunning => _isRunning;
  int? get serverPort => _server?.port;
  String? get serverUrl => _isRunning && _localIp != null
      ? Uri(
          scheme: VrJoystickConstants.schemeHttp,
          host: _localIp,
          port: _server!.port,
          path: VrJoystickConstants.pathRoot,
          queryParameters: {VrJoystickConstants.queryToken: sessionToken},
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
  Map<String, String> get recommendedActions => _modeRequest.actions;

  /// Activates or deactivates the built-in single-screen handheld gamepad.
  void setLocalHandheldActive(bool active) {
    if (_disposed || _localHandheldActive == active) return;
    final wasConnected = isConnected;
    _localHandheldActive = active;
    if (_client == null) {
      _latestState = RemoteControllerState(
        orientation: _latestState.orientation.clone(),
        mode: _modeRequest.mode,
        controllerVisible: false,
      );
      if (!active && !_disposed) {
        _stateController.add(_latestState);
      }
    }
    if (wasConnected != isConnected && !_disposed) {
      _connectionController.add(isConnected);
    }
  }

  /// Injects a local touchscreen gamepad snapshot when running in single-screen
  /// handheld console mode. If an external 2nd smartphone is paired, the
  /// external controller takes precedence.
  void emitLocalHandheldState(RemoteControllerState state) {
    if (_disposed) return;
    if (!_localHandheldActive) {
      setLocalHandheldActive(true);
    }
    if (_client != null) return;
    _latestState = state;
    _lastAcceptedStateUs = _nowUs;
    _acceptedStates++;
    _stateController.add(_latestState);
  }

  /// Announces a separately hosted, read-only preview to the paired controller.
  ///
  /// This does not start a LAN server or alter controller input/mode state.
  /// The host owns the preview lifetime and calls this with null when it stops.
  /// Only authenticated attached links receive the URI, including its optional
  /// viewer token. A reconnect receives the current offer after its mode message;
  /// stopping this service forgets it. Credentials are never logged.
  void setCastPreviewUri(Uri? uri) {
    if (_disposed || uri == _castPreviewUri) return;
    if (uri != null &&
        ((uri.scheme != VrJoystickConstants.schemeHttp &&
                uri.scheme != VrJoystickConstants.schemeHttps) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment)) {
      throw ArgumentError(
        VrJoystickTranslationConstants.errorInvalidPreviewUrl,
      );
    }
    final message = _castPreviewMessage(uri);
    if (utf8.encode(message).length > _maxCastPreviewMessageBytes) {
      throw ArgumentError(
        VrJoystickTranslationConstants.errorPreviewExceedsBleLimit,
      );
    }
    _castPreviewUri = uri;
    _sendCastPreview(message);
  }

  static String _castPreviewMessage(Uri? uri) => jsonEncode({
    VrJoystickConstants.fieldType: VrJoystickConstants.castPreviewMessageType,
    VrJoystickConstants.fieldUrl: uri?.toString(),
  });

  void _sendCastPreview(String message) {
    final client = _client;
    if (client == null || _disposed) return;
    try {
      client.add(message);
    } catch (_) {
      _disconnectClient(
        client,
        reason: VrControllerDisconnectReason.transportError,
      );
    }
  }

  /// Requests a controller layout for the active app, optionally with what
  /// each button does there ([actions], keyed `A`/`B`/`X`/`Y`/`L`/`R`/`GRIP`)
  /// so the phone can caption its keys. Reconnecting receives the current
  /// recommendation again. Older clients may ignore this message; modern
  /// clients acknowledge a neutral full state before controls resume.
  ///
  /// [horizontalLook] opts games such as Doom into horizontal right-stick
  /// look. Changing this input profile requires a new neutral acknowledgement.
  /// A caption-only change (same profile, new actions) is sent without releasing
  /// held inputs: it is a relabel, not a layout swap.
  void requestControllerMode(
    RemoteControllerMode mode, {
    Map<String, String> actions = const {},
    bool horizontalLook = false,
  }) {
    if (mode == RemoteControllerMode.laser) {
      throw ArgumentError.value(
        mode,
        VrJoystickConstants.fieldMode,
        VrJoystickTranslationConstants.errorLaserModeDeprecated,
      );
    }
    if (_disposed) return;
    final clean = VrControllerModeRequest.sanitizeActions(actions);
    final sameMode = mode == _modeRequest.mode;
    final sameProfile =
        sameMode && horizontalLook == _modeRequest.horizontalLook;
    if (sameProfile && _sameActions(clean, _modeRequest.actions)) return;
    final preserveHeldAck =
        sameProfile &&
        _client != null &&
        _acceptedModeRevision == _modeRequest.revision &&
        _latestState.mode == mode;
    _modeRequest = VrControllerModeRequest(
      mode: mode,
      revision: _modeRequest.revision + 1,
      actions: clean,
      horizontalLook: horizontalLook,
    );
    _heldCaptionAckRevision = preserveHeldAck ? _modeRequest.revision : null;
    if (!sameProfile) {
      if (_localHandheldActive && _client == null) {
        _latestState = RemoteControllerState(
          orientation: _latestState.orientation.clone(),
          mode: mode,
          controllerVisible: false,
        );
        if (!_disposed) _stateController.add(_latestState);
      } else {
        _releaseInputs();
      }
    }
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
  Future<bool> startServer({int port = VrJoystickConstants.defaultServerPort}) {
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

      server.listen(_handleHttpRequest);
      _ensureInputWatchdog();

      // Start UDP auto-discovery beacon
      _startUdpBeacon(server.port, generation);

      return true;
    } catch (_) {
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
        final tokens =
            request.uri.queryParametersAll[VrJoystickConstants.queryToken];
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
    } catch (_) {
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
                  VrJoystickConstants.fieldService:
                      VrJoystickConstants.udpServiceId,
                  VrJoystickConstants.fieldPort: wsPort,
                  VrJoystickConstants.fieldIp: _localIp,
                  VrJoystickConstants.fieldName:
                      VrJoystickConstants.defaultBeaconName,
                  VrJoystickConstants.fieldRequiresPairingToken: true,
                  VrJoystickConstants.fieldTimestamp:
                      DateTime.now().millisecondsSinceEpoch,
                });
                final bytes = utf8.encode(beaconData);
                socket.send(
                  bytes,
                  InternetAddress(VrJoystickConstants.broadcastIp),
                  VrJoystickConstants.udpDiscoveryPort,
                );
              } catch (_) {}
            });
          })
          .catchError((_) {});
    } catch (_) {}
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
    _heldCaptionAckRevision = null;
    _modeControlSupported = false;
    _releaseInputs(controllerVisible: true);
    if (previous == null) _connectionController.add(true);
    if (previous != null) {
      _lastDisconnectReason = VrControllerDisconnectReason.replaced;
      unawaited(
        _closeLink(
          previous,
          WebSocketStatus.normalClosure,
          VrJoystickTranslationConstants.errorReplacedByController,
        ),
      );
    }
    HapticFeedback.mediumImpact();

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
            closeReason: VrJoystickTranslationConstants.errorInputLimitExceeded,
            reason: VrControllerDisconnectReason.inputLimitExceeded,
          );
          return;
        }
        if (isBinary) {
          if (_wireFormat == VrControllerWireFormat.json) {
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
            _wireFormat = VrControllerWireFormat.binaryPose;
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
        if (_wireFormat == VrControllerWireFormat.binaryPose) {
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
          final sequence = _optionalCounter(
            json,
            VrJoystickConstants.fieldSequence,
          );
          if (_lastSequence != null &&
              (sequence == null || sequence <= _lastSequence!)) {
            _rejectedStates++;
            return;
          }
          final timestampUs = _optionalCounter(
            json,
            VrJoystickConstants.fieldTimestampUs,
          );
          for (final key in VrJoystickConstants.booleanStateKeys) {
            if (json.containsKey(key) && json[key] is! bool) {
              throw FormatException(
                '$key${VrJoystickTranslationConstants.errorMustBeBooleanSuffix}',
              );
            }
          }
          for (final key in VrJoystickConstants.numericStateKeys) {
            final value = json[key];
            if (value != null && (value is! num || !value.isFinite)) {
              throw FormatException(
                '${VrJoystickTranslationConstants.errorNonFiniteFieldPrefix}$key',
              );
            }
          }
          for (final key in VrJoystickConstants.angularVelocityKeys) {
            final value = json[key] as num?;
            // Far above a normal hand movement; protects prediction from
            // finite but physically implausible sensor spikes.
            if (value != null && value.abs() > 100) {
              throw FormatException(
                '${VrJoystickTranslationConstants.errorAngularVelocityOutOfRangePrefix}$key',
              );
            }
          }
          final double qx =
              (json[VrJoystickConstants.fieldQx] as num?)?.toDouble() ?? 0.0;
          final double qy =
              (json[VrJoystickConstants.fieldQy] as num?)?.toDouble() ?? 0.0;
          final double qz =
              (json[VrJoystickConstants.fieldQz] as num?)?.toDouble() ?? 0.0;
          final double qw =
              (json[VrJoystickConstants.fieldQw] as num?)?.toDouble() ?? 1.0;
          final angularVelocity = vm.Vector3(
            (json[VrJoystickConstants.fieldWx] as num?)?.toDouble() ?? 0.0,
            (json[VrJoystickConstants.fieldWy] as num?)?.toDouble() ?? 0.0,
            (json[VrJoystickConstants.fieldWz] as num?)?.toDouble() ?? 0.0,
          );

          final bool trigger = json[VrJoystickConstants.fieldTrigger] == true;
          final bool action = json[VrJoystickConstants.fieldAction] == true;
          final bool btnA = json[VrJoystickConstants.fieldBtnA] == true;
          final bool btnB =
              json[VrJoystickConstants.fieldBtnB] == true || action;
          final bool btnX = json[VrJoystickConstants.fieldBtnX] == true;
          final bool btnY = json[VrJoystickConstants.fieldBtnY] == true;
          final bool btnL = json[VrJoystickConstants.fieldBtnL] == true;
          final bool btnR = json[VrJoystickConstants.fieldBtnR] == true;
          final bool btnGrip = json[VrJoystickConstants.fieldBtnGrip] == true;
          final bool stickClick =
              json[VrJoystickConstants.fieldStickClick] == true;

          final double stickX =
              (json[VrJoystickConstants.fieldStickX] as num?)?.toDouble() ??
              0.0;
          final double stickY =
              (json[VrJoystickConstants.fieldStickY] as num?)?.toDouble() ??
              0.0;
          final double tx =
              (json[VrJoystickConstants.fieldTx] as num?)?.toDouble() ?? stickX;
          final double ty =
              (json[VrJoystickConstants.fieldTy] as num?)?.toDouble() ?? stickY;
          final double turnRate =
              (json[VrJoystickConstants.fieldTurn] as num?)?.toDouble() ??
              (json[VrJoystickConstants.fieldTurnRate] as num?)?.toDouble() ??
              (json[VrJoystickConstants.fieldLookX] as num?)?.toDouble() ??
              0.0;
          final double pitchRate =
              (json[VrJoystickConstants.fieldPitchRate] as num?)?.toDouble() ??
              (json[VrJoystickConstants.fieldLookPitch] as num?)?.toDouble() ??
              (json[VrJoystickConstants.fieldLookY] as num?)?.toDouble() ??
              0.0;
          final double laserX =
              (json[VrJoystickConstants.fieldLaserX] as num?)?.toDouble() ??
              (json[VrJoystickConstants.fieldAimX] as num?)?.toDouble() ??
              0.0;
          final double laserY =
              (json[VrJoystickConstants.fieldLaserY] as num?)?.toDouble() ??
              (json[VrJoystickConstants.fieldAimY] as num?)?.toDouble() ??
              0.0;
          final bool recenter = json[VrJoystickConstants.fieldRecenter] == true;
          final double? rangeMeters =
              (json[VrJoystickConstants.fieldRangeMeters] as num?)
                  ?.toDouble() ??
              (json[VrJoystickConstants.fieldRange] as num?)?.toDouble();

          final String modeStr =
              json[VrJoystickConstants.fieldMode] as String? ??
              VrJoystickConstants.modeJoystick;
          final mode = switch (modeStr) {
            VrJoystickConstants.modeLaser => RemoteControllerMode.laser,
            VrJoystickConstants.modeDriving => RemoteControllerMode.driving,
            VrJoystickConstants.modeNes => RemoteControllerMode.nes,
            _ => RemoteControllerMode.joystick,
          };
          final drivingPaused =
              json[VrJoystickConstants.fieldDrivingPaused] == true;
          final hostModeRevision = _optionalCounter(
            json,
            VrJoystickConstants.fieldHostModeRevision,
          );
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
          _wireFormat = VrControllerWireFormat.json;
          _lastStateReceivedUs = now;
          if (hostModeRevision != null) {
            _modeControlSupported = true;
            _acceptedModeRevision = hostModeRevision;
          }

          final rawSearchQuery = json[VrJoystickConstants.fieldSearchQuery];
          final String? searchQuery =
              rawSearchQuery is String && rawSearchQuery.trim().isNotEmpty
              ? rawSearchQuery.trim().substring(
                  0,
                  math.min(
                    rawSearchQuery.trim().length,
                    VrJoystickConstants.maxSearchQueryLength,
                  ),
                )
              : null;
          final bool searchSubmitted =
              json[VrJoystickConstants.fieldSearchSubmitted] == true;

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
            moveAtEdge: json[VrJoystickConstants.fieldMoveAtEdge] as bool?,
            touchX: tx.clamp(-1.0, 1.0),
            touchY: ty.clamp(-1.0, 1.0),
            turnRate: turnRate.clamp(-1.0, 1.0),
            pitchRate: pitchRate.clamp(-1.0, 1.0),
            laserX: laserX.clamp(-1.0, 1.0),
            laserY: laserY.clamp(-1.0, 1.0),
            laserSlideActive:
                json[VrJoystickConstants.fieldLaserSlideActive] == true,
            recenter: recenter,
            controllerVisible:
                json[VrJoystickConstants.fieldControllerVisible] as bool? ??
                true,
            steering: drivingAxis(VrJoystickConstants.fieldSteering, -1),
            drivingTilt: json[VrJoystickConstants.fieldMotionAvailable] == true
                ? drivingAxis(VrJoystickConstants.fieldDrivingTilt, -1)
                : 0,
            throttle: drivingAxis(VrJoystickConstants.fieldThrottle, 0),
            brake: drivingAxis(VrJoystickConstants.fieldBrake, 0),
            drivingPaused: drivingPaused,
            motionAvailable:
                json[VrJoystickConstants.fieldMotionAvailable] == true,
            rangeMeters: rangeMeters,
            searchQuery: searchQuery,
            searchSubmitted: searchSubmitted,
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
    final preview = _castPreviewUri;
    if (preview != null) _sendCastPreview(_castPreviewMessage(preview));
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
    final modeMatches =
        mode == _modeRequest.mode ||
        (mode == RemoteControllerMode.laser &&
            _modeRequest.mode == RemoteControllerMode.joystick);
    if (!modeMatches) return false;
    if (_heldCaptionAckRevision == revision) return true;
    // A new foreground experience may acknowledge ready-to-drive. The full
    // neutral check below still rejects held pedals, sticks and buttons.
    for (final key in VrJoystickConstants.neutralButtonKeys) {
      if (json[key] == true) return false;
    }
    for (final key in VrJoystickConstants.neutralAxisKeys) {
      if (json[key] != null && json[key] != 0) return false;
    }
    return true;
  }

  static int? _optionalCounter(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int || value < 0) {
      throw FormatException(
        '${VrJoystickTranslationConstants.errorInvalidCounterPrefix}$key',
      );
    }
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
    _heldCaptionAckRevision = null;
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
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..headers.set(
        HttpHeaders.cacheControlHeader,
        VrJoystickConstants.headerNoStore,
      )
      ..headers.set(
        VrJoystickConstants.headerReferrerPolicy,
        VrJoystickConstants.headerNoReferrer,
      )
      ..write(VrJoystickConstants.webControllerHtml)
      ..close();
  }

  void stop() {
    _lifecycleGeneration++;
    _castPreviewUri = null;
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
