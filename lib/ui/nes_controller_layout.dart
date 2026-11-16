import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/constants/vr_joystick_constants.dart';
import '../utils/constants/vr_joystick_translation_constants.dart';
import 'vr_nes_button.dart';
import 'vr_nes_dpad.dart';

/// NES-shaped touch surface. Button names here describe the visible controls;
/// the parent retains ownership of protocol mapping and session neutralization.
class NesControllerLayout extends StatelessWidget {
  const NesControllerLayout({
    super.key,
    required this.onDirection,
    required this.onButton,
    required this.onSettings,
    required this.connected,
    required this.pressed,
    required this.captions,
    this.onConnect,
    this.preview,
  });

  final void Function(double x, double y) onDirection;
  final void Function(String button, bool down) onButton;
  final VoidCallback onSettings;
  final VoidCallback? onConnect;
  final Widget? preview;
  final bool connected;
  final Set<String> pressed;
  final Map<String, String> captions;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey(VrJoystickConstants.keyNesSurface),
    color: const Color(0xFFC6C4BC),
    child: SafeArea(
      minimum: MediaQuery.systemGestureInsetsOf(context),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final small = constraints.maxWidth < 650;
            final spacious =
                constraints.maxWidth >= 736 && constraints.maxHeight >= 376;
            final target = spacious ? 56.0 : 48.0;
            final gap = spacious ? 10.0 : 8.0;
            final pairWidth = 2 * target + gap;
            Widget button(String id, String label, {bool red = false}) =>
                VrNesButton(
                  key: ValueKey('${VrJoystickConstants.keyNesButtonPrefix}$id'),
                  label: label,
                  caption: captions[id],
                  active: pressed.contains(id),
                  red: red,
                  onChanged: (down) => onButton(id, down),
                );
            return Column(
              children: [
                SizedBox(
                  height: target,
                  child: Row(
                    children: [
                      const Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            VrJoystickTranslationConstants.nesHeaderTitle,
                            style: TextStyle(
                              color: Color(0xFF972F36),
                              fontSize: 21,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(width: gap),
                      TextButton.icon(
                        onPressed: onConnect,
                        icon: Icon(
                          Icons.bluetooth_connected,
                          size: 15,
                          color: connected
                              ? const Color(0xFF28725D)
                              : const Color(0xFF6E655D),
                        ),
                        label: Text(
                          connected
                              ? VrJoystickTranslationConstants.nesLinked
                              : VrJoystickTranslationConstants.nesConnect,
                          style: TextStyle(
                            fontSize: small ? 9 : 11,
                            fontWeight: FontWeight.w800,
                            color: const Color(0xFF3C4245),
                          ),
                        ),
                        style: TextButton.styleFrom(
                          minimumSize: Size.square(target),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                      ),
                      SizedBox(width: gap),
                      SizedBox(
                        width: small ? 94 : 148,
                        height: target,
                        child: button(
                          VrJoystickConstants.nesKeyHome,
                          VrJoystickConstants.nesLabelHome,
                        ),
                      ),
                      SizedBox(width: gap),
                      SizedBox.square(
                        dimension: target,
                        child: IconButton(
                          tooltip: VrJoystickTranslationConstants
                              .tooltipSettingsAndMode,
                          onPressed: onSettings,
                          padding: EdgeInsets.zero,
                          icon: const Icon(
                            Icons.settings_rounded,
                            color: Color(0xFF404548),
                            size: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: gap),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFF24282B),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0xFF8F918A),
                        width: 3,
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(small ? 10 : 16),
                      child: LayoutBuilder(
                        builder: (context, body) {
                          final middleWidth = math.min(
                            math.max(pairWidth, body.maxWidth * .27),
                            body.maxWidth * .44,
                          );
                          return Row(
                            children: [
                              Expanded(
                                flex: 36,
                                child: LayoutBuilder(
                                  builder: (context, pad) => Center(
                                    child: SizedBox.square(
                                      dimension: math.min(
                                        pad.maxWidth,
                                        math.max(target, pad.maxHeight - 16),
                                      ),
                                      child: VrNesDpad(onChanged: onDirection),
                                    ),
                                  ),
                                ),
                              ),
                              SizedBox(width: gap),
                              SizedBox(
                                width: middleWidth,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child:
                                          preview ??
                                          Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              for (var i = 0; i < 3; i++)
                                                Container(
                                                  height: small ? 7 : 10,
                                                  margin:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                        vertical: 2,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFF505557,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                    ),
                                    SizedBox(height: gap),
                                    SizedBox(
                                      height: small ? 62 : 72,
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: button(
                                              VrJoystickConstants.nesKeySelect,
                                              VrJoystickConstants
                                                  .nesLabelSelect,
                                            ),
                                          ),
                                          SizedBox(width: gap),
                                          Expanded(
                                            child: button(
                                              VrJoystickConstants.nesKeyStart,
                                              VrJoystickConstants.nesLabelStart,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    const FittedBox(
                                      child: Text(
                                        VrJoystickTranslationConstants
                                            .nesClassicControl,
                                        style: TextStyle(
                                          color: Color(0xFFADB3B3),
                                          fontSize: 10,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(width: gap),
                              Expanded(
                                flex: 37,
                                child: LayoutBuilder(
                                  builder: (context, actions) {
                                    final actionWidth = math.min(
                                      math.max(
                                        0.0,
                                        (actions.maxWidth - gap) / 2,
                                      ),
                                      math.max(target, actions.maxHeight * .52),
                                    );
                                    Widget action(String id) => SizedBox(
                                      width: actionWidth,
                                      height: math.max(
                                        target,
                                        actionWidth + 30,
                                      ),
                                      child: button(id, id, red: true),
                                    );
                                    return Center(
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          action(
                                            VrJoystickConstants.actionKeyB,
                                          ),
                                          SizedBox(width: gap),
                                          action(
                                            VrJoystickConstants.actionKeyA,
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
