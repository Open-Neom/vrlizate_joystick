import 'package:flutter/material.dart';

import '../utils/constants/vr_joystick_constants.dart';
import '../utils/constants/vr_joystick_translation_constants.dart';
import 'vr_laser_aim_reticle_painter.dart';

/// Full-screen view displayed when the smartphone controller enters one-handed
/// `RemoteControllerMode.laser`.
///
/// Replaces the dual-joystick layout with the live visor target view and laser
/// reticle, supporting:
/// - **Single Tap (`onTap`)** with the free hand -> Immediate Click / Select
/// - **5-Second Steady Wait** -> Auto-Click countdown & trigger
/// - **Long Press (`onLongPress`)** with the free hand -> Opens **Wordsphere**
///   for text input and destination search.
class VrLaserPointingView extends StatelessWidget {
  const VrLaserPointingView({
    super.key,
    required this.aimX,
    required this.aimY,
    required this.yawDegrees,
    required this.pitchDegrees,
    required this.dwellProgress,
    required this.dwellRemainingSeconds,
    required this.clickActive,
    required this.onTapClick,
    required this.onLongPressSearch,
    required this.onPanAimDelta,
    required this.onPanAimEnd,
    required this.onRecenter,
    required this.onReturnToJoystick,
    this.activeSearchQuery,
    this.previewWidget,
  });

  final double aimX;
  final double aimY;
  final double yawDegrees;
  final double pitchDegrees;
  final double dwellProgress;
  final double dwellRemainingSeconds;
  final bool clickActive;
  final VoidCallback onTapClick;
  final VoidCallback onLongPressSearch;
  final ValueChanged<Offset> onPanAimDelta;
  final VoidCallback onPanAimEnd;
  final VoidCallback onRecenter;
  final VoidCallback onReturnToJoystick;
  final String? activeSearchQuery;
  final Widget? previewWidget;

  @override
  Widget build(BuildContext context) {
    final horizontalAngleText =
        '${VrJoystickTranslationConstants.laserHorizontalLabelPrefix}'
        '${yawDegrees.toStringAsFixed(1)}'
        '${VrJoystickTranslationConstants.laserVerticalLabelPrefix}'
        '${pitchDegrees.toStringAsFixed(1)}'
        '${VrJoystickTranslationConstants.laserDegreeSuffix}';

    final dwellBadgeText = clickActive
        ? VrJoystickTranslationConstants.laserClickTriggeredBadge
        : '${VrJoystickTranslationConstants.laserDwellCountdownPrefix}'
              '${dwellRemainingSeconds.toStringAsFixed(1)}'
              '${VrJoystickTranslationConstants.laserDwellCountdownSuffix}';

    return GestureDetector(
      key: const Key(VrJoystickConstants.keyLaserPointingSurface),
      behavior: HitTestBehavior.opaque,
      onTap: onTapClick,
      onLongPress: onLongPressSearch,
      onPanUpdate: (details) => onPanAimDelta(details.delta),
      onPanEnd: (_) => onPanAimEnd(),
      onPanCancel: onPanAimEnd,
      child: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 0.95,
            colors: [
              Color(0xFF0D2137),
              Color(0xFF060B14),
            ],
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (previewWidget != null)
              Opacity(
                opacity: 0.58,
                child: previewWidget!,
              ),
            CustomPaint(
              key: const Key(VrJoystickConstants.keyLaserPointingReticle),
              painter: VrLaserAimReticlePainter(
                aimX: aimX,
                aimY: aimY,
                dwellProgress: dwellProgress,
                clickActive: clickActive,
              ),
              child: const SizedBox.expand(),
            ),
            // Top bar: One-Handed Laser badge, angles, and quick controls
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xCC071526),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: const Color(0x8800E5FF)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.bolt_rounded,
                              size: 14,
                              color: Color(0xFF00E5FF),
                            ),
                            SizedBox(width: 5),
                            Text(
                              VrJoystickTranslationConstants.laserOneHandBadge,
                              style: TextStyle(
                                color: Color(0xFF80D8FF),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.7,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xAA08111E),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          horizontalAngleText,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      OutlinedButton.icon(
                        key: const Key(
                          VrJoystickConstants.keyLaserPointingWordsphereButton,
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: const Color(0xCC0D1B2E),
                          foregroundColor: const Color(0xFF80D8FF),
                          side: const BorderSide(color: Color(0x6600E5FF)),
                        ),
                        onPressed: onLongPressSearch,
                        icon: const Icon(Icons.blur_circular_rounded, size: 14),
                        label: const Text(
                          VrJoystickTranslationConstants
                              .laserOpenWordsphereButton,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const Key(
                          VrJoystickConstants.keyLaserPointingRecenter,
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: const Color(0xCC0D1B2E),
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Color(0x55FFFFFF)),
                        ),
                        onPressed: onRecenter,
                        icon: const Icon(
                          Icons.center_focus_strong_rounded,
                          size: 14,
                        ),
                        label: const Text(
                          VrJoystickTranslationConstants.laserRecenterButton,
                          style: TextStyle(fontSize: 10.5),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const Key(
                          VrJoystickConstants.keyLaserPointingBackToJoystick,
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: const Color(0xCC0D1B2E),
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Color(0x44FFFFFF)),
                        ),
                        onPressed: onReturnToJoystick,
                        icon: const Icon(
                          Icons.sports_esports_rounded,
                          size: 14,
                        ),
                        label: const Text(
                          VrJoystickTranslationConstants
                              .laserReturnToJoystickButton,
                          style: TextStyle(fontSize: 10.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Bottom HUD: 5-second auto-click countdown, active search destination, and free-hand gesture instructions
            Positioned(
              left: 16,
              right: 16,
              bottom: 10,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (activeSearchQuery != null &&
                      activeSearchQuery!.trim().isNotEmpty)
                     Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xDD0A253B),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: const Color(0xAA00E5FF)),
                        ),
                        child: Text(
                          '${VrJoystickTranslationConstants.laserDestinationActivePrefix}$activeSearchQuery',
                          style: const TextStyle(
                            color: Color(0xFF80D8FF),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  Container(
                    key: const Key(
                      VrJoystickConstants.keyLaserPointingDwellBadge,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xD808111D),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: clickActive
                            ? const Color(0xFF69F0AE)
                            : const Color(0x5500E5FF),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          dwellBadgeText,
                          style: TextStyle(
                            color: clickActive
                                ? const Color(0xFF69F0AE)
                                : const Color(0xFF00E5FF),
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          VrJoystickTranslationConstants.laserTapHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 1),
                        const Text(
                          VrJoystickTranslationConstants.laserLongPressHint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Color(0xFF80D8FF),
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
