import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _GravitySamples {
  _GravitySamples(this.controller);
  final VrSteeringController controller;
  int nowUs = 0;

  double hold(double elevation, {double flip = 1, double wheel = 0}) {
    final angle = elevation * math.pi / 180;
    for (var i = 0; i < 80; i++) {
      nowUs += 20000;
      controller.updateGravity(
        flip * 9.81 * math.cos(angle) * math.cos(wheel),
        9.81 * math.cos(angle) * math.sin(wheel),
        9.81 * math.sin(angle),
        nowUs,
      );
    }
    return controller.drivingTiltAt(nowUs);
  }
}

void main() {
  Quaternion twist(double radians) =>
      Quaternion.axisAngle(Vector3(0, 0, 1), radians);

  test(
    'physical tilt is calibrated, deliberate and equal in landscape flips',
    () {
      for (final flip in [-1.0, 1.0]) {
        final controller = VrSteeringController()..setMotionAvailable(true);
        final samples = _GravitySamples(controller);
        expect(samples.hold(15, flip: flip), 0);
        expect(
          samples.hold(24, flip: flip),
          0,
        ); // Below the 10 degree deadzone.
        expect(samples.hold(36, flip: flip), closeTo(math.pow(.5, 1.35), .001));
        expect(samples.hold(47, flip: flip), closeTo(1, .001));
        expect(samples.hold(-17, flip: flip), closeTo(-1, .001));
      }
    },
  );

  test('turning the wheel cannot become a physical accelerator', () {
    final controller = VrSteeringController()..setMotionAvailable(true);
    final samples = _GravitySamples(controller);
    samples.hold(25);
    for (final wheel in [-.95, -.5, .5, .95]) {
      expect(samples.hold(25, wheel: wheel), 0);
    }
    controller.calibrate(Quaternion.identity());
    expect(samples.hold(55), 0);
    expect(samples.hold(23), closeTo(-1, .001));
  });

  test(
    'impact rejects tilt until fresh samples settle, not just elapsed time',
    () {
      final controller = VrSteeringController()..setMotionAvailable(true);
      final samples = _GravitySamples(controller);
      samples.hold(0);
      expect(samples.hold(35), 1);
      controller.updateGravity(24, 0, 0, ++samples.nowUs);
      expect(controller.drivingTiltAt(samples.nowUs), 0);
      controller.updateGravity(8, 0, 5.5, ++samples.nowUs);
      expect(controller.drivingTiltAt(samples.nowUs + 250000), 0);
      expect(samples.hold(35), 1);
    },
  );

  test('no sensor, stale samples and recovery never replay tilt', () {
    final controller = VrSteeringController();
    final samples = _GravitySamples(controller);
    expect(samples.hold(0), 0);
    expect(samples.hold(35), 0);
    controller.setMotionAvailable(true);
    expect(samples.hold(15), 0);
    expect(samples.hold(50), 1);
    samples.nowUs += 400001;
    expect(controller.drivingTiltAt(samples.nowUs), 0);
    expect(samples.hold(50), 0); // Recovered posture becomes neutral.
    expect(samples.hold(15), -1);
    controller.setMotionAvailable(false);
    expect(controller.drivingTiltAt(samples.nowUs), 0);
  });

  test('pause, release and sensor errors require fresh neutral posture', () {
    final controller = VrSteeringController()..setMotionAvailable(true);
    final samples = _GravitySamples(controller);
    samples.hold(0);
    expect(samples.hold(35), 1);
    controller.setPaused(true);
    expect(samples.hold(-20), 0);
    controller.setPaused(false);
    expect(samples.hold(-20), 0);
    expect(samples.hold(15), 1);
    controller.release();
    expect(controller.drivingTiltAt(samples.nowUs), 0);
    expect(samples.hold(15), 0);
    expect(samples.hold(-20), -1);
    controller.clearGravity();
    expect(controller.drivingTiltAt(samples.nowUs), 0);
    expect(samples.hold(-20), 0);
    for (final x in [0.0, double.nan, double.infinity]) {
      controller.updateGravity(x, 0, 0, ++samples.nowUs);
      expect(controller.drivingTiltAt(samples.nowUs), 0);
    }
  });

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
