import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/src/vr_controller_shake_detector.dart';

void main() {
  for (final axis in [0, 1, 2]) {
    for (final sign in [-1.0, 1.0]) {
      test('deliberate shake on axis $axis sign $sign toggles once', () {
        final detector = VrControllerShakeDetector();
        expect(detector.addSample(0, 0, 9.80665, 0), isFalse);
        final sample = [0.0, 0.0, 9.80665];
        sample[axis] += 30 * sign;
        expect(
          detector.addSample(sample[0], sample[1], sample[2], 20000),
          isFalse,
        );
        expect(
          detector.addSample(sample[0], sample[1], sample[2], 40000),
          isTrue,
        );
        expect(
          detector.addSample(sample[0], sample[1], sample[2], 60000),
          isFalse,
        );
        expect(
          detector.addSample(sample[0], sample[1], sample[2], 80000),
          isFalse,
        );
      });
    }
  }

  test('normal steering tilts and gravity alone never toggle', () {
    final detector = VrControllerShakeDetector();
    for (var i = 0; i < 600; i++) {
      final angle = i * .2;
      expect(
        detector.addSample(
          9.80665 * math.sin(angle),
          9.80665 * math.cos(angle),
          0,
          i * 20000,
        ),
        isFalse,
      );
    }
  });

  test(
    'requires quiet rearm AND cooldown; continuous shaking is one toggle',
    () {
      final detector = VrControllerShakeDetector();
      detector.addSample(0, 0, 9.80665, 0);
      expect(detector.addSample(30, 0, 9.80665, 20000), isFalse);
      expect(detector.addSample(30, 0, 9.80665, 40000), isTrue);
      for (var time = 60000; time <= 1600000; time += 20000) {
        expect(detector.addSample(30, 0, 9.80665, time), isFalse);
      }
      for (var time = 1620000; time <= 1900000; time += 20000) {
        expect(detector.addSample(0, 0, 9.80665, time), isFalse);
      }
      expect(detector.addSample(-30, 0, 9.80665, 1920000), isFalse);
      expect(detector.addSample(-30, 0, 9.80665, 1940000), isTrue);
      for (var time = 1960000; time <= 2240000; time += 20000) {
        detector.addSample(0, 0, 9.80665, time);
      }
      expect(detector.addSample(30, 0, 9.80665, 2260000), isFalse);
      expect(detector.addSample(30, 0, 9.80665, 2280000), isFalse);
    },
  );

  test('rejects invalid, duplicate-time, isolated and startup spikes', () {
    final detector = VrControllerShakeDetector();
    expect(detector.addSample(30, 0, 9.80665, 0), isFalse);
    expect(detector.addSample(30, 0, 9.80665, 20000), isFalse);
    expect(detector.addSample(0, 0, 9.80665, 40000), isFalse);
    expect(detector.addSample(double.nan, 0, 0, 60000), isFalse);
    expect(detector.addSample(double.infinity, 0, 0, 60000), isFalse);
    expect(detector.addSample(300, 0, 0, 60000), isFalse);
    expect(detector.addSample(30, 0, 9.80665, 60000), isFalse);
    expect(detector.addSample(30, 0, 9.80665, 60000), isFalse);
    expect(detector.addSample(0, 0, 9.80665, 80000), isFalse);
    expect(detector.addSample(30, 0, 9.80665, 100000), isFalse);
    detector.reset();
    expect(detector.addSample(30, 0, 9.80665, 120000), isFalse);
  });
}
