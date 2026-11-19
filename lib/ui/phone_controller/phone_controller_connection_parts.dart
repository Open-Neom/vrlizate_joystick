part of '../phone_controller_page.dart';

const _reconnectDelays = [
  Duration(milliseconds: 500),
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 10),
];

const _bluetoothPairingNotice =
    VrJoystickTranslationConstants.statusBluetoothPairingNotice;

Future<void> _closeLink(VrControllerLink link) async {
  try {
    await link.close();
  } catch (_) {
    // A failed transport teardown must not interfere with another session.
  }
}

bool _isSessionExpired(Object error) =>
    (error is VrControllerConnectionException && error.isSessionExpired) ||
    (error is WebSocketException &&
        (error.httpStatusCode == HttpStatus.unauthorized ||
            error.httpStatusCode == HttpStatus.forbidden));

bool _canRetryConnection(Object error) {
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

extension _PhoneControllerConnectionParts on _PhoneControllerPageState {
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
        _refresh(() {
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
                _refresh(() {
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
      : _isFaroWifiExternalLink
      ? VrJoystickTranslationConstants.transportFaroWifi
      : widget.transportType == VrTransportType.bluetoothLe ||
            !widget.allowWifiConnection
      ? VrJoystickTranslationConstants.transportBluetoothLe
      : VrJoystickTranslationConstants.transportExternalLink;

  bool get _usesExternalLink =>
      widget.linkConnector != null &&
      (!widget.allowWifiConnection || !_useWifiOverride);

  bool get _isFaroWifiExternalLink =>
      _usesExternalLink && widget.externalLinkOverWifi;

  bool get _showsBluetooth =>
      (!widget.allowWifiConnection || _usesExternalLink) &&
      !_isFaroWifiExternalLink;

  String get _primaryConnectButtonLabel {
    if (_isFaroWifiExternalLink) {
      return _isConnected
          ? VrJoystickTranslationConstants.statusFaroWifiConnectedShort
          : VrJoystickTranslationConstants.buttonConnectFaro;
    }
    return _isConnected
        ? VrJoystickTranslationConstants.buttonReconnect
        : VrJoystickTranslationConstants.buttonConnect;
  }

  bool get _hasConnectionTarget =>
      _usesExternalLink || widget.allowWifiConnection;

  String get _targetDescription => (_showsBluetooth || _isFaroWifiExternalLink)
      ? _externalConnectionLabel
      : '${_lastTarget?.host ?? widget.targetHost ?? _discoveredHost ?? VrJoystickTranslationConstants.statusUnpairedLabel}${VrJoystickConstants.colonSeparator}$_targetPort${VrJoystickConstants.spaceOpenParen}$_transportLabel${VrJoystickConstants.closeParen}';

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

  Future<void> _connect({bool automatic = false}) async {
    if (!mounted || !_surfaceMounted || !_isForeground || _isConnecting) {
      return;
    }
    if (automatic && !_canReconnect) return;
    if (!_hasConnectionTarget) {
      _stopAutomaticReconnect();
      _refresh(() => _status = _bluetoothPairingNotice);
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
      _refresh(() => _status = error.message);
      return;
    } on UnsupportedError catch (error) {
      _stopAutomaticReconnect();
      _refresh(
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
    _refresh(() {
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
      _attachLinkQuality(socket);
      _hostModeSession.reset();
      _effectivePassthroughRevision = -1;
      _desktopBridgeRevision = -1;
      _desktopBridge = null;
      unawaited(_visionService.setDesktopOffloadPaused(false));
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
      _refresh(() {
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
      unawaited(_announceAiCapabilities(socket, generation));
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
        _refresh(() {
          _isConnected = false;
          _isConnecting = false;
          // Exceptions can contain the authenticated URL; don't echo secrets.
          _status = expired
              ? VrJoystickTranslationConstants.statusLinkExpired
              : _isFaroWifiExternalLink
              ? '${VrJoystickTranslationConstants.statusExternalConnectFailedPrefix}$_externalConnectionLabel${VrJoystickTranslationConstants.statusFaroConnectFailedSuffix}'
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

  void _attachLinkQuality(VrControllerLink socket) {
    _detachLinkQuality(notify: false);
    if (socket is VrObservableControllerLink) {
      _observableLink = socket;
      _linkQuality = socket.linkQualityListenable.value;
      socket.linkQualityListenable.addListener(_onLinkQualityChanged);
      _applyLinkQuality(_linkQuality);
    }
  }

  void _detachLinkQuality({bool notify = true}) {
    final prev = _observableLink;
    if (prev != null) {
      prev.linkQualityListenable.removeListener(_onLinkQualityChanged);
    }
    _observableLink = null;
    _linkQuality = null;
    _restartStreamTimer(16);
    if (notify && mounted) _refresh(() {});
  }

  void _onLinkQualityChanged() {
    final current = _observableLink?.linkQualityListenable.value;
    if (!mounted || current == _linkQuality) return;
    _refresh(() {
      _linkQuality = current;
    });
    _applyLinkQuality(current);
  }

  void _applyLinkQuality(VrControllerLinkQuality? quality) {
    final bridgeHz = (_desktopBridge?.stationConnected ?? false)
        ? _desktopBridge!.recommendedJoystickHz
        : 60;
    final effectiveHz = quality != null
        ? math.max(quality.recommendedHz, !_showsBluetooth ? bridgeHz : 60)
        : (!_showsBluetooth ? bridgeHz : 60);
    final targetMs = effectiveHz >= 120 ? 8 : 16;
    _restartStreamTimer(targetMs);
    final offloadedToDesktop = _desktopBridge?.castOffloadedToDesktop ?? false;
    if (offloadedToDesktop || (quality != null && !quality.canCarryVideoCast)) {
      if (_castPreview.value != null) _castPreview.value = null;
    } else if (_isForeground &&
        _castAutoEnabled &&
        !_deviceIsLowRam &&
        _castOffer != null &&
        _castPreview.value == null) {
      _castPreview.value = _castOffer;
    }
  }

  void _clearCast({bool forgetOffer = true}) {
    _castGeneration++;
    if (forgetOffer) {
      _castOffer = null;
      _castAutoEnabled = !_deviceIsLowRam;
    }
    _castPreview.value = null;
  }

  bool get _canDisplayCastUi => _linkQuality?.canCarryVideoCast ?? true;

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
      if (_isForeground &&
          _castAutoEnabled &&
          _canDisplayCastUi &&
          !(_desktopBridge?.castOffloadedToDesktop ?? false)) {
        _castPreview.value = uri;
      }
      if (mounted) _refresh(() {});
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
    _refresh(() {
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
    _refresh(() {
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
      if (mounted) _refresh(() => _castDialogOpen = false);
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
    _refresh(() {
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
      if (mounted) _refresh(() => _castDialogOpen = false);
    }
  }

  bool _acceptDesktopBridgeState(Object? data) {
    final bridge = VrDesktopBridgeState.tryParseMessage(data);
    if (bridge == null) return false;
    if (bridge.revision <= _desktopBridgeRevision) return true;
    _desktopBridgeRevision = bridge.revision;
    final activeBridge = bridge.stationConnected ? bridge : null;
    if (activeBridge != null && activeBridge.castOffloadedToDesktop) {
      _castPreview.value = null;
    } else if (activeBridge == null &&
        _isForeground &&
        _castAutoEnabled &&
        !_deviceIsLowRam &&
        _canDisplayCastUi &&
        _castOffer != null) {
      _castPreview.value = _castOffer;
    }
    unawaited(
      _visionService.setDesktopOffloadPaused(
        activeBridge != null && activeBridge.visionOffloadedToDesktop,
      ),
    );
    _refresh(() {
      _desktopBridge = activeBridge;
    });
    _applyLinkQuality(_linkQuality);
    if (activeBridge?.hapticAlert == 'desk_proximity_warning') {
      _hapticDoublePulse();
    } else if (activeBridge?.hapticAlert == 'hand_pinch_confirm') {
      _hapticClick();
    }
    return true;
  }

  void _onHostMessage(Object? data, VrControllerLink socket, int generation) {
    if (!mounted ||
        !_surfaceMounted ||
        generation != _socketGeneration ||
        !identical(_socket, socket)) {
      return;
    }
    if (_acceptEffectivePassthroughState(data) ||
        _acceptDesktopBridgeState(data) ||
        _acceptCastOffer(data) ||
        _acceptHapticPulse(data) ||
        _acceptAiInferRequest(data, socket, generation)) {
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
      _refresh(() => _hostActions = request.actions);
      _sendState(force: true);
      return;
    }
    final preservePause = request.mode == _activeMode && _steering.state.paused;
    // Mode requests are scoped to this authenticated socket. Send no packet
    // between accepting its revision and installing a completely neutral mode.
    _refresh(() {
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
      _lastDrivingTickUs = _nowUs;
      _status = request.mode == RemoteControllerMode.driving
          ? VrJoystickTranslationConstants.statusDrivingReady
          : request.mode == RemoteControllerMode.nes
          ? VrJoystickTranslationConstants.statusNesReady
          : VrJoystickTranslationConstants.statusJoystickReady;
    });
    _syncImuSubscriptions();
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
    _detachLinkQuality(notify: false);
    _linkSubscription?.cancel();
    _linkSubscription = null;
    unawaited(_closeLink(socket));
    _socketGeneration = 0;
    _hostModeSession.reset();
    _lastHostMode = null;
    _hostActions = const {};
    _desktopBridge = null;
    _desktopBridgeRevision = -1;
    unawaited(_visionService.setDesktopOffloadPaused(false));
    _clearCast();
    _statePacer.reset();
    if (_activeMode == RemoteControllerMode.driving) {
      _steering.setPaused(true);
    }
    _releaseInputs();
    _refresh(() {
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

  Future<void> _announceAiCapabilities(
    VrControllerLink socket,
    int generation,
  ) async {
    final coProcessor =
        widget.aiCoProcessor ?? VrJoystickAiCoProcessor.defaultCoProcessor;
    if (coProcessor == null) return;
    try {
      final caps = await coProcessor.probeCapabilities();
      if (!mounted ||
          !_isConnected ||
          generation != _socketGeneration ||
          !identical(_socket, socket) ||
          !socket.isOpen) {
        return;
      }
      socket.add(
        jsonEncode({
          VrJoystickConstants.fieldType:
              VrJoystickConstants.aiCapabilitiesMessageType,
          'supported': caps.supported,
          'engine': caps.engineLabel,
          'ramMb': caps.ramMb,
        }),
      );
    } catch (_) {
      // Optional AI capability discovery must never disrupt controller input.
    }
  }

  bool _acceptHapticPulse(Object? data) {
    if (data is! String || data.length > 160) return false;
    if (!data.contains(VrJoystickConstants.hapticPulseMessageType)) {
      return false;
    }
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic> ||
          decoded[VrJoystickConstants.fieldType] !=
              VrJoystickConstants.hapticPulseMessageType) {
        return false;
      }
      if (!_hapticsEnabled) return true;
      switch (decoded['p']) {
        case 'heavy':
          HapticFeedback.heavyImpact();
          break;
        case 'medium':
          HapticFeedback.mediumImpact();
          break;
        default:
          HapticFeedback.selectionClick();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _acceptAiInferRequest(
    Object? data,
    VrControllerLink socket,
    int generation,
  ) {
    if (data is! String || data.length > 4096) return false;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return false;
    }
    if (decoded is! Map<String, dynamic> ||
        decoded[VrJoystickConstants.fieldType] !=
            VrJoystickConstants.aiInferRequestMessageType) {
      return false;
    }
    final reqId = decoded['reqId'];
    final prompt = decoded['prompt'];
    final sys = decoded['sys'];
    final maxTok = decoded['maxTok'];
    if (reqId is! String ||
        reqId.isEmpty ||
        reqId.length > 48 ||
        prompt is! String ||
        prompt.trim().isEmpty ||
        prompt.length > 2048 ||
        (sys != null && (sys is! String || sys.length > 1024))) {
      return true;
    }
    final coProcessor =
        widget.aiCoProcessor ?? VrJoystickAiCoProcessor.defaultCoProcessor;
    if (coProcessor == null) {
      try {
        socket.add(
          jsonEncode({
            VrJoystickConstants.fieldType:
                VrJoystickConstants.aiInferResponseMessageType,
            'reqId': reqId,
            'ok': false,
            'text': '',
            'engine': 'unavailable',
          }),
        );
      } catch (_) {}
      return true;
    }
    final boundedMaxTokens = (maxTok is int ? maxTok : 160).clamp(32, 320);
    unawaited(() async {
      try {
        final result = await coProcessor.infer(
          prompt: prompt,
          systemPrompt: sys as String?,
          maxTokens: boundedMaxTokens,
        );
        if (!mounted ||
            !_isConnected ||
            generation != _socketGeneration ||
            !identical(_socket, socket) ||
            !socket.isOpen) {
          return;
        }
        var replyText = result.text.trim();
        // Keep UTF-8 payload well below 1023-byte BLE GATT control frame ceiling.
        while (utf8.encode(replyText).length > 760 && replyText.length > 32) {
          replyText =
              '${replyText.substring(0, (replyText.length * 0.85).floor())}…';
        }
        socket.add(
          jsonEncode({
            VrJoystickConstants.fieldType:
                VrJoystickConstants.aiInferResponseMessageType,
            'reqId': reqId,
            'ok': result.ok && replyText.isNotEmpty,
            'text': replyText,
            'engine': result.engineLabel,
          }),
        );
      } catch (_) {
        if (mounted &&
            _isConnected &&
            generation == _socketGeneration &&
            identical(_socket, socket) &&
            socket.isOpen) {
          try {
            socket.add(
              jsonEncode({
                VrJoystickConstants.fieldType:
                    VrJoystickConstants.aiInferResponseMessageType,
                'reqId': reqId,
                'ok': false,
                'text': '',
                'engine': 'error',
              }),
            );
          } catch (_) {}
        }
      }
    }());
    return true;
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
                      : _isFaroWifiExternalLink
                      ? (_isConnected
                            ? Icons.wifi_tethering_rounded
                            : Icons.portable_wifi_off_rounded)
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
                    (_showsBluetooth || _isFaroWifiExternalLink)
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
            _primaryConnectButtonLabel,
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

  Widget _buildLinkAdvisoryBanner(VrLinkPerformanceAdvisory advisory) {
    final isWarning = advisory.severity == VrLinkAdvisorySeverity.warning;
    final accent = isWarning
        ? const Color(0xFFFFB74D)
        : const Color(0xFF7DD3FC);
    return GestureDetector(
      key: const ValueKey('controller_link_advisory_banner'),
      onTap: () => _refresh(() => _dismissedAdvisoryCode = advisory.code),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Icon(
              isWarning ? Icons.speed_rounded : Icons.tips_and_updates_outlined,
              size: 12,
              color: accent,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                advisory.message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: accent,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.close_rounded, size: 12, color: accent),
          ],
        ),
      ),
    );
  }
}
