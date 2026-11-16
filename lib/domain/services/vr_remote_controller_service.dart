import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate/vrlizate.dart'
    show
        VrCompactGamepadCodec,
        VrCompactGamepadFrame,
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
import '../models/vr_controller_link_quality.dart';
import '../models/vr_controller_mode_request.dart';
import '../models/vr_controller_telemetry.dart';
import '../models/vr_desktop_bridge_state.dart';
import '../models/vr_local_address_candidate.dart';
import '../models/vr_tracking_marker_configuration.dart';
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
  VrTrackingMarkerConfiguration? _trackingMarker;
  VrTrackingMarkerConfiguration? get trackingMarker => _trackingMarker;
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
  int? _lastModeSentUs;
  Uri? _castPreviewUri;
  VrDesktopBridgeState? _desktopBridgeState;
  int _desktopBridgeRevision = 0;
  double? _effectivePassthroughMix;
  bool _effectiveCameraEnabled = false;
  int _effectivePassthroughRevision = 0;
  Timer? _effectivePassthroughTimer;
  int? _lastEffectivePassthroughSentUs;

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
      throw ArgumentError(VrJoystickTranslationConstants.errorPositiveTimeouts);
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
  RemoteControllerState _rawLatestState = RemoteControllerState(
    orientation: vm.Quaternion.identity(),
  );
  bool _systemOverlayCaptured = false;
  bool _awaitReleaseAfterOverlay = false;
  final List<void Function(RemoteControllerState)> _rawStateListeners = [];

  final StreamController<RemoteControllerState> _stateController =
      StreamController<RemoteControllerState>.broadcast();

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  Stream<RemoteControllerState> get onState => _stateController.stream;
  Stream<bool> get onConnectionChanged => _connectionController.stream;

  bool _localHandheldActive = false;
  bool _handsFreeVirtualActive = false;
  Timer? _voiceLocomotionTimer;
  Timer? _voiceLocomotionStopTimer;
  Timer? _voiceButtonReleaseTimer;
  double _voiceStickX = 0.0;
  double _voiceStickY = 0.0;
  double _voiceTurnRate = 0.0;

  bool get isConnected =>
      _client != null || _localHandheldActive || _handsFreeVirtualActive;
  bool get isLocalHandheldActive => _localHandheldActive;
  bool get isHandsFreeVirtualActive => _handsFreeVirtualActive;
  bool get isVoiceLocomotionActive =>
      _voiceLocomotionTimer != null &&
      (_voiceLocomotionStopTimer?.isActive ?? false);
  bool get isSystemOverlayCaptured => _systemOverlayCaptured;
  RemoteControllerState get rawLatestState => _rawLatestState;

  /// Returns true when [link] is currently the active controller link.
  bool isLinkAttached(VrControllerLink link) => identical(_client, link);

  /// Registers a system-level listener (e.g. Universal Subtle Floating Menu)
  /// that observes un-neutralized controller states even while overlay capture
  /// is active.
  void addRawStateListener(void Function(RemoteControllerState) listener) {
    if (_disposed || _rawStateListeners.contains(listener)) return;
    _rawStateListeners.add(listener);
  }

  void removeRawStateListener(void Function(RemoteControllerState) listener) {
    _rawStateListeners.remove(listener);
  }

  /// Captures controller sticks/buttons for a system overlay (such as the
  /// Universal Subtle Quick Menu) so underlying 3D scenes receive neutralized
  /// locomotion/actions while the overlay is open — and latches button release
  /// when closing so the closing press never leaks into the underlying scene.
  void setSystemOverlayCapture(bool captured) {
    if (_disposed || _systemOverlayCaptured == captured) return;
    _systemOverlayCaptured = captured;
    if (!captured && _hasHeldOverlayButtons(_rawLatestState)) {
      _awaitReleaseAfterOverlay = true;
    } else if (captured) {
      _awaitReleaseAfterOverlay = false;
    }
    _publishState(_neutralizedSnapshotFrom(_rawLatestState), notifyRaw: false);
  }

  static bool _hasHeldOverlayButtons(RemoteControllerState s) =>
      s.btnA ||
      s.btnB ||
      s.btnL ||
      s.btnR ||
      s.btnZL ||
      s.btnZR ||
      s.isTriggerPressed ||
      s.isActionPressed;

  /// Emits a synthetic `recenter` pulse to the active VR scene (`Home`,
  /// `Plazas Famosas`, `Worlds`, or any running `DemoRunner` app).
  void pulseRecenter() {
    if (_disposed) return;
    final base = _neutralizedSnapshotFrom(_rawLatestState);
    final pulse = RemoteControllerState(
      passthroughCommandRevision: base.passthroughCommandRevision,
      orientation: base.orientation.clone(),
      angularVelocity: base.angularVelocity.clone(),
      mode: base.mode,
      recenter: true,
      drivingPaused: base.drivingPaused,
      controllerVisible: base.controllerVisible,
      rangeMeters: base.rangeMeters,
      passthroughMix: base.passthroughMix,
      passthroughActive: base.passthroughActive,
      spatialHudVisible: base.spatialHudVisible,
    );
    _stateController.add(pulse);
    _stateController.add(base);
  }

  void _ensureHandsFreeVirtualConnected() {
    if (_disposed || _client != null || _localHandheldActive) return;
    if (!_handsFreeVirtualActive) {
      _handsFreeVirtualActive = true;
      _connectionController.add(true);
    }
  }

  /// Drives smooth 3D spatial walking, strafing, or turning from a spoken Itzli
  /// voice command or facial gesture — even when zero physical Joystick is paired!
  void driveVoiceLocomotion({
    double stickX = 0.0,
    double stickY = 0.0,
    double turnRate = 0.0,
    Duration duration = const Duration(milliseconds: 2200),
  }) {
    if (_disposed) return;
    final sx = stickX.isFinite ? stickX.clamp(-1.0, 1.0) : 0.0;
    final sy = stickY.isFinite ? stickY.clamp(-1.0, 1.0) : 0.0;
    final tr = turnRate.isFinite ? turnRate.clamp(-1.0, 1.0) : 0.0;
    if ((sx.abs() < 0.005 && sy.abs() < 0.005 && tr.abs() < 0.005) ||
        duration <= Duration.zero) {
      stopVoiceLocomotion();
      return;
    }

    _ensureHandsFreeVirtualConnected();
    _awaitReleaseAfterOverlay = false;
    _voiceLocomotionTimer?.cancel();
    _voiceLocomotionTimer = null;
    _voiceLocomotionStopTimer?.cancel();
    _voiceLocomotionStopTimer = null;
    _voiceStickX = 0.0;
    _voiceStickY = 0.0;
    _voiceTurnRate = 0.0;

    // Emit an explicit non-neutralized zero frame first so any consumer waiting
    // for neutral stick after connection/menu close unlatches immediately.
    if (!_systemOverlayCaptured) {
      final zeroBase = _rawLatestState;
      _publishState(
        RemoteControllerState(
          passthroughCommandRevision: zeroBase.passthroughCommandRevision,
          orientation: zeroBase.orientation.clone(),
          angularVelocity: zeroBase.angularVelocity.clone(),
          mode: zeroBase.mode,
          stickX: 0.0,
          stickY: 0.0,
          moveAtEdge: false,
          turnRate: 0.0,
          isNeutralized: false,
          controllerVisible: zeroBase.controllerVisible,
          rangeMeters: zeroBase.rangeMeters,
          passthroughMix: zeroBase.passthroughMix,
          passthroughActive: zeroBase.passthroughActive,
          spatialHudVisible: zeroBase.spatialHudVisible,
        ),
        notifyRaw: false,
      );
    }

    _voiceStickX = sx;
    _voiceStickY = sy;
    _voiceTurnRate = tr;

    void emitStep() {
      if (_disposed) {
        stopVoiceLocomotion();
        return;
      }
      final base = _rawLatestState;
      _publishState(
        RemoteControllerState(
          passthroughCommandRevision: base.passthroughCommandRevision,
          orientation: base.orientation.clone(),
          angularVelocity: base.angularVelocity.clone(),
          mode: base.mode,
          stickX: _voiceStickX,
          stickY: _voiceStickY,
          moveAtEdge: false,
          turnRate: _voiceTurnRate,
          isNeutralized: false,
          controllerVisible: _client != null
              ? base.controllerVisible
              : _localHandheldActive,
          rangeMeters: base.rangeMeters,
          passthroughMix: base.passthroughMix,
          passthroughActive: base.passthroughActive,
          spatialHudVisible: base.spatialHudVisible,
        ),
        notifyRaw: _client == null,
      );
    }

    _voiceLocomotionStopTimer = Timer(duration, stopVoiceLocomotion);
    emitStep();
    _voiceLocomotionTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => emitStep(),
    );
  }

  /// Immediately halts any active voice-driven locomotion and zeroes sticks.
  void stopVoiceLocomotion() {
    final wasActive =
        _voiceLocomotionTimer != null ||
        _voiceLocomotionStopTimer != null ||
        _voiceStickX != 0.0 ||
        _voiceStickY != 0.0 ||
        _voiceTurnRate != 0.0;
    _voiceLocomotionTimer?.cancel();
    _voiceLocomotionTimer = null;
    _voiceLocomotionStopTimer?.cancel();
    _voiceLocomotionStopTimer = null;
    _voiceStickX = 0.0;
    _voiceStickY = 0.0;
    _voiceTurnRate = 0.0;
    if (wasActive && !_disposed) {
      final base = _rawLatestState;
      _publishState(
        RemoteControllerState(
          passthroughCommandRevision: base.passthroughCommandRevision,
          orientation: base.orientation.clone(),
          angularVelocity: base.angularVelocity.clone(),
          mode: base.mode,
          stickX: 0.0,
          stickY: 0.0,
          moveAtEdge: false,
          turnRate: 0.0,
          isNeutralized: false,
          controllerVisible: _client != null
              ? base.controllerVisible
              : _localHandheldActive,
          rangeMeters: base.rangeMeters,
          passthroughMix: base.passthroughMix,
          passthroughActive: base.passthroughActive,
          spatialHudVisible: base.spatialHudVisible,
        ),
        notifyRaw: _client == null,
      );
    }
  }

  /// Emits a hands-free primary confirm/click (`btnA` + `trigger`) to the active
  /// VR scene (works with or without a paired Joystick).
  void pulsePrimarySelect() {
    if (_disposed) return;
    _ensureHandsFreeVirtualConnected();
    _voiceButtonReleaseTimer?.cancel();
    final base = _neutralizedSnapshotFrom(_rawLatestState);
    final pressed = RemoteControllerState(
      passthroughCommandRevision: base.passthroughCommandRevision,
      orientation: base.orientation.clone(),
      angularVelocity: base.angularVelocity.clone(),
      mode: base.mode,
      btnA: true,
      isTriggerPressed: true,
      controllerVisible: _client != null ? base.controllerVisible : false,
      rangeMeters: base.rangeMeters,
      passthroughMix: base.passthroughMix,
      passthroughActive: base.passthroughActive,
      spatialHudVisible: base.spatialHudVisible,
    );
    _publishState(pressed);
    _voiceButtonReleaseTimer = Timer(const Duration(milliseconds: 55), () {
      if (_disposed) return;
      _publishState(_neutralizedSnapshotFrom(_rawLatestState));
    });
  }

  /// Emits a hands-free back/cancel pulse (`btnB` + `action`) to the active VR scene.
  void pulseBackAction() {
    if (_disposed) return;
    _ensureHandsFreeVirtualConnected();
    _voiceButtonReleaseTimer?.cancel();
    final base = _neutralizedSnapshotFrom(_rawLatestState);
    final pressed = RemoteControllerState(
      passthroughCommandRevision: base.passthroughCommandRevision,
      orientation: base.orientation.clone(),
      angularVelocity: base.angularVelocity.clone(),
      mode: base.mode,
      btnB: true,
      isActionPressed: true,
      controllerVisible: _client != null ? base.controllerVisible : false,
      rangeMeters: base.rangeMeters,
      passthroughMix: base.passthroughMix,
      passthroughActive: base.passthroughActive,
      spatialHudVisible: base.spatialHudVisible,
    );
    _publishState(pressed);
    _voiceButtonReleaseTimer = Timer(const Duration(milliseconds: 55), () {
      if (_disposed) return;
      _publishState(_neutralizedSnapshotFrom(_rawLatestState));
    });
  }

  RemoteControllerState _neutralizedSnapshotFrom(RemoteControllerState src) =>
      RemoteControllerState(
        passthroughCommandRevision: src.passthroughCommandRevision,
        orientation: src.orientation.clone(),
        angularVelocity: src.angularVelocity.clone(),
        mode: src.mode,
        drivingPaused: src.mode == RemoteControllerMode.driving,
        isNeutralized: true,
        pointerPoseReady: false,
        controllerVisible: src.controllerVisible,
        rangeMeters: src.rangeMeters,
        passthroughMix: src.passthroughMix,
        passthroughActive: src.passthroughActive,
        spatialHudVisible: src.spatialHudVisible,
        leftFootU: src.leftFootU,
        leftFootV: src.leftFootV,
        rightFootU: src.rightFootU,
        rightFootV: src.rightFootV,
        feetConfidence: src.feetConfidence,
        handU: src.handU,
        handV: src.handV,
        handConfidence: src.handConfidence,
        visorU: src.visorU,
        visorV: src.visorV,
        visorWidth: src.visorWidth,
        joystickCameraRole: src.joystickCameraRole,
        joystickMiniFrame: src.joystickMiniFrame,
      );

  void _publishState(RemoteControllerState next, {bool notifyRaw = true}) {
    var effectiveNext = next;
    if (_voiceLocomotionTimer != null) {
      if (!(_voiceLocomotionStopTimer?.isActive ?? false)) {
        _voiceLocomotionTimer?.cancel();
        _voiceLocomotionTimer = null;
        _voiceLocomotionStopTimer?.cancel();
        _voiceLocomotionStopTimer = null;
        _voiceStickX = 0.0;
        _voiceStickY = 0.0;
        _voiceTurnRate = 0.0;
      } else if (_client != null && notifyRaw) {
        final manualIntent =
            next.stickX.abs() > 0.14 ||
            next.stickY.abs() > 0.14 ||
            next.turnRate.abs() > 0.14 ||
            next.btnA ||
            next.btnB ||
            next.btnZL ||
            next.btnZR ||
            next.isTriggerPressed ||
            next.isActionPressed;
        if (manualIntent) {
          _voiceLocomotionTimer?.cancel();
          _voiceLocomotionTimer = null;
          _voiceLocomotionStopTimer?.cancel();
          _voiceLocomotionStopTimer = null;
          _voiceStickX = 0.0;
          _voiceStickY = 0.0;
          _voiceTurnRate = 0.0;
        } else {
          effectiveNext = RemoteControllerState(
            passthroughCommandRevision: next.passthroughCommandRevision,
            orientation: next.orientation.clone(),
            angularVelocity: next.angularVelocity.clone(),
            mode: next.mode,
            stickX: _voiceStickX,
            stickY: _voiceStickY,
            moveAtEdge: false,
            turnRate: _voiceTurnRate,
            pitchRate: next.pitchRate,
            controllerVisible: next.controllerVisible,
            rangeMeters: next.rangeMeters,
            passthroughMix: next.passthroughMix,
            passthroughActive: next.passthroughActive,
            spatialHudVisible: next.spatialHudVisible,
          );
        }
      }
    }
    final capturedBeforeRaw = _systemOverlayCaptured;
    if (notifyRaw) {
      _rawLatestState = effectiveNext;
      if (_awaitReleaseAfterOverlay && !_hasHeldOverlayButtons(effectiveNext)) {
        _awaitReleaseAfterOverlay = false;
      }
    }
    if (notifyRaw && _rawStateListeners.isNotEmpty) {
      for (final listener in List<void Function(RemoteControllerState)>.of(
        _rawStateListeners,
      )) {
        listener(effectiveNext);
      }
    }
    final shouldNeutralize =
        capturedBeforeRaw ||
        _systemOverlayCaptured ||
        _awaitReleaseAfterOverlay;
    _latestState = shouldNeutralize
        ? _neutralizedSnapshotFrom(effectiveNext)
        : effectiveNext;
    if (!_disposed) {
      _stateController.add(_latestState);
    }
  }

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
  bool get recommendedHorizontalLook => _modeRequest.horizontalLook;
  Map<String, String> get recommendedActions => _modeRequest.actions;

  /// Activates or deactivates the built-in single-screen handheld gamepad.
  void setLocalHandheldActive(bool active) {
    if (_disposed || _localHandheldActive == active) return;
    final wasConnected = isConnected;
    _localHandheldActive = active;
    if (_client == null) {
      _latestState = RemoteControllerState(
        passthroughCommandRevision: _passthroughCommandRevision,
        passthroughMix: _latchedPassthroughMix,
        passthroughActive: _latchedPassthroughActive,
        spatialHudVisible: _latchedSpatialHudVisible,
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
    _emitWithLatchedPassthrough();
  }

  /// Mirrors the visor's effective setting. This is feedback, never a camera
  /// command, and does not mutate the received input or its command revisions.
  /// Deduplication keeps normal tracking/frame updates off the BLE channel.
  void setEffectivePassthroughState({
    required double mix,
    required bool cameraEnabled,
  }) {
    if (_disposed || !mix.isFinite) return;
    final effective = cameraEnabled ? mix.clamp(0.0, 1.0) : 0.0;
    if (_effectivePassthroughMix == effective &&
        _effectiveCameraEnabled == cameraEnabled) {
      return;
    }
    _effectivePassthroughMix = effective;
    _effectiveCameraEnabled = cameraEnabled;
    _effectivePassthroughRevision++;
    final last = _lastEffectivePassthroughSentUs;
    final elapsed = last == null ? 100000 : _nowUs - last;
    if (!cameraEnabled || _client == null || elapsed >= 100000) {
      _sendEffectivePassthroughState();
    } else {
      _effectivePassthroughTimer ??= Timer(
        Duration(microseconds: 100000 - elapsed),
        _sendEffectivePassthroughState,
      );
    }
  }

  void _sendEffectivePassthroughState() {
    _effectivePassthroughTimer?.cancel();
    _effectivePassthroughTimer = null;
    final mix = _effectivePassthroughMix;
    final client = _client;
    if (_disposed || client == null || mix == null) return;
    _lastEffectivePassthroughSentUs = _nowUs;
    try {
      client.add(
        jsonEncode({
          VrJoystickConstants.fieldType:
              VrJoystickConstants.passthroughStateMessageType,
          VrJoystickConstants.fieldRevision: _effectivePassthroughRevision,
          VrJoystickConstants.fieldPassthroughMix: mix,
          'cameraEnabled': _effectiveCameraEnabled,
        }),
      );
    } catch (_) {
      _disconnectClient(
        client,
        reason: VrControllerDisconnectReason.transportError,
      );
    }
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

  VrDesktopBridgeState? get desktopBridgeState => _desktopBridgeState;
  Uri? get castPreviewUri => _castPreviewUri;

  /// Publishes autonomous Desktop Estación Faro bridge state and offload
  /// directives (`castOffload`, `visionOffload`, `recommendedHz`, `haptic`) to
  /// the connected Joystick smartphone over BLE or WebSocket.
  void setDesktopBridgeState(VrDesktopBridgeState? state) {
    if (_disposed) return;
    final current = _desktopBridgeState;
    if (state == null) {
      if (current == null || !current.stationConnected) return;
      final next = VrDesktopBridgeState.disconnected(
        revision: ++_desktopBridgeRevision,
      );
      _desktopBridgeState = next;
      _sendDesktopBridge(next);
      return;
    }
    if (current != null &&
        current.sameConfigurationAs(state) &&
        state.hapticAlert == null) {
      return;
    }
    final stamped = VrDesktopBridgeState(
      revision: ++_desktopBridgeRevision,
      stationConnected: state.stationConnected,
      stationName: state.stationName,
      castOffloadedToDesktop: state.castOffloadedToDesktop,
      visionOffloadedToDesktop: state.visionOffloadedToDesktop,
      recommendedJoystickHz: state.recommendedJoystickHz,
      deskClearanceMeters: state.deskClearanceMeters,
      hapticAlert: state.hapticAlert,
      activeDecisionSummary: state.activeDecisionSummary,
      topologyMode: state.topologyMode,
      substituteGyroWithPcVision: state.substituteGyroWithPcVision,
    );
    _desktopBridgeState = stamped;
    _sendDesktopBridge(stamped);
  }

  void _sendDesktopBridge(VrDesktopBridgeState state) {
    final client = _client;
    if (client == null || _disposed) return;
    final message = state.toJsonMessage();
    if (utf8.encode(message).length > _maxCastPreviewMessageBytes) return;
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
          passthroughCommandRevision: _passthroughCommandRevision,
          passthroughMix: _latchedPassthroughMix,
          passthroughActive: _latchedPassthroughActive,
          spatialHudVisible: _latchedSpatialHudVisible,
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
    _lastModeSentUs = _nowUs;
    try {
      client.add(jsonEncode(_modeRequest.toJson()));
    } catch (_) {
      _disconnectClient(
        client,
        reason: VrControllerDisconnectReason.transportError,
      );
    }
  }

  void _maybeResendControllerMode(int nowUs) {
    if (_acceptedModeRevision == _modeRequest.revision) return;
    final last = _lastModeSentUs;
    if (last != null && nowUs - last < 120000) return;
    _sendControllerMode();
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
    _trackingMarker = null;
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
    _lastModeSentUs = null;
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
        final bool isCompactFrame = data is VrCompactGamepadFrame;
        final List<int>? binaryList = !isCompactFrame && data is List<int>
            ? data
            : null;
        final int? binaryPacketType = binaryList != null
            ? VrRemoteBinaryCodec.inspectPacketType(binaryList)
            : null;
        final bool isBinary = binaryPacketType != null;
        final int maxAllowedBinaryLen =
            binaryPacketType == VrRemoteBinaryCodec.packetTypeFullGamepad
            ? VrRemoteBinaryCodec.fullGamepadPacketLength
            : VrRemoteBinaryCodec.posePacketLength;
        if (++_rateWindowCount > _maxMessagesPerSecond ||
            (!isCompactFrame &&
                (isBinary
                    ? binaryList!.length > maxAllowedBinaryLen
                    : (data is! String ||
                          data.length > _maxMessageCharacters)))) {
          _rejectedStates++;
          _disconnectClient(
            socket,
            closeCode: WebSocketStatus.policyViolation,
            closeReason: VrJoystickTranslationConstants.errorInputLimitExceeded,
            reason: VrControllerDisconnectReason.inputLimitExceeded,
          );
          return;
        }
        if (isCompactFrame) {
          _ingestCompactGamepadFrame(data, now);
          return;
        }
        if (binaryPacketType == VrRemoteBinaryCodec.packetTypeFullGamepad &&
            binaryList != null) {
          final bytes = binaryList is Uint8List
              ? binaryList
              : Uint8List.fromList(binaryList);
          final compact = const VrCompactGamepadCodec().tryDecode(bytes);
          if (compact == null) {
            _rejectedStates++;
            return;
          }
          _ingestCompactGamepadFrame(compact, now);
          return;
        }
        if (isBinary && binaryList != null) {
          if (_wireFormat == VrControllerWireFormat.json) {
            _rejectedStates++;
            return;
          }
          try {
            final bytes = binaryList is Uint8List
                ? binaryList
                : Uint8List.fromList(binaryList);
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

            _syncPredictorLatencyFromLink();
            _posePredictor.pushFrame(pose);
            _posePredictor.predictTo(_predictedOrientation);
            _lastSequence = pose.sequence;
            _wireFormat = VrControllerWireFormat.binaryPose;
            _lastStateReceivedUs = now;

            _latestState = RemoteControllerState(
              passthroughCommandRevision: _passthroughCommandRevision,
              passthroughMix: _latchedPassthroughMix,
              passthroughActive: _latchedPassthroughActive,
              spatialHudVisible: _latchedSpatialHudVisible,
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
            _publishState(_latestState);
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
          if (json['type'] == VrTrackingMarkerConfiguration.messageType) {
            final marker = VrTrackingMarkerConfiguration.fromMessage(json);
            if (marker == null) {
              _rejectedStates++;
              return;
            }
            _trackingMarker = marker;
            _emitWithLatchedPassthrough();
            return;
          }
          if (json[VrJoystickConstants.fieldType] ==
              VrJoystickConstants.passthroughControlType) {
            final rawMix = json[VrJoystickConstants.fieldPassthroughMix];
            if (rawMix is num && rawMix.isFinite) {
              _latchedPassthroughMix = rawMix.toDouble().clamp(0.0, 1.0);
              if (json[VrJoystickConstants.fieldPassthroughCommand] == true) {
                _passthroughCommandRevision++;
              }
            }
            final rawActive = json[VrJoystickConstants.fieldPassthroughActive];
            _latchedPassthroughActive = rawActive is bool
                ? rawActive
                : (_latchedPassthroughMix > 0.01);
            final rawHud = json[VrJoystickConstants.fieldSpatialHudVisible];
            if (rawHud is bool) {
              _latchedSpatialHudVisible = rawHud;
            }
            _emitWithLatchedPassthrough();
            return;
          }
          if (json[VrJoystickConstants.fieldType] ==
              VrJoystickConstants.visionTelemetryMessageType) {
            _ingestVisionTelemetry(json);
            _emitWithLatchedPassthrough();
            return;
          }
          final sequence = _optionalCounter(
            json,
            VrJoystickConstants.fieldSequence,
          );
          if (_lastSequence != null) {
            if (sequence == null) {
              _rejectedStates++;
              return;
            }
            if (sequence <= 0xFFFFFFFF && _lastSequence! <= 0xFFFFFFFF) {
              final advance = (sequence - _lastSequence!) & 0xFFFFFFFF;
              if (advance == 0 || advance >= 0x80000000) {
                _rejectedStates++;
                return;
              }
            } else if (sequence <= _lastSequence!) {
              _rejectedStates++;
              return;
            }
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
          final bool btnZL = json[VrJoystickConstants.fieldBtnZL] == true;
          final bool btnZR = json[VrJoystickConstants.fieldBtnZR] == true;
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
          final rawRange =
              json.containsKey(VrJoystickConstants.fieldRangeMeters)
              ? json[VrJoystickConstants.fieldRangeMeters]
              : json[VrJoystickConstants.fieldRange];
          final double? rangeMeters =
              rawRange is num && rawRange.isFinite && rawRange > 0
              ? rawRange.toDouble()
              : null;

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
            if (hostModeRevision != null &&
                hostModeRevision < _modeRequest.revision) {
              _maybeResendControllerMode(now);
            }
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
          _syncPredictorLatencyFromLink();
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
          if (json.containsKey(VrJoystickConstants.fieldPassthroughMix)) {
            _latchedPassthroughMix =
                ((json[VrJoystickConstants.fieldPassthroughMix] as num?)
                            ?.toDouble() ??
                        0.0)
                    .clamp(0.0, 1.0);
          }
          if (json.containsKey(VrJoystickConstants.fieldPassthroughActive)) {
            _latchedPassthroughActive =
                json[VrJoystickConstants.fieldPassthroughActive] == true;
          } else {
            _latchedPassthroughActive = _latchedPassthroughMix > 0.01;
          }
          if (json.containsKey(VrJoystickConstants.fieldRangeMeters) ||
              json.containsKey(VrJoystickConstants.fieldRange)) {
            _hasRangeTelemetry = true;
            _latchedRangeMeters =
                rangeMeters != null && rangeMeters.isFinite && rangeMeters > 0
                ? rangeMeters
                : null;
          }
          if (json.containsKey(VrJoystickConstants.fieldSpatialHudVisible)) {
            _latchedSpatialHudVisible =
                json[VrJoystickConstants.fieldSpatialHudVisible] == true;
          }

          _latestState = RemoteControllerState(
            passthroughCommandRevision: _passthroughCommandRevision,
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
            btnZL: btnZL,
            btnZR: btnZR,
            btnGrip: btnGrip,
            stickClick: stickClick,
            stickX: stickX.clamp(-1.0, 1.0),
            stickY: stickY.clamp(-1.0, 1.0),
            moveAtEdge: json[VrJoystickConstants.fieldMoveAtEdge] as bool?,
            dpadX:
                ((json[VrJoystickConstants.fieldDpadX] as num?)?.toDouble() ??
                        0.0)
                    .clamp(-1.0, 1.0),
            dpadY:
                ((json[VrJoystickConstants.fieldDpadY] as num?)?.toDouble() ??
                        0.0)
                    .clamp(-1.0, 1.0),
            touchX: tx.clamp(-1.0, 1.0),
            touchY: ty.clamp(-1.0, 1.0),
            turnRate: turnRate.clamp(-1.0, 1.0),
            pitchRate: pitchRate.clamp(-1.0, 1.0),
            laserX: laserX.clamp(-1.0, 1.0),
            laserY: laserY.clamp(-1.0, 1.0),
            laserSlideActive:
                json[VrJoystickConstants.fieldLaserSlideActive] == true,
            pointerPoseReady:
                json[VrJoystickConstants.fieldPointerPoseReady] == true,
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
            rangeMeters: _latchedRangeMeters,
            searchQuery: searchQuery,
            searchSubmitted: searchSubmitted,
            passthroughMix: _latchedPassthroughMix,
            passthroughActive: _latchedPassthroughActive,
            spatialHudVisible: _latchedSpatialHudVisible,
            leftFootU: _latchedLeftFootU,
            leftFootV: _latchedLeftFootV,
            rightFootU: _latchedRightFootU,
            rightFootV: _latchedRightFootV,
            feetConfidence: _latchedFeetConfidence,
            handU: _latchedHandU,
            handV: _latchedHandV,
            handConfidence: _latchedHandConfidence,
            visorU: _latchedVisorU,
            visorV: _latchedVisorV,
            visorWidth: _latchedVisorWidth,
            joystickCameraRole: _latchedJoystickCameraRole,
            joystickMiniFrame: _latchedJoystickMiniFrame,
            mode: mode,
          );

          _lastAcceptedStateUs = now;
          _acceptedStates++;
          _publishState(_latestState);
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
    _sendEffectivePassthroughState();
    final bridge = _desktopBridgeState;
    if (bridge != null && bridge.stationConnected) {
      _sendDesktopBridge(bridge);
    }
    final preview = _castPreviewUri;
    if (preview != null) _sendCastPreview(_castPreviewMessage(preview));
  }

  double _latchedPassthroughMix = 0.0;
  int _passthroughCommandRevision = 0;
  bool _latchedPassthroughActive = false;
  bool _latchedSpatialHudVisible = false;
  double? _latchedRangeMeters;
  bool _hasRangeTelemetry = false;
  double? _latchedLeftFootU;
  double? _latchedLeftFootV;
  double? _latchedRightFootU;
  double? _latchedRightFootV;
  double? _latchedFeetConfidence;
  double? _latchedHandU;
  double? _latchedHandV;
  double? _latchedHandConfidence;
  double? _latchedVisorU;
  double? _latchedVisorV;
  double? _latchedVisorWidth;
  String? _latchedJoystickCameraRole;
  String? _latchedJoystickMiniFrame;

  void _ingestVisionTelemetry(Map<String, dynamic> json) {
    double? finiteNum(String key) {
      final v = json[key];
      return (v is num && v.isFinite) ? v.toDouble() : null;
    }

    if (json.containsKey(VrJoystickConstants.fieldRangeMeters)) {
      // Absence is a partial update; an explicit null invalidates the previous
      // measurement. Never resurrect it from a retained controller state.
      _hasRangeTelemetry = true;
      final range = finiteNum(VrJoystickConstants.fieldRangeMeters);
      _latchedRangeMeters = range != null && range > 0 ? range : null;
    }
    _latchedLeftFootU =
        finiteNum(VrJoystickConstants.fieldLeftFootU) ?? _latchedLeftFootU;
    _latchedLeftFootV =
        finiteNum(VrJoystickConstants.fieldLeftFootV) ?? _latchedLeftFootV;
    _latchedRightFootU =
        finiteNum(VrJoystickConstants.fieldRightFootU) ?? _latchedRightFootU;
    _latchedRightFootV =
        finiteNum(VrJoystickConstants.fieldRightFootV) ?? _latchedRightFootV;
    _latchedFeetConfidence =
        finiteNum(VrJoystickConstants.fieldFeetConfidence) ??
        _latchedFeetConfidence;
    _latchedHandU = finiteNum(VrJoystickConstants.fieldHandU) ?? _latchedHandU;
    _latchedHandV = finiteNum(VrJoystickConstants.fieldHandV) ?? _latchedHandV;
    _latchedHandConfidence =
        finiteNum(VrJoystickConstants.fieldHandConfidence) ??
        _latchedHandConfidence;
    _latchedVisorU =
        finiteNum(VrJoystickConstants.fieldVisorU) ?? _latchedVisorU;
    _latchedVisorV =
        finiteNum(VrJoystickConstants.fieldVisorV) ?? _latchedVisorV;
    _latchedVisorWidth =
        finiteNum(VrJoystickConstants.fieldVisorWidth) ?? _latchedVisorWidth;
    final role = json[VrJoystickConstants.fieldJoystickCameraRole];
    if (role is String && role.isNotEmpty) {
      _latchedJoystickCameraRole = role;
    }
    final frame = json[VrJoystickConstants.fieldJoystickMiniFrame];
    if (frame is String && frame.isNotEmpty && frame.length <= 1600) {
      _latchedJoystickMiniFrame = frame;
    }
  }

  /// Directly updates the latched Breakthrough/Passthrough mix (`0.0 .. 1.0`)
  /// on the Visor host and notifies listeners.
  void setPassthroughMix(double mix) {
    if (_disposed || !mix.isFinite) return;
    _latchedPassthroughMix = mix.clamp(0.0, 1.0);
    _latchedPassthroughActive = _latchedPassthroughMix > 0.01;
    _passthroughCommandRevision++;
    _emitWithLatchedPassthrough();
  }

  /// Directly toggles the 3-Camera & Live Calculations HUD inside the Visor.
  void setSpatialHudVisible(bool visible) {
    if (_disposed) return;
    _latchedSpatialHudVisible = visible;
    _emitWithLatchedPassthrough();
  }

  void _emitWithLatchedPassthrough() {
    final prev = _latestState;
    _latestState = RemoteControllerState(
      passthroughCommandRevision: _passthroughCommandRevision,
      orientation: prev.orientation.clone(),
      angularVelocity: prev.angularVelocity.clone(),
      isTriggerPressed: prev.isTriggerPressed,
      isActionPressed: prev.isActionPressed,
      btnA: prev.btnA,
      btnB: prev.btnB,
      btnX: prev.btnX,
      btnY: prev.btnY,
      btnL: prev.btnL,
      btnR: prev.btnR,
      btnZL: prev.btnZL,
      btnZR: prev.btnZR,
      btnGrip: prev.btnGrip,
      stickClick: prev.stickClick,
      stickX: prev.stickX,
      stickY: prev.stickY,
      moveAtEdge: prev.moveAtEdge,
      dpadX: prev.dpadX,
      dpadY: prev.dpadY,
      touchX: prev.touchX,
      touchY: prev.touchY,
      turnRate: prev.turnRate,
      pitchRate: prev.pitchRate,
      laserX: prev.laserX,
      laserY: prev.laserY,
      laserSlideActive: prev.laserSlideActive,
      pointerPoseReady: prev.pointerPoseReady,
      recenter: prev.recenter,
      controllerVisible: prev.controllerVisible,
      steering: prev.steering,
      drivingTilt: prev.drivingTilt,
      throttle: prev.throttle,
      brake: prev.brake,
      drivingPaused: prev.drivingPaused,
      motionAvailable: prev.motionAvailable,
      isNeutralized: prev.isNeutralized,
      rangeMeters: _hasRangeTelemetry ? _latchedRangeMeters : prev.rangeMeters,
      searchQuery: prev.searchQuery,
      searchSubmitted: prev.searchSubmitted,
      passthroughMix: _latchedPassthroughMix,
      passthroughActive: _latchedPassthroughActive,
      spatialHudVisible: _latchedSpatialHudVisible,
      leftFootU: _latchedLeftFootU,
      leftFootV: _latchedLeftFootV,
      rightFootU: _latchedRightFootU,
      rightFootV: _latchedRightFootV,
      feetConfidence: _latchedFeetConfidence,
      handU: _latchedHandU,
      handV: _latchedHandV,
      handConfidence: _latchedHandConfidence,
      visorU: _latchedVisorU,
      visorV: _latchedVisorV,
      visorWidth: _latchedVisorWidth,
      joystickCameraRole: _latchedJoystickCameraRole,
      joystickMiniFrame: _latchedJoystickMiniFrame,
      mode: prev.mode,
    );
    _publishState(_latestState);
  }

  void _syncPredictorLatencyFromLink() {
    final link = _client;
    if (link is VrObservableControllerLink) {
      final oneWayMs = link.linkQualityListenable.value.oneWayEstimateMs;
      if (oneWayMs != null && oneWayMs.isFinite && oneWayMs > 0) {
        _posePredictor.updateLatency(
          Duration(microseconds: (oneWayMs * 1000.0).round().clamp(2000, 45000)),
        );
      }
    }
  }

  void _ingestCompactGamepadFrame(VrCompactGamepadFrame f, int now) {
    if (_wireFormat == VrControllerWireFormat.binaryPose) {
      _rejectedStates++;
      return;
    }
    final ackSink = _client is VrCompactGamepadAckSink
        ? _client! as VrCompactGamepadAckSink
        : null;
    if (_lastSequence != null) {
      final advance = (f.sequence - _lastSequence!) & 0xFFFFFFFF;
      if (advance == 0 || advance >= 0x80000000) {
        _rejectedStates++;
        ackSink?.acknowledgeCompactGamepadSequence(_lastSequence!);
        return;
      }
    }
    final mode = switch (f.modeIndex) {
      1 => RemoteControllerMode.laser,
      2 => RemoteControllerMode.driving,
      3 => RemoteControllerMode.nes,
      _ => RemoteControllerMode.joystick,
    };
    if (!_acceptsCompactModeState(f, mode)) {
      if (f.hostModeRevision != null &&
          f.hostModeRevision! < _modeRequest.revision) {
        _maybeResendControllerMode(now);
      }
      _rejectedStates++;
      return;
    }
    final drivingActive =
        mode == RemoteControllerMode.driving && !f.drivingPaused;
    final range =
        f.rangeMeters != null && f.rangeMeters!.isFinite && f.rangeMeters! > 0
        ? f.rangeMeters
        : null;
    final pose = VrRemotePoseFrame(
      sequence: f.sequence,
      senderTimestampMicroseconds: f.senderTimestampMicroseconds,
      orientation: f.orientation.clone(),
      angularVelocity: f.angularVelocity.clone(),
      rangeMeters: range,
      rangeSource: range != null ? VrRangeSource.fixed : null,
    );
    _syncPredictorLatencyFromLink();
    _posePredictor.pushFrame(pose);
    _posePredictor.predictTo(_predictedOrientation);
    _lastSequence = f.sequence;
    _wireFormat = VrControllerWireFormat.json;
    _lastStateReceivedUs = now;
    if (f.hostModeRevision != null) {
      _modeControlSupported = true;
      _acceptedModeRevision = f.hostModeRevision;
    }
    _latchedPassthroughMix = f.passthroughMix.clamp(0.0, 1.0);
    _latchedPassthroughActive = f.passthroughActive;
    _latchedSpatialHudVisible = f.spatialHudVisible;
    if (range != null) {
      _hasRangeTelemetry = true;
      _latchedRangeMeters = range;
    }

    _latestState = RemoteControllerState(
      passthroughCommandRevision: _passthroughCommandRevision,
      orientation: _predictedOrientation.clone(),
      angularVelocity: f.angularVelocity.clone(),
      isTriggerPressed: f.trigger || f.btnR,
      isActionPressed: f.action || f.btnB,
      btnA: f.btnA,
      btnB: f.btnB || f.action,
      btnX: f.btnX,
      btnY: f.btnY,
      btnL: f.btnL,
      btnR: f.btnR,
      btnZL: f.btnZL,
      btnZR: f.btnZR,
      btnGrip: f.btnGrip,
      stickClick: f.stickClick,
      stickX: f.stickX.clamp(-1.0, 1.0),
      stickY: f.stickY.clamp(-1.0, 1.0),
      moveAtEdge: f.moveAtEdge,
      dpadX: f.dpadX,
      dpadY: f.dpadY,
      touchX: f.stickX.clamp(-1.0, 1.0),
      touchY: f.stickY.clamp(-1.0, 1.0),
      turnRate: f.lookX.clamp(-1.0, 1.0),
      pitchRate: f.lookY.clamp(-1.0, 1.0),
      laserX: f.laserX.clamp(-1.0, 1.0),
      laserY: f.laserY.clamp(-1.0, 1.0),
      laserSlideActive: f.laserSlideActive,
      pointerPoseReady: f.pointerPoseReady,
      recenter: f.recenter,
      controllerVisible: f.controllerVisible,
      steering: drivingActive ? f.steering.clamp(-1.0, 1.0) : 0.0,
      drivingTilt: (drivingActive && f.motionAvailable)
          ? f.drivingTilt.clamp(-1.0, 1.0)
          : 0.0,
      throttle: drivingActive ? f.throttle.clamp(0.0, 1.0) : 0.0,
      brake: drivingActive ? f.brake.clamp(0.0, 1.0) : 0.0,
      drivingPaused: f.drivingPaused,
      motionAvailable: f.motionAvailable,
      rangeMeters: _latchedRangeMeters,
      passthroughMix: _latchedPassthroughMix,
      passthroughActive: _latchedPassthroughActive,
      spatialHudVisible: _latchedSpatialHudVisible,
      leftFootU: _latchedLeftFootU,
      leftFootV: _latchedLeftFootV,
      rightFootU: _latchedRightFootU,
      rightFootV: _latchedRightFootV,
      feetConfidence: _latchedFeetConfidence,
      handU: _latchedHandU,
      handV: _latchedHandV,
      handConfidence: _latchedHandConfidence,
      visorU: _latchedVisorU,
      visorV: _latchedVisorV,
      visorWidth: _latchedVisorWidth,
      joystickCameraRole: _latchedJoystickCameraRole,
      joystickMiniFrame: _latchedJoystickMiniFrame,
      mode: mode,
    );
    _lastAcceptedStateUs = now;
    _acceptedStates++;
    ackSink?.acknowledgeCompactGamepadSequence(f.sequence);
    _publishState(_latestState);
  }

  bool _acceptsCompactModeState(
    VrCompactGamepadFrame f,
    RemoteControllerMode mode,
  ) {
    final revision = f.hostModeRevision;
    if (revision == null) return !_modeControlSupported;
    if (revision != _modeRequest.revision) return false;
    if (_acceptedModeRevision == revision) return true;
    final modeMatches =
        mode == _modeRequest.mode ||
        (mode == RemoteControllerMode.laser &&
            _modeRequest.mode == RemoteControllerMode.joystick);
    if (!modeMatches) return false;
    if (_heldCaptionAckRevision == revision) return true;
    if (f.trigger ||
        f.action ||
        f.btnA ||
        f.btnB ||
        f.btnX ||
        f.btnY ||
        f.btnL ||
        f.btnR ||
        f.btnZL ||
        f.btnZR ||
        f.btnGrip ||
        f.stickClick ||
        f.recenter) {
      return false;
    }
    if (f.stickX != 0 ||
        f.stickY != 0 ||
        f.lookX != 0 ||
        f.lookY != 0 ||
        f.laserX != 0 ||
        f.laserY != 0 ||
        f.steering != 0 ||
        f.throttle != 0 ||
        f.brake != 0) {
      return false;
    }
    return true;
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
    _effectivePassthroughTimer?.cancel();
    _effectivePassthroughTimer = null;
    _trackingMarker = null;
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
      passthroughCommandRevision: _passthroughCommandRevision,
      orientation: _latestState.orientation.clone(),
      mode: _latestState.mode,
      drivingPaused: _latestState.mode == RemoteControllerMode.driving,
      isNeutralized: true,
      pointerPoseReady: false,
      controllerVisible: controllerVisible ?? _latestState.controllerVisible,
      rangeMeters: _hasRangeTelemetry
          ? _latchedRangeMeters
          : _latestState.rangeMeters,
      passthroughMix: _latchedPassthroughMix,
      passthroughActive: _latchedPassthroughActive,
      spatialHudVisible: _latchedSpatialHudVisible,
      leftFootU: _latchedLeftFootU,
      leftFootV: _latchedLeftFootV,
      rightFootU: _latchedRightFootU,
      rightFootV: _latchedRightFootV,
      feetConfidence: _latchedFeetConfidence,
      handU: _latchedHandU,
      handV: _latchedHandV,
      handConfidence: _latchedHandConfidence,
      visorU: _latchedVisorU,
      visorV: _latchedVisorV,
      visorWidth: _latchedVisorWidth,
      joystickCameraRole: _latchedJoystickCameraRole,
      joystickMiniFrame: _latchedJoystickMiniFrame,
    );
    _publishState(_latestState);
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
    _voiceLocomotionTimer?.cancel();
    _voiceLocomotionTimer = null;
    _voiceLocomotionStopTimer?.cancel();
    _voiceLocomotionStopTimer = null;
    _voiceButtonReleaseTimer?.cancel();
    _voiceButtonReleaseTimer = null;
    _handsFreeVirtualActive = false;
    _effectivePassthroughTimer?.cancel();
    _effectivePassthroughTimer = null;
    _lifecycleGeneration++;
    _castPreviewUri = null;
    _desktopBridgeState = null;
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
