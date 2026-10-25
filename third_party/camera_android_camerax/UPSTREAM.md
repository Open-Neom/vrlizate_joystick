# VRlizate CameraX analysis-budget fork

Copied without changing the package version from the cached pub.dev source of
`camera_android_camerax 0.7.4+8`, 2026-10-22. The unmodified upstream file hashes
and aggregate tree hash are in `UPSTREAM_SOURCE_SHA256.json`:
`90e2bdb1e1a428530a3f9efa534ce0cdd73287b51468297245a16263da7c3f5d`.

Upstream: https://pub.dev/packages/camera_android_camerax/versions/0.7.4+8
Source: https://github.com/flutter/packages/tree/main/packages/camera/camera_android_camerax
The original `LICENSE` and all source notices are retained (BSD-3-Clause).
New fork code uses the same BSD-3-Clause terms. No generated Pigeon source,
CameraX version, permission, preview/capture surface or AE FPS request is changed.

## Opt-in API

After a `CameraController.initialize()` completes, call:

```dart
const budget = MethodChannel('vrlizate/camera_analysis_budget');
await budget.invokeMapMethod<String, dynamic>('setIntervalMs', {
  'cameraId': controller.cameraId,
  'intervalMs': 333,
});
final status = await budget.invokeMapMethod<String, dynamic>('getStatus', {
  'cameraId': controller.cameraId,
});
```

`intervalMs` accepts an integer from 0 to 10000. Zero is the default and disables
throttling; no unrelated camera consumer is automatically assigned a budget.
The response includes `supported`, `configured` (for set), `intervalMs`,
`deliveredFrames`, `skippedFrames` and `gateBeforePigeon`. Counters describe
analysis delivery only, not preview, rendering, input or model FPS.

The Dart implementation internally binds each texture cameraId to its native
ImageAnalysis Pigeon ID during initialization, and unregisters it at disposal.
An engine-owned registry stores one budget per ImageAnalysis, without process
static state. Unknown owners and malformed requests return explicit errors;
the camera initialization tolerates absent extension channels for compatibility.

The native wrapper rejects an early frame before invoking the upstream
Analyzer, closes its ImageProxy immediately and never announces that frame's
proxy/planes to Dart. Preview and capture FPS remain CameraX's original request.
Delivered frames retain the upstream ownership and close path. Restarting an
analyzer resets its deadline; changing budget admits the next frame immediately;
camera disposal/engine detach removes its state. Separate owners do not share
deadlines or counters.

The interval is a cap, not a precise scheduler. Sampling quantizes to available
camera callbacks: 167 ms at exact 12 FPS may yield roughly 4 deliveries/s, while
140 ms admits alternate callbacks (roughly 6/s). These are arithmetic examples,
not measured device performance.

## Verification

`python3 tool/run_frame_gate_tests.py` tests the pure Java gate with a local JDK,
without Android/Gradle/Flutter. It checks default behavior, deadlines, counters,
restart, independent owners, zero override, bad intervals and disposal reset.
The native channel and actual preview/frame cadence require Android integration
tests and a real-device comparison. A lower Dart delivery count alone does not
prove lower total CPU, unchanged preview quality or sustained VR FPS.
