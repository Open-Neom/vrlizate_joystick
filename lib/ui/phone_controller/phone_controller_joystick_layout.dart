part of '../phone_controller_page.dart';

extension _PhoneControllerJoystickLayout on _PhoneControllerPageState {
  // ─── Modo Joystick Virtual Layout ────────────────────────────────────────

  Widget _buildJoystickLayout() {
    final driving = _activeMode == RemoteControllerMode.driving;
    final surfaceEpoch = _surfaceEpoch;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        final insets = _joystickSafeInsets(context);
        if (_joystickSize != constraints.biggest || _joystickInsets != insets) {
          _joystickSize = constraints.biggest;
          _joystickInsets = insets;
          _joystickGeometry = VrJoystickGeometry.fit(
            constraints.biggest,
            leftInset: insets.left,
            rightInset: insets.right,
            topInset: insets.top,
            bottomInset: insets.bottom,
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
          return Positioned.fromRect(
            rect: rect,
            child: _exclusivePassthroughControl(
              VrControllerRegion(
                key: ValueKey(
                  '${VrJoystickConstants.keyJoystickButtonPrefix}$title',
                ),
                path: _joystickLocalPaths[control]!,
                labelPosition: geometry.labels[control]! - rect.topLeft,
                label: title,
                actionLabel: subtitle,
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
                enableRimDpad: movement && !driving,
                onDpadChanged: movement
                    ? (dx, dy) {
                        if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                        _dpadX = dx;
                        _dpadY = dy;
                        _sendState(force: true);
                      }
                    : null,
                onPressed: (pressed) {
                  if (!_acceptsSurfaceInput(surfaceEpoch)) return;
                  final nowUs = _nowUs;
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
                  final nowUs = _nowUs;
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
                  final nowUs = _nowUs;
                  if (movement) {
                    final locked = _leftAutoWalkController.onPointerUp(
                      nowUs,
                      autoWalkEnabled: _autoWalkLockEnabled,
                    );
                    if (locked) {
                      _moveAtEdge = true;
                      _moveResponse.setInput(0.0, 1.0);
                      _refresh(() {});
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
              timestampUs: _nowUs,
            );
            if (changed) {
              _sendGesturePassthroughChange(previousMix);
              _lastPassthroughHapticBucket =
                  (_passthroughGesture.passthroughMix * 4).round();
              _hapticLight();
              _refresh(() {});
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
              timestampUs: _nowUs,
            );
            if (changed) {
              _sendGesturePassthroughChange(previousMix);
              final bucket = (_passthroughGesture.passthroughMix * 4).round();
              if (bucket != _lastPassthroughHapticBucket) {
                _lastPassthroughHapticBucket = bucket;
                _hapticClick();
              }
              _refresh(() {});
              _sendState();
            }
          },
          onPointerUp: (event) {
            if (_exclusiveControlPointers.remove(event.pointer)) return;
            final previousMix = _passthroughGesture.passthroughMix;
            final changed = _passthroughGesture.onPointerUpOrCancel(
              pointerId: event.pointer,
              timestampUs: _nowUs,
            );
            if (changed && mounted) {
              _sendGesturePassthroughChange(previousMix);
              _hapticMedium();
              _refresh(() {});
              _sendState(force: true);
            }
          },
          onPointerCancel: (event) {
            if (_exclusiveControlPointers.remove(event.pointer)) return;
            final previousMix = _passthroughGesture.passthroughMix;
            final changed = _passthroughGesture.onPointerUpOrCancel(
              pointerId: event.pointer,
              timestampUs: _nowUs,
            );
            if (changed && mounted) {
              _sendGesturePassthroughChange(previousMix);
              _refresh(() {});
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
                onDown: () => _refresh(
                  () => _btnLActive = !driving || !_steering.state.paused,
                ),
                onUp: () => _refresh(() => _btnLActive = false),
              ),
              button(
                VrJoystickControl.r,
                title: VrJoystickConstants.actionKeyR,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyR),
                active: _btnRActive,
                colors: const [Color(0xFFFF9100), Color(0xFFD64D18)],
                onDown: () => _refresh(
                  () => _btnRActive = !driving || !_steering.state.paused,
                ),
                onUp: () => _refresh(() => _btnRActive = false),
              ),
              button(
                VrJoystickControl.zl,
                title: VrJoystickConstants.actionKeyZL,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyZL),
                active: _btnZLActive,
                colors: const [Color(0xFF18687E), Color(0xFF294D94)],
                onDown: () => _refresh(() => _btnZLActive = true),
                onUp: () => _refresh(() => _btnZLActive = false),
              ),
              button(
                VrJoystickControl.zr,
                title: VrJoystickConstants.actionKeyZR,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyZR),
                active: _btnZRActive,
                colors: const [Color(0xFFE06A23), Color(0xFFAF3A32)],
                onDown: () => _refresh(() => _btnZRActive = true),
                onUp: () => _refresh(() => _btnZRActive = false),
              ),
              button(
                VrJoystickControl.y,
                title: VrJoystickConstants.actionKeyY,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyY),
                active: _btnYActive,
                colors: const [Color(0xFFFFD54F), Color(0xFFF59E0B)],
                textColor: const Color(0xFF211500),
                onDown: () => _refresh(() => _btnYActive = true),
                onUp: () => _refresh(() => _btnYActive = false),
              ),
              button(
                VrJoystickControl.x,
                title: VrJoystickConstants.actionKeyX,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyX),
                active: _btnXActive,
                colors: const [Color(0xFF2979FF), Color(0xFF1555BA)],
                onDown: () {
                  if (driving) {
                    _refresh(() {
                      _steering.setPaused(true);
                      _releaseInputs();
                      _surfaceEpoch++;
                    });
                    _pulseDrivingAction(reset: true);
                  } else {
                    _refresh(() => _btnXActive = true);
                  }
                },
                onUp: () => _refresh(() => _btnXActive = false),
              ),
              button(
                VrJoystickControl.b,
                title: VrJoystickConstants.actionKeyB,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyB),
                active: _btnBActive,
                colors: const [Color(0xFFFF5252), Color(0xFFB71C45)],
                onDown: () => _refresh(() {
                  if (driving) {
                    _steering.setPaused(true);
                    _releaseInputs();
                  }
                  _btnBActive = true;
                }),
                onUp: () => _refresh(() => _btnBActive = false),
              ),
              button(
                VrJoystickControl.a,
                title: VrJoystickConstants.actionKeyA,
                subtitle: _actionLabel(VrJoystickConstants.actionKeyA),
                active: _btnAActive,
                colors: const [Color(0xFF10B981), Color(0xFF087848)],
                onDown: driving
                    ? _selectDrivingMenu
                    : () => _refresh(() => _btnAActive = true),
                onUp: () => _refresh(() => _btnAActive = false),
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
                child: _buildJoystickCenter(
                  buttonHeight: math.max(
                    44,
                    geometry[VrJoystickControl.recenter].height,
                  ),
                  buttonGap:
                      geometry.previewPanel.top -
                      geometry[VrJoystickControl.recenter].bottom,
                ),
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

  Widget _buildJoystickCenter({
    required double buttonHeight,
    required double buttonGap,
  }) => LayoutBuilder(
    key: const ValueKey(VrJoystickConstants.keyControllerCenterPanel),
    builder: (context, constraints) => ValueListenableBuilder<Uri?>(
      valueListenable: _castPreview,
      builder: (context, uri, _) => Column(
        children: [
          if (constraints.maxHeight >= 150 &&
              _isConnected &&
              _linkQuality?.advisory != null &&
              _dismissedAdvisoryCode != _linkQuality!.advisory!.code) ...[
            _buildLinkAdvisoryBanner(_linkQuality!.advisory!),
            const SizedBox(height: 3),
          ],
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
          if (constraints.maxHeight >= buttonHeight + 30 + buttonGap &&
              _canDisplayCastUi)
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
          if (constraints.maxHeight >= buttonHeight + 64 + buttonGap)
            _exclusivePassthroughControl(
              VrBreakthroughCurtainBar(
                passthroughMix: _reportedPassthroughMix,
                connected: _isConnected,
                synchronized: _hasEffectivePassthroughState,
                pending: _pendingPassthroughMix != null,
                spatialHudVisible: _spatialHudVisible,
                showSpatialHudToggle:
                    _deviceHasConcurrentCameras != false ||
                    (_linkQuality?.peerSupportsConcurrentCameras ?? false),
                onMixChanged: _setBreakthroughMix,
                onToggleMix: _toggleBreakthroughMix,
                onToggleSpatialHud: () => _toggleSpatialHud(),
              ),
            ),
          if (constraints.maxHeight >= buttonHeight + 30 + buttonGap)
            SizedBox(height: buttonGap),
          SizedBox(
            height: math.min(buttonHeight, constraints.maxHeight),
            child: Row(
              children: [
                for (final laser in [false, true]) ...[
                  if (laser) SizedBox(width: buttonGap),
                  Expanded(
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
                                ? VrJoystickTranslationConstants.rightModeLaser
                                : VrJoystickTranslationConstants.rightModeView,
                          ),
                        ),
                        style: TextButton.styleFrom(
                          minimumSize: Size(0, buttonHeight),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                ],
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
        if (_desktopBridge case final bridge? when bridge.stationConnected) ...[
          Container(
            key: const ValueKey('joystick_desktop_bridge_banner'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF00E676).withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: const Color(0xFF00E676).withValues(alpha: 0.55),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  bridge.castOffloadedToDesktop
                      ? 'Vista en ${bridge.stationName ?? "PC Faro"} · Joystick liberado'
                      : 'Puente activo · ${bridge.stationName ?? "PC Faro"}',
                  style: const TextStyle(
                    color: Color(0xFF69F0AE),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (bridge.activeDecisionSummary case final summary?)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      summary,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9.5,
                      ),
                    ),
                  ),
                if (bridge.substituteGyroWithPcVision)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Text(
                      'Orientación asistida por Webcam PC',
                      style: TextStyle(
                        color: Color(0xFF80D8FF),
                        fontSize: 9.0,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
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
        if (_hostActions.containsKey(VrJoystickConstants.actionKeyZL) ||
            _hostActions.containsKey(VrJoystickConstants.actionKeyZR)) ...[
          const SizedBox(height: 4),
          Text(
            [
              for (final key in const [
                VrJoystickConstants.actionKeyZL,
                VrJoystickConstants.actionKeyZR,
              ])
                if (_hostActions.containsKey(key))
                  '$key · ${_actionLabel(key)}',
            ].join(VrJoystickConstants.centerGuideSpacer),
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
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
                        : _isFaroWifiExternalLink
                        ? (_isConnected
                              ? Icons.wifi_tethering_rounded
                              : Icons.portable_wifi_off_rounded)
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
                        _primaryConnectButtonLabel,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_isConnected && _linkQuality != null) ...[
                  const SizedBox(width: 4),
                  Container(
                    key: const ValueKey('controller_link_quality_badge'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: _linkQuality!.isUdpUpgraded
                          ? const Color(0xFF10B981).withValues(alpha: 0.18)
                          : const Color(0xFF00E5FF).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: _linkQuality!.isUdpUpgraded
                            ? const Color(0xFF10B981).withValues(alpha: 0.65)
                            : const Color(0xFF00E5FF).withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      _linkQuality!.compactBadgeLabel,
                      style: TextStyle(
                        color: _linkQuality!.isUdpUpgraded
                            ? const Color(0xFF10B981)
                            : const Color(0xFF7DD3FC),
                        fontSize: 8.0,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
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
}
