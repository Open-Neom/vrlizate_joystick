# vrlizate_joystick

Mando dual-analógico en segundo smartphone, perfiles de control especializados (Joystick, Conducción, NES) y servicio de emparejamiento para Flutter y VRlizate.

> Versión actual: **1.0.0**. Consulta [CHANGELOG.md](CHANGELOG.md) para el historial de cambios.

## Características principales

- **Controles ergonómicos en bordes (horizontal):** franjas laterales/superiores para `L/R`, `Y/B` y `X/A` alrededor de los sticks circulares, dejando el panel central para acciones contextuales, selector `Vista`/`Láser` y vista previa del visor.
- **Doble stick virtual progresivo (`VirtualThumbstick`):**
  - **Stick izquierdo:** locomoción 3D con zona muerta radial (10%), rampa progresiva de velocidad (1.8 s) y detección de intención de giro en el borde (`moveAtEdge` al 92%, liberación al 84%).
  - **Control derecho (`Vista` / `Láser`):** inclinación vertical (o dos ejes si la experiencia solicita `horizontalLook: true`), giro de vista por inclinación del teléfono (`VrMotionLookController`) al mantener presionado el stick, o pad táctil de puntero láser con agarre por pulsación sostenida (`Láser`).
- **Perfiles dirigidos por el anfitrión (`RemoteControllerMode` y `VrGamepadLayoutPreset`):**
  - `joystick` (`dualStickVr`): locomoción, vista/láser y botones `A/B/X/Y/L/R`.
  - `driving` (`steeringWheel`): volante 3DoF por giroscopio (`VrSteeringController`) con deslizador táctil de respaldo, acelerador (`R`), freno (`L`) y pausa explícita.
  - `nes` (`retroArcade8Way`): cruceta digital (D-pad), botones `B/A`, `Select`, `Start` y `Home`.
  - Remapeo de botones (`VrButtonMapping`) y patrones hápticos predefinidos (`VrHapticPatternPreset`).
- **Telemetría y visibilidad 3D:** sacudir el mando (o usar Ajustes) alterna la visibilidad del mando 3D en el visor (`controllerVisible`) sin recentrar la cámara ni interrumpir la partida.
- **Vista previa del visor (`vrlizate_cast`):** muestra automáticamente la transmisión monocular LAN en el centro del mando cuando el visor anuncia `cast_preview`.

## Inicio rápido

### En el visor (servidor WebSocket opcional del SDK)

```dart
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

final service = VrRemoteControllerService();
await service.startServer();
await service.refreshLocalAddress();
RemoteControllerQrDialog.show(context, service: service);

// Solicitar cambio de perfil según la experiencia activa:
service.requestControllerMode(RemoteControllerMode.driving);
service.requestControllerMode(RemoteControllerMode.nes);
service.requestControllerMode(RemoteControllerMode.joystick);
```

*(Nota: `VRlizate_app` utiliza su transporte Bluetooth LE sobre este mismo contrato de estados y perfiles).*

### En el teléfono mando

```dart
// Escáner QR integrado con liberación automática de cámara al conectar:
Navigator.of(context).push(
  MaterialPageRoute<void>(builder: (_) => const VrControllerPairingPage()),
);

// O apertura directa de la interfaz del mando:
Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => const PhoneControllerPage(
      initialMode: RemoteControllerMode.joystick,
    ),
  ),
);
```

## Contrato de entrada

- **`btnA`, `btnL` y `btnR` son independientes:** `A` selecciona en UI, `B` cancela/regresa, `L` es utilidad y `R` es gatillo primario.
- **Supresión de dwell:** mientras hay un teléfono mando conectado, el anfitrión desactiva la selección automática por tiempo de mirada (`setDwellSuppressed(remotePhone, true)`).
- **Seguridad en cambios de modo y reconexión:** todo cambio de perfil o reconexión exige un acuse en estado neutral; el watchdog de 500 ms neutraliza entradas obsoletas y `driving` permanece en pausa hasta pulsar `CONTINUAR`.

## Estado de Breakthrough / passthrough

El visor conserva la autoridad sobre su cámara y publica el ajuste efectivo al
mando mediante el enlace dúplex ya autenticado, incluido Bluetooth LE. La app
debe comunicar sus cambios locales o persistidos al servicio:

```dart
service.setEffectivePassthroughState(
  mix: .65,
  cameraEnabled: true,
);
```

El mensaje visor → mando es una observación de estado:

```json
{
  "type": "vrlizate.passthrough.state",
  "revision": 7,
  "passthroughMix": 0.65,
  "cameraEnabled": true
}
```

- `revision`: contador creciente del visor. El mando descarta revisiones ya
  observadas dentro del enlace actual; una reconexión establece una nueva base.
- `passthroughMix`: mezcla efectiva entre `0.0` y `1.0`. Cuando
  `cameraEnabled` es `false`, el servicio publica `0.0`.
- `cameraEnabled`: ajuste vigente del visor. Este mensaje no certifica por sí
  solo permisos de cámara, recepción de vídeo ni latencia de la transmisión.

Se publica al cambiar el estado y se entrega el último snapshot inmediatamente
al conectar un mando autenticado. Los cambios ON durante un arrastre se agrupan
cada 100 ms, hasta 10 actualizaciones por segundo, conservando el valor más
reciente. OFF (`cameraEnabled: false`) se envía inmediatamente y cancela la
actualización pendiente. Desconectar o detener el servicio cancela sus timers;
no existe polling periódico de confirmación ni tráfico por cada frame de VR.

Recibir este estado no genera comandos, acuses de entrada, vibración ni cambios
de cámara. Tampoco modifica `latestState` o `passthroughCommandRevision` en el
visor. Una acción deliberada del usuario mantiene el contrato mando → visor
`type: "vrlizate.passthrough"` con `passthroughCommand: true`; los snapshots
retenidos y las observaciones del visor nunca se convierten en esa acción.
El apagado local y las protecciones existentes contra revisiones obsoletas
siguen siendo responsabilidad del visor.

La barra y Ajustes distinguen lo confirmado de lo solicitado:

- **Sincronizando visor:** enlace conectado, todavía sin snapshot válido; los
  controles de passthrough permanecen deshabilitados.
- **Esperando visor:** hay un cambio solicitado sin confirmar. La barra conserva
  el último porcentaje confirmado y sólo resuelve la espera cuando observa una
  revisión nueva con el valor solicitado. Es confirmación del estado observado,
  no un ACK independiente por cada paquete.
- **Sin conexión · reconectar:** el estado actual es desconocido y se bloquean
  barra, slider y gestos de cámara. No se guardan órdenes OFF u ON para enviarlas
  posteriormente; al reconectar se recibe el estado vigente del visor.

Por ello, pulsar OFF no muestra 0 % como si ya estuviera aplicado cuando el
enlace perdió la orden. El overlay de porcentaje se oculta durante la espera o
desconexión, y los Ajustes abiertos se actualizan al recibir la confirmación o
perder el enlace. Este protocolo es independiente del streaming Wi-Fi: una
imagen pausada no confirma el estado de la cámara ni del enlace Bluetooth.

## Verificación

```sh
flutter analyze
flutter test
```

## Licencia

Apache License 2.0 — consulta [LICENSE](LICENSE).

## Physical phone pointer posture

`VrPhonePointerPolicy` is the shared Home/demo permission for a phone ray. It
requires explicit pointer intent, visible controller feedback, a non-neutralized
state and `RemoteControllerState.pointerPoseReady`. An old touch offset, an aim
quaternion or sideways movement does not qualify the physical posture. Legacy
and synthetic states default to false; walking/look/buttons keep their own rules.

`PhoneControllerPage` observes natural phone accelerometer axes: upright landscape
(±X gravity dominant), not portrait (±Y) or a flat display (±Z). Entry requires
200 ms of continuous valid samples; readiness expires after 150 ms without a
sample. Hysteresis permits modest natural pitch/roll. No extra camera is opened.
The controller may be held beside the body, for example on the right, with the
display facing inward and the rear camera outward. Keep its long edge horizontal
and its display upright. Turning around the vertical axis does not disqualify
this grip; holding the display face-up with the rear camera pointing down does.
This is an inclination gate, **not** absolute heading, screen-facing-user proof,
optical calibration or 6DoF tracking. The existing calibrated tracking path is
required to establish the devices' real relative position and heading.

Normal controls retain the user's Vista/Láser choice. The full-screen one-handed
layout remains selectable in settings; its automatic layout shortcut is opt-in
through `autoSwitchToOneHandedLaser`. Gravity does not identify how many hands
hold a phone. Gyro laser rates project on observed gravity/up and screen/right,
for both landscapes. Hidden/invalid feedback pauses automatic clicks; dwell uses
real elapsed time at 8/16/33 ms update intervals.

Update both endpoints. The core compact frame remains 46 bytes (byte42 bit3).
Direct BLE/hybrid UDP use the separately negotiated `pointerPostureV1` capability
and keep their existing packet lengths. An old Faro that decodes/re-encodes the
core frame also needs updating. The gate does not remove transport delay; an
existing Faro discrete backlog under ACK loss remains a separate freshness issue.
