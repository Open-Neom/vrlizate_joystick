import 'package:flutter/material.dart';

import '../utils/constants/vr_joystick_constants.dart';
import '../utils/constants/vr_joystick_translation_constants.dart';

/// Interactive center-panel bar on the VRlizate Smartphone Joystick for
/// triggering or scrubbing the Breakthrough / Passthrough curtain (`0% .. 100%`)
/// and toggling the in-visor 3-Camera & Live Calculations HUD (`3 CÁM`).
class VrBreakthroughCurtainBar extends StatelessWidget {
  const VrBreakthroughCurtainBar({
    super.key,
    required this.passthroughMix,
    required this.spatialHudVisible,
    required this.onMixChanged,
    required this.onToggleMix,
    required this.onToggleSpatialHud,
    this.connected = true,
    this.synchronized = true,
    this.pending = false,
  });

  final double passthroughMix;
  final bool spatialHudVisible;
  final ValueChanged<double> onMixChanged;
  final VoidCallback onToggleMix;
  final VoidCallback onToggleSpatialHud;
  final bool connected;
  final bool synchronized;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final mixClamped = passthroughMix.clamp(0.0, 1.0);
    final pct = (mixClamped * 100).round();
    final ready = connected && synchronized;
    final isActive = ready && mixClamped > 0.01;

    return Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              void handleDragPosition(double localDx) {
                final width = constraints.maxWidth;
                if (width <= 0) return;
                // Distance from horizontal center (0 at center, 1 at left/right edge)
                // or full left-to-right progress if dragging from left edge:
                final normX = (localDx / width).clamp(0.0, 1.0);
                final centerDist = ((normX - 0.5).abs() * 2.15).clamp(0.0, 1.0);
                onMixChanged(centerDist);
              }

              return GestureDetector(
                key: const ValueKey(
                  VrJoystickConstants.keyBreakthroughCenterBar,
                ),
                behavior: HitTestBehavior.opaque,
                onTap: ready ? onToggleMix : null,
                onHorizontalDragStart: !ready
                    ? null
                    : (details) => handleDragPosition(details.localPosition.dx),
                onHorizontalDragUpdate: !ready
                    ? null
                    : (details) => handleDragPosition(details.localPosition.dx),
                child: Container(
                  height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A1224),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isActive
                          ? const Color(0xFF00E5FF)
                          : const Color(0xFF00E5FF).withValues(alpha: 0.45),
                      width: isActive ? 1.5 : 1.0,
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Center-outward curtain fill
                      if (isActive)
                        FractionallySizedBox(
                          widthFactor: mixClamped.clamp(0.05, 1.0),
                          heightFactor: 1.0,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  const Color(
                                    0xFF10B981,
                                  ).withValues(alpha: 0.38),
                                  const Color(
                                    0xFF00E5FF,
                                  ).withValues(alpha: 0.50),
                                  const Color(
                                    0xFF10B981,
                                  ).withValues(alpha: 0.38),
                                ],
                              ),
                              borderRadius: BorderRadius.circular(7),
                            ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            !connected
                                ? 'SIN CONEXIÓN · RECONECTAR'
                                : !synchronized
                                ? 'SINCRONIZANDO VISOR'
                                : pending
                                ? 'ESPERANDO VISOR'
                                : isActive
                                ? '${VrJoystickTranslationConstants.breakthroughBarActivePrefix}$pct${VrJoystickTranslationConstants.breakthroughBarActiveSuffix}'
                                : VrJoystickTranslationConstants
                                      .breakthroughBarIdleLabel,
                            style: TextStyle(
                              color: isActive
                                  ? const Color(0xFF00E5FF)
                                  : Colors.white70,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          key: const ValueKey(VrJoystickConstants.keySpatialHudToggle),
          onTap: ready ? onToggleSpatialHud : null,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              color: spatialHudVisible
                  ? const Color(0xFF10B981).withValues(alpha: 0.25)
                  : const Color(0xFF162035),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: spatialHudVisible
                    ? const Color(0xFF10B981)
                    : Colors.white24,
                width: spatialHudVisible ? 1.5 : 1.0,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.linked_camera_rounded,
                  size: 13,
                  color: spatialHudVisible
                      ? const Color(0xFF10B981)
                      : Colors.white70,
                ),
                const SizedBox(width: 3),
                Text(
                  VrJoystickTranslationConstants.spatialHudButtonLabel,
                  style: TextStyle(
                    color: spatialHudVisible
                        ? const Color(0xFF10B981)
                        : Colors.white70,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
