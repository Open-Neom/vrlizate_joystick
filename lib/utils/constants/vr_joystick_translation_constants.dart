abstract final class VrJoystickTranslationConstants {
  // Exceptions & Validation Messages
  static const String errorPastePairingLink =
      'Pega el enlace de emparejamiento del visor.';
  static const String errorInvalidPairingLink =
      'El enlace de emparejamiento está incompleto o no es válido.';
  static const String errorPasteFullLinkWithToken =
      'Pega el enlace completo del visor, incluido su token.';
  static const String errorIpAloneDoesNotAuthorize =
      'La IP sola no autoriza la conexión. Escanea el QR o pega el enlace del visor.';
  static const String errorInvalidVisorPort =
      'El puerto del visor no es válido.';
  static const String errorPendingTransportSuffix =
      ' está pendiente de implementación. Usa el enlace Wi-Fi local del visor.';
  static const String errorHostModeArgument =
      'Host mode must be joystick/driving/nes with a safe revision.';
  static const String errorInvalidSizeArgument = 'Must be finite and positive.';
  static const String errorInvalidProgressiveStickConfig =
      'Invalid progressive stick configuration.';
  static const String errorInvalidSteeringConfig =
      'Invalid steering range, deadzone, response exponent or pedal rates.';
  static const String errorMustBeFinite = 'Must be finite.';
  static const String errorMustBeFinitePose = 'Must be a finite pose.';
  static const String errorUseAppQrCode =
      'Usa el QR «Mando con app» del visor (vrlizate://pair). '
      'Los enlaces web no se abren aquí.';
  static const String errorIncompleteQrReload =
      'El enlace está incompleto o no es válido. Vuelve a mostrar el QR del visor.';
  static const String errorNotAControllerInvitation =
      'Este QR no es una invitación para un mando. Usa el QR del visor para conectar un segundo teléfono.';
  static const String errorTransportUnavailableMiddle =
      ' no está disponible en esta app. ';
  static const String errorScanBluetoothQr =
      'Escanea el QR Bluetooth del visor.';
  static const String errorUseWifiPairing =
      'Usa el emparejamiento Wi-Fi local del visor.';
  static const String errorOpenFromVisorApp =
      'Abre el vínculo desde la app del visor.';
  static const String errorMissingBleUuid =
      'Falta el identificador Bluetooth válido del visor. Genera un nuevo QR.';
  static const String errorPositiveTimeouts =
      'Input timeout and watchdog interval must be positive.';
  static const String errorEmptySessionToken = 'Must not be empty.';
  static const String errorInvalidPreviewUrl =
      'Preview must be an HTTP(S) URL without user info or fragment.';
  static const String errorPreviewExceedsBleLimit =
      'Preview announcement exceeds the BLE control limit.';
  static const String errorLaserModeDeprecated =
      'Use joystick with its aiming pad.';
  static const String errorReplacedByController = 'Replaced by controller';
  static const String errorInputLimitExceeded = 'Input limit exceeded';
  static const String errorMustBeBooleanSuffix = ' must be a boolean.';
  static const String errorNonFiniteFieldPrefix =
      'Non-finite controller field: ';
  static const String errorAngularVelocityOutOfRangePrefix =
      'Angular velocity out of range: ';
  static const String errorInvalidCounterPrefix = 'Invalid ';
  static const String errorConnectionTimedOut =
      'Controller connection timed out';
  static const String errorControllerLinkClosed = 'Controller link is closed';
  static const String errorConnectionCancelled = 'Connection cancelled';
  static const String errorWhileUpdatingSavedSession =
      'while updating a saved controller session';

  // Transport Labels
  static const String transportBluetoothLe = 'Bluetooth LE';
  static const String transportBluetoothLePending = 'Bluetooth LE (pendiente)';
  static const String transportWifiLocal = 'Wi-Fi local';
  static const String transportWifiDirect = 'Wi-Fi Direct';
  static const String transportWifiDirectPending = 'Wi-Fi Direct (pendiente)';
  static const String transportDirectSocket = 'Conexión Directa (Socket)';
  static const String transportExternalLink = 'Enlace externo';
  static const String transportPending = 'Transporte pendiente.';

  // Default Button Action Captions
  static const String actionSelect = 'Seleccionar';
  static const String actionBackCancel = 'Atrás / cancelar';
  static const String actionChangeMode = 'Cambiar modo';
  static const String actionSpecial = 'Acción especial';
  static const String actionUtility = 'Utilidad';
  static const String actionTrigger = 'Gatillo';
  static const String actionGrip = 'Agarrar';

  static const String nesCaptionA = 'Acción A';
  static const String nesCaptionB = 'Acción B';
  static const String nesCaptionStart = 'Iniciar / pausa';
  static const String nesCaptionSelect = 'Seleccionar';
  static const String nesCaptionHome = 'Guardar y salir';

  // NES Controller Layout Strings
  static const String nesHeaderTitle = 'VRLIZATE  /  NES';
  static const String nesLinked = 'VINCULADO';
  static const String nesConnect = 'CONECTAR';
  static const String nesClassicControl = 'CONTROL CLÁSICO';
  static const String nesDpadSemantics = 'Cruceta NES, ocho direcciones';

  // QR Dialog Strings
  static const String qrNoLanRunningMessage =
      'Conecta este visor a Wi-Fi o activa un punto de acceso '
      'y vuelve a abrir el QR. Los datos móviles no sirven '
      'para emparejar los dos teléfonos en una red local.';
  static const String qrNoActiveVisorMessage =
      'No hay un visor activo. Vuelve al Home e intenta de nuevo.';
  static const String qrClose = 'Cerrar';
  static const String qrBrowserSemantics = 'QR para navegador';
  static const String qrAppSemantics = 'QR para app VRlizate';
  static const String qrConnectAnotherPhone = 'Conectar otro teléfono';
  static const String qrContinueToVisor = 'Continuar al visor';
  static const String qrBackToVisor = 'Volver al visor';
  static const String qrChipWithApp = 'Mando con app';
  static const String qrChipWithoutApp = 'Sin instalar app';
  static const String qrControllerConnectedTitle = 'Mando conectado';
  static const String qrSecondPhoneInstructionsTitle =
      'En el teléfono que será el mando:';
  static const String qrPlacePhoneInVisor =
      'Ya puedes colocar este teléfono en el visor.';
  static const String qrConnectSameWifi =
      'Conecta ambos teléfonos a la misma red Wi-Fi.';
  static const String qrScanBrowserStep =
      'Escanea este QR con la cámara del teléfono y abre el enlace en su navegador.';
  static const String qrScanAppStep =
      'Abre VRlizate > Usar como mando > Escanear QR';
  static const String qrBrowserTouchNote =
      'Control táctil en el navegador; no requiere sensores.';
  static const String qrAppScannerNote =
      'Apunta a este código con el escáner de VRlizate, no con la cámara del sistema.';
  static const String qrRemovePhoneNote =
      'Retira este teléfono del visor para mostrar el QR.';
  static const String qrAdvancedOptions = 'Opciones avanzadas';
  static const String qrSecurityWarning =
      'Estos enlaces permiten controlar el visor. Compártelos sólo con personas de confianza.';
  static const String qrLinkForApp = 'Enlace para VRlizate';
  static const String qrLinkForBrowser = 'Enlace para navegador';
  static const String qrCopied = 'Copiado';
  static const String qrCopyPrefix = 'Copiar ';

  // Pairing Page Strings
  static const String pairingBleOnlyInstructions =
      'Activa Bluetooth en ambos teléfonos y mantenlos cerca. '
      'No requiere una red ni internet. El mando se abrirá aquí.';
  static const String pairingBleOrWifiInstructions =
      'Escanea el QR Bluetooth o Wi-Fi local del visor. '
      'El mando usará el transporte indicado en ese vínculo.';
  static const String pairingEmptyTransportInstructions =
      'Abre el vínculo desde la app del visor para conectar el mando.';
  static const String pairingWifiOnlyInstructions =
      'Conecta ambos teléfonos a la misma red Wi-Fi. '
      'El mando se abrirá aquí, sin usar Chrome ni otra cámara.';
  static const String pairingCameraReadError =
      'No se pudo leer la cámara. Puedes pegar el enlace del visor.';
  static const String pairingCameraStartError =
      'No se pudo iniciar la cámara. Pega el enlace o vuelve a intentar.';
  static const String pairingCameraCloseError =
      'No se pudo cerrar la cámara. Vuelve atrás e intenta de nuevo.';
  static const String pairingClipboardEmpty =
      'El portapapeles no contiene un enlace de emparejamiento.';
  static const String pairingPasteError =
      'No se pudo pegar el enlace. Puedes escribirlo abajo.';
  static const String pairingTorchUnavailable =
      'La linterna no está disponible. Acerca el QR o mejora la iluminación.';
  static const String pairingCameraPermissionDenied =
      'Permiso de cámara denegado. Puedes habilitarlo en Ajustes o pegar el enlace del visor.';
  static const String pairingCameraUnsupported =
      'No hay una cámara compatible. Pega o escribe el enlace del visor.';
  static const String pairingCameraFailed =
      'No se pudo usar la cámara. Puedes pegar el enlace o volver a intentar.';
  static const String pairingAimAtBleQr =
      'Apunta al QR Bluetooth que aparece en el visor.';
  static const String pairingAimAtAppQr =
      'Apunta al QR «Mando con app» que aparece en el visor.';
  static const String pairingPreparingCamera =
      'Preparando cámara… Si prefieres, pega el enlace.';
  static const String pairingTitle = 'Conectar mando';
  static const String pairingScanQrHeading = 'Escanea el QR del visor';
  static const String pairingClosingCamera =
      'Cerrando cámara y preparando el mando…';
  static const String pairingTorchLabel = 'Linterna';
  static const String pairingRetryCamera = 'Reintentar cámara';
  static const String pairingDesktopFallbackNotice =
      'El escáner integrado está disponible en Android e iOS. '
      'Aquí puedes pegar o escribir el enlace del visor.';
  static const String pairingPasteLinkButton = 'Pegar enlace';
  static const String pairingLinkLabel = 'Enlace de emparejamiento';
  static const String pairingLinkHint = 'vrlizate://pair?…';

  // PhoneControllerPage Status & UI Strings
  static const String statusSearchingWifi = 'Buscando visor en la red Wi-Fi...';
  static const String statusUnpairedPrefix = 'Sin vincular · ';
  static const String statusUnpairedLabel = 'Sin vincular';
  static const String statusBluetoothPairingNotice =
      'Escanea el QR Bluetooth del visor para vincular este mando.';
  static const String statusConnectingPrefix = 'Conectando · ';
  static const String statusConnectingToVisorPrefix = 'Conectando al visor ';
  static const String statusEllipsis = '...';
  static const String statusLinkedExternalPrefix = '⚡ VINCULADO · ';
  static const String statusLinkedParentVisorPrefix =
      '⚡ VINCULADO AL VISOR PADRE (';
  static const String statusConnectedToVisor = '⚡ CONECTADO AL VISOR';
  static const String statusLinkExpired =
      'El vínculo del visor caducó. Escanea un QR nuevo para conectar.';
  static const String statusExternalConnectFailedPrefix =
      'No se pudo vincular por ';
  static const String statusExternalConnectFailedSuffix =
      '. Revisa el visor, los permisos y vuelve a intentar.';
  static const String statusWifiConnectFailed =
      'No se pudo vincular. Verifica el enlace del visor y la red Wi-Fi.';
  static const String statusDisconnectedManual =
      'Desconectado del visor. Revisa el vínculo y pulsa CONECTAR.';
  static const String statusDisconnectedReconnecting =
      'Desconectado del visor. Recuperando el vínculo...';
  static const String statusDrivingReady =
      'Conducción lista · gira o inclina el teléfono';
  static const String statusNesReady = 'NES listo · cruceta, A y B';
  static const String statusJoystickReady =
      'Joystick listo · puntero y botones disponibles';

  // Cast Dialogs & Controls
  static const String castWifiTitle = 'Vista del visor por Wi-Fi';
  static const String castWifiDescription =
      'Los controles continúan por Bluetooth. Conecta ambos teléfonos a la misma red Wi-Fi y activa compartir en el visor.';
  static const String castViewLinkedVisor = 'Ver visor vinculado';
  static const String castPasteLinkLabel = 'O pega el enlace de la vista';
  static const String castLowFpsNotice =
      'Vista previa de pocos FPS · Sin audio';
  static const String castCancel = 'Cancelar';
  static const String castPasteFullLocalLink =
      'Pega el enlace local completo del visor.';
  static const String castViewLink = 'Ver enlace';
  static const String castProjectTitle = 'Proyectar la vista del visor';
  static const String castProjectDescription =
      'Abre este enlace en un navegador de la misma Wi-Fi. La imagen llega directamente del visor; el mando sigue por Bluetooth.';
  static const String castProjectHdmiHint =
      'Computadora → HDMI → TV o proyector. El navegador de una Smart TV requiere compatibilidad. No incluye detección Cast en esta beta.';
  static const String castCopyLink = 'Copiar enlace';
  static const String castBackToController = 'Volver al mando';
  static const String castProjectTooltip = 'Proyectar en otro dispositivo';
  static const String castClosePreviewTooltip = 'Cerrar vista';
  static const String castOpenPreviewButton = 'Vista del visor';

  // Settings Modal & Chrome Strings
  static const String settingsTitle = 'AJUSTES DEL MANDO VR';
  static const String settingsVisorPrefix = 'Visor: ';
  static const String settingsControlModeSection = 'MODO DE CONTROL';
  static const String settingsDualJoystickTitle = 'JOYSTICK DUAL';
  static const String settingsDualJoystickSubtitle =
      'Navegación + Vista + Puntero integrado';
  static const String settingsDrivingTitle = 'CONDUCCIÓN';
  static const String settingsDrivingSubtitle =
      'Giroscopio + inclinación · pedales · L/R vistas';
  static const String settingsParentConnectionSection =
      'CONEXIÓN CON EL VISOR PADRE';
  static const String settingsDirectBleSubtitle =
      'Vínculo directo Bluetooth con el visor.';
  static const String settingsIpHint =
      '192.168.1.XX:8080 o vrlizate://pair?...';
  static const String buttonReconnect = 'RECONECTAR';
  static const String buttonConnect = 'CONECTAR';
  static const String roleChildDirect = 'Mando Hijo (Enlace Directo)';
  static const String roleStandalone = 'Mando Independiente';
  static const String settingsGesturesSection = 'GESTOS Y RECENTRADO';
  static const String settingsMotionLookTitle =
      'Inclinar la vista con el teléfono';
  static const String settingsMotionLookSubtitle =
      'En Vista, pulsa el mando derecho para fijar el centro. Inclina arriba o abajo y mantén; suelta para detenerte. En Láser, el teléfono no mueve la cámara.';
  static const String settingsShowInVisorTitle = 'Mostrar mando en visor';
  static const String settingsShowInVisorSubtitle =
      'Muestra los botones y sticks pulsados dentro del VR.';
  static const String settingsShakeToggleTitle =
      'Sacudir para mostrar/ocultar el mando';
  static const String settingsShakeToggleSubtitle =
      'Sacude el control en cualquier dirección. No cambia la mira ni recentra el visor; también funciona en conducción.';
  static const String settingsHapticsTitle = 'Vibración háptica del mando';
  static const String settingsHapticsSubtitle =
      'Respuesta táctil al pulsar botones, límites del joystick, sacudir o recentrar.';
  static const String settingsRecenterNow = 'Recentrar Vista y Mandos Ahora';

  // Controller Body & Layouts
  static const String appBar3DofTitle = 'MANDO 3DoF VRLIZATE';
  static const String tooltipRecenterView = 'Recentrar vista';
  static const String tooltipSettingsAndMode = 'Ajustes y Modo';
  static const String tooltipExitController = 'Salir del mando';
  static const String tooltipConfigureVisor = 'Configurar visor';
  static const String gyroCheckingNotice =
      'Comprobando giroscopio · controles táctiles disponibles';
  static const String gyroUnavailableNotice =
      'Sin giroscopio disponible · usa los controles táctiles';
  static const String childRoleBannerTitle = 'ROL: MANDO HIJO';
  static const String childRoleParentPrefix = 'Visor Padre: ';
  static const String configIpFallback = 'Config IP';

  // Driving Mode Layout
  static const String drivingHeaderTitle = 'CONDUCCIÓN · VRLIZATE';
  static const String drivingBrakeTitle = 'FRENAR';
  static const String drivingBrakeSubtitle = 'Freno / reversa';
  static const String drivingViewMinus = 'Vista −';
  static const String drivingViewPlus = 'Vista +';
  static const String drivingWheelSemantics =
      'Volante por giroscopio, sin control táctil';
  static const String drivingCenterWheelTitle = 'CENTRAR VOLANTE';
  static const String drivingCenterWheelSubtitle = 'Sostén tu postura neutra';
  static const String drivingCenterWheelLongSubtitle =
      'Sostén tu postura neutra y pulsa';
  static const String drivingThrottleTitle = 'ACELERAR';
  static const String drivingThrottleSubtitle = 'Mantén presionado';
  static const String drivingPauseResumeCaption = 'Pausa / seguir';
  static const String drivingStatusCheckingGyro = 'COMPROBANDO GIROSCOPIO';
  static const String drivingStatusTurnPhone = 'GIRA EL TELÉFONO PARA DIRIGIR';
  static const String drivingStatusNoGyro =
      'SIN GIROSCOPIO · DIRECCIÓN NO DISPONIBLE';
  static const String drivingStatusPaused = 'PAUSA · controles liberados';
  static const String drivingStatusTiltInstructions =
      'Inclina adelante: acelera · atrás: frena/reversa';
  static const String drivingStatusPedalsOnly =
      'Los pedales funcionan; la dirección requiere sensor';
  static const String drivingButtonContinue = 'CONTINUAR';
  static const String drivingButtonPause = 'PAUSAR';

  // Dual Joystick & Laser Pad Layout
  static const String joystickRecenterTitle = 'RECENTRAR VISTA';
  static const String joystickRecenterSubtitle = 'Centrar horizonte y mira';
  static const String rightModeLaser = 'Láser';
  static const String rightModeView = 'Vista';
  static const String centerGuideWalkOnly = 'IZQUIERDO · CAMINAR';
  static const String centerGuideWalkAndTurn = 'IZQUIERDO · CAMINAR Y GIRAR';
  static const String centerGuideHorizontalLook =
      'Esta experiencia usa Vista para girar';
  static const String centerGuideEdgeTurn =
      'Mantén el borde para cambiar de rumbo';
  static const String statusGripActive = '✊ GRIP (AGARRE) ACTIVO';
  static const String statusRightAimHoldGrip =
      'DERECHO · APUNTAR · MANTÉN PARA AGARRAR';
  static const String statusRightViewVerticalAndTurn =
      'DERECHO · VISTA ARRIBA / ABAJO Y GIRO';
  static const String statusRightViewVerticalOnly =
      'DERECHO · VISTA ARRIBA / ABAJO';
  static const String laserBadgeGripActive = 'GRIP ACTIVO';
  static const String laserBadgeCompact = 'LÁSER';
  static const String laserBadgeFrontal = '180° FRONTAL';
  static const String laserBottomCompactGrip = 'AGARRANDO';
  static const String laserBottomCompactSlide = 'DESLIZA · MANTÉN';
  static const String laserBottomFullGrip =
      '✊ GRIP (AGARRE) ACTIVO · ARRASTRA PARA MOVER';
  static const String laserBottomFullIdle =
      'DESLIZA LÁSER · MANTÉN PRESIONADO PARA GRIP';
  static const String laserPointer3DActive = 'PUNTERO LÁSER 3D ACTIVO';
  static const String laserPointer3DSubtitle =
      'Mueve este teléfono en tu mano para apuntar en VR';
  static const String laserRecenterSight = 'Recentrar Mira';
  static const String laserBackHomeTitle = 'ATRÁS / HOME';
  static const String laserBackHomeSubtitle = 'Cerrar panel o volver';
  static const String laserTriggerClickTitle = 'GATILLO (CLIC)';
  static const String laserTriggerClickSubtitle = 'Seleccionar pedestal';
  static const String statusVisorDetectedPrefix = 'Visor detectado (';
  static const String statusVisorDetectedSuffix =
      '). Escanea su QR o pega su enlace para vincular.';
  static const String settingsStatusPrefix = 'Estado: ';
  static const String settingsTransportMiddle = '\nTransporte: ';
  static const String settingsRoleMiddle = ' | Rol: ';
  static const String laserAimingPrefix = 'APUNTANDO: (';
  static const String laserAimingDegreeComma = '°, ';
  static const String laserAimingDegreeEnd = '°)';
  static const String telemetryNavPrefix = 'NAV: (';
  static const String telemetryVistaMiddle = ') | VISTA: (';
  static const String telemetryLaserMiddle = ') | LÁSER: (';
  static const String telemetryCommaSpace = ', ';
  static const String telemetryEndParen = ')';

  // One-Handed Laser Pointing, 5s Dwell & Wordsphere Search Strings
  static const String errorInvalidDwellConfig =
      'Dwell duration must be positive and steady threshold must be non-negative.';
  static const String statusLaserOneHandReady =
      'Láser 1 mano activo · mueve el teléfono para apuntar';
  static const String laserOneHandBadge = 'LÁSER 1 MANO · APUNTANDO';
  static const String laserTapHint =
      'TAP (otra mano) = Clic  ·  ESPERAR 5s = Auto-Clic';
  static const String laserLongPressHint =
      'MANTÉN PRESIONADO (otra mano) = Escribir / Buscar con Wordsphere';
  static const String laserDwellCountdownPrefix = 'AUTO-CLIC EN ';
  static const String laserDwellCountdownSuffix = 's';
  static const String laserClickTriggeredBadge = '¡CLIC ENVIADO!';
  static const String laserReturnToJoystickButton = 'Modo Joystick';
  static const String laserOpenWordsphereButton = 'Wordsphere';
  static const String laserRecenterButton = 'Recentrar';
  static const String laserDestinationActivePrefix = 'DESTINO: ';
  static const String laserHorizontalLabelPrefix = 'H: ';
  static const String laserVerticalLabelPrefix = '°  ·  V: ';
  static const String laserDegreeSuffix = '°';
  static const String wordsphereSheetTitle =
      'BÚSQUEDA Y DESTINOS WORDSPHERE';
  static const String wordsphereSheetSubtitle =
      'Traza palabras en la esfera con tu mano libre o elige un destino de VRlizate';
  static const String wordsphereSearchFieldHint =
      '¿A dónde quieres ir o qué deseas buscar en VRlizate?';
  static const String wordsphereSubmitButton = 'IR / BUSCAR';
  static const String wordsphereBackspaceTooltip = 'Borrar palabra';
  static const String wordsphereSpaceTooltip = 'Espacio';
  static const String wordsphereClearTooltip = 'Limpiar';
  static const String wordsphereQuickDestinationsLabel =
      'DESTINOS RÁPIDOS DE VRLIZATE:';

  // Dual-Thumb Center-to-Lateral Passthrough Split Gesture Strings
  static const String passthroughMixBadgePrefix = 'PASSTHROUGH MIX: ';
  static const String passthroughCycleBadgePrefix =
      'PASSTHROUGH 0→100→0%: ';
  static const String passthroughFastSwipeBadgePrefix =
      'PASSTHROUGH RÁPIDO: ';
  static const String passthroughPercentSuffix = '%';
  static const String passthroughCenterArmedHint =
      'DESLIZA PULGARES A LOS LADOS · RÁPIDO: ON/OFF · LENTO: MIX 0→100→0%';
  static const String breakthroughBarIdleLabel =
      '◀ ● ● BREAKTHROUGH (DESLIZA) ▶';
  static const String breakthroughBarActivePrefix = '◀ BREAKTHROUGH ';
  static const String breakthroughBarActiveSuffix = '% ▶';
  static const String spatialHudButtonLabel = '3 CÁM';
  static const String settingsBreakthroughTitle =
      'Cortina Breakthrough / Passthrough (0% → 100%)';
  static const String settingsBreakthroughSubtitle =
      'Toca el centro con 2 pulgares y desliza hacia los lados, o usa la barra central.';
  static const String settingsSpatialHudTitle =
      'Mostrar HUD de 3 Cámaras y Cálculos en Visor';
  static const String settingsSpatialHudSubtitle =
      'Muestra en el visor la sincronización de las 3 cámaras y telemetría espacial en vivo.';
  static const String childRoleSyncingBannerTitle =
      'SINCRONIZANDO CON EL VISOR VR · ABRIENDO HOME 3D…';
}
