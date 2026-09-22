# Changelog

## 0.2.0 - 2026-09-22

- Request portrait while the QR scanner is the active route; the controller
  requests landscape on entry. Do not overwrite a replacement route's
  orientation when an old controller disposes after its navigation animation.

- Recover transient native-controller disconnections with six bounded retries;
  pause releases input while preserving a live link, and resume rearms recovery.
  Cancel obsolete attempts on destination changes and reject stale completions.
- Add authenticated-target callbacks for host-owned invitation storage and
  receiver telemetry for input age, accepted/rejected states, watchdog releases
  and disconnect reasons. Input age uses local time and is not RTT.

- Prefer Wi-Fi/hotspot LAN addresses for pairing; never advertise cellular,
  VPN or loopback addresses. Refresh the advertised address without rotating
  the token or disconnecting a controller; show guidance when no LAN is available.
- Add persistent `controllerVisible` snapshots and a manual settings fallback.
  Shake now shows/hides viewer feedback in joystick and driving, never recenters;
  gravity-aware detection debounces vigorous movement without ordinary tilt.
- Native laser aiming is touch-only, including after releasing the aiming pad;
  retain gyroscope integration for wheel steering and generic wire pose support.
- Keep enlarged Y/B regions on the outer edges; assign the upper-inner circular
  surrounds to L/R for both paint and touch, preserving sticks and X/A geometry.
- Frame each circular joystick with concave edge bands: L/R above, Y/B on the
  outer sides, X/A across bottom edges and corners. Use the same paths for paint
  and hit testing; move status/settings centrally to free physical edges.
  Preserve landscape on return and independent multi-touch/cancellation.
- Add explicit A selection in driving without resuming stale held pedals.
- Add `VrControllerPairingPage`: bundled native QR reader (mobile_scanner 7.4.1),
  permission/manual fallback, strict child/localSocket validation and camera
  release before automatic connection. Clipboard reads require a button press.
- Simplify the viewer's QR page: in-app instructions, separate browser fallback,
  larger adaptive QR and optional advanced links, preserving server ownership.
- Default to the dual joystick with integrated aiming; remove the separate
  laser layout from mode settings, including legacy initial-mode requests.
- Add authenticated, revisioned host layout recommendations: neutral ACK on
  change/reconnection and paused driving before a fresh resume/accelerator press.
  Native and browser controllers follow the active app; browser steering is touch.
- Add calibrated motion steering (55° full lock, progressive response 1.15),
  touch fallback, independent pedals, pause and lifecycle-safe input release.
- Ignore cancellation callbacks from replaced/disposed controller surfaces.
- ES: joystick inicial, volante contextual más suave y liberación segura al
  cambiar de demo, desconectar o cerrar la pantalla del mando.
- Require vrlizate 1.12.0; move workspace overrides out of the public manifest.
- Keep A/L/R independent: L never activates the primary trigger; A is exposed
  through btnA, R through btnR (also primary trigger). Hosts map one semantic action.
- Add validated `laserSlideActive`; touch aiming owns native joystick pose
  without IMU pose writes or prediction velocity, including after release.
- Validate every navigation/look/laser axis and preserve release on pause.
- Fix experimental binary sequence wrap, exact-size checks, stick endpoints and
  per-connection format consistency. Update both binary endpoints together.
- JSON remains the complete native/browser controller protocol; the 28-byte
  binary pose path omits controls and is not a drop-in replacement or Zero-GC.
- ES: botones independientes, exclusión pad/IMU y validación de red. El nuevo
  mínimo del core debe publicarse primero; estas versiones aún no están publicadas.

## 0.1.0

- Initial modular release extracted from `VRlizate_app`.
- Symmetrical Dual Joystick layout (Left 3D navigation, Right 360°/180° view & tilt).
- 4 Top ergonomic action buttons (`RT`, `GRIP`, `A`, `B`).
- Accelerometer shake-to-recenter gesture with haptic feedback.
- Dedicated modal Settings bottom sheet (⚙️).
- `VirtualThumbstick` analog widget with deadzone and animated spring return.
- `VrRemoteControllerService` with 60 FPS WebSocket sync and embedded HTML5 canvas fallback.
- `RemoteControllerQrDialog` for fast QR scanning and deep link pairing.
