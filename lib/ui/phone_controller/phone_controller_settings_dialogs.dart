part of '../phone_controller_page.dart';

extension _PhoneControllerSettingsDialogs on _PhoneControllerPageState {
  void _showIpConfigDialog() => _openSettings();

  void _openSettings() {
    if (_settingsOpen) return;
    _refresh(() {
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
                        title: VrJoystickTranslationConstants.laserOneHandBadge,
                        subtitle: VrJoystickTranslationConstants
                            .statusLaserOneHandReady,
                        icon: Icons.bolt_rounded,
                        isSelected: _activeMode == RemoteControllerMode.laser,
                        onTap: () {
                          _selectMode(RemoteControllerMode.laser);
                          setModalState(() {});
                          Navigator.of(ctx).pop();
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
                                  _refresh(() => _useWifiOverride = next);
                                },
                              ),
                              const SizedBox(height: 8),
                            ],
                            Row(
                              children: [
                                Expanded(
                                  child:
                                      (_showsBluetooth ||
                                          _isFaroWifiExternalLink)
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
                                              _isFaroWifiExternalLink
                                                  ? VrJoystickTranslationConstants
                                                        .settingsFaroWifiSubtitle
                                                  : _usesExternalLink
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
                                            _refresh(
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
                                    _primaryConnectButtonLabel,
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
                            _refresh(() {
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
                          _refresh(() => _shakeToToggleEnabled = val);
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
                          _refresh(() => _hapticsEnabled = val);
                          setModalState(() {});
                          _persistHaptics(val);
                          if (val) {
                            _hapticLight();
                          }
                        },
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _spatialHudVisible,
                        activeThumbColor: const Color(0xFF10B981),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsSpatialHudTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsSpatialHudSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          _toggleSpatialHud(val);
                          setModalState(() {});
                        },
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey(
                          'controller-public-tracking-marker',
                        ),
                        onPressed: _openPublicTrackingMarker,
                        icon: const Icon(Icons.qr_code_2, size: 16),
                        label: const Text('Marcador de calibración'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF7DD3FC),
                        ),
                      ),
                      ListenableBuilder(
                        listenable: _visionService,
                        builder: (context, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SwitchListTile(
                              key: const ValueKey(
                                'controller-auxiliary-camera',
                              ),
                              contentPadding: EdgeInsets.zero,
                              value: _visionService.enableHardwareCameraStream,
                              activeThumbColor: const Color(0xFF10B981),
                              title: const Text(
                                'Cámara auxiliar',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              subtitle: const Text(
                                'Usa una lente de este mando. '
                                'Permanece activa aunque ocultes el HUD; la cámara del visor es independiente.',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                ),
                              ),
                              onChanged: _cameraSettingsBusy
                                  ? null
                                  : (enabled) async {
                                      setModalState(
                                        () => _cameraSettingsBusy = true,
                                      );
                                      _visionService
                                              .enableHardwareCameraStream =
                                          enabled;
                                      try {
                                        if (enabled) {
                                          await _visionService.start();
                                        } else {
                                          await _visionService.stop();
                                        }
                                      } finally {
                                        if (ctx.mounted) {
                                          setModalState(
                                            () => _cameraSettingsBusy = false,
                                          );
                                        } else {
                                          _cameraSettingsBusy = false;
                                        }
                                      }
                                    },
                            ),
                            if (_visionService.enableHardwareCameraStream) ...[
                              SwitchListTile(
                                key: const ValueKey(
                                  'controller-body-detection',
                                ),
                                contentPadding: EdgeInsets.zero,
                                value: _visionService.bodyDetectionEnabled,
                                activeThumbColor: const Color(0xFF10B981),
                                title: const Text(
                                  'Detección corporal',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                subtitle: const Text(
                                  'Modelo local de 33 puntos, una persona. Usa resolución media '
                                  'y hasta 2 análisis/s con presupuesto adaptativo sobre esta misma cámara. No mide distancia.',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 10,
                                  ),
                                ),
                                onChanged: _cameraSettingsBusy
                                    ? null
                                    : (enabled) async {
                                        setModalState(
                                          () => _cameraSettingsBusy = true,
                                        );
                                        try {
                                          await _visionService
                                              .setBodyDetectionEnabled(enabled);
                                        } finally {
                                          if (ctx.mounted) {
                                            setModalState(
                                              () => _cameraSettingsBusy = false,
                                            );
                                          } else {
                                            _cameraSettingsBusy = false;
                                          }
                                        }
                                      },
                              ),
                              if (_visionService.bodyDetectionEnabled)
                                _buildBodyInferenceDiagnostic(),
                              DropdownButton<String>(
                                key: const ValueKey(
                                  'controller-auxiliary-lens',
                                ),
                                isExpanded: true,
                                dropdownColor: const Color(0xFF101528),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                                value: _visionService.autoMultiplexLenses
                                    ? 'auto'
                                    : _visionService.activeRole,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'rear',
                                    child: Text('Lente trasera · estable'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'front',
                                    child: Text('Lente frontal · estable'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'auto',
                                    child: Text(
                                      'Auto · alterna lentes; no simultáneas',
                                    ),
                                  ),
                                ],
                                onChanged: _cameraSettingsBusy
                                    ? null
                                    : (mode) async {
                                        if (mode == null) return;
                                        setModalState(
                                          () => _cameraSettingsBusy = true,
                                        );
                                        try {
                                          await _visionService
                                              .setCameraLensMode(mode);
                                        } finally {
                                          if (ctx.mounted) {
                                            setModalState(
                                              () => _cameraSettingsBusy = false,
                                            );
                                          } else {
                                            _cameraSettingsBusy = false;
                                          }
                                        }
                                      },
                              ),
                              Text(
                                _cameraSettingsBusy
                                    ? 'Preparando cámara…'
                                    : _visionService.isCameraStreaming
                                    ? 'Activa · ${_visionService.cameraFramesProcessed} analizados · '
                                          '${_visionService.cameraFramesDropped} descartados · '
                                          'análisis ${(_visionService.lastCameraProcessingMicroseconds / 1000).toStringAsFixed(2)} ms'
                                    : _visionService.lastCameraError != null
                                    ? 'Cámara no disponible: ${_visionService.lastCameraError}'
                                    : 'Sin captura. Comprueba el permiso de cámara.',
                                key: const ValueKey(
                                  'controller-camera-performance',
                                ),
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                ),
                              ),
                              SwitchListTile(
                                key: const ValueKey(
                                  'controller-auxiliary-preview-toggle',
                                ),
                                contentPadding: EdgeInsets.zero,
                                value: _showAuxiliaryCameraPreview,
                                activeThumbColor: const Color(0xFF10B981),
                                title: const Text(
                                  'Ver cámara auxiliar',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                                subtitle: const Text(
                                  'Vista local para orientar la lente seleccionada, '
                                  'compartiendo su captura activa.',
                                  style: TextStyle(
                                    color: Colors.white60,
                                    fontSize: 10,
                                  ),
                                ),
                                onChanged: (value) => setModalState(
                                  () => _showAuxiliaryCameraPreview = value,
                                ),
                              ),
                              if (_showAuxiliaryCameraPreview)
                                _buildAuxiliaryCameraPreview(),
                            ],
                            SwitchListTile(
                              key: const ValueKey(
                                'controller-experimental-sonar',
                              ),
                              contentPadding: EdgeInsets.zero,
                              value: _visionService.enableUltrasonicRanging,
                              activeThumbColor: const Color(0xFFFF9100),
                              title: const Text(
                                'Sondeo acústico experimental',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                              subtitle: Text(
                                _visionService.ultrasonicUnavailable
                                    ? 'Sin medición calibrada disponible. Desactiva y activa para reintentar.'
                                    : 'Usa micrófono y altavoz. Sólo informa distancia con una medición calibrada; '
                                          'no es sensado por Wi-Fi o Bluetooth.',
                                style: const TextStyle(
                                  color: Colors.white60,
                                  fontSize: 10,
                                ),
                              ),
                              onChanged: (enabled) {
                                _visionService.enableUltrasonicRanging =
                                    enabled;
                                setModalState(() {});
                              },
                            ),
                          ],
                        ),
                      ),
                      SwitchListTile(
                        key: const ValueKey(
                          VrJoystickConstants.keyControllerDynamicOriginToggle,
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: _dynamicTouchOriginEnabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsDynamicOriginTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsDynamicOriginSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          _refresh(() => _dynamicTouchOriginEnabled = val);
                          setModalState(() {});
                          unawaited(
                            _persistBoolPref(
                              VrJoystickConstants.prefKeyDynamicTouchOrigin,
                              val,
                            ),
                          );
                        },
                      ),
                      SwitchListTile(
                        key: const ValueKey(
                          VrJoystickConstants
                              .keyControllerCardinalDetentsToggle,
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: _cardinalDetentsEnabled,
                        activeThumbColor: const Color(0xFF00E5FF),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsCardinalDetentsTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsCardinalDetentsSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          _refresh(() => _cardinalDetentsEnabled = val);
                          setModalState(() {});
                          unawaited(
                            _persistBoolPref(
                              VrJoystickConstants.prefKeyCardinalDetentsEnabled,
                              val,
                            ),
                          );
                        },
                      ),
                      SwitchListTile(
                        key: const ValueKey(
                          VrJoystickConstants.keyControllerAutoWalkToggle,
                        ),
                        contentPadding: EdgeInsets.zero,
                        value: _autoWalkLockEnabled,
                        activeThumbColor: const Color(0xFF10B981),
                        title: const Text(
                          VrJoystickTranslationConstants
                              .settingsAutoWalkLockTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: const Text(
                          VrJoystickTranslationConstants
                              .settingsAutoWalkLockSubtitle,
                          style: TextStyle(color: Colors.white60, fontSize: 10),
                        ),
                        onChanged: (val) {
                          _refresh(() {
                            _autoWalkLockEnabled = val;
                            if (!val) {
                              _leftAutoWalkController.reset();
                              _moveAtEdge = false;
                              _moveResponse.reset();
                              _updateJoystick();
                            }
                          });
                          setModalState(() {});
                          unawaited(
                            _persistBoolPref(
                              VrJoystickConstants.prefKeyAutoWalkLockEnabled,
                              val,
                            ),
                          );
                          _sendState(force: true);
                        },
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        VrJoystickTranslationConstants
                            .settingsRightLookModeTitle,
                        style: TextStyle(
                          color: Color(0xFFFF9100),
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      SegmentedButton<VrRightStickLookMode>(
                        key: const ValueKey(
                          VrJoystickConstants
                              .keyControllerRightLookModeSelector,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: VrRightStickLookMode.smoothDualAxis,
                            label: Text(
                              VrJoystickTranslationConstants
                                  .rightLookModeSmoothLabel,
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                          ButtonSegment(
                            value: VrRightStickLookMode.comfortSnapTurn,
                            label: Text(
                              VrJoystickTranslationConstants
                                  .rightLookModeSnapLabel,
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                          ButtonSegment(
                            value: VrRightStickLookMode.flickStick,
                            label: Text(
                              VrJoystickTranslationConstants
                                  .rightLookModeFlickLabel,
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                          ButtonSegment(
                            value: VrRightStickLookMode.inertialTrackball,
                            label: Text(
                              VrJoystickTranslationConstants
                                  .rightLookModeTrackballLabel,
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                        selected: {_rightStickLookMode},
                        onSelectionChanged: (selection) {
                          final next = selection.first;
                          _refresh(() {
                            _rightStickLookMode = next;
                            _flickStickController.reset();
                            _inertialTrackballController.reset();
                            _updateJoystick();
                          });
                          setModalState(() {});
                          unawaited(_persistRightStickLookMode(next));
                          _hapticClick();
                          _sendState(force: true);
                        },
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<int>(
                        valueListenable: _passthroughSettingsRevision,
                        builder: (context, revision, child) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF080816),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: _passthroughGesture.passthroughActive
                                  ? const Color(0xFF00E5FF)
                                  : Colors.white12,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Expanded(
                                    child: Text(
                                      VrJoystickTranslationConstants
                                          .settingsBreakthroughTitle,
                                      style: TextStyle(
                                        color: Color(0xFF00E5FF),
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    _passthroughStatus,
                                    key: const ValueKey(
                                      'joystick_passthrough_settings_status',
                                    ),
                                    style: const TextStyle(
                                      color: Color(0xFF10B981),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              const Text(
                                VrJoystickTranslationConstants
                                    .settingsBreakthroughSubtitle,
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 9.5,
                                ),
                              ),
                              Slider(
                                key: const ValueKey(
                                  'joystick_passthrough_settings_slider',
                                ),
                                value: _passthroughGesture.passthroughMix,
                                min: 0.0,
                                max: 1.0,
                                activeColor: const Color(0xFF00E5FF),
                                inactiveColor: Colors.white24,
                                onChanged: !_canControlPassthrough
                                    ? null
                                    : (val) {
                                        _setBreakthroughMix(val);
                                        setModalState(() {});
                                      },
                                // A deliberate release also reapplies the same
                                // chosen mix after the visor was switched OFF.
                                onChangeEnd: _canControlPassthrough
                                    ? _setBreakthroughMix
                                    : null,
                              ),
                            ],
                          ),
                        ),
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
      if (mounted) _refresh(() => _settingsOpen = false);
    });
  }

  Widget _buildAuxiliaryCameraPreview() {
    final controller = _visionService.previewController;
    if (controller == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Esperando la captura de la lente seleccionada…',
          style: TextStyle(color: Colors.white60, fontSize: 10),
        ),
      );
    }
    final lens = switch (controller.description.lensDirection) {
      CameraLensDirection.front => 'Frontal del mando',
      CameraLensDirection.back => 'Trasera del mando',
      CameraLensDirection.external => 'Lente externa del mando',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$lens · vista local',
          key: const ValueKey('controller-auxiliary-preview-lens'),
          style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 11),
        ),
        const SizedBox(height: 6),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, maxHeight: 220),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              // CameraPreview uses the active controller's native texture and
              // applies device orientation/aspect ratio without a YUV copy.
              child: CameraPreview(controller, key: ObjectKey(controller)),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _openPublicTrackingMarker() async {
    final resend = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _sendPublicTrackingMarker(),
    );
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => VrPublicTrackingMarkerPage(
            initialConfiguration: _trackingMarkerConfiguration,
            onConfiguration: (configuration) {
              _trackingMarkerConfiguration = configuration;
              _sendPublicTrackingMarker();
            },
          ),
        ),
      );
    } finally {
      resend.cancel();
    }
  }

  Widget _buildBodyInferenceDiagnostic() {
    final joints = _visionService.bodyLandmarks;
    final reliable = joints
        .where((joint) => joint.inFrameLikelihood >= .5)
        .length;
    final state = switch (_visionService.bodyStatus) {
      'ready' =>
        'Esqueleto estimado · $reliable/${joints.length} puntos con visibilidad ≥50%',
      'no_person' => 'Modelo activo · sin propuesta corporal',
      'thermal_backoff' =>
        'Análisis pausado por temperatura · nivel ${_visionService.bodyThermalStatus ?? '—'}',
      'confirming_pose' =>
        'Propuesta en comprobación · ${_visionService.bodyStableFrames} imágenes estables',
      'rejected_pose' => 'Propuesta descartada por visibilidad o geometría',
      'stale' => 'Detección caducada · esperando imagen reciente',
      'waiting_for_camera' ||
      'waiting_for_frame' => 'Preparando captura para el modelo…',
      'unsupported_resolution' =>
        'Resolución insuficiente: requiere al menos 480×360',
      'unavailable' => 'Modelo no disponible en esta plataforma',
      _ => 'Estado del modelo: ${_visionService.bodyStatus}',
    };
    final latency = _visionService.bodyInferenceMs;
    final roundTrip = _visionService.bodyRoundTripMs;
    final du = _visionService.bodyDisplacementU;
    final dv = _visionService.bodyDisplacementV;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        key: const ValueKey('controller-body-diagnostic'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            state,
            style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 10),
          ),
          if (_visionService.bodyStatus == 'thermal_backoff')
            Text(
              'Reintento en al menos ${((_visionService.bodyRetryAfterMs ?? 2000) / 1000).toStringAsFixed(0)} s. '
              'Sin puntos corporales vigentes durante la pausa.',
              style: const TextStyle(color: Colors.white60, fontSize: 10),
            ),
          if (latency != null || roundTrip != null)
            Text(
              'ML Kit local · inferencia ${latency?.toStringAsFixed(1) ?? '—'} ms · '
              'total ${roundTrip?.toStringAsFixed(1) ?? '—'} ms · '
              'máximo ${_visionService.bodyInferenceMaxHz.toStringAsFixed(1)} análisis/s · '
              '${_visionService.bodyInferenceFramesDropped} imágenes omitidas',
              style: const TextStyle(color: Colors.white60, fontSize: 10),
            ),
          Text(
            '${_visionService.bodyRawLandmarkCount} puntos propuestos · '
            'filtro: ${_visionService.bodyGateReason}. Una propuesta aceptada todavía puede ser incorrecta.',
            style: const TextStyle(color: Colors.white60, fontSize: 10),
          ),
          if (du != null && dv != null)
            Text(
              'Cambio 2D desde la referencia: X ${(du * 100).toStringAsFixed(1)}%, '
              'Y ${(dv * 100).toStringAsFixed(1)}% de la imagen. '
              'Incluye movimiento de la cámara; no identifica personas ni acciones.',
              style: const TextStyle(color: Colors.white60, fontSize: 10),
            ),
          if (_showAuxiliaryCameraPreview && joints.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Text(
              'Mapa 2D del modelo · imagen orientada, sin espejo',
              style: TextStyle(color: Colors.white60, fontSize: 10),
            ),
            SizedBox(
              height: 120,
              child: CustomPaint(
                painter: _BodyLandmarkDiagnosticPainter(joints),
              ),
            ),
          ],
        ],
      ),
    );
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
}
