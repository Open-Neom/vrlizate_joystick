# 🕹️ vrlizate_joystick

Modular dual-analog joystick, 3D VR smartphone controller, and low-latency WebSocket service for Flutter & VRlizate.

Use a compatible secondary smartphone (child device) as a touch gamepad, or
add motion control when a working gyroscope is available. The controller does
not render the stereo VR world; its native Flutter UI still uses graphics
resources. Compatibility with every old phone or browser is **not** guaranteed.

## Features

- **Native edge-framed landscape controls:** L/R span the top, Y/B the outer sides,
  and X/A the bottom edges and corners. Concave bands frame each circular stick;
  the painted shapes also define the touch regions. Connection/settings and
  experience actions stay in the center, leaving the outer edges for controls. Native
  entry/exit keeps both landscape orientations.
  ES: X abajo izquierda, A abajo derecha, Y lateral izquierdo, B lateral derecho;
  L/R arriba. Son franjas con recorte circular, no botones aislados.
  Y/B keep enlarged outer-edge targets; L/R own the top strips and upper-inner
  circular surrounds next to the central panel. ES: los lóbulos interiores
  superiores pertenecen a L/R; Y/B permanecen en las orillas exteriores.
  El izquierdo conserva su tamaño; el derecho mide el 78% para ampliar el centro.
- **Dual Analog Virtual Thumbsticks:**
  - **Left Stick:** 3D locomotion / omnidirectional ground navigation $(XZ)$.
  - **Right Control:** `Vista` provides vertical thumb/phone inclination;
    `Láser` replaces that same circular region with touch aim and hold-to-grip.
    Switching releases all held inputs and the old gesture before continuing.
    Walking uses the left stick for heading; native games can request both
    view axes through `horizontalLook` (see the contract below).
  - Both use a continuous radial deadzone (10%) and a 1.5 response exponent.
    A firm, steady hold ramps gain over 1.8 seconds: movement 0.5→1.0 and look
    0.45→0.8. Small deflections remain precise; release, a turn over 55 degrees
    from the held direction, backgrounding and profile changes reset the ramp.
  - Native left-stick rim intent is reported before this speed ramp. Entering
    the outer 92% sets `moveAtEdge`; returning below 84% or releasing clears it.
    A walking host can use a sustained rim hold to turn toward the chosen
    heading while keeping the same progressive movement speed. NES and driving
    do not request this walking behavior.
- **Hold-to-look motion:** Press the right stick, including its center, to set
  the phone's neutral orientation. Deflect the phone and hold that posture to
  keep turning, even after physical rotation stops. Returning to neutral or
  releasing stops the motion contribution; each new press sets a new center.
  The gyro tracks relative orientation and gravity defines the axes in either
  landscape direction. An angular 3° deadzone and 1.25 response exponent soften
  the center; 25° reaches the maximum contribution of 0.6. Only output speed
  saturates: further physical deflection is retained so returning to center
  works correctly. Thumb input still adds to motion, with combined norm at most
  1. Stale/failed sensors fall back to thumb and require a new press to rearm.
  The `Inclinar la vista con el teléfono` setting is enabled by default and saved locally.
  It applies only to `Vista`, not touch laser, NES or driving. Walking profiles
  consume only vertical inclination; explicit game profiles can also use yaw.
  There is no position
  tracking or absolute compass heading; long holds can accumulate gyro drift.
  Integration uses sensor timestamps; the local monotonic clock handles
  freshness, so batched callbacks do not change the measured deflection.
  A new press recenters this local control without recentering the viewer.
  Near a 170° physical rotation the gesture disarms to avoid an ambiguous
  orientation; it needs a fresh press. A completely flat initial phone needs
  a usable gravity basis first. With an inclined screen, rotation around its
  normal can contribute yaw, as it has a component around world-up.
- **Independent Action Buttons:** `A/B/X/Y`, `L` utility and `R` primary trigger.
- **Touch Aiming Pad:** Available in the right control's `Láser` mode, with
  touch-only aim and 280 ms hold-to-grip. Offset aim is retained after release;
  switching back to `Vista` centers and releases it for head-gaze selection.
  Native joystick packets send
  zero pointer angular velocity. Hold-to-look motion travels in `lookX/lookY`
  instead, so it never takes over the laser pose or changes the BLE envelope.
- **Central experience panel:** Shows actual host-provided button actions and
  the `Vista`/`Láser` selector. It does not currently stream the visor image.
  A future thumbnail channel must fragment bounded images, discard stale frames
  and prioritize controls; the current reliable BLE state queue is not a video
  transport. GPU capture and YouTube composition need device validation.
- **Shake-to-show/hide:** A deliberate controller shake toggles the viewer's
  controller feedback, in joystick and driving. Gravity-aware detection,
  quiet rearming and a cooldown reject ordinary wheel tilts and repeat toggles.
  Settings offer manual visibility and a separate shake enable switch. Shake
  never recenters the visor; the labelled recenter button remains explicit.
- **VirtualThumbstick Widget:** Highly customizable 2D analog on-screen joystick with spring return, deadzone threshold, and cyberpunk styling.
- **WebSocket Streaming:** Full-state JSON with authenticated pairing tokens.
  Native controls are sampled every 16 ms. Unchanged state is sent every 200 ms;
  continuous BLE analog changes are capped at 30 Hz, and Wi-Fi at the 16 ms
  sampling interval. Button edges, neutral releases and mode acknowledgements
  are immediate. The simpler browser fallback refreshes held state every 100 ms.
- **Connection recovery:** Transient failures retry while the controller is
  foreground, with delays capped at 10 seconds. Backgrounding releases inputs
  and preserves a surviving link; resuming retries immediately. Rejected or
  expired credentials require fresh pairing. The receiver still neutralizes
  stale controls after 500 ms; reconnection does not replay held input. OS app
  termination/radio suspension can still close the underlying connection.
- **QR Pairing Dialog:** One-tap pairing workflow using `vrlizate://pair?...` canonical URIs.
- **Driving profile:** Calibrated screen-normal steering, touch fallback,
  independent held accelerator/brake, explicit pause/resume and A for selecting
  the viewer's world-space menus without pressing the accelerator.
- **NES profile:** Host-selected classic controller with a digital D-pad,
  red B/A buttons and Select/Start. A separate Home action saves/exits through
  the host. The native layout has no look stick or laser pad. Bluetooth is the
  native pairing flow used by VRlizate; the opt-in browser transport below is
  retained for SDK compatibility.

## Quick Start

```dart
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

// Start controller server in visor
final service = VrRemoteControllerService();
await service.startServer();

// Refresh the advertised LAN address before reopening pairing after a
// network change. This keeps the current token, port and connection.
await service.refreshLocalAddress();
// Then show pairing (with Wi-Fi guidance instead of a QR if no LAN exists):
RemoteControllerQrDialog.show(context, service: service);
```

ES: el QR prioriza Wi-Fi/punto de acceso y evita las interfaces de datos móviles
y VPN. Sin una dirección LAN válida no se publica un QR con localhost ni con
una IP celular. Tras cambiar de red, vuelve a abrir el emparejamiento y escanea
el QR actual. Ambos teléfonos deben poder comunicarse dentro de esa red.

## Controller Page

Recommended native entry: open the in-app scanner to avoid relying on the
external camera app to launch a custom URI scheme. Android/iOS request camera
access only here; other platforms retain explicit manual entry.

```dart
Navigator.of(context).push(MaterialPageRoute<void>(
  builder: (_) => const VrControllerPairingPage(),
));
```

ES: en el mando abre **Usar como mando** y apunta al QR **Mando con app** del
visor. El lector acepta invitaciones `vrlizate://pair` para `child/localSocket`,
detiene y dispone la cámara antes de abrir el joystick. Un QR inválido no abre
URLs ni crea sockets. El QR **Sin instalar app** es para el navegador externo.
El lector Android se incluye en el APK; no requiere descargar ML Kit al escanear.
En iOS declara `NSCameraUsageDescription` y `NSLocalNetworkUsageDescription`.
Mantén una ruta de entrada ligera debajo para volver sin arrancar el visor.

For already validated credentials or an explicitly manual controller UI:

```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => PhoneControllerPage(
      initialMode: RemoteControllerMode.joystick,
    ),
  ),
);
```

## Controller contract / Contrato del mando

`btnA`, `btnL`, and `btnR` are independent. `isTriggerPressed` reflects an
explicit `trigger` or `btnR`, never `btnA` or `btnL`. A host may combine A and
trigger into one primary action, but must edge-detect that combined state to
avoid duplicate selections. `laserSlideActive` identifies a held head-relative
pad even at `(0, 0)`; it is false after release, pause, disconnect, or timeout.
Hosts should use `laserX`/`laserY` for native touch aim, not gyro orientation.

VRlizate App reserves **A for UI selection** and R for game actions. While a
phone is connected, the host calls `arbiter.setDwellSuppressed(remotePhone, true)`;
on disconnect it releases that hold. Merely stopping stick traffic must not
reactivate automatic selection. ES: mirar apunta; con mando, sólo A selecciona.

`btnA`, `btnL` y `btnR` son independientes: L es utilidad y R es gatillo.
Si el visor combina A y gatillo como acción primaria, debe detectar el flanco
del estado combinado para evitar clics duplicados. `laserSlideActive` indica
que el dedo controla el pad relativo a la cabeza, incluso en el centro; no
debe confundirse con una pose IMU en el mundo. El mando conserva la última
orientación del pad al soltar sin aplicar nuevos deltas IMU. El giroscopio
aporta dirección al volante o giro de vista mientras se pulsa el stick derecho;
nunca modifica el láser.

`RemoteControllerState.moveAtEdge` is an optional boolean: true/false carries
the native thumb's raw rim contact, while null identifies an older sender or
transport so the host can infer intent from the received stick magnitude.
It never commands a camera rotation itself. The VRlizate BLE adapter negotiates
`edgeTurnIntent` during mutual authentication, then carries this hint in bit 15
of the existing 21-byte state. Without agreement the bit stays zero and the hint
is omitted, preserving compatibility with older receivers. Movement axes and
their progressive response are unchanged.

An experience can explicitly request `horizontalLook: true` in its controller
mode request when it needs independent horizontal right-stick turning, such as
classic Doom. New requests default to false; old messages that omit this field
keep their previous two-axis look behavior. Changing this profile releases held
input and requires a neutral acknowledgement, while caption-only updates retain
their existing behavior.

`controllerVisible` is a boolean desired state (default `true` for legacy
clients), included in every native snapshot, not a toggle pulse. Watchdog
neutralization/disconnect preserve it. A new connection defaults visible until
its first snapshot, which restores the native page's preference. Opening a new
native controller page starts visible; this is a session preference, not stored
across app restarts. Malformed or stale snapshots cannot change visibility.
The host renders the feedback in Home and demos and honors this field.
ES: sacudir el **mando**, en cualquier dirección, muestra/oculta su representación
en el visor. También puede usarse «Mostrar mando en visor» en Ajustes sin sensor.
No dispara A/B, no cambia de demo ni recentra la vista.

## Experimental binary poses / Poses binarias experimentales

The native and browser clients **send JSON**, not binary. The optional server
path accepts exactly 28-byte `VrRemoteBinaryCodec` poses: orientation, angular
velocity, one normalized touch pair and six button bits (trigger, action, A,
B, grip, stick-click). It always yields joystick mode and carries **no** second
stick, X/Y/L/R buttons, touch-pad ownership, recenter, or measured range. Input
and heartbeat binary packet types are not handled by this server. This codec
allocates and is not a Zero-GC or full-gamepad replacement.

The first valid frame selects JSON or binary for that connection; reconnect
to change format. Binary sequences use uint16 serial arithmetic: duplicates,
backward frames and the ambiguous 32768-step jump are rejected; a forward gap
must be less than 32768. Sender timestamps retain only their lower 32 bits and
are not absolute timestamps. Null touch coordinates use signed **-32768**;
**+32767 means 1.0**. Update experimental senders and receivers together: the
old +32767 null sentinel was ambiguous and cannot be recovered reliably.

Los 28 bytes son una vía experimental de pose, no el estado completo del
mando. La ruta actual continúa siendo JSON. El receptor exige la longitud
exacta, valida todos los ejes numéricos y neutraliza entradas al perder datos.
No existe interoperabilidad automática con el antiguo centinela nulo ambiguo;
actualiza ambos extremos. HTTP/WebSocket no están cifrados: utiliza una LAN de
confianza. El QR/enlace entrega el token; UDP anuncia el visor sin divulgarlo.

## Driving / Conducción

Controllers start in **JOYSTICK / Vista**, with `Láser` available in the same right control, not
in a separate laser startup screen. The host can recommend **CONDUCCIÓN** for
Riviera and **JOYSTICK** when leaving it; native settings also allow a manual
choice. Explicit `PhoneControllerPage(initialMode: RemoteControllerMode.driving)`
is supported, but an authenticated host recommendation takes precedence.
Hold the phone horizontally with both hands, press **CENTRAR VOLANTE**, then
turn it clockwise to steer right. The default motion range is ±55° with a 2°
deadzone and a 1.15 response exponent to soften the center. Touch steering stays
linear; direction and pedal ramps are unchanged.
Centering the wheel is local: it does **not** send the visor `recenter` command.
The separately labelled visor-recenter control remains available in the toolbar.
The laser/grip pad is disabled in this profile. Shake-to-show/hide and its
manual settings switch remain available; ordinary steering tilt is not a shake.

- R holds the accelerator; L holds the brake. Pedals rise at 3/s and fall at
  6/s; brake overrides throttle. These are synthetic ramps, not pressure sensing.
- A horizontal slider is always available, including phones without an IMU.
  It springs to zero on release and recalibrates the current hand pose to avoid
  a jump back to an old wheel angle. **USAR TÁCTIL** disables motion steering.
- **PAUSAR**, lifecycle suspension and disconnect immediately release inputs.
  Resuming the app does not resume driving: press **CONTINUAR** and press the
  pedals again. **ATRÁS / HOME** releases driving and retains the B/back action.
  **CONTINUAR** emits one 150 ms A pulse so the host can distinguish explicit
  resume from a recovered heartbeat. The replay icon emits X while paused.
- Native sensor errors or two seconds without valid gyro samples show a touch
  fallback. Laser mode changes to dual touch controls; driving remains usable
  with the slider. A recovered sensor is recalibrated before driving continues.
  Losing a sensor while actively using motion steering also pauses and releases
  the pedals; confirm **CONTINUAR** to use the touch fallback.

El perfil es un volante **3DoF relativo**, no seguimiento de posición. Integrar
el giroscopio puede acumular deriva; recentra el volante cuando sea necesario.
No hay fusión con gravedad, magnetómetro ni calibración automática entre visor
y mando. Usa el deslizador si el sensor falla o prefieres no girar el teléfono.

The reusable, UI-independent `VrSteeringController` accepts quaternion poses,
`calibrate`, `setTouchSteering`, `setPedals`, `advance(elapsedSeconds)` and
`setPaused`. It computes a local-Z swing/twist angle; arbitrary neutral poses,
both landscape orientations and quaternion sign equivalence are covered by
unit tests. Elapsed-time steps are capped at 100 ms after scheduling gaps.

Full-state JSON adds optional fields (legacy frames still work):

| Field | Meaning |
| --- | --- |
| `mode: "driving"` | Explicit driving profile; not locomotion or laser |
| `steering` | -1 left, 0 straight, +1 right |
| `throttle`, `brake` | Normalized 0..1 pedals |
| `drivingPaused` | Neutralize driving when true |
| `motionAvailable` | Recent valid gyro samples; not necessarily the chosen steering source |

The receiver rejects non-finite values and invalid pause booleans, clamps
axes, and zeroes driving values in other modes. Timeout/disconnect publishes
`drivingPaused: true` for driving clients. Hosts **must** route this profile
to a vehicle controller instead of turning R into selection/fire or interpreting
it as walking. Back/Home remains available. The experimental binary pose format
does not carry driving controls. The embedded browser follows the same host
mode request and offers touch steering, held throttle/brake, explicit resume
and Home. It is a simpler layout, without native IMU wheel support or pedal
ramps; browser pedals are digital 0/1 and brake overrides throttle.
Receiver-generated `RemoteControllerState.isNeutralized` marks timeout,
disconnect and replacement releases; it cannot be supplied through JSON.
After this safety marker, hosts must observe released pedals/buttons before
accepting a new start/resume gesture. A recovered held accelerator is not one.

### Host-driven mode / Modo recomendado por el visor

```dart
service.requestControllerMode(RemoteControllerMode.driving); // Enter Riviera
service.requestControllerMode(RemoteControllerMode.nes); // Enter NES runtime
service.requestControllerMode(RemoteControllerMode.joystick); // Leave demo
```

The active experience selects the profile. `nes` uses the existing state fields:
visible A -> `btnA`, visible B -> `btnX`, Start -> `btnY`, Select -> `btnL`,
Home -> `btnB`; its D-pad emits `stickX/stickY` in -1/0/1, positive Y upwards.
Game input and platform navigation therefore stay distinct. Other consoles
need an implemented layout and tested mapping before requesting a new profile;
the NES profile does not imply SNES/N64 support. Update both native phones to
receive this layout; older clients cannot display profiles they do not know.
The opt-in browser fallback accepts `nes` but retains its generic controls.

The authenticated WebSocket sends a separate command:

```json
{"type":"vrlizate.controllerMode","version":1,"mode":"driving","revision":1}
```

`VrControllerModeSession` ignores duplicate/stale revisions and resets only on
a new connection. A native/web client clears all buttons, gestures and timers,
switches its layout, then includes `hostModeRevision` in every full-state JSON
packet. The first acknowledgement of a new revision must be neutral; driving
must also be paused. Until then, older-revision packets and held inputs are
ignored. Reconnecting receives the current request again and requires another
neutral acknowledgement. Choosing a manual mode after that acknowledgement is
allowed; a subsequent host request takes priority. No mode change sends an A
press or resumes acceleration. Legacy clients without this acknowledgement
remain readable, but cannot be promised automatic layout changes. The `laser`
wire enum remains compatible; hosts recommend joystick, driving or NES.

Al entrar a Riviera el visor solicita volante; al salir solicita joystick. El
cambio suelta entradas y deja conducción **pausada**: pulsa CONTINUAR y vuelve
a presionar los pedales. Los paquetes atrasados no restauran botones sostenidos
de clientes que reconocen este protocolo. VRlizate conecta este protocolo por
su puente Bluetooth; el servicio conserva WS local como transporte opcional
del SDK.

## Compatibility / Compatibilidad real

| Profile | Required | Current limitations |
| --- | --- | --- |
| Native touch | Host-app-supported Android/iOS, working multitouch, authenticated host link (BLE in VRlizate; optional WebSocket in SDK hosts) | No gyro/camera needed for touch or a pasted pairing link. This package is not a separate lightweight APK. |
| Native motion look | Native touch requirements + working gyro and accelerometer streams | Relative deflection requests sustained turn while held; gyro drift is possible during long holds. No positional tracking. Missing/stale sensors preserve thumb look and require a fresh press. |
| Native wheel | Native touch requirements + working gyro stream; accelerometer for tilt pedals | Relative gyro drift; no 6DoF. Missing sensors fall back to touch. |
| Embedded browser touch | JavaScript, WebSocket, URLSearchParams, touch events, Pointer Events and reachable LAN | Joystick A/B/grip or host-selected touch wheel/pedals, manual feedback toggle; not native layout parity. No certified oldest browser version. |
| Embedded browser motion | Not implemented in the touch fallback | No gyro aiming or shake detection. Use native controller for motion steering/shake. |

Adding browser orientation APIs would require a secure context and permission handling;
the [W3C orientation specification](https://www.w3.org/TR/orientation-event/)
documents these requirements. Knowing a `wss:` URL in the client parser does
not make the local server HTTPS-capable. HTTPS hosting/proxying also needs a
trusted certificate and a reachable secure socket endpoint; that deployment
is not provided by this package.

Native SDK requirements are listed in `pubspec.yaml`; the embedding app sets
the actual OS/device floor. Configure platform motion/local-network usage
descriptions, Internet access, and the `vrlizate` scheme before advertising
iOS/Android support. Mount `VrControllerPairingPage` to use the included native
scanner, or offer explicit pasting of the complete token-bearing link. BLE and Wi-Fi
Direct are advertised protocol options, **not implemented transports** here.
Discovery is optional UDP; AP isolation, firewalls and some hotspots can block
peer connections even on the same Wi-Fi. Use a trusted private demonstration
network, not an untrusted conference LAN. The bearer token does not encrypt data.

No prometemos «cualquier smartphone funcional». El contrato es **mando táctil
en teléfonos compatibles; movimiento como mejora opcional**. El visor necesita
su propia validación de GPU, sensores y rendimiento; un S25 de visor no reduce
el mínimo de sistema operativo de la app instalada en el mando.

### Physical release checklist / Pruebas físicas pendientes

Unit/widget and loopback WebSocket tests do not certify devices. Before release:

1. Test an older supported Android without gyro, one with gyro, and a supported
   iPhone; record exact OS/browser/build rather than inferring compatibility.
2. Deny motion/camera/network permissions; confirm touch input, pasted links and
   clear errors. Test browser HTTP touch separately from any future HTTPS IMU.
3. In both landscape directions, calibrate ±55°, hold R while steering, add L,
   release either finger, switch modes, pause, resume and use Home.
4. Lock screen, switch apps, receive a call, disable Wi-Fi and replace/reconnect
   the controller. Verify neutral inputs and explicit driving resume; measure
   watchdog latency (configured 500 ms plus polling/scheduling, not hard real-time).
5. Run a 30-minute low-end-controller session; measure drift, input latency,
   battery/thermal load, accidental presses and connection recovery on the
   actual booth network. Do not equate a 16 ms timer with guaranteed 60 Hz delivery.

## Verify / Verificar

```sh
flutter test
flutter analyze
```

## Vista del visor por Wi-Fi

La app puede anunciar `cast_preview` con una URL de `vrlizate_cast` por el enlace autenticado. El mando abre automáticamente una vista monocular en el centro del joystick y en los perfiles NES/conducción. Cerrar la imagen mantiene los controles Bluetooth. Proyectar comparte el enlace/QR con otros navegadores, que reciben los cuadros directamente del visor. El servidor HTTP del mando antiguo no interviene. La sesión y el enlace se mantienen únicamente en memoria y se descartan al perder o cambiar el vínculo.

Primera beta: JPEG a pocos FPS, sin audio ni descubrimiento de televisores. Ver [vrlizate_cast](../vrlizate_cast/README.md).
