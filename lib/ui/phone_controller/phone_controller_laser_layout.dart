part of '../phone_controller_page.dart';

/// A separate, unmirrored diagnostic plot avoids claiming pixel registration
/// against device-specific mirrored GPU camera previews.
class _BodyLandmarkDiagnosticPainter extends CustomPainter {
  const _BodyLandmarkDiagnosticPainter(this.landmarks);
  final List<VrBodyLandmark> landmarks;

  static const _bones = <(int, int)>[
    (11, 12),
    (11, 13),
    (13, 15),
    (12, 14),
    (14, 16),
    (11, 23),
    (12, 24),
    (23, 24),
    (23, 25),
    (25, 27),
    (24, 26),
    (26, 28),
    (27, 29),
    (29, 31),
    (28, 30),
    (30, 32),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF080816),
    );
    final points = <int, VrBodyLandmark>{
      for (final landmark in landmarks)
        if (landmark.inFrameLikelihood >= .5 &&
            landmark.u >= 0 &&
            landmark.u <= 1 &&
            landmark.v >= 0 &&
            landmark.v <= 1)
          landmark.type: landmark,
    };
    Offset location(VrBodyLandmark point) =>
        Offset(point.u * size.width, point.v * size.height);
    final paint = Paint()
      ..color = const Color(0xFF10B981)
      ..strokeWidth = 1.5;
    for (final (start, end) in _bones) {
      final a = points[start];
      final b = points[end];
      if (a != null && b != null) {
        canvas.drawLine(location(a), location(b), paint);
      }
    }
    paint.color = const Color(0xFF7DD3FC);
    for (final point in points.values) {
      canvas.drawCircle(location(point), 2.5, paint);
    }
  }

  @override
  bool shouldRepaint(_BodyLandmarkDiagnosticPainter oldDelegate) =>
      !identical(landmarks, oldDelegate.landmarks);
}

extension _PhoneControllerLaserLayout on _PhoneControllerPageState {
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
          _refresh(() => _isLaserSlideActive = true);
          if (_hapticsEnabled) HapticFeedback.selectionClick();
          handleTouch(event.localPosition);
          _gripHoldTimer?.cancel();
          _gripHoldTimer = Timer(const Duration(milliseconds: 280), () {
            if (_acceptsSurfaceInput(surfaceEpoch) && _isLaserSlideActive) {
              _refresh(() => _btnGripActive = true);
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
          _refresh(() {
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

  // ─── Modo Puntero Láser 3DoF Layout (1 Mano + Tap/5s Clic + Long-Press Wordsphere) ───

  Widget _buildLaserPointerLayout() {
    return ValueListenableBuilder<Uri?>(
      valueListenable: _castPreview,
      builder: (context, castUri, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _laserAimViewRevision,
              builder: (context, _, _) {
                final yawDeg = _laserYaw * (180.0 / math.pi);
                final pitchDeg = _laserPitch * (180.0 / math.pi);
                return VrLaserPointingView(
                  aimX: _laserStickX,
                  aimY: _laserStickY,
                  yawDegrees: yawDeg,
                  pitchDegrees: pitchDeg,
                  dwellProgress: _laserSteadyDwell.progress,
                  dwellRemainingSeconds: _laserSteadyDwell.remainingSeconds,
                  clickActive: _triggerActive || _btnAActive,
                  pointingReady: _laserInteractionReady,
                  activeSearchQuery: _activeSearchQuery,
                  previewWidget: castUri == null
                      ? null
                      : _castImagePanel(castUri),
                  onTapClick: _pulseLaserClick,
                  onLongPressSearch: _openWordsphereSearchSheet,
                  onPanAimDelta: _nudgeLaserAimByPan,
                  onPanAimEnd: () {},
                  onRecenter: _recenterController,
                  onReturnToJoystick: () =>
                      _selectMode(RemoteControllerMode.joystick),
                );
              },
            ),
            if (_wordsphereSearchSheetVisible)
              Positioned.fill(
                child: VrWordsphereSearchSheet(
                  wordsphereController: _wordsphereController,
                  textController: _wordsphereTextController,
                  onQueryChanged: _onWordsphereQueryChanged,
                  onSubmitted: _submitWordsphereSearch,
                  onClose: _closeWordsphereSearchSheet,
                ),
              ),
          ],
        );
      },
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
            if (_isConnected && _linkQuality != null) ...[
              const SizedBox(width: 6),
              Container(
                key: const ValueKey('controller_link_quality_badge'),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _linkQuality!.isUdpUpgraded
                      ? const Color(0xFF10B981).withValues(alpha: 0.18)
                      : const Color(0xFF00E5FF).withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
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
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
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
