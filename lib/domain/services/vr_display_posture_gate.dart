import 'dart:math' as math;

/// Physical display classification used to coordinate Android orientation locks
/// and handheld pointer posture gating.
enum VrDisplayFormFactor {
  phone,
  unfoldedNearSquareFoldable,
  landscapeTablet,
  externalDesktopMonitor,
}

/// Snapshot of physical display geometry and Android multi-display topology.
///
/// Dimensions (`[maxWidthPx]`, `[maxHeightPx]`) represent the physical display
/// (`WindowManager.maximumWindowMetrics`), never a split-screen sub-window.
final class VrDisplayPostureSnapshot {
  const VrDisplayPostureSnapshot({
    required this.maxWidthPx,
    required this.maxHeightPx,
    required this.density,
    this.isDefaultDisplay = true,
    this.isExternalDesktopDisplay = false,
    this.isCastingActive = false,
    this.automaticSystemOrientation = false,
  });

  final int maxWidthPx;
  final int maxHeightPx;
  final double density;

  /// `true` when the Activity runs on `Display.DEFAULT_DISPLAY` (handheld panel).
  final bool isDefaultDisplay;

  /// `true` when the Activity itself is hosted on an external HDMI/DP/DeX
  /// desktop monitor (`displayId != DEFAULT_DISPLAY`, non-casting).
  final bool isExternalDesktopDisplay;

  /// `true` when a wireless/Miracast/virtual screen-recording display is active.
  /// Casting mirrors the handheld screen and must NEVER unlock phone posture!
  final bool isCastingActive;

  /// User preference allowing free OS rotation (`SCREEN_ORIENTATION_UNSPECIFIED`).
  final bool automaticSystemOrientation;

  double get safeDensity =>
      (density.isFinite && density > 0.25) ? density : 1.0;

  int get shortSidePx => math.max(1, math.min(maxWidthPx, maxHeightPx));
  int get longSidePx => math.max(1, math.max(maxWidthPx, maxHeightPx));

  double get smallestWidthDp => shortSidePx / safeDensity;
  double get aspectRatio => longSidePx / shortSidePx;

  factory VrDisplayPostureSnapshot.fromRuntimeMap(
    Map<String, Object?> map, {
    bool automaticSystemOrientation = false,
  }) {
    final w = (map['maxDisplayWidthPx'] as num?)?.toInt() ?? 1920;
    final h = (map['maxDisplayHeightPx'] as num?)?.toInt() ?? 1080;
    final d = (map['displayDensity'] as num?)?.toDouble() ?? 2.625;
    return VrDisplayPostureSnapshot(
      maxWidthPx: w,
      maxHeightPx: h,
      density: d,
      isDefaultDisplay: (map['isDefaultDisplay'] as bool?) ?? true,
      isExternalDesktopDisplay:
          (map['isExternalDesktopDisplay'] as bool?) ?? false,
      isCastingActive: (map['isCastingActive'] as bool?) ?? false,
      automaticSystemOrientation: automaticSystemOrientation,
    );
  }
}

/// Orientation and pointer-posture decision produced by [VrDisplayPostureGate].
final class VrDisplayPostureDecision {
  const VrDisplayPostureDecision({
    required this.formFactor,
    required this.shouldLockSensorLandscape,
    required this.requiresGravityPointerPosture,
    required this.smallestWidthDp,
    required this.aspectRatio,
  });

  final VrDisplayFormFactor formFactor;

  /// Whether Android should request `SCREEN_ORIENTATION_SENSOR_LANDSCAPE`
  /// (`false` -> `SCREEN_ORIENTATION_UNSPECIFIED` so unfolded foldables and
  /// external DeX desktop windows avoid Android 14–16 letterboxing).
  final bool shouldLockSensorLandscape;

  /// Whether handheld 3DoF/laser pointing must pass [VrPhonePointerPosture]'s
  /// gravity inclination gate (`true` on phones, foldables, tablets, and during
  /// wireless screen casting; `false` only on stationary external DeX monitors).
  final bool requiresGravityPointerPosture;

  final double smallestWidthDp;
  final double aspectRatio;
}

/// Evaluates foldable, tablet, phone, Samsung DeX, and wireless-casting rules
/// inspired by the permissive (`MIT`) `GameOrientation` metric thresholds
/// (`LARGE_SW_DP = 600`, `NEAR_SQUARE = 1.25`) combined with strict
/// `Display.DEFAULT_DISPLAY` vs casting disambiguation.
abstract final class VrDisplayPostureGate {
  static const double largeSmallestWidthDp = 600.0;
  static const double nearSquareAspectLimit = 1.25;

  static VrDisplayPostureDecision evaluate(VrDisplayPostureSnapshot snapshot) {
    final swDp = snapshot.smallestWidthDp;
    final aspect = snapshot.aspectRatio;

    // Stationary external desktop monitor / Samsung DeX on an external display.
    // Wireless casting (`isCastingActive` while `isDefaultDisplay` is true, or
    // virtual cast mirrors) NEVER qualifies as an external desktop monitor.
    final isTrueExternalDesktop =
        !snapshot.isDefaultDisplay &&
        snapshot.isExternalDesktopDisplay &&
        !snapshot.isCastingActive;

    if (isTrueExternalDesktop) {
      return VrDisplayPostureDecision(
        formFactor: VrDisplayFormFactor.externalDesktopMonitor,
        shouldLockSensorLandscape: false,
        requiresGravityPointerPosture: false,
        smallestWidthDp: swDp,
        aspectRatio: aspect,
      );
    }

    if (swDp >= largeSmallestWidthDp && aspect < nearSquareAspectLimit) {
      // Unfolded inner foldable panel (e.g. ~2208x1840 -> ~1.20:1): release
      // fixed landscape lock to prevent OS letterboxing while keeping the
      // handheld gravity gate active when used as a physical controller.
      return VrDisplayPostureDecision(
        formFactor: VrDisplayFormFactor.unfoldedNearSquareFoldable,
        shouldLockSensorLandscape: false,
        requiresGravityPointerPosture: true,
        smallestWidthDp: swDp,
        aspectRatio: aspect,
      );
    }

    final formFactor = swDp >= largeSmallestWidthDp
        ? VrDisplayFormFactor.landscapeTablet
        : VrDisplayFormFactor.phone;

    return VrDisplayPostureDecision(
      formFactor: formFactor,
      shouldLockSensorLandscape: !snapshot.automaticSystemOrientation,
      requiresGravityPointerPosture: true,
      smallestWidthDp: swDp,
      aspectRatio: aspect,
    );
  }
}
