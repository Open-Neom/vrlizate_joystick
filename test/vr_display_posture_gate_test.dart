import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  group('VrDisplayPostureGate & VrPhonePointerPolicy', () {
    test('standard phone (< 600 dp) locks sensorLandscape and requires gravity gate', () {
      const snapshot = VrDisplayPostureSnapshot(
        maxWidthPx: 2400,
        maxHeightPx: 1080,
        density: 2.75, // swDp = 392.7 dp
      );
      final decision = VrDisplayPostureGate.evaluate(snapshot);
      expect(decision.formFactor, VrDisplayFormFactor.phone);
      expect(decision.shouldLockSensorLandscape, isTrue);
      expect(decision.requiresGravityPointerPosture, isTrue);
    });

    test(
      'unfolded near-square foldable (swDp >= 600, aspect < 1.25) unlocks orientation '
      'to prevent Android 14-16 letterboxing while preserving handheld gravity gate',
      () {
        const foldableInner = VrDisplayPostureSnapshot(
          maxWidthPx: 2208,
          maxHeightPx: 1840,
          density: 2.625, // swDp = 700.95 dp, aspect = 1.20
        );
        final decision = VrDisplayPostureGate.evaluate(foldableInner);
        expect(
          decision.formFactor,
          VrDisplayFormFactor.unfoldedNearSquareFoldable,
        );
        expect(decision.shouldLockSensorLandscape, isFalse);
        expect(decision.requiresGravityPointerPosture, isTrue);
      },
    );

    test('widescreen tablet (swDp >= 600, aspect >= 1.25) keeps sensorLandscape lock', () {
      const tablet = VrDisplayPostureSnapshot(
        maxWidthPx: 2560,
        maxHeightPx: 1600,
        density: 2.0, // swDp = 800 dp, aspect = 1.60
      );
      final decision = VrDisplayPostureGate.evaluate(tablet);
      expect(decision.formFactor, VrDisplayFormFactor.landscapeTablet);
      expect(decision.shouldLockSensorLandscape, isTrue);
      expect(decision.requiresGravityPointerPosture, isTrue);
    });

    test(
      'wireless Miracast / screen-casting NEVER unlocks phone orientation or bypasses gravity gate',
      () {
        const phoneWhileCasting = VrDisplayPostureSnapshot(
          maxWidthPx: 2400,
          maxHeightPx: 1080,
          density: 2.75,
          isDefaultDisplay: true,
          isExternalDesktopDisplay: true, // Even if an external Presentation exists!
          isCastingActive: true,
        );
        final decision = VrDisplayPostureGate.evaluate(phoneWhileCasting);
        expect(decision.formFactor, VrDisplayFormFactor.phone);
        expect(decision.shouldLockSensorLandscape, isTrue);
        expect(decision.requiresGravityPointerPosture, isTrue);

        final flatPhoneState = RemoteControllerState(
          orientation: vm.Quaternion.identity(),
          pointerPoseReady: false,
          laserSlideActive: true,
          laserX: 0.25,
        );
        expect(
          VrPhonePointerPolicy.isPointing(
            flatPhoneState,
            displayDecision: decision,
          ),
          isFalse,
        );
      },
    );

    test(
      'true external desktop / Samsung DeX monitor unlocks orientation and allows stationary pointing',
      () {
        const dexExternalMonitor = VrDisplayPostureSnapshot(
          maxWidthPx: 2560,
          maxHeightPx: 1440,
          density: 1.5,
          isDefaultDisplay: false,
          isExternalDesktopDisplay: true,
          isCastingActive: false,
        );
        final decision = VrDisplayPostureGate.evaluate(dexExternalMonitor);
        expect(decision.formFactor, VrDisplayFormFactor.externalDesktopMonitor);
        expect(decision.shouldLockSensorLandscape, isFalse);
        expect(decision.requiresGravityPointerPosture, isFalse);

        final stationaryMouseState = RemoteControllerState(
          orientation: vm.Quaternion.identity(),
          pointerPoseReady: false,
          laserSlideActive: true,
          laserX: 0.30,
        );
        expect(
          VrPhonePointerPolicy.isPointing(
            stationaryMouseState,
            displayDecision: decision,
          ),
          isTrue,
        );
      },
    );
  });
}
