# 🕹️ vrlizate_joystick

Modular dual-analog joystick, 3D VR smartphone controller, and low-latency WebSocket service for Flutter & VRlizate.

Turn any secondary smartphone (child device) or web browser into an ergonomic, low-latency 3D VR gamepad and remote controller.

## Features

- **Dual Analog Virtual Thumbsticks:**
  - **Left Stick:** 3D locomotion / omnidirectional ground navigation $(XZ)$.
  - **Right Stick:** 360° yaw turn & 180° pitch tilt for looking around and correcting horizon drift.
- **4 Ergonomic Action Buttons:**
  - Left upper: `RT · GATILLO` & `GRIP`.
  - Right upper: `A` & `B`.
- **Shake-to-Recenter:** Shake detection via accelerometer with haptic feedback to instantly recenter visor gaze and controller.
- **VirtualThumbstick Widget:** Highly customizable 2D analog on-screen joystick with spring return, deadzone threshold, and cyberpunk styling.
- **WebSocket Streaming:** 60 FPS state sync with authenticated pairing tokens and fallback Web Canvas.
- **QR Pairing Dialog:** One-tap pairing workflow using `vrlizate://pair?...` canonical URIs.

## Quick Start

```dart
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

// Start controller server in visor
final service = VrRemoteControllerService();
await service.startServer();

// Or show pairing dialog:
RemoteControllerQrDialog.show(context, service: service);
```

## Controller Page

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
