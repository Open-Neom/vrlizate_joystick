import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  void hold(
    VrPhonePointerPosture gate,
    double x,
    double y,
    double z, {
    int start = 0,
    int end = 200000,
  }) {
    for (var t = start; t <= end; t += 20000) {
      gate.updateGravity(x, y, z, t);
    }
  }

  for (final sign in [-1.0, 1.0]) {
    test('upright landscape $sign opens only after a continuous hold', () {
      final gate = VrPhonePointerPosture();
      hold(gate, sign * 9.81, .1, .1, end: 180000);
      expect(gate.isReadyAt(180000), isFalse);
      gate.updateGravity(sign * 9.81, .1, .1, 200000);
      expect(gate.isReadyAt(200000), isTrue);
    });
  }

  for (final gravity in [
    [0.0, 0.0, 9.81],
    [0.0, 0.0, -9.81],
    [0.0, 9.81, 0.0],
    [0.0, -9.81, 0.0],
    [4.0, 7.6, 4.8],
    [1.5, .1, 9.4],
  ]) {
    test('flat, portrait or lateral pose $gravity never opens', () {
      final gate = VrPhonePointerPosture();
      hold(gate, gravity[0], gravity[1], gravity[2], end: 1000000);
      expect(gate.isReadyAt(1000000), isFalse);
    });
  }

  test(
    'exit is immediate; reentry needs a new hold; hysteresis avoids flicker',
    () {
      final gate = VrPhonePointerPosture();
      hold(gate, 9.81, .1, .1);
      gate.updateGravity(8.8, .2, 4.5, 220000);
      expect(gate.isReadyAt(220000), isTrue);
      gate.updateGravity(.1, .1, 9.81, 240000);
      expect(gate.isReadyAt(240000), isFalse);
      gate.updateGravity(9.81, .1, .1, 260000);
      expect(gate.isReadyAt(260000), isFalse);
      hold(gate, 9.81, .1, .1, start: 280000, end: 460000);
      expect(gate.isReadyAt(460000), isTrue);
    },
  );

  test(
    'stale data, gaps, bad clocks and invalid accelerations fail closed',
    () {
      final gate = VrPhonePointerPosture();
      hold(gate, 9.81, 0, 0);
      expect(gate.isReadyAt(349999), isTrue);
      expect(gate.isReadyAt(350000), isFalse);
      gate.updateGravity(9.81, 0, 0, 360000);
      expect(gate.isReadyAt(360000), isFalse);
      hold(gate, 9.81, 0, 0, start: 380000, end: 560000);
      expect(gate.isReadyAt(560000), isTrue);
      gate.updateGravity(9.81, 0, 0, 550000);
      expect(gate.isReadyAt(560000), isFalse);
      for (final x in [double.nan, double.infinity, 0.0, 30.0]) {
        gate.updateGravity(x, 0, 0, 600000);
        expect(gate.isReadyAt(600000), isFalse);
      }
    },
  );

  test(
    'invalid duplicate samples revoke readiness instead of preserving it',
    () {
      final gate = VrPhonePointerPosture();
      hold(gate, 9.81, 0, 0);
      gate.updateGravity(double.nan, 0, 0, 200000);
      expect(gate.isReadyAt(200000), isFalse);
    },
  );

  test('explicit reset clears a previous physical posture', () {
    final gate = VrPhonePointerPosture();
    hold(gate, 9.81, 0, 0);
    gate.reset();
    expect(gate.isReadyAt(200000), isFalse);
  });

  test('gyro projects on real up/right axes in either landscape', () {
    for (final sign in [-1.0, 1.0]) {
      final gate = VrPhonePointerPosture();
      hold(gate, sign * 9.81, 0, 0);
      expect(gate.yawRate(-sign * .5, 0, 0), closeTo(.5, 1e-9));
      expect(gate.pitchRate(0, -sign * .5), closeTo(.5, 1e-9));
      expect(gate.yawRate(0, 0, .5), 0);
      expect(gate.pitchRate(0, 0), 0);
    }
  });

  test(
    'pointer intent, motion or retained aim never substitutes for posture',
    () {
      RemoteControllerState state({
        bool pose = false,
        bool visible = true,
        bool neutral = false,
      }) => RemoteControllerState(
        orientation: vm.Quaternion.euler(.3, .2, .1),
        angularVelocity: vm.Vector3(1, 2, 3),
        mode: RemoteControllerMode.laser,
        laserX: .8,
        laserSlideActive: true,
        pointerPoseReady: pose,
        controllerVisible: visible,
        isNeutralized: neutral,
      );
      expect(VrPhonePointerPolicy.isPointing(state()), isFalse);
      expect(VrPhonePointerPolicy.isPointing(state(pose: true)), isTrue);
      expect(
        VrPhonePointerPolicy.isPointing(state(pose: true, visible: false)),
        isFalse,
      );
      expect(
        VrPhonePointerPolicy.isPointing(state(pose: true, neutral: true)),
        isFalse,
      );
      expect(
        VrPhonePointerPolicy.isPointing(
          RemoteControllerState(
            orientation: vm.Quaternion.identity(),
            pointerPoseReady: true,
            stickX: 1,
            turnRate: 1,
          ),
        ),
        isFalse,
        reason: 'Walking or looking is not pointer intent',
      );
    },
  );
}
