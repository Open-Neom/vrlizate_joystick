part of '../phone_controller_page.dart';

extension _PhoneControllerNesDrivingLayouts on _PhoneControllerPageState {
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
          _refresh(() {
            _stickX = x;
            _stickY = y;
          });
          _sendState(force: true);
        },
        onButton: (button, down) {
          if (!accepts()) return;
          _refresh(() {
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
    final safeSize = MediaQuery.paddingOf(
      context,
    ).deflateSize(MediaQuery.sizeOf(context));
    final spacious = safeSize.width >= 760 && safeSize.height >= 400;
    final target = spacious ? 56.0 : 48.0;
    final gap = spacious ? 10.0 : 8.0;

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
              height: target,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  IconButton(
                    tooltip:
                        VrJoystickTranslationConstants.tooltipExitController,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints.tightFor(width: target),
                    icon: const Icon(Icons.arrow_back, color: Colors.white70),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            VrJoystickTranslationConstants.drivingHeaderTitle,
                            style: TextStyle(
                              color: Color(0xFF00E5FF),
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          _buildDrivingStatus(),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: gap),
                  TextButton(
                    onPressed: _toggleDrivingPause,
                    style: TextButton.styleFrom(
                      minimumSize: Size.square(target),
                    ),
                    child: Text(
                      _steering.state.paused
                          ? VrJoystickTranslationConstants.drivingButtonContinue
                          : VrJoystickTranslationConstants.drivingButtonPause,
                    ),
                  ),
                  SizedBox(width: gap),
                  TextButton(
                    onPressed: _isConnecting || !_hasConnectionTarget
                        ? null
                        : _connect,
                    style: TextButton.styleFrom(
                      minimumSize: Size.square(target),
                    ),
                    child: Text(_primaryConnectButtonLabel),
                  ),
                  SizedBox(width: gap),
                  IconButton(
                    tooltip:
                        VrJoystickTranslationConstants.tooltipSettingsAndMode,
                    padding: EdgeInsets.zero,
                    constraints: BoxConstraints.tightFor(width: target),
                    icon: const Icon(
                      Icons.settings_rounded,
                      color: Color(0xFF00E5FF),
                    ),
                    onPressed: _openSettings,
                  ),
                ],
              ),
            ),
            SizedBox(height: gap),
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
                      onDown: () => _refresh(
                        () => _brakePedalHeld = !_steering.state.paused,
                      ),
                      onUp: () => _refresh(() => _brakePedalHeld = false),
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    flex: 4,
                    child: Column(
                      children: [
                        SizedBox(
                          height: target,
                          child: Row(
                            children: [
                              Expanded(
                                child: control(
                                  VrJoystickConstants.actionKeyL,
                                  VrJoystickTranslationConstants
                                      .drivingViewMinus,
                                  _btnLActive,
                                  () => _refresh(() => _btnLActive = true),
                                  () => _refresh(() => _btnLActive = false),
                                ),
                              ),
                              SizedBox(width: gap),
                              Expanded(
                                child: control(
                                  VrJoystickConstants.actionKeyR,
                                  VrJoystickTranslationConstants
                                      .drivingViewPlus,
                                  _btnRActive,
                                  () => _refresh(() => _btnRActive = true),
                                  () => _refresh(() => _btnRActive = false),
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
                          height: target,
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
                  SizedBox(width: gap),
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
                      onDown: () => _refresh(
                        () => _throttlePedalHeld = !_steering.state.paused,
                      ),
                      onUp: () => _refresh(() => _throttlePedalHeld = false),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: gap),
            SizedBox(
              height: target,
              child: Row(
                children: [
                  Expanded(
                    child: control(
                      VrJoystickConstants.actionKeyX,
                      _actionLabel(VrJoystickConstants.actionKeyX),
                      _btnXActive,
                      () {
                        _refresh(() {
                          _steering.setPaused(true);
                          _releaseInputs();
                          _surfaceEpoch++;
                        });
                        _pulseDrivingAction(reset: true);
                      },
                      () => _refresh(() => _btnXActive = false),
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: control(
                      VrJoystickConstants.actionKeyY,
                      _actionLabel(VrJoystickConstants.actionKeyY),
                      _btnYActive,
                      () => _refresh(() => _btnYActive = true),
                      () => _refresh(() => _btnYActive = false),
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: control(
                      VrJoystickConstants.actionKeyA,
                      VrJoystickTranslationConstants.drivingPauseResumeCaption,
                      _btnAActive,
                      _toggleDrivingPause,
                      () {},
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    child: control(
                      VrJoystickConstants.actionKeyB,
                      _actionLabel(VrJoystickConstants.actionKeyB),
                      _btnBActive,
                      () => _refresh(() {
                        _steering.setPaused(true);
                        _releaseInputs();
                        _btnBActive = true;
                      }),
                      () => _refresh(() => _btnBActive = false),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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

  Widget _buildDrivingStatus() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
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
            ? VrJoystickTranslationConstants.drivingStatusTiltInstructions
            : VrJoystickTranslationConstants.drivingStatusPedalsOnly,
        style: const TextStyle(color: Colors.white70, fontSize: 10),
      ),
    ],
  );
}
