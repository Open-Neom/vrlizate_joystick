abstract final class VrJoystickConstants {
  // Schemes, Hosts, Paths & Query Parameters
  static const String schemeVrlizate = 'vrlizate';
  static const String schemeHttp = 'http';
  static const String schemeHttps = 'https';
  static const String schemeWs = 'ws';
  static const String schemeWss = 'wss';
  static const String hostPair = 'pair';
  static const String pathRoot = '/';
  static const String pathPair = '/pair';
  static const String pathPairRelative = 'pair';
  static const String queryToken = 'token';
  static const List<String> webSchemes = [
    schemeHttp,
    schemeHttps,
    schemeWs,
    schemeWss,
  ];

  // Ports & Network
  static const int defaultServerPort = 8080;
  static const int udpDiscoveryPort = 8081;
  static const String broadcastIp = '255.255.255.255';
  static const String defaultIpPrefix = '192.168.1.';
  static const String dotSeparator = '.';
  static const String udpServiceId = 'vrlizate_vr_host';
  static const String defaultVisorDeviceName = 'VRlizate-Visor';
  static const String defaultBeaconName = 'VRlizate Visor';
  static const String headerNoStore = 'no-store';
  static const String headerReferrerPolicy = 'Referrer-Policy';
  static const String headerNoReferrer = 'no-referrer';
  static const String colonSeparator = ':';
  static const String spaceOpenParen = ' (';
  static const String closeParen = ')';
  static const String centerGuideBullet = ' · ';
  static const String centerGuideSpacer = '     ';
  static const String udpListenerLogPrefix =
      '[PhoneControllerPage] UDP listener notice: ';

  // SharedPreferences Keys
  static const String prefKeyHostIp = 'vrlizate_host_ip';
  static const String prefKeyHapticsEnabled = 'vrlizate_haptics_enabled';
  static const String prefKeyMotionLookEnabled = 'vrlizate_motion_look_enabled';
  static const String prefKeyDynamicTouchOrigin =
      'vrlizate_dynamic_touch_origin';
  static const String prefKeyCardinalDetentsEnabled =
      'vrlizate_cardinal_detents_enabled';
  static const String prefKeyAutoWalkLockEnabled =
      'vrlizate_auto_walk_lock_enabled';
  static const String prefKeyRightStickLookMode =
      'vrlizate_right_stick_look_mode';

  // Open-Source Inspired Thumbstick & Look Enhancement Constants
  // 1. Dynamic / Floating Touch Origin (nipplejs / AirConsole inspired)
  static const double defaultDynamicOriginMaxRatio = 0.38;

  // 2. Radial & Cardinal Haptic Detents (Steam Controller / VirtualGamePad inspired)
  static const double hapticMidRingThreshold = 0.50;
  static const double hapticMidRingRelease = 0.43;
  static const double hapticOuterRimThreshold = 0.92;
  static const double hapticOuterRimRelease = 0.84;
  static const double hapticCardinalMinRadius = 0.36;
  static const double hapticCardinalEnterDegrees = 7.0;
  static const double hapticCardinalExitDegrees = 11.5;

  // 3. Flick Stick & Comfort Snap-Turn (JoyShockMapper inspired)
  static const double snapTurnTriggerThreshold = 0.72;
  static const double snapTurnRearmThreshold = 0.35;
  static const double snapTurnPulseDurationSeconds = 0.12;
  static const double snapTurnCooldownSeconds = 0.30;
  static const double flickStickRimEngageThreshold = 0.80;
  static const double flickStickRimReleaseThreshold = 0.65;
  static const double flickStickSnapDurationSeconds = 0.14;
  static const double flickStickSweepGain = 0.65;

  // 4. Double-Tap (L3/R3) & Auto-Walk / Sprint Lock (moonlight-android inspired)
  static const int doubleTapMaxTapDurationUs = 260000;
  static const int doubleTapMaxIntervalUs = 360000;
  static const double autoWalkForwardMinY = 0.78;
  static const double autoWalkForwardMaxAbsX = 0.38;
  static const int autoWalkHoldLockDurationUs = 200000;
  static const int stickClickPulseDurationMs = 150;

  // 5. Inertial Virtual Trackball (Steam Controller inspired)
  static const double trackballFrictionPerSecond = 3.2;
  static const double trackballMinLaunchSpeed = 0.15;
  static const double trackballStopSpeedThreshold = 0.025;
  static const double trackballVelocitySmoothing = 0.45;

  // Protocol & Wire Keys
  static const String controllerModeType = 'vrlizate.controllerMode';
  static const int controllerModeVersion = 1;
  static const int maxSafeJsRevision = 9007199254740991;
  static const int maxActionCaptionLength = 24;
  static const String castPreviewMessageType = 'cast_preview';
  static const String aiCapabilitiesMessageType = 'ai_caps';
  static const String aiInferRequestMessageType = 'ai_infer_req';
  static const String aiInferResponseMessageType = 'ai_infer_res';

  // Action & Button Keys
  static const String actionKeyA = 'A';
  static const String actionKeyB = 'B';
  static const String actionKeyX = 'X';
  static const String actionKeyY = 'Y';
  static const String actionKeyL = 'L';
  static const String actionKeyR = 'R';
  static const String actionKeyZL = 'ZL';
  static const String actionKeyZR = 'ZR';
  static const String actionKeyGrip = 'GRIP';
  static const String nesKeyStart = 'start';
  static const String nesKeySelect = 'select';
  static const String nesKeyHome = 'home';
  static const String nesLabelHome = 'HOME';
  static const String nesLabelSelect = 'SELECT';
  static const String nesLabelStart = 'START';

  static const Set<String> allowedActionKeys = {
    actionKeyA,
    actionKeyB,
    actionKeyX,
    actionKeyY,
    actionKeyL,
    actionKeyR,
    actionKeyZL,
    actionKeyZR,
    actionKeyGrip,
  };

  // JSON Payload Field Keys
  static const String fieldType = 'type';
  static const String fieldVersion = 'version';
  static const String fieldMode = 'mode';
  static const String fieldRevision = 'revision';
  static const String fieldHorizontalLook = 'horizontalLook';
  static const String fieldActions = 'actions';
  static const String fieldUrl = 'url';
  static const String fieldService = 'service';
  static const String fieldPort = 'port';
  static const String fieldIp = 'ip';
  static const String fieldName = 'name';
  static const String fieldRequiresPairingToken = 'requiresPairingToken';
  static const String fieldTimestamp = 'timestamp';
  static const String fieldSequence = 'sequence';
  static const String fieldTimestampUs = 'timestampUs';
  static const String fieldHostModeRevision = 'hostModeRevision';
  static const String fieldQx = 'qx';
  static const String fieldQy = 'qy';
  static const String fieldQz = 'qz';
  static const String fieldQw = 'qw';
  static const String fieldWx = 'wx';
  static const String fieldWy = 'wy';
  static const String fieldWz = 'wz';
  static const String fieldStickX = 'stickX';
  static const String fieldStickY = 'stickY';
  static const String fieldMoveAtEdge = 'moveAtEdge';
  static const String fieldDpadX = 'dpadX';
  static const String fieldDpadY = 'dpadY';
  static const String fieldTx = 'tx';
  static const String fieldTy = 'ty';
  static const String fieldTurn = 'turn';
  static const String fieldTurnRate = 'turnRate';
  static const String fieldLookX = 'lookX';
  static const String fieldPitchRate = 'pitchRate';
  static const String fieldLookPitch = 'lookPitch';
  static const String fieldLookY = 'lookY';
  static const String fieldLaserX = 'laserX';
  static const String fieldLaserY = 'laserY';
  static const String fieldAimX = 'aimX';
  static const String fieldAimY = 'aimY';
  static const String fieldLaserSlideActive = 'laserSlideActive';
  static const String fieldPointerPoseReady = 'pointerPoseReady';
  static const String fieldRecenter = 'recenter';
  static const String fieldControllerVisible = 'controllerVisible';
  static const String fieldRangeMeters = 'rangeMeters';
  static const String fieldRange = 'range';
  static const String fieldTrigger = 'trigger';
  static const String fieldAction = 'action';
  static const String fieldBtnA = 'btnA';
  static const String fieldBtnB = 'btnB';
  static const String fieldBtnX = 'btnX';
  static const String fieldBtnY = 'btnY';
  static const String fieldBtnL = 'btnL';
  static const String fieldBtnR = 'btnR';
  static const String fieldBtnZL = 'btnZL';
  static const String fieldBtnZR = 'btnZR';
  static const String fieldBtnGrip = 'btnGrip';
  static const String fieldStickClick = 'stickClick';
  static const String fieldSteering = 'steering';
  static const String fieldDrivingTilt = 'drivingTilt';
  static const String fieldThrottle = 'throttle';
  static const String fieldBrake = 'brake';
  static const String fieldDrivingPaused = 'drivingPaused';
  static const String fieldMotionAvailable = 'motionAvailable';
  static const String fieldSearchQuery = 'searchQuery';
  static const String fieldSearchSubmitted = 'searchSubmitted';
  static const String fieldPassthroughMix = 'passthroughMix';
  static const String fieldPassthroughActive = 'passthroughActive';
  static const String fieldPassthroughCommand = 'passthroughCommand';
  static const int maxSearchQueryLength = 120;

  // Dual-Thumb Center-to-Lateral Passthrough Split Gesture Constants
  static const double passthroughCenterMinNormX = 0.16;
  static const double passthroughCenterMaxNormX = 0.84;
  static const double passthroughMaxInitialThumbSpan = 0.68;
  static const int passthroughThumbSyncWindowUs = 900000;
  static const double passthroughMinActivationSpread = 0.035;
  static const double passthroughFullSpanNormDistance = 0.84;
  static const double passthroughFastSwipeMinSpeedPerSec = 1.40;
  static const int passthroughFastSwipeMaxDurationUs = 380000;
  static const double passthroughFastSwipeMinSpread = 0.32;
  static const double passthroughUltraSlowMaxSpeedPerSec = 0.55;
  static const int passthroughUltraSlowMinDurationUs = 850000;
  static const double passthroughDirectionToleranceNorm = 0.04;
  static const double passthroughUpperCameraBandMaxNormY = 0.35;
  static const double passthroughLowerWireframeBandMinNormY = 0.65;
  static const int passthroughDoubleTapMaxTapDurationUs = 260000;
  static const int passthroughDoubleTapMaxIntervalUs = 450000;
  static const int passthroughSonarPulseDurationUs = 1200000;
  static const String passthroughControlType = 'vrlizate.passthrough';
  static const String passthroughStateMessageType =
      'vrlizate.passthrough.state';
  static const String visionTelemetryMessageType = 'vrlizate.visionTelemetry';
  static const String fieldPassthroughStyle = 'passthroughStyle';
  static const String fieldPassthroughSonarPulse = 'passthroughSonarPulse';
  static const String fieldPassthroughCurtainLeft = 'passthroughCurtainLeft';
  static const String fieldPassthroughCurtainRight = 'passthroughCurtainRight';
  static const String fieldSpatialHudVisible = 'spatialHudVisible';
  static const String fieldLeftFootU = 'leftFootU';
  static const String fieldLeftFootV = 'leftFootV';
  static const String fieldRightFootU = 'rightFootU';
  static const String fieldRightFootV = 'rightFootV';
  static const String fieldFeetConfidence = 'feetConfidence';
  static const String fieldHandU = 'handU';
  static const String fieldHandV = 'handV';
  static const String fieldHandConfidence = 'handConfidence';
  static const String fieldVisorU = 'visorU';
  static const String fieldVisorV = 'visorV';
  static const String fieldVisorWidth = 'visorWidth';
  static const String fieldJoystickCameraRole = 'joystickCameraRole';
  static const String fieldJoystickMiniFrame = 'joystickMiniFrame';
  static const String keyPassthroughCurtainOverlay =
      'passthrough_curtain_overlay';
  static const String keyBreakthroughCenterBar = 'breakthrough_center_bar';
  static const String keySpatialHudToggle = 'spatial_hud_toggle';

  // Joystick Camera Vision (Cám 2 Piso + Cám 3 Manos/Visor) & Ultrasonic Sonar Constants
  static const String ultrasonicSonarChannelName = 'vrlizate/ultrasonic_sonar';
  static const String ultrasonicPingMethod = 'ping';
  static const String ultrasonicFieldEchoDistanceMeters = 'echoDistanceMeters';
  static const String ultrasonicFieldSnrDb = 'snrDb';
  static const String cameraRoleRear = 'rear';
  static const String cameraRoleFront = 'front';
  static const String envKeyFlutterTest = 'FLUTTER_TEST';
  static const int visionMiniFrameGridWidth = 24;
  static const int visionMiniFrameGridHeight = 18;
  static const double defaultLeftFootU = 0.36;
  static const double defaultLeftFootV = 0.72;
  static const double defaultRightFootU = 0.64;
  static const double defaultRightFootV = 0.72;
  static const double defaultHandU = 0.50;
  static const double defaultHandV = 0.58;
  static const double defaultVisorU = 0.50;
  static const double defaultVisorV = 0.24;
  static const double defaultVisorWidth = 0.20;
  static const double defaultRangeMeters = 0.54;
  static const int ultrasonicPingIntervalMs = 520;
  static const int cameraLensMultiplexIntervalMs = 3400;
  static const double minValidUltrasonicSnrDb = 3.8;
  static const double minUltrasonicEchoMeters = 0.22;
  static const double maxUltrasonicEchoMeters = 1.15;

  // One-Handed Laser Detector & 5-Second Dwell Constants
  static const double oneHandedLateralTiltMinRatio = 0.42;
  static const double oneHandedPointingMinOmega = 0.15;
  static const int oneHandedSwitchHoldUs = 200000;
  static const double oneHandedReturnFlatGxRatio = 0.88;
  static const double oneHandedReturnFlatGyMaxRatio = 0.20;
  static const int oneHandedReturnHoldUs = 350000;
  static const double oneHandedMinGravityMagnitude = 7.5;
  static const double oneHandedMaxGravityMagnitude = 12.5;
  static const double laserAutoClickDwellSeconds = 5.0;
  static const double laserSteadyOmegaThreshold = 0.35;
  static const double laserMaxDeltaSeconds = 0.5;
  static const int laserClickPulseDurationMs = 150;
  static const double laserMaxYawRadians = 1.5707963267948966;
  static const double laserMaxPitchRadians = 1.25;
  static const double laserGyroYawRollCoupling = 0.35;

  static const String modeJoystick = 'joystick';
  static const String modeLaser = 'laser';
  static const String modeDriving = 'driving';
  static const String modeNes = 'nes';

  static const List<String> booleanStateKeys = [
    fieldBtnZL,
    fieldBtnZR,
    fieldLaserSlideActive,
    fieldPointerPoseReady,
    fieldDrivingPaused,
    fieldMotionAvailable,
    fieldControllerVisible,
    fieldMoveAtEdge,
    fieldSearchSubmitted,
    fieldPassthroughActive,
    fieldSpatialHudVisible,
  ];

  static const List<String> numericStateKeys = [
    fieldQx,
    fieldQy,
    fieldQz,
    fieldQw,
    fieldWx,
    fieldWy,
    fieldWz,
    fieldStickX,
    fieldStickY,
    fieldDpadX,
    fieldDpadY,
    fieldTx,
    fieldTy,
    fieldTurn,
    fieldTurnRate,
    fieldLookX,
    fieldPitchRate,
    fieldLookPitch,
    fieldLookY,
    fieldLaserX,
    fieldLaserY,
    fieldAimX,
    fieldAimY,
    fieldSteering,
    fieldDrivingTilt,
    fieldThrottle,
    fieldBrake,
    fieldPassthroughMix,
  ];

  static const List<String> angularVelocityKeys = [fieldWx, fieldWy, fieldWz];

  static const List<String> neutralButtonKeys = [
    fieldTrigger,
    fieldAction,
    fieldBtnA,
    fieldBtnB,
    fieldBtnX,
    fieldBtnY,
    fieldBtnL,
    fieldBtnR,
    fieldBtnZL,
    fieldBtnZR,
    fieldBtnGrip,
    fieldStickClick,
    fieldLaserSlideActive,
    fieldRecenter,
    fieldMoveAtEdge,
    fieldSearchSubmitted,
  ];

  static const List<String> neutralAxisKeys = [
    fieldStickX,
    fieldStickY,
    fieldDpadX,
    fieldDpadY,
    fieldTx,
    fieldTy,
    fieldTurn,
    fieldTurnRate,
    fieldLookX,
    fieldPitchRate,
    fieldLookPitch,
    fieldLookY,
    fieldLaserX,
    fieldLaserY,
    fieldAimX,
    fieldAimY,
    fieldSteering,
    fieldDrivingTilt,
    fieldThrottle,
    fieldBrake,
  ];

  static const Set<String> pacerReleaseAxes = {
    fieldStickX,
    fieldStickY,
    fieldDpadX,
    fieldDpadY,
    fieldLookX,
    fieldLookY,
    fieldLaserX,
    fieldLaserY,
    fieldSteering,
    fieldDrivingTilt,
    fieldThrottle,
    fieldBrake,
    fieldPassthroughMix,
  };

  // Directional glyphs for VirtualThumbstick
  static const String arrowUp = '▲';
  static const String arrowDown = '▼';
  static const String arrowLeft = '◀';
  static const String arrowRight = '▶';
  static const String courierFontFamily = 'Courier';

  // ValueKeys for UI & Widget Testing
  static const String keyNesSurface = 'nes_surface';
  static const String keyNesButtonPrefix = 'nes_button_';
  static const String keyNesDpad = 'nes_dpad';
  static const String keyNesControlsPrefix = 'nes_controls_';
  static const String keyVrPairingTorch = 'vr_pairing_torch';
  static const String keyVrPairingRetry = 'vr_pairing_retry';
  static const String keyVrPairingError = 'vr_pairing_error';
  static const String keyVrPairingPaste = 'vr_pairing_paste';
  static const String keyVrPairingLink = 'vr_pairing_link';
  static const String keyVrPairingConnect = 'vr_pairing_connect';
  static const String keyCastUseOffer = 'cast-use-offer';
  static const String keyCastManualUri = 'cast-manual-uri';
  static const String keySettingsCastPreview = 'settings-cast-preview';
  static const String keyControllerPairingTarget = 'controller_pairing_target';
  static const String keyControllerTransportSelector =
      'controller_transport_selector';
  static const String keyControllerMotionLookToggle =
      'controller_motion_look_toggle';
  static const String keyControllerVisibilityToggle =
      'controller_visibility_toggle';
  static const String keyControllerShakeToggle = 'controller_shake_toggle';
  static const String keyControllerSurfacePrefix = 'controller_surface_';
  static const String keyJoystickButtonPrefix = 'joystick_button_';
  static const String keyDrivingBrakePedal = 'driving_brake_pedal';
  static const String keyDrivingWheel = 'driving_wheel';
  static const String keyJoystickRecenter = 'joystick_recenter';
  static const String keyDrivingThrottlePedal = 'driving_throttle_pedal';
  static const String keyJoystickMoveStick = 'joystick_move_stick';
  static const String keyJoystickLookStick = 'joystick_look_stick';
  static const String keyJoystickSurface = 'joystick_surface';
  static const String keyControllerCenterPanel = 'controller_center_panel';
  static const String keyControllerCastPreview = 'controller-cast-preview';
  static const String keyControllerProjectCast = 'controller-project-cast';
  static const String keyControllerCastToggle = 'controller-cast-toggle';
  static const String keyRightModeLaser = 'right_mode_laser';
  static const String keyRightModeView = 'right_mode_view';
  static const String keyLaserSlidePad = 'laser_slide_pad';
  static const String keyLaserPointingSurface = 'laser_pointing_surface';
  static const String keyLaserPointingReticle = 'laser_pointing_reticle';
  static const String keyLaserPointingRecenter = 'laser_pointing_recenter';
  static const String keyLaserPointingWordsphereButton =
      'laser_pointing_wordsphere_button';
  static const String keyLaserPointingBackToJoystick =
      'laser_pointing_back_to_joystick';
  static const String keyLaserPointingDwellBadge = 'laser_pointing_dwell_badge';
  static const String keyWordsphereSearchSheet = 'wordsphere_search_sheet';
  static const String keyWordsphereSearchField = 'wordsphere_search_field';
  static const String keyWordsphereSearchSubmit = 'wordsphere_search_submit';
  static const String keyWordsphereSearchBackspace =
      'wordsphere_search_backspace';
  static const String keyWordsphereSearchSpace = 'wordsphere_search_space';
  static const String keyWordsphereSearchClear = 'wordsphere_search_clear';
  static const String keyWordsphereBoard = 'wordsphere_board';
  static const String keyWordsphereDestinationChipPrefix = 'wordsphere_dest_';
  static const String keyControllerDynamicOriginToggle =
      'controller_dynamic_origin_toggle';
  static const String keyControllerCardinalDetentsToggle =
      'controller_cardinal_detents_toggle';
  static const String keyControllerAutoWalkToggle =
      'controller_auto_walk_toggle';
  static const String keyControllerRightLookModeSelector =
      'controller_right_look_mode_selector';
  static const String keyAutoWalkLockedBadge = 'auto_walk_locked_badge';

  static const List<String> wordsphereDestinations = [
    'Mall VR',
    'Lobby Central',
    'Arcade NES',
    'Conducción',
    'Cine 360',
    'Galería',
    'Mundos VR',
  ];

  // Regular Expression Patterns
  static const String excludedInterfacePattern =
      r'^(?:lo(?:\d|$)|(?:v4-)?rmnet|r_rmnet|ccmni|pdp_ip|wwan|mobile|cellular|'
      r'radio|rev_rmnet|usb_rmnet|seth|tun|tap|utun|ppp|ipsec|wg(?:\d|[-_]|$)|vpn|'
      r'tailscale|zerotier|zt[a-z0-9]|clat|v4-|dummy|docker|veth|virbr|'
      r'vboxnet|vmnet|awdl|llw|vti|ip_vti|ip6tnl|sit\d|gre|p2p)';
  static const String wifiInterfacePattern =
      r'^(?:wlan|wifi|wi-fi|wl[a-z0-9]|ap\d|swlan|softap|hotspot)';
  static const String ethernetInterfacePattern = r'^(?:eth|en\d|enp|ens|eno)';
  static const String invalidHostCharsPattern = r'[\s/?#@]';
  static const String uuidPattern =
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';

  // Embedded HTML5 Web Controller Fallback
  static const String webControllerHtml = '''<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>VRlizate Mando & Joystick VR</title>
  <style>
    :root { --touch-size: 48px; --touch-gap: 8px; }
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
      height: 100dvh;
      overflow: hidden;
    }
    .header {
      display: flex;
      gap: var(--touch-gap);
      justify-content: space-between;
      align-items: center;
      padding-bottom: 8px;
      border-bottom: 1px solid rgba(0, 229, 255, 0.2);
    }
    .title { font-size: 16px; font-weight: bold; color: #00E5FF; letter-spacing: 1px; }
    .status { font-size: 11px; color: #10B981; font-weight: bold; }
    .tabs { display: flex; gap: var(--touch-gap); margin: var(--touch-gap) 0; }
    .tab {
      flex: 1;
      padding: 8px;
      border-radius: 10px;
      border: 1px solid #00E5FF;
      background: #101528;
      color: #00E5FF;
      color: #00E5FF;
      font-size: 12px;
      font-weight: bold;
      text-align: center;
      cursor: pointer;
    }
    button.tab {
      min-width: var(--touch-size);
      min-height: var(--touch-size);
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
      gap: var(--touch-gap);
      width: 140px;
    }
    #driveControls { gap: var(--touch-gap); }
    .game-btn {
      min-width: var(--touch-size);
      min-height: var(--touch-size);
      padding: 4px 6px;
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
    .shoulder-controls {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 176px));
      gap: var(--touch-gap);
      width: 100%;
      justify-content: space-between;
    }
    .shoulder-pair {
      display: grid;
      grid-template-columns: repeat(2, minmax(var(--touch-size), 1fr));
      gap: var(--touch-gap);
    }
    .shoulder-controls .game-btn {
      background: #253557;
      font-size: 12px;
      touch-action: none;
    }
    .btn-grip { background: #1F293D; border: 1px solid #00E5FF; color: #00E5FF; }
    .game-btn:active { filter: brightness(1.3); }
    .telemetry {
      font-size: 11px;
      color: rgba(0, 229, 255, 0.6);
      text-align: center;
      padding: 6px;
    }
    @media (max-height: 360px) {
      body { padding: 6px; }
      .header { padding-bottom: 4px; }
      .tab { padding: 4px; }
      .game-btn { font-size: 12px; }
      .stick-container { width: 130px; height: 130px; }
      .stick-knob { width: 48px; height: 48px; }
      .telemetry { padding: 3px; }
    }
    @media (max-height: 320px) {
      .stick-container { width: 96px; height: 96px; }
    }
    @media (max-height: 300px) {
      .stick-container { width: 72px; height: 72px; }
      .stick-knob { width: 36px; height: 36px; }
      .main-area { margin-top: var(--touch-gap); }
    }
    @media (max-height: 420px) and (min-width: 480px) {
      .btn-cluster {
        display: grid;
        grid-template-columns: repeat(3, minmax(var(--touch-size), 1fr));
        width: min(57vw, 360px);
      }
      #driveControls {
        grid-column: 1 / -1;
        grid-template-columns: repeat(3, minmax(var(--touch-size), 1fr));
      }
    }
    @media (min-width: 760px) and (min-height: 400px) {
      :root { --touch-size: 56px; --touch-gap: 10px; }
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
    <button id="tabJoy" class="tab active" onclick="setMode('joystick')">🕹️ JOYSTICK ANALÓGICO</button>
    <div id="modeHint" class="tab">La app activa el volante</div>
  </div>

  <div class="shoulder-controls" id="shoulderControls">
    <div class="shoulder-pair">
      <button id="btnZL" class="game-btn">ZL</button>
      <button id="btnL" class="game-btn">L</button>
    </div>
    <div class="shoulder-pair">
      <button id="btnR" class="game-btn">R</button>
      <button id="btnZR" class="game-btn">ZR</button>
    </div>
  </div>
  <div class="main-area">
    <!-- Joystick left side -->
    <div class="stick-container" id="stickBase">
      <div class="stick-knob" id="stickKnob"></div>
    </div>

    <!-- Buttons right side -->
    <div class="btn-cluster">
      <button id="btnA" class="game-btn btn-a">A · ELEGIR / OK</button>
      <button id="btnB" class="game-btn btn-b">B · ATRÁS / CANCELAR</button>
      <button id="btnGrip" class="game-btn btn-grip">AGARRE / MENÚ</button>
      <div id="driveControls" style="display:none">
        <button id="driveToggle" class="game-btn btn-a">CONTINUAR (A)</button>
        <button id="btnThrottle" class="game-btn btn-a">R · SIGUIENTE VISTA</button>
        <button id="btnBrake" class="game-btn btn-b">L · VISTA ANTERIOR</button>
      </div>
    </div>
  </div>

  <div id="telemetry" class="telemetry">X: 0.00 | Y: 0.00 · Modo: Joystick</div>

  <script>
    let ws;
    let mode = 'joystick';
    let stickX = 0, stickY = 0;
    let btnA = false, btnB = false, btnGrip = false;
    const shoulders = { L: false, R: false, ZL: false, ZR: false };
    const qx = 0, qy = 0, qz = 0, qw = 1;
    let controllerVisible = true;
    let sequence = 0;
    let hostModeRevision = null;
    let drivingPaused = true, throttleHeld = false, brakeHeld = false;
    let drivePulse = null;
    const buttonPointers = new Map();

    // Host captions for the buttons this layout has. Text only
    // via innerText, known keys only, capped like the native client.
    const defaultCaptions = { A: 'ELEGIR / OK', B: 'ATRÁS / CANCELAR', GRIP: 'AGARRE / MENÚ' };
    function applyActions(actions) {
      const clean = {};
      if (actions && typeof actions === 'object') {
        for (const key of ['A', 'B', 'L', 'R', 'ZL', 'ZR', 'GRIP']) {
          const value = actions[key];
          if (typeof value === 'string' && value.trim()) clean[key] = value.trim().slice(0, 24);
        }
      }
      document.getElementById('btnA').innerText = 'A · ' + (clean.A || defaultCaptions.A).toUpperCase();
      document.getElementById('btnB').innerText = 'B · ' + (clean.B || defaultCaptions.B).toUpperCase();
      document.getElementById('btnGrip').innerText = (clean.GRIP || defaultCaptions.GRIP).toUpperCase();
      document.getElementById('btnThrottle').innerText = 'R · ' + (clean.R || 'SIGUIENTE VISTA').toUpperCase();
      document.getElementById('btnBrake').innerText = 'L · ' + (clean.L || 'VISTA ANTERIOR').toUpperCase();
      for (const key of Object.keys(shoulders)) {
        const button = document.getElementById('btn' + key);
        button.innerText = clean[key] ? key + ' · ' + clean[key] : key;
      }
    }
    function setMode(newMode) {
      if (newMode !== 'joystick' && newMode !== 'driving' && newMode !== 'nes') return;
      if (mode !== newMode) {
        releaseInputs(false);
        mode = newMode;
        drivingPaused = newMode === 'driving' ? document.hidden : true;
      }
      updateModeUi();
      sendState();
    }

    function updateModeUi() {
      const driving = mode === 'driving';
      document.getElementById('tabJoy').className = !driving ? 'tab active' : 'tab';
      document.getElementById('modeHint').innerText = driving ? 'Stick ↑ acelera · ↓ frena/reversa · ↔ gira · L/R vista' : mode === 'nes' ? 'NES · A acción · GRIP Start · B Home' : 'La app activa el volante';
      document.getElementById('driveControls').style.display = driving ? 'grid' : 'none';
      document.getElementById('shoulderControls').style.display = mode === 'joystick' ? 'grid' : 'none';
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
        // Keep the current mode so reconnecting cannot look like a fresh
        // driving transition and clear the safety pause.
        releaseInputs(false);
        updateModeUi();
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
            (request.mode !== 'joystick' && request.mode !== 'driving' && request.mode !== 'nes') ||
            (hostModeRevision !== null && request.revision <= hostModeRevision)) return;
        hostModeRevision = request.revision;
        setMode(request.mode); // A mode transition ACK is always fully released.
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
    let isTouching = false;
    let activeStickTouchId = null;
    let moveAtEdge = false;

    function findActiveStickTouch(touchList) {
      if (!touchList) return null;
      for (let i = 0; i < touchList.length; i++) {
        if (touchList[i].identifier === activeStickTouchId) return touchList[i];
      }
      return null;
    }

    function handleTouchPoint(touch) {
      const rect = base.getBoundingClientRect();
      const centerX = rect.left + rect.width / 2;
      const centerY = rect.top + rect.height / 2;
      const dx = touch.clientX - centerX;
      const dy = touch.clientY - centerY;
      const dist = Math.hypot(dx, dy);
      const maxRadius = Math.min(55, rect.width * 0.32);

      let clampedDx = dx, clampedDy = dy;
      if (dist > maxRadius) {
        clampedDx = (dx / dist) * maxRadius;
        clampedDy = (dy / dist) * maxRadius;
      }

      knob.style.transform = `translate(\${clampedDx}px, \${clampedDy}px)`;
      stickX = parseFloat((clampedDx / maxRadius).toFixed(2));
      stickY = parseFloat((-clampedDy / maxRadius).toFixed(2)); // Up is positive
      moveAtEdge = dist >= maxRadius * 0.88;

      updateTelemetry();
      sendState();
    }

    function resetStick(send = true) {
      activeStickTouchId = null;
      knob.style.transform = 'translate(0px, 0px)';
      stickX = 0; stickY = 0; moveAtEdge = false;
      updateTelemetry();
      if (send) sendState();
    }

    base.addEventListener('touchstart', (e) => {
      e.preventDefault();
      if (activeStickTouchId !== null) return;
      const t = (e.changedTouches && e.changedTouches[0]) ||
                (e.targetTouches && e.targetTouches[0]) ||
                (e.touches && e.touches[0]);
      if (!t) return;
      activeStickTouchId = t.identifier;
      isTouching = true;
      handleTouchPoint(t);
      if (navigator.vibrate) navigator.vibrate(15);
    });
    base.addEventListener('touchmove', (e) => {
      if (!isTouching) return;
      e.preventDefault();
      const t = findActiveStickTouch(e.touches) ||
                findActiveStickTouch(e.changedTouches);
      if (t) handleTouchPoint(t);
    });
    function onStickTouchEnd(e) {
      if (!isTouching) return;
      if (activeStickTouchId !== null && e.changedTouches) {
        if (!findActiveStickTouch(e.changedTouches)) return;
      }
      isTouching = false;
      resetStick();
    }
    base.addEventListener('touchend', onStickTouchEnd);
    base.addEventListener('touchcancel', onStickTouchEnd);

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
    for (const key of Object.keys(shoulders)) {
      bindBtn('btn' + key, (v) => shoulders[key] = v && mode === 'joystick');
    }
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
          stickX: mode === 'driving' && drivingPaused ? 0 : stickX,
          stickY: mode === 'driving' && drivingPaused ? 0 : stickY,
          moveAtEdge: mode === 'joystick' && moveAtEdge,
          btnA,
          btnB,
          btnGrip,
          btnR: throttleHeld || shoulders.R,
          btnL: brakeHeld || shoulders.L,
          btnZL: shoulders.ZL,
          btnZR: shoulders.ZR,
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
      for (const key of Object.keys(shoulders)) shoulders[key] = false;
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
}
