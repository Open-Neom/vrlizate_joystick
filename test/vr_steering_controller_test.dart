import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  Quaternion twist(double radians) =>
      Quaternion.axisAngle(Vector3(0, 0, 1), radians);

  test('clockwise screen twist turns right in both landscape orientations', () {
    for (final landscape in [-math.pi / 2, math.pi / 2]) {
      final controller = VrSteeringController()..setMotionAvailable(true);
      // Include an arbitrary yaw/pitch: calibration is not world-Z yaw.
      final neutral = Quaternion.euler(0.7, 0.4, landscape);
      controller.calibrate(neutral);
      expect(controller.state.steering, 0);
      controller.updateOrientation(neutral * twist(-controller.rangeRadians));
      expect(controller.state.steering, closeTo(1, 1e-6));
      controller.updateOrientation(neutral * twist(controller.rangeRadians));
      expect(controller.state.steering, closeTo(-1, 1e-6));
    }
  });

  test(
    'deadzone, configurable range, clamping and quaternion double cover',
    () {
      final controller = VrSteeringController(
        rangeRadians: 1,
        deadzoneRadians: 0.1,
        responseExponent: 1,
      )..setMotionAvailable(true);
      controller.updateOrientation(twist(-0.09));
      expect(controller.state.steering, 0);
      controller.updateOrientation(twist(-0.55));
      expect(controller.state.steering, closeTo(0.5, 1e-6));
      controller.updateOrientation(twist(-2));
      expect(controller.state.steering, 1);
      final q = twist(-0.55);
      controller.updateOrientation(Quaternion(-q.x, -q.y, -q.z, -q.w));
      expect(controller.state.steering, closeTo(0.5, 1e-6));
    },
  );

  test('default motion response is gentler, symmetric and keeps full lock', () {
    final controller = VrSteeringController()..setMotionAvailable(true);
    expect(controller.rangeRadians, closeTo(55 * math.pi / 180, 1e-9));
    expect(controller.responseExponent, 1.15);
    for (final degrees in [10.0, 20.0, 30.0, 45.0]) {
      final radians = degrees * math.pi / 180;
      final oldMagnitude =
          (radians - math.pi / 90) / (math.pi / 4 - math.pi / 90);
      controller.updateOrientation(twist(-radians));
      final right = controller.state.steering;
      expect(right, greaterThan(0));
      expect(right, lessThan(oldMagnitude));
      controller.updateOrientation(twist(radians));
      expect(controller.state.steering, closeTo(-right, 1e-9));
    }
    controller.updateOrientation(twist(-55 * math.pi / 180));
    expect(controller.state.steering, closeTo(1, 1e-6));
    controller.updateOrientation(twist(55 * math.pi / 180));
    expect(controller.state.steering, closeTo(-1, 1e-6));
    // Touch remains linear and owns the output; no response curve is fed back
    // into the slider's position or applied to throttle/brake.
    controller.setTouchSteering(.4);
    expect(controller.state.steering, .4);
  });

  test('recenter is local and ignores swing about X/Y', () {
    final controller = VrSteeringController()..setMotionAvailable(true);
    for (final axis in [Vector3(1, 0, 0), Vector3(0, 1, 0)]) {
      controller.updateOrientation(Quaternion.axisAngle(axis, 1));
      expect(controller.state.steering, closeTo(0, 1e-6));
      controller.updateOrientation(Quaternion.axisAngle(axis, math.pi));
      expect(controller.state.steering, 0);
    }
    controller.updateOrientation(twist(-0.6));
    expect(controller.state.steering, greaterThan(0.5));
    controller.calibrate(twist(-0.6));
    expect(controller.state.steering, 0);
  });

  test('touch works with no IMU and owns motion while held', () {
    final controller = VrSteeringController();
    controller.updateOrientation(twist(-0.7));
    expect(controller.state.steering, 0);
    controller.setTouchSteering(-0.8);
    expect(controller.state.steering, -0.8);
    controller.setTouchSteering(null);
    expect(controller.state.steering, 0);
    controller.setMotionAvailable(true);
    controller.updateOrientation(twist(-1.2));
    controller.setTouchSteering(-0.8);
    expect(controller.state.steering, -0.8);
    controller.setTouchSteering(null);
    expect(controller.state.steering, greaterThan(0));
    controller.setMotionAvailable(false);
    expect(controller.state.steering, 0);
  });

  test('pedals ramp by elapsed time and braking overrides acceleration', () {
    final controller = VrSteeringController();
    controller.setPedals(throttlePressed: true, brakePressed: false);
    controller.advance(0.1);
    expect(controller.state.throttle, closeTo(0.3, 1e-6));
    controller.advance(0.1);
    expect(controller.state.throttle, closeTo(0.6, 1e-6));
    controller.setPedals(throttlePressed: true, brakePressed: true);
    controller.advance(0.1);
    expect(controller.state.throttle, 0);
    expect(controller.state.brake, closeTo(0.3, 1e-6));
    controller.setPedals(throttlePressed: false, brakePressed: false);
    controller.advance(0.1);
    expect(controller.state.throttle, 0);
    expect(controller.state.brake, 0);
  });

  test(
    'pause/release immediately neutralize and require fresh pedal input',
    () {
      final controller = VrSteeringController()..setMotionAvailable(true);
      controller.updateOrientation(twist(-0.7));
      controller.setPedals(throttlePressed: true, brakePressed: false);
      controller.advance(0.1);
      controller.setPaused(true);
      controller.setTouchSteering(1);
      controller.setPedals(throttlePressed: true, brakePressed: true);
      controller.advance(10);
      expect(controller.state.paused, isTrue);
      expect(controller.state.steering, 0);
      expect(controller.state.throttle, 0);
      expect(controller.state.brake, 0);
      controller.setPaused(false);
      controller.advance(0.1);
      expect(controller.state.paused, isFalse);
      expect(controller.state.throttle, 0);
      expect(controller.state.steering, 0);
      controller.setPedals(throttlePressed: true, brakePressed: false);
      controller.advance(60);
      expect(controller.state.throttle, closeTo(0.3, 1e-6));
      controller.release();
      expect(controller.state.throttle, 0);
    },
  );

  test(
    'rejects invalid configuration and non-finite inputs without poisoning',
    () {
      expect(() => VrSteeringController(rangeRadians: 0), throwsArgumentError);
      expect(
        () => VrSteeringController(deadzoneRadians: 2),
        throwsArgumentError,
      );
      expect(
        () => VrSteeringController(pedalRisePerSecond: double.nan),
        throwsArgumentError,
      );
      expect(
        () => VrSteeringController(responseExponent: double.nan),
        throwsArgumentError,
      );
      expect(
        () => VrSteeringController(responseExponent: .5),
        throwsArgumentError,
      );
      final controller = VrSteeringController();
      controller.setTouchSteering(0.4);
      expect(
        () => controller.setTouchSteering(double.infinity),
        throwsArgumentError,
      );
      expect(
        () => controller.updateOrientation(Quaternion(0, 0, 0, 0)),
        throwsArgumentError,
      );
      expect(
        () => controller.calibrate(Quaternion(double.nan, 0, 0, 1)),
        throwsArgumentError,
      );
      expect(() => controller.advance(double.nan), throwsArgumentError);
      expect(() => controller.advance(-1), throwsArgumentError);
      expect(controller.state.steering, 0.4);
    },
  );
}
