import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  group('VrGamepadLayoutPreset', () {
    test('defines all 4 layout presets with expected properties', () {
      expect(VrGamepadLayoutPreset.values, hasLength(4));
      expect(VrGamepadLayoutPreset.dualStickVr.supportsAnalogStick, isTrue);
      expect(VrGamepadLayoutPreset.dualStickVr.supportsGyroSteering, isFalse);
      expect(VrGamepadLayoutPreset.dualStickVr.supportsLaserAiming, isTrue);
      expect(
        VrGamepadLayoutPreset.retroArcade8Way.recommendedMode,
        RemoteControllerMode.nes,
      );
      expect(VrGamepadLayoutPreset.steeringWheel.supportsGyroSteering, isTrue);
      expect(VrGamepadLayoutPreset.mediaRemote.supportsAnalogStick, isFalse);
      expect(
        VrGamepadLayoutPreset.fromWireName('steeringWheel'),
        VrGamepadLayoutPreset.steeringWheel,
      );
    });
  });

  group('VrHapticPatternPreset', () {
    test(
      'defines all 5 haptic presets with positive pulse counts and durations',
      () {
        expect(VrHapticPatternPreset.values, hasLength(5));
        for (final preset in VrHapticPatternPreset.values) {
          expect(preset.pulseDurationsMs, isNotEmpty);
          expect(preset.totalDuration.inMilliseconds, greaterThan(0));
        }
        expect(VrHapticPatternPreset.portalEnter.pulseDurationsMs, hasLength(2));
        expect(
          VrHapticPatternPreset.holdExitWarning.pulseDurationsMs,
          hasLength(3),
        );
        expect(
          VrHapticPatternPreset.fromWireName('portalEnter'),
          VrHapticPatternPreset.portalEnter,
        );
      },
    );
  });

  group('VrButtonMapping', () {
    test('default mapping resolves identity and 800ms hold duration', () {
      const mapping = VrButtonMapping.standard();
      expect(
        mapping.holdCenterForHomeDuration,
        const Duration(milliseconds: 800),
      );
      expect(
        mapping.resolveButton(VrJoystickConstants.actionKeyA),
        VrJoystickConstants.actionKeyA,
      );
      expect(
        mapping.resolveButton(VrJoystickConstants.actionKeyB),
        VrJoystickConstants.actionKeyB,
      );
    });

    test('copyWith, swapConfirmCancel, and JSON round-trip work', () {
      const mapping = VrButtonMapping();
      final swapped = mapping.copyWith(
        buttonOverrides: {
          VrJoystickConstants.actionKeyX: VrJoystickConstants.actionKeyY,
        },
        swapConfirmCancel: true,
        holdCenterForHomeDuration: const Duration(seconds: 2),
      );
      expect(
        swapped.resolveButton(VrJoystickConstants.actionKeyA),
        VrJoystickConstants.actionKeyB,
      );
      expect(
        swapped.resolveButton(VrJoystickConstants.actionKeyB),
        VrJoystickConstants.actionKeyA,
      );
      expect(
        swapped.resolveButton(VrJoystickConstants.actionKeyX),
        VrJoystickConstants.actionKeyY,
      );
      expect(swapped.holdCenterForHomeDuration, const Duration(seconds: 2));
      expect(swapped, isNot(equals(mapping)));
      final roundTrip = VrButtonMapping.fromJson(swapped.toJson());
      expect(roundTrip, equals(swapped));
      expect(roundTrip.hashCode, equals(swapped.hashCode));
    });
  });

  group('VrJoystickConstants & VrJoystickTranslationConstants', () {
    test('exposes centralized constants and translations', () {
      expect(VrJoystickConstants.defaultServerPort, 8080);
      expect(VrJoystickConstants.udpDiscoveryPort, 8081);
      expect(
        VrJoystickConstants.webControllerHtml,
        contains('<!DOCTYPE html>'),
      );
      expect(VrJoystickTranslationConstants.settingsTitle, isNotEmpty);
      expect(VrJoystickTranslationConstants.qrConnectAnotherPhone, isNotEmpty);
    });
  });
}
