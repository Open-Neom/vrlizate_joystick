part of '../phone_controller_page.dart';

const MethodChannel _deviceCapabilitiesChannel = MethodChannel(
  'vrlizate/device_capabilities',
);

extension _PhoneControllerSensorsAndVision on _PhoneControllerPageState {
  bool get _hasDualHandTouchActive =>
      _stickX.abs() > 0.05 ||
      _stickY.abs() > 0.05 ||
      _lookStickHeld ||
      _isLaserSlideActive ||
      _btnAActive ||
      _btnBActive ||
      _btnXActive ||
      _btnYActive ||
      _btnLActive ||
      _btnRActive ||
      _btnZLActive ||
      _btnZRActive ||
      _btnGripActive;

  void _startShakeDetection() {
    try {
      _accelSub =
          accelerometerEventStream(
            samplingPeriod: const Duration(milliseconds: 20),
          ).listen(
            (AccelerometerEvent event) {
              if (!mounted || !_isForeground) return;
              final nowUs = _nowUs;
              _oneHandedLaserDetector.posture.updateGravity(
                event.x,
                event.y,
                event.z,
                nowUs,
              );
              // Driving tilt remains available when shake-to-hide is disabled.
              _steering.updateGravity(event.x, event.y, event.z, nowUs);
              _motionLook.updateGravity(event.x, event.y, event.z, nowUs);
              if (_visionService.enableHardwareCameraStream ||
                  _visionService.enableUltrasonicRanging ||
                  _visionService.bodyDetectionEnabled) {
                _visionService.updateImuGravity(event.x, event.y, event.z);
              }
              if (!_settingsOpen && !_castDialogOpen) {
                if (widget.autoSwitchToOneHandedLaser &&
                    _activeMode == RemoteControllerMode.joystick &&
                    _oneHandedLaserDetector.shouldSwitchToLaser(
                      gx: event.x,
                      gy: event.y,
                      gz: event.z,
                      omegaMagnitude: _lastGyroOmegaMag,
                      dualTouchActive: _hasDualHandTouchActive,
                      timestampUs: nowUs,
                    )) {
                  _refresh(() {
                    _releaseInputs();
                    _surfaceEpoch++;
                    _activeMode = RemoteControllerMode.laser;
                    _laserSteadyDwell.reset();
                    _status =
                        VrJoystickTranslationConstants.statusLaserOneHandReady;
                  });
                  _hapticMedium();
                  _sendState(force: true);
                  return;
                }
                if (widget.autoSwitchToOneHandedLaser &&
                    _activeMode == RemoteControllerMode.laser &&
                    !_wordsphereSearchSheetVisible &&
                    _oneHandedLaserDetector.isOneHandedLaserActive &&
                    _oneHandedLaserDetector.shouldReturnToJoystick(
                      gx: event.x,
                      gy: event.y,
                      gz: event.z,
                      timestampUs: nowUs,
                    )) {
                  _refresh(() {
                    _releaseInputs();
                    _surfaceEpoch++;
                    _activeMode = RemoteControllerMode.joystick;
                    _laserSteadyDwell.reset();
                  });
                  _hapticMedium();
                  _sendState(force: true);
                  return;
                }
              }
              if (_lookStickHeld) {
                _shakeDetector.reset();
                return;
              }
              if (_settingsOpen || !_shakeToToggleEnabled) return;
              if (_shakeDetector.addSample(event.x, event.y, event.z, nowUs)) {
                _onShakeDetected();
              }
            },
            onError: (_) {
              _oneHandedLaserDetector.posture.reset();
              _steering.clearGravity();
              _motionLook.reset();
            },
          );
    } catch (_) {}
  }

  void _onShakeDetected() {
    _hapticDoublePulse();
    _setControllerVisible(!_controllerVisible);
  }

  void _setControllerVisible(bool visible) {
    _refresh(() => _controllerVisible = visible);
    _sendState();
  }

  Future<void> _loadSavedHaptics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedHaptics = prefs.getBool(
        VrJoystickConstants.prefKeyHapticsEnabled,
      );
      final savedMotionLook = prefs.getBool(
        VrJoystickConstants.prefKeyMotionLookEnabled,
      );
      final savedDynamicOrigin = prefs.getBool(
        VrJoystickConstants.prefKeyDynamicTouchOrigin,
      );
      final savedCardinalDetents = prefs.getBool(
        VrJoystickConstants.prefKeyCardinalDetentsEnabled,
      );
      final savedAutoWalkLock = prefs.getBool(
        VrJoystickConstants.prefKeyAutoWalkLockEnabled,
      );
      final savedLookModeName = prefs.getString(
        VrJoystickConstants.prefKeyRightStickLookMode,
      );
      if (mounted) {
        _refresh(() {
          if (savedHaptics != null) _hapticsEnabled = savedHaptics;
          if (savedMotionLook != null) _motionLookEnabled = savedMotionLook;
          if (savedDynamicOrigin != null) {
            _dynamicTouchOriginEnabled = savedDynamicOrigin;
          }
          if (savedCardinalDetents != null) {
            _cardinalDetentsEnabled = savedCardinalDetents;
          }
          if (savedAutoWalkLock != null) {
            _autoWalkLockEnabled = savedAutoWalkLock;
            if (!_autoWalkLockEnabled) _leftAutoWalkController.reset();
          }
          if (savedLookModeName != null) {
            for (final mode in VrRightStickLookMode.values) {
              if (mode.name == savedLookModeName) {
                _rightStickLookMode = mode;
                break;
              }
            }
          }
          // Preference loading must never activate a gesture already held.
          if (!_motionLookEnabled) {
            _motionLook.setActive(false, _nowUs);
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _persistHaptics(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(VrJoystickConstants.prefKeyHapticsEnabled, enabled);
    } catch (_) {}
  }

  Future<void> _persistMotionLook(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        VrJoystickConstants.prefKeyMotionLookEnabled,
        enabled,
      );
    } catch (_) {}
  }

  Future<void> _persistBoolPref(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _persistRightStickLookMode(VrRightStickLookMode mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        VrJoystickConstants.prefKeyRightStickLookMode,
        mode.name,
      );
    } catch (_) {}
  }

  void _pulseStickClick() {
    _stickClickPulseTimer?.cancel();
    _refresh(() {
      _stickClickActive = true;
    });
    _hapticMedium();
    _sendState(force: true);
    _stickClickPulseTimer = Timer(
      const Duration(
        milliseconds: VrJoystickConstants.stickClickPulseDurationMs,
      ),
      () {
        if (!mounted) return;
        _refresh(() {
          _stickClickActive = false;
        });
        _sendState(force: true);
      },
    );
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
                _lastGyroOmegaMag = 0.0;
                // Rejecting a sample must not leave the previous turn rate
                // alive until the sensor watchdog expires. Keep thumb input.
                if (_activeMode == RemoteControllerMode.joystick) {
                  _motionLook.reset();
                  _updateJoystick();
                  _sendState(force: true);
                }
                return;
              }
              _lastMotionUs = _nowUs;
              _lastGyroOmegaMag = math.sqrt(
                event.x * event.x + event.y * event.y + event.z * event.z,
              );
              _setMotionCapability(VrMotionCapability.available);
              if (_activeMode == RemoteControllerMode.joystick &&
                  _lookStickHeld &&
                  _motionLookEnabled &&
                  !_settingsOpen) {
                _motionLook.updateGyroscope(
                  event.x,
                  event.y,
                  event.z,
                  _lastMotionUs!,
                  sensorTimeUs: event.timestamp.microsecondsSinceEpoch,
                );
              }
              if (_activeMode == RemoteControllerMode.laser) {
                if (!_laserInteractionReady) {
                  _lastGyroTime = event.timestamp;
                  _angularVelocity.setZero();
                  return;
                }
                final now = event.timestamp;
                if (_lastGyroTime != null) {
                  final dt =
                      (now.difference(_lastGyroTime!).inMicroseconds) / 1e6;
                  if (dt > 0 && dt < 0.25) {
                    _angularVelocity.setValues(event.x, event.y, event.z);
                    final posture = _oneHandedLaserDetector.posture;
                    final deltaYaw =
                        posture.yawRate(event.x, event.y, event.z) * dt;
                    final deltaPitch = posture.pitchRate(event.x, event.y) * dt;
                    _laserYaw = (_laserYaw + deltaYaw).clamp(
                      -VrJoystickConstants.laserMaxYawRadians,
                      VrJoystickConstants.laserMaxYawRadians,
                    );
                    _laserPitch = (_laserPitch + deltaPitch).clamp(
                      -VrJoystickConstants.laserMaxPitchRadians,
                      VrJoystickConstants.laserMaxPitchRadians,
                    );
                    _laserStickX =
                        (_laserYaw / VrJoystickConstants.laserMaxYawRadians)
                            .clamp(-1.0, 1.0);
                    _laserStickY =
                        (_laserPitch /
                                VrJoystickConstants.laserMaxPitchRadians)
                            .clamp(-1.0, 1.0);
                    _laserSlideNormX = _laserStickX;
                    _laserSlideNormY = -_laserStickY;
                    final qYaw = vm.Quaternion.axisAngle(
                      vm.Vector3(0, 1, 0),
                      -_laserYaw,
                    );
                    final qPitch = vm.Quaternion.axisAngle(
                      vm.Vector3(1, 0, 0),
                      _laserPitch,
                    );
                    _orientation = (qYaw * qPitch).normalized();
                    _laserAimViewRevision.value++;
                    _sendState();
                  }
                }
                _lastGyroTime = now;
                return;
              }
              if (_activeMode != RemoteControllerMode.driving) {
                // Only the touch pad owns laser aim, including after release.
                // Relative phone deflection requests a sustained look rate
                // through lookX/Y; it never owns the pointer pose.
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
              _lastGyroOmegaMag = 0.0;
              _motionLook.reset();
              _angularVelocity.setZero();
              _lastGyroTime = null;
              _setMotionCapability(VrMotionCapability.unavailable);
            },
          );
    } catch (_) {
      _setMotionCapability(VrMotionCapability.unavailable);
    }

    // Sample controls at 60 Hz (or 120 Hz on upgraded Pro 5/6 GHz links). The
    // sender paces analog updates and keeps idle links alive without
    // serializing/transmitting identical state each tick.
    _restartStreamTimer(16);
  }

  Future<void> _probeLocalHardwareCapabilities() async {
    try {
      Map<Object?, Object?>? raw;
      if (!kIsWeb) {
        final directBridge = VrDirectDeviceBridge.instance;
        final isDirectAndroid =
            defaultTargetPlatform == TargetPlatform.android &&
            directBridge.androidOpenXrHandlesSync() != null;
        final isDirectIos =
            defaultTargetPlatform == TargetPlatform.iOS && Platform.isIOS;
        if (isDirectAndroid || isDirectIos) {
          raw = directBridge.readDeviceCapabilitiesSync();
        }
      }
      final channelRaw =
          raw ?? await _deviceCapabilitiesChannel.invokeMethod<Object?>('read');
      if (!mounted || channelRaw is! Map) return;
      final map = channelRaw;
      final hasGyro = map['hasHardwareGyroscope'];
      final hasCam3 = map['hasConcurrentCameras'];
      final ramMb = map['totalRamMb'];
      final lowRam =
          map['isLowRamDevice'] == true || (ramMb is int && ramMb <= 4200);
      _refresh(() {
        if (hasGyro is bool) _deviceHasHardwareGyroscope = hasGyro;
        if (hasCam3 is bool) _deviceHasConcurrentCameras = hasCam3;
        _deviceIsLowRam = lowRam;
        if (_deviceIsLowRam && _castPreview.value == null) {
          _castAutoEnabled = false;
        }
        if (_deviceHasHardwareGyroscope == false) {
          _motionLookEnabled = false;
          _motionLook.setActive(false, _nowUs);
        }
      });
      if (_deviceHasHardwareGyroscope == false) {
        await _gyroSub?.cancel();
        _gyroSub = null;
        _setMotionCapability(VrMotionCapability.unavailable);
      } else {
        _syncImuSubscriptions();
      }
    } catch (_) {
      // Optional native probe; widget tests and platforms without the channel
      // retain default capabilities.
    }
  }

  void _syncImuSubscriptions() {
    final needGyro =
        _isForeground &&
        _deviceHasHardwareGyroscope != false &&
        _activeMode != RemoteControllerMode.nes;
    final gyro = _gyroSub;
    if (gyro != null) {
      if (needGyro && gyro.isPaused) {
        _lastGyroTime = null;
        gyro.resume();
      } else if (!needGyro && !gyro.isPaused) {
        gyro.pause();
        _lastGyroOmegaMag = 0.0;
        _lastGyroTime = null;
      }
    }

    final needAccel =
        _isForeground &&
        (_activeMode != RemoteControllerMode.nes || _shakeToToggleEnabled);
    final accel = _accelSub;
    if (accel != null) {
      if (needAccel && accel.isPaused) {
        accel.resume();
      } else if (!needAccel && !accel.isPaused) {
        accel.pause();
      }
    }
  }

  void _restartStreamTimer(int intervalMs) {
    final clamped = intervalMs.clamp(8, 33);
    if (_streamTimer != null && _streamIntervalMs == clamped) return;
    _streamIntervalMs = clamped;
    _streamTimer?.cancel();
    _streamTimer = Timer.periodic(Duration(milliseconds: clamped), (_) {
      if (!mounted || !_isForeground) return;
      final now = _nowUs;
      final dtSeconds = (now - _lastDrivingTickUs) / 1e6;
      final pointerReady = _laserInteractionReady;
      if (pointerReady != _lastPaintedPointerPoseReady) {
        _lastPaintedPointerPoseReady = pointerReady;
        _refresh(() {
          if (!pointerReady) {
            _laserSteadyDwell.reset();
            if (_laserClickPulseTimer != null) {
              _laserClickPulseTimer!.cancel();
              _laserClickPulseTimer = null;
              _triggerActive = false;
              _btnAActive = false;
            }
          }
        });
      }
      if (_activeMode == RemoteControllerMode.joystick) {
        _updateJoystick(elapsed: dtSeconds, nowUs: now);
      }
      if (now - (_lastMotionUs ?? 0) > 2000000) {
        _lastGyroOmegaMag = 0.0;
        _setMotionCapability(VrMotionCapability.unavailable);
      }
      if (_activeMode == RemoteControllerMode.laser) {
        final triggered = _laserSteadyDwell.update(
          angularSpeedRadiansPerSec: _lastGyroOmegaMag,
          dtSeconds: dtSeconds,
          paused:
              !pointerReady ||
              _motionCapability != VrMotionCapability.available,
        );
        if (triggered) {
          _lastPaintedLaserDwellProgress = _laserSteadyDwell.progress;
          _pulseLaserClick();
        } else if (now - _lastDrivingPaintUs >= 33333 &&
            (_laserSteadyDwell.progress - _lastPaintedLaserDwellProgress)
                    .abs() >=
                0.005) {
          _lastDrivingPaintUs = now;
          _lastPaintedLaserDwellProgress = _laserSteadyDwell.progress;
          _refresh(() {});
        }
      }
      if (_activeMode == RemoteControllerMode.driving) {
        _steering.setPedals(
          throttlePressed: _throttlePedalHeld,
          brakePressed: _brakePedalHeld,
        );
        _steering.advance(dtSeconds);
        final driving = _steering.state;
        final painted = _lastPaintedDrivingState;
        if (now - _lastDrivingPaintUs >= 33333 &&
            (painted == null ||
                driving.steering != painted.steering ||
                driving.throttle != painted.throttle ||
                driving.brake != painted.brake ||
                driving.paused != painted.paused)) {
          _lastDrivingPaintUs = now;
          _lastPaintedDrivingState = driving;
          _refresh(() {});
        }
      }
      _lastDrivingTickUs = now;
      if (!_visionService.isDesktopOffloadPaused &&
          (_visionService.enableHardwareCameraStream ||
              _visionService.enableUltrasonicRanging ||
              _visionService.bodyDetectionEnabled)) {
        _visionService.tick();
        _sendVisionTelemetryMessageIfDue(now);
      }
      _sendState();
    });
  }

  /// One conditioned output for BLE and socket clients. The thumbstick remains
  /// visually tied to the finger; only transmitted intent follows the ramp.
  void _updateJoystick({double elapsed = 0, int? nowUs}) {
    if (_activeMode != RemoteControllerMode.joystick) return;
    _moveResponse.advance(elapsed);
    _lookResponse.advance(elapsed);
    final move = _moveResponse.output;
    final look = _lookResponse.output;
    final motion = _motionLook.sample(nowUs ?? _nowUs);
    if (_leftAutoWalkController.isAutoWalkLocked) {
      _stickX = 0.0;
      _stickY = math.max(move.y, 1.0);
      _moveAtEdge = true;
    } else {
      _stickX = move.x;
      _stickY = move.y;
    }
    // Right thumbstick horizontal deflection turns left/right according to
    // the active look mode; relative phone tilt while holding the look stick
    // contributes vertical pitch only.
    double x;
    double y;
    switch (_rightStickLookMode) {
      case VrRightStickLookMode.smoothDualAxis:
        x = _horizontalLookEnabled ? look.x : 0.0;
        y = look.y + motion.y;
      case VrRightStickLookMode.comfortSnapTurn:
        x = _horizontalLookEnabled
            ? _flickStickController.update(
                mode: _rightStickLookMode,
                x: _rawLookX,
                y: _rawLookY,
                dtSeconds: elapsed,
              )
            : 0.0;
        y = look.y + motion.y;
      case VrRightStickLookMode.flickStick:
        x = _horizontalLookEnabled
            ? _flickStickController.update(
                mode: _rightStickLookMode,
                x: _rawLookX,
                y: _rawLookY,
                dtSeconds: elapsed,
              )
            : 0.0;
        y = motion.y;
      case VrRightStickLookMode.inertialTrackball:
        if (_lookStickHeld) {
          x = _horizontalLookEnabled ? look.x : 0.0;
          y = look.y + motion.y;
        } else if (_inertialTrackballController.isCoasting) {
          final coast = _inertialTrackballController.advance(elapsed);
          x = _horizontalLookEnabled ? coast.x : 0.0;
          y = coast.y;
        } else {
          x = 0.0;
          y = 0.0;
        }
    }
    final magnitude = math.sqrt(x * x + y * y);
    if (magnitude > 1) {
      x /= magnitude;
      y /= magnitude;
    }
    _lookX = _rightLaser ? 0 : x;
    _lookY = _rightLaser ? 0 : y;
  }

  void _selectRightControl(bool laser) {
    if (_rightLaser == laser || _activeMode != RemoteControllerMode.joystick) {
      return;
    }
    _refresh(() {
      _releaseInputs();
      _surfaceEpoch++;
      _rightLaser = laser;
    });
    _hapticClick();
    _sendState(force: true);
  }

  void _setMotionCapability(VrMotionCapability capability) {
    if (!mounted || _motionCapability == capability) return;
    _refresh(() {
      final wasDrivingWithMotion =
          _activeMode == RemoteControllerMode.driving &&
          _steering.motionAvailable;
      _motionCapability = capability;
      _steering.setMotionAvailable(capability == VrMotionCapability.available);
      if (capability == VrMotionCapability.unavailable) {
        _motionLook.reset();
        _angularVelocity.setZero();
        _lastGyroTime = null;
        if (wasDrivingWithMotion) {
          _steering.setPaused(true);
          _releaseInputs(send: true);
        }
      }
    });
  }

  void _selectMode(RemoteControllerMode mode) {
    _refresh(() {
      _releaseInputs();
      _surfaceEpoch++;
      _activeMode = mode;
      _oneHandedLaserDetector.setModeActive(mode == RemoteControllerMode.laser);
      _laserSteadyDwell.reset();
      _wordsphereSearchSheetVisible = false;
      if (mode == RemoteControllerMode.laser) {
        _status = VrJoystickTranslationConstants.statusLaserOneHandReady;
      }
      _steering.setPaused(false);
      _steering.calibrate(_wheelOrientation);
      _lastDrivingTickUs = _nowUs;
    });
    _syncImuSubscriptions();
    _hapticClick();
    _sendState(force: true);
  }

  void _centerSteering() {
    _refresh(() => _steering.calibrate(_wheelOrientation));
    _hapticClick();
    _sendState();
  }

  void _toggleDrivingPause() {
    final paused = !_steering.state.paused;
    _refresh(() {
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
    _refresh(() {
      _btnAActive = !reset;
      _btnXActive = reset;
    });
    _sendState();
    _drivingActionTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      _refresh(() {
        _btnAActive = false;
        _btnXActive = false;
      });
      _sendState();
    });
  }

  void _selectDrivingMenu() {
    _refresh(() {
      _releaseInputs();
      // Drop old pedal gestures, including a pending tap-down, before making
      // the controller ready. Choosing a menu must never restore held throttle.
      _surfaceEpoch++;
      _steering.setPaused(false);
    });
    _pulseDrivingAction();
  }

  void _updateLaserSlide(double nx, double ny) {
    _refresh(() {
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

  void _pulseLaserClick() {
    if (!_laserInteractionReady) return;
    _laserClickPulseTimer?.cancel();
    _laserSteadyDwell.reset();
    _refresh(() {
      _triggerActive = true;
      _btnAActive = true;
    });
    _hapticMedium();
    _sendState(force: true);
    _laserClickPulseTimer = Timer(
      const Duration(
        milliseconds: VrJoystickConstants.laserClickPulseDurationMs,
      ),
      () {
        if (!mounted) return;
        _refresh(() {
          _triggerActive = false;
          _btnAActive = false;
        });
        _sendState(force: true);
      },
    );
  }

  void _nudgeLaserAimByPan(Offset delta) {
    if (_activeMode != RemoteControllerMode.laser) return;
    _laserSteadyDwell.reset();
    final nx = (_laserStickX + delta.dx / 180.0).clamp(-1.0, 1.0);
    final ny = (_laserStickY - delta.dy / 140.0).clamp(-1.0, 1.0);
    _updateLaserSlide(nx, -ny);
  }

  void _openWordsphereSearchSheet() {
    _laserSteadyDwell.reset();
    _refresh(() {
      _wordsphereSearchSheetVisible = true;
    });
    _hapticMedium();
    _sendState(force: true);
  }

  void _closeWordsphereSearchSheet() {
    _refresh(() {
      _wordsphereSearchSheetVisible = false;
    });
    _hapticLight();
    _sendState(force: true);
  }

  void _onWordsphereQueryChanged(String query) {
    final trimmed = query.trim();
    _refresh(() {
      _activeSearchQuery = trimmed.isEmpty
          ? null
          : trimmed.substring(
              0,
              math.min(
                trimmed.length,
                VrJoystickConstants.maxSearchQueryLength,
              ),
            );
    });
    _sendState(force: true);
  }

  void _submitWordsphereSearch(String rawQuery) {
    final trimmed = rawQuery.trim();
    if (trimmed.isEmpty) {
      _closeWordsphereSearchSheet();
      return;
    }
    final normalized = trimmed.substring(
      0,
      math.min(trimmed.length, VrJoystickConstants.maxSearchQueryLength),
    );
    _searchSubmitPulseTimer?.cancel();
    _refresh(() {
      _activeSearchQuery = normalized;
      _searchSubmittedPulse = true;
      _wordsphereSearchSheetVisible = false;
    });
    _hapticDoublePulse();
    _sendState(force: true);
    _searchSubmitPulseTimer = Timer(
      const Duration(
        milliseconds: VrJoystickConstants.laserClickPulseDurationMs,
      ),
      () {
        if (!mounted) return;
        _refresh(() {
          _searchSubmittedPulse = false;
        });
        _sendState(force: true);
      },
    );
  }

  void _releaseInputs({bool send = false}) {
    _moveResponse.reset();
    _lookResponse.reset();
    _motionLook.reset();
    _lookStickHeld = false;
    _lastDrivingTickUs = _nowUs;
    _drivingActionTimer?.cancel();
    _drivingActionTimer = null;
    _laserClickPulseTimer?.cancel();
    _laserClickPulseTimer = null;
    _searchSubmitPulseTimer?.cancel();
    _searchSubmitPulseTimer = null;
    _recenterResetTimer?.cancel();
    _recenterResetTimer = null;
    _stickClickPulseTimer?.cancel();
    _stickClickPulseTimer = null;
    _leftAutoWalkController.reset();
    _rightStickClickDetector.reset();
    _flickStickController.reset();
    _inertialTrackballController.reset();
    _rawLookX = 0;
    _rawLookY = 0;
    _stickX = 0;
    _stickY = 0;
    _dpadX = 0;
    _dpadY = 0;
    _moveAtEdge = false;
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
    _btnZLActive = false;
    _btnZRActive = false;
    _btnGripActive = false;
    _stickClickActive = false;
    _searchSubmittedPulse = false;
    _passthroughGesture.cancelGesture();
    _exclusiveControlPointers.clear();
    _throttlePedalHeld = false;
    _brakePedalHeld = false;
    _gripHoldTimer?.cancel();
    _gripHoldTimer = null;
    _angularVelocity.setZero();
    _lastGyroTime = null;
    _steering.release();
    if (send) _sendState(force: true);
  }

  void _notifyPassthroughSettings() {
    if (mounted && _surfaceMounted) {
      _passthroughSettingsRevision.value++;
    }
  }

  bool get _canControlPassthrough =>
      _isConnected &&
      (_socket?.isOpen ?? false) &&
      _hasEffectivePassthroughState;

  String get _passthroughStatus => !_isConnected
      ? 'Sin conexión · reconectar'
      : !_hasEffectivePassthroughState
      ? 'Sincronizando visor'
      : _pendingPassthroughMix != null
      ? 'Esperando visor'
      : '${(_reportedPassthroughMix * 100).round()}${VrJoystickTranslationConstants.passthroughPercentSuffix}';

  void _setBreakthroughMix(double mix) {
    if (!mix.isFinite || !_canControlPassthrough) return;
    final clamped = mix.clamp(0.0, 1.0);
    _refresh(() {
      _passthroughGesture.setPassthroughMix(clamped);
    });
    final bucket = (clamped * 4).round();
    if (bucket != _lastPassthroughHapticBucket) {
      _lastPassthroughHapticBucket = bucket;
      _hapticClick();
    }
    _sendPassthroughControlMessage(force: true, userCommand: true);
    _sendState();
  }

  Widget _exclusivePassthroughControl(Widget child) => Listener(
    onPointerDown: (event) => _exclusiveControlPointers.add(event.pointer),
    child: child,
  );

  void _toggleBreakthroughMix() {
    if (!_canControlPassthrough) return;
    final current = _passthroughGesture.passthroughMix;
    final next = current < 0.25 ? 0.65 : (current < 0.85 ? 1.0 : 0.0);
    _refresh(() {
      _passthroughGesture.setPassthroughMix(next);
    });
    _hapticMedium();
    _sendPassthroughControlMessage(force: true, userCommand: true);
    _sendState(force: true);
  }

  void _toggleSpatialHud([bool? value]) {
    if (!_canControlPassthrough) return;
    final next = value ?? !_spatialHudVisible;
    _refresh(() {
      _spatialHudVisible = next;
    });
    _hapticClick();
    _sendPassthroughControlMessage(force: true);
    _sendState(force: true);
  }

  void _sendPassthroughControlMessage({
    bool force = false,
    bool userCommand = false,
  }) {
    final ws = _socket;
    if (ws == null || !ws.isOpen || !_isConnected) return;
    final mix = _passthroughGesture.passthroughMix;
    if (userCommand) {
      if (!_canControlPassthrough) return;
      _pendingPassthroughMix = (mix - _reportedPassthroughMix).abs() > .005
          ? mix
          : null;
      _notifyPassthroughSettings();
    }
    if (!force &&
        (mix - _lastSentPassthroughMix).abs() < 0.015 &&
        _spatialHudVisible == _lastSentSpatialHudVisible) {
      return;
    }
    _lastSentPassthroughMix = mix;
    _lastSentSpatialHudVisible = _spatialHudVisible;
    final controlPayload = jsonEncode({
      VrJoystickConstants.fieldType: VrJoystickConstants.passthroughControlType,
      if (userCommand) VrJoystickConstants.fieldPassthroughCommand: true,
      VrJoystickConstants.fieldPassthroughMix: mix,
      VrJoystickConstants.fieldPassthroughActive:
          _passthroughGesture.passthroughActive,
      VrJoystickConstants.fieldSpatialHudVisible: _spatialHudVisible,
    });
    try {
      ws.add(controlPayload);
    } catch (_) {
      _onDisconnected(ws);
    }
  }

  void _sendGesturePassthroughChange(double previousMix) {
    if ((_passthroughGesture.passthroughMix - previousMix).abs() > 0.000001) {
      _sendPassthroughControlMessage(force: true, userCommand: true);
    }
  }

  void _onVisionServiceUpdated() {
    if (!mounted || !_isForeground || !_isConnected) return;
    _sendVisionTelemetryMessageIfDue(_nowUs);
  }

  void _sendVisionTelemetryMessageIfDue(int nowUs) {
    final ws = _socket;
    if (ws == null || !ws.isOpen || !_isConnected || !_isForeground) return;
    final minIntervalUs = _showsBluetooth ? 1500000 : 500000;
    if (nowUs - _lastVisionTelemetryUs < minIntervalUs) return;
    final payloadMap = _visionService.buildVisionTelemetryPayload(
      includeMiniFrame: !_showsBluetooth,
    );
    if (payloadMap == null) return;
    _lastVisionTelemetryUs = nowUs;
    try {
      ws.add(jsonEncode(payloadMap));
    } catch (_) {
      _onDisconnected(ws);
    }
  }

  void _sendState({bool force = false}) {
    final ws = _socket;
    if (ws != null && ws.isOpen && _isConnected && (_isForeground || force)) {
      _sendPassthroughControlMessage();
      final driving = _steering.state;
      final isDriving = _activeMode == RemoteControllerMode.driving;
      final isLaserOverBle =
          _showsBluetooth && _activeMode == RemoteControllerMode.laser;
      final wireModeName = isLaserOverBle
          ? RemoteControllerMode.joystick.name
          : _activeMode.name;
      final measuredRangeMeters = _visionService.currentRangeMeters;
      final liveRangeMeters = measuredRangeMeters == null
          ? null
          : (measuredRangeMeters * 100.0).round() / 100.0;
      final quality = _linkQuality;
      final bridgeHz =
          !_showsBluetooth && (_desktopBridge?.stationConnected ?? false)
          ? _desktopBridge!.recommendedJoystickHz
          : 60;
      final customInterval = quality == null
          ? (bridgeHz >= 120 ? const Duration(microseconds: 8000) : null)
          : (quality.recommendedHz >= 120 || bridgeHz >= 120
                ? const Duration(microseconds: 8000)
                : (quality.isUdpUpgraded ||
                          quality.transport ==
                              VrControllerFastTransport.bleSinglePacket
                      ? VrControllerStatePacer.socketAnalogInterval
                      : VrControllerStatePacer.bleAnalogInterval));
      final isBluetoothPacing =
          (widget.transportType == VrTransportType.bluetoothLe &&
              !_useWifiOverride &&
              !_isFaroWifiExternalLink) &&
          !(quality?.isUdpUpgraded ?? false);
      if (ws is VrCompactGamepadCapableLink &&
          (ws as VrCompactGamepadCapableLink).supportsCompactGamepadFrames &&
          _activeSearchQuery == null &&
          !_searchSubmittedPulse) {
        final modeIdx = switch (wireModeName) {
          VrJoystickConstants.modeLaser => 1,
          VrJoystickConstants.modeDriving => 2,
          VrJoystickConstants.modeNes => 3,
          _ => 0,
        };
        final frame = VrCompactGamepadFrame(
          sequence: _sequence,
          senderTimestampMicroseconds: DateTime.now().microsecondsSinceEpoch,
          orientation: _orientation.clone(),
          angularVelocity: _angularVelocity.clone(),
          stickX: isDriving ? 0.0 : _stickX,
          stickY: isDriving ? 0.0 : _stickY,
          lookX: isDriving ? 0.0 : _lookX,
          lookY: isDriving ? 0.0 : _lookY,
          laserX: _laserStickX,
          laserY: _laserStickY,
          steering: isDriving ? driving.steering : 0.0,
          drivingTilt: isDriving ? _steering.drivingTiltAt(_nowUs) : 0.0,
          throttle: isDriving ? driving.throttle : 0.0,
          brake: isDriving ? driving.brake : 0.0,
          modeIndex: modeIdx,
          hostModeRevision: _hostModeSession.revision,
          trigger: _triggerActive || (!isDriving && _btnRActive),
          action: _actionActive || _btnBActive,
          btnA: _btnAActive,
          btnB: _btnBActive,
          btnX: _btnXActive,
          btnY: _btnYActive,
          btnL: _btnLActive,
          btnR: _btnRActive,
          btnZL: _btnZLActive,
          btnZR: _btnZRActive,
          btnGrip: _btnGripActive,
          stickClick: _stickClickActive,
          recenter: _recenterTriggered,
          moveAtEdge:
              _activeMode == RemoteControllerMode.joystick && _moveAtEdge,
          dpadUp: _dpadY > 0.5,
          dpadDown: _dpadY < -0.5,
          dpadLeft: _dpadX < -0.5,
          dpadRight: _dpadX > 0.5,
          laserSlideActive: _isLaserSlideActive || isLaserOverBle,
          controllerVisible: _controllerVisible,
          pointerPoseReady: _pointerPoseReady,
          drivingPaused: isDriving && driving.paused,
          motionAvailable: _motionCapability == VrMotionCapability.available,
          passthroughActive: _passthroughGesture.passthroughActive,
          spatialHudVisible: _spatialHudVisible,
          passthroughMix: _passthroughGesture.passthroughMix,
          rangeMeters: liveRangeMeters,
        );
        if (!_statePacer.shouldSendCompact(
          frame,
          nowUs: _nowUs,
          bluetooth: isBluetoothPacing,
          force: force,
          customAnalogInterval: customInterval,
        )) {
          return;
        }
        _sequence = (_sequence + 1) & 0xFFFFFFFF;
        try {
          ws.add(frame);
        } catch (_) {
          _onDisconnected(ws);
        }
        return;
      }
      final state = <String, Object?>{
        VrJoystickConstants.fieldHostModeRevision: _hostModeSession.revision,
        VrJoystickConstants.fieldQx: _orientation.x,
        VrJoystickConstants.fieldQy: _orientation.y,
        VrJoystickConstants.fieldQz: _orientation.z,
        VrJoystickConstants.fieldQw: _orientation.w,
        VrJoystickConstants.fieldWx: _angularVelocity.x,
        VrJoystickConstants.fieldWy: _angularVelocity.y,
        VrJoystickConstants.fieldWz: _angularVelocity.z,
        VrJoystickConstants.fieldStickX: isDriving ? 0.0 : _stickX,
        VrJoystickConstants.fieldStickY: isDriving ? 0.0 : _stickY,
        VrJoystickConstants.fieldDpadX: isDriving ? 0.0 : _dpadX,
        VrJoystickConstants.fieldDpadY: isDriving ? 0.0 : _dpadY,
        VrJoystickConstants.fieldMoveAtEdge:
            _activeMode == RemoteControllerMode.joystick && _moveAtEdge,
        VrJoystickConstants.fieldTx: isDriving ? 0.0 : _stickX,
        VrJoystickConstants.fieldTy: isDriving ? 0.0 : _stickY,
        VrJoystickConstants.fieldLookX: isDriving ? 0.0 : _lookX,
        VrJoystickConstants.fieldLookY: isDriving ? 0.0 : _lookY,
        VrJoystickConstants.fieldTurn: isDriving ? 0.0 : _lookX,
        VrJoystickConstants.fieldTurnRate: isDriving ? 0.0 : _lookX,
        VrJoystickConstants.fieldPitchRate: isDriving ? 0.0 : _lookY,
        VrJoystickConstants.fieldLookPitch: isDriving ? 0.0 : _lookY,
        VrJoystickConstants.fieldLaserX: _laserStickX,
        VrJoystickConstants.fieldLaserY: _laserStickY,
        VrJoystickConstants.fieldLaserSlideActive:
            _isLaserSlideActive || isLaserOverBle,
        VrJoystickConstants.fieldAimX: _laserStickX,
        VrJoystickConstants.fieldAimY: _laserStickY,
        VrJoystickConstants.fieldRecenter: _recenterTriggered,
        VrJoystickConstants.fieldControllerVisible: _controllerVisible,
        VrJoystickConstants.fieldPointerPoseReady: _pointerPoseReady,
        VrJoystickConstants.fieldRangeMeters: liveRangeMeters,
        VrJoystickConstants.fieldTrigger:
            _triggerActive || (!isDriving && _btnRActive),
        VrJoystickConstants.fieldAction: _actionActive || _btnBActive,
        VrJoystickConstants.fieldBtnA: _btnAActive,
        VrJoystickConstants.fieldBtnB: _btnBActive,
        VrJoystickConstants.fieldBtnX: _btnXActive,
        VrJoystickConstants.fieldBtnY: _btnYActive,
        VrJoystickConstants.fieldBtnL: _btnLActive,
        VrJoystickConstants.fieldBtnR: _btnRActive,
        VrJoystickConstants.fieldBtnZL: _btnZLActive,
        VrJoystickConstants.fieldBtnZR: _btnZRActive,
        VrJoystickConstants.fieldBtnGrip: _btnGripActive,
        VrJoystickConstants.fieldStickClick: _stickClickActive,
        VrJoystickConstants.fieldMode: wireModeName,
        VrJoystickConstants.fieldSteering:
            _activeMode == RemoteControllerMode.driving
            ? driving.steering
            : 0.0,
        VrJoystickConstants.fieldDrivingTilt:
            _activeMode == RemoteControllerMode.driving
            ? _steering.drivingTiltAt(_nowUs)
            : 0.0,
        VrJoystickConstants.fieldThrottle:
            _activeMode == RemoteControllerMode.driving
            ? driving.throttle
            : 0.0,
        VrJoystickConstants.fieldBrake:
            _activeMode == RemoteControllerMode.driving ? driving.brake : 0.0,
        VrJoystickConstants.fieldDrivingPaused:
            _activeMode == RemoteControllerMode.driving && driving.paused,
        VrJoystickConstants.fieldMotionAvailable:
            _motionCapability == VrMotionCapability.available,
        VrJoystickConstants.fieldSearchQuery: _activeSearchQuery,
        VrJoystickConstants.fieldSearchSubmitted: _searchSubmittedPulse,
        VrJoystickConstants.fieldPassthroughMix:
            _passthroughGesture.passthroughMix,
        VrJoystickConstants.fieldPassthroughActive:
            _passthroughGesture.passthroughActive,
        VrJoystickConstants.fieldSpatialHudVisible: _spatialHudVisible,
      };
      if (!_statePacer.shouldSend(
        state,
        nowUs: _nowUs,
        bluetooth: isBluetoothPacing,
        force: force,
        customAnalogInterval: customInterval,
      )) {
        return;
      }
      final seq = _sequence;
      _sequence = (_sequence + 1) & 0xFFFFFFFF;
      final tsUs = DateTime.now().microsecondsSinceEpoch;

      final payload = jsonEncode({
        ...state,
        VrJoystickConstants.fieldSequence: seq,
        VrJoystickConstants.fieldTimestampUs: tsUs,
      });

      try {
        ws.add(payload);
      } catch (_) {
        _onDisconnected(ws);
      }
    }
  }

  void _recenterController() {
    _laserSteadyDwell.reset();
    _refresh(() {
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
        _refresh(() {
          _recenterTriggered = false;
        });
        _sendState();
      }
    });
  }
}
