# vrlizate_joystick

Mando dual-analógico en segundo smartphone, perfiles de control especializados (Joystick, Conducción, NES) y servicio de emparejamiento para Flutter y VRlizate.

> Versión actual: **0.2.0**. Consulta [CHANGELOG.md](CHANGELOG.md) para el historial de cambios.

## Características principales

- **Controles ergonómicos en bordes (horizontal):** franjas laterales/superiores para `L/R`, `Y/B` y `X/A` alrededor de los sticks circulares, dejando el panel central para acciones contextuales, selector `Vista`/`Láser` y vista previa del visor.
- **Doble stick virtual progresivo (`VirtualThumbstick`):**
  - **Stick izquierdo:** locomoción 3D con zona muerta radial (10%), rampa progresiva de velocidad (1.8 s) y detección de intención de giro en el borde (`moveAtEdge` al 92%, liberación al 84%).
  - **Control derecho (`Vista` / `Láser`):** inclinación vertical (o dos ejes si la experiencia solicita `horizontalLook: true`), giro de vista por inclinación del teléfono (`VrMotionLookController`) al mantener presionado el stick, o pad táctil de puntero láser con agarre por pulsación sostenida (`Láser`).
- **Perfiles dirigidos por el anfitrión (`RemoteControllerMode`):**
  - `joystick`: locomoción, vista/láser y botones `A/B/X/Y/L/R`.
  - `driving`: volante 3DoF por giroscopio (`VrSteeringController`) con deslizador táctil de respaldo, acelerador (`R`), freno (`L`) y pausa explícita.
  - `nes`: cruceta digital (D-pad), botones `B/A`, `Select`, `Start` y `Home`.
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

## Verificación

```sh
flutter analyze
flutter test
```

## Licencia

Apache License 2.0 — consulta [LICENSE](LICENSE).
