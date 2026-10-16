import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:vrlizate_joystick/src/vr_motion_look_controller.dart';

const _g = 9.80665;
const _zero = (x: 0.0, y: 0.0);

double _radians(double degrees) => degrees * math.pi / 180;

class _Trace {
  _Trace({this.flip = 1, double elevation = 0, this.physicalGravity = false}) {
    gx = flip * _g * math.cos(_radians(elevation));
    gz = _g * math.sin(_radians(elevation));
    _initialGravity = vm.Vector3(gx, gy, gz);
    controller.updateGravity(gx, gy, gz, now);
    controller.setActive(true, now);
    quiet(2);
  }
  final double flip;
  final bool physicalGravity;
  late final vm.Vector3 _initialGravity;
  vm.Quaternion _physical = vm.Quaternion.identity();
  final controller = VrMotionLookController();
  double gx = 0, gy = 0, gz = 0;
  int now = 0;

  ({double x, double y}) get value => controller.sample(now);

  void tick(
    double x,
    double y,
    double z, {
    int dt = 10000,
    bool gravity = true,
  }) {
    now += dt;
    if (physicalGravity) {
      final omega = vm.Vector3(x, y, z);
      final speed = omega.length;
      if (speed > 0 && speed.isFinite) {
        _physical =
            (_physical *
                    vm.Quaternion.axisAngle(omega / speed, speed * dt / 1e6))
                .normalized();
      }
      // Independent physical oracle: support/up in the rotating device frame
      // is inverse(body-to-initial orientation) applied to initial support.
      final support = _physical.conjugated().rotated(_initialGravity);
      gx = support.x;
      gy = support.y;
      gz = support.z;
    }
    if (gravity) controller.updateGravity(gx, gy, gz, now);
    controller.updateGyroscope(x, y, z, now);
  }

  void quiet(int count) {
    for (var i = 0; i < count; i++) {
      tick(0, 0, 0);
    }
  }

  void rotate(
    double x,
    double y,
    double z,
    double degrees, {
    int steps = 100,
    int dt = 10000,
  }) {
    final speed = _radians(degrees) / (steps * dt / 1e6);
    for (var i = 0; i < steps; i++) {
      tick(x * speed, y * speed, z * speed, dt: dt);
    }
    quiet(4); // Flush the median's two trailing samples before measuring pose.
  }

  void repress() {
    controller.setActive(false, now);
    controller.setActive(true, now);
    quiet(2);
  }
}

void main() {
  for (final flip in [-1.0, 1.0]) {
    for (final direction in ['right', 'left', 'up', 'down']) {
      test(
        '$direction tilt persists with quiet gyro for >2s in landscape $flip',
        () {
          final trace = _Trace(flip: flip, physicalGravity: true);
          final horizontal = direction == 'right' || direction == 'left';
          final sign = direction == 'right' || direction == 'up' ? 1.0 : -1.0;
          trace.rotate(
            horizontal ? -flip * sign : 0,
            horizontal ? 0 : -flip * sign,
            0,
            15,
          );
          final deflected = trace.value;
          expect(
            (horizontal ? deflected.x : deflected.y) * sign,
            greaterThan(.2),
          );
          expect(horizontal ? deflected.y : deflected.x, 0);
          trace.quiet(250);
          expect(trace.value.x, closeTo(deflected.x, 1e-12));
          expect(trace.value.y, closeTo(deflected.y, 1e-12));
          trace.controller.setActive(false, trace.now);
          expect(trace.value, _zero);
        },
      );
    }
  }

  test('gyro rate alone cannot sustain look once the gesture is released', () {
    final trace = _Trace()..rotate(-1, 0, 0, 20);
    expect(trace.value.x, greaterThan(0));
    trace.controller.setActive(false, trace.now);
    trace.rotate(-1, 0, 0, 20);
    expect(trace.value, _zero);
    trace.controller.setActive(true, trace.now);
    expect(trace.value, _zero);
    trace.controller.updateGyroscope(-1, 0, 0, trace.now);
    expect(trace.value, _zero);
    trace.quiet(250);
    expect(trace.value, _zero);
    trace.rotate(-1, 0, 0, 15);
    expect(trace.value.x, greaterThan(.2));
  });

  test(
    'large deflection retains its true pose past the 25 degree output limit',
    () {
      final trace = _Trace()..rotate(-1, 0, 0, 70);
      expect(trace.value.x, closeTo(.6, 1e-10));
      trace.rotate(1, 0, 0, 35);
      // Actual angle is still 35°; clamping stored tilt to 25° would turn left.
      expect(trace.value.x, closeTo(.6, 1e-10));
      trace.rotate(1, 0, 0, 20);
      expect(trace.value.x, greaterThan(.2));
      expect(trace.value.x, lessThan(.4));
      trace.rotate(1, 0, 0, 15);
      expect(trace.value, _zero);
    },
  );

  test(
    'slow return below .025rad/s still undoes the complete stored angle',
    () {
      final trace = _Trace()..rotate(-1, 0, 0, 12);
      expect(trace.value.x, greaterThan(.1));
      // 12° / 12s = .01745 rad/s; a velocity deadzone would stick off-centre.
      trace.rotate(1, 0, 0, 12, steps: 1200);
      expect(trace.value, _zero);
      expect(trace.controller.active, isTrue);
    },
  );

  test(
    'composed body rotations return through their inverse without scalar Euler drift',
    () {
      final trace = _Trace(physicalGravity: true);
      trace.rotate(-1, 0, 0, 35);
      trace.rotate(0, -1, 0, 30);
      expect(trace.value.x, greaterThan(0));
      expect(trace.value.y, greaterThan(0));
      trace.rotate(0, 1, 0, 30);
      trace.rotate(1, 0, 0, 35);
      expect(trace.value, _zero);
    },
  );

  test('diagonal angular command is vector capped to .60', () {
    final trace = _Trace(physicalGravity: true);
    trace.rotate(-1 / math.sqrt2, -1 / math.sqrt2, 0, 60);
    final value = trace.value;
    expect(value.x, greaterThan(0));
    expect(value.y, greaterThan(0));
    expect(
      math.sqrt(value.x * value.x + value.y * value.y),
      closeTo(.60, 1e-10),
    );
  });

  test('response starts continuously at 3 degrees with exponent 1.25', () {
    final trace = _Trace()..rotate(-1, 0, 0, 2.99);
    expect(trace.value, _zero);
    trace.rotate(-1, 0, 0, .02);
    expect(trace.value.x, greaterThan(0));
    expect(trace.value.x, lessThan(.001));
    final half = _Trace()..rotate(-1, 0, 0, 14);
    expect(half.value.x, closeTo(.6 * math.pow(.5, 1.25), 1e-8));
  });

  test('physical gravity yaw and pitch agree for both inclined landscapes', () {
    for (final flip in [-1.0, 1.0]) {
      final yaw = _Trace(flip: flip, elevation: 45, physicalGravity: true);
      yaw.rotate(-flip / math.sqrt2, 0, -1 / math.sqrt2, 15);
      expect(yaw.value.x, greaterThan(.2));
      expect(yaw.value.y, 0);
      final pitch = _Trace(flip: flip, elevation: 45, physicalGravity: true);
      pitch.rotate(0, -flip, 0, 15);
      expect(pitch.value.y, greaterThan(.2));
      expect(pitch.value.x, 0);
    }
  });

  test(
    'screen roll projects onto physical yaw only when gravity is inclined',
    () {
      final upright = _Trace(physicalGravity: true)..rotate(0, 0, 1, 20);
      expect(upright.value, _zero);
      final inclined = _Trace(elevation: 45, physicalGravity: true)
        ..rotate(0, 0, -1, 20);
      expect(inclined.value.x, greaterThan(.2));
      expect(inclined.value.y, 0);
    },
  );

  test('crossing a flat phone posture does not flip yaw or collapse pitch', () {
    for (final flip in [-1.0, 1.0]) {
      final trace = _Trace(flip: flip, elevation: 75);
      // Device-frame gravity moves smoothly through +Z as pitch goes from
      // the starting 75° inclination to 105°. The gesture axes remain frozen.
      const steps = 150;
      for (var i = 1; i <= steps; i++) {
        final angle = _radians(75 + 30 * i / steps);
        trace.gx = flip * _g * math.cos(angle);
        trace.gz = _g * math.sin(angle);
        trace.tick(0, flip * _radians(30) / (steps * .01), 0);
        expect(trace.value.x.abs(), lessThan(.00001));
      }
      trace.quiet(10);
      expect(trace.value.y, closeTo(-.6, 1e-8));
      trace.quiet(220);
      expect(trace.value.y, closeTo(-.6, 1e-8));
    }
  });

  test(
    'an isolated gyro impulse is suppressed rather than changing neutral',
    () {
      final trace = _Trace();
      trace.tick(-5, 0, 0);
      trace.quiet(30);
      expect(trace.value, _zero);
      trace.rotate(-1, 0, 0, 15);
      final pose = trace.value;
      trace.tick(-5, 0, 0);
      trace.quiet(30);
      expect(trace.value.x, closeTo(pose.x, 1e-12));
    },
  );

  test(
    'first pending gesture tolerates sample-before-sensors but expires after150ms',
    () {
      final controller = VrMotionLookController()..setActive(true, 0);
      expect(controller.sample(0), _zero);
      expect(controller.active, isTrue);
      controller.updateGyroscope(-1, 0, 0, 10000);
      expect(controller.sample(10000), _zero);
      expect(controller.active, isTrue);
      controller.updateGravity(_g, 0, 0, 20000);
      controller.updateGyroscope(0, 0, 0, 20000);
      expect(controller.active, isTrue);
      for (var t = 30000; t <= 300000; t += 10000) {
        controller.updateGravity(_g, 0, 0, t);
        controller.updateGyroscope(-1, 0, 0, t);
      }
      expect(controller.sample(300000).x, greaterThan(.2));
      controller.reset();
      controller.setActive(true, 400000);
      expect(controller.sample(549999), _zero);
      expect(controller.active, isTrue);
      expect(controller.sample(550000), _zero);
      expect(controller.active, isFalse);
    },
  );

  test('initial flat orientation needs an observed screen-right basis', () {
    final controller = VrMotionLookController();
    controller.updateGravity(0, 0, _g, 0);
    controller.setActive(true, 0);
    for (var t = 10000; t <= 150000; t += 10000) {
      controller.updateGravity(0, 0, _g, t);
      controller.updateGyroscope(1, 1, 1, t);
      expect(controller.sample(t), _zero);
    }
    expect(controller.active, isFalse);
  });

  test(
    'stale gyro disarms and fresh data alone cannot restore old deflection',
    () {
      final trace = _Trace()..rotate(-1, 0, 0, 15);
      trace.now += VrMotionLookController.staleAfterUs;
      trace.controller.updateGravity(trace.gx, trace.gy, trace.gz, trace.now);
      expect(trace.value, _zero);
      expect(trace.controller.active, isFalse);
      trace.rotate(-1, 0, 0, 15);
      expect(trace.value, _zero);
      trace.repress();
      expect(trace.value, _zero);
      trace.rotate(-1, 0, 0, 15);
      expect(trace.value.x, greaterThan(.2));
    },
  );

  test(
    'gyro gap cannot integrate across stale time even without sample calls',
    () {
      final trace = _Trace()..rotate(-1, 0, 0, 15);
      for (var i = 0; i < 15; i++) {
        trace.now += 10000;
        trace.controller.updateGravity(trace.gx, trace.gy, trace.gz, trace.now);
      }
      trace.controller.updateGyroscope(-1, 0, 0, trace.now);
      expect(trace.controller.active, isFalse);
      expect(trace.value, _zero);
    },
  );

  test(
    'stale gravity disarms despite ongoing gyro and requires a fresh press',
    () {
      final trace = _Trace()..rotate(-1, 0, 0, 15);
      for (var i = 0; i < 16; i++) {
        trace.tick(0, 0, 0, gravity: false);
      }
      expect(trace.value, _zero);
      expect(trace.controller.active, isFalse);
      trace.quiet(3);
      expect(trace.value, _zero);
      trace.repress();
      trace.rotate(-1, 0, 0, 15);
      expect(trace.value.x, greaterThan(.2));
    },
  );

  for (final invalid in [double.nan, double.infinity, -double.infinity, 9.0]) {
    test('invalid gyro $invalid cancels gesture until a new press', () {
      final trace = _Trace()..rotate(-1, 0, 0, 15);
      trace.tick(invalid, 0, 0);
      expect(trace.value, _zero);
      expect(trace.controller.active, isFalse);
      trace.rotate(-1, 0, 0, 15);
      expect(trace.value, _zero);
      trace.repress();
      trace.rotate(-1, 0, 0, 15);
      expect(trace.value.x, greaterThan(.2));
    });
  }

  test(
    'gravity magnitude/direction impulses invalidate without changing the old base',
    () {
      for (final gravity in [
        (30.0, 0.0, 0.0),
        (0.0, _g, 0.0),
        (double.nan, 0.0, 0.0),
        (0.0, 0.0, 0.0),
      ]) {
        final trace = _Trace()..rotate(0, -1, 0, 15);
        trace.now += 10000;
        trace.controller.updateGravity(
          gravity.$1,
          gravity.$2,
          gravity.$3,
          trace.now,
        );
        expect(trace.value, _zero);
        expect(trace.controller.active, isFalse);
        trace.quiet(3);
        trace.repress();
        trace.rotate(0, -1, 0, 15);
        expect(trace.value.y, greaterThan(.2));
        expect(trace.value.x, 0);
      }
    },
  );

  test(
    '170 degree guard disarms before quaternion logarithm can change branch',
    () {
      final trace = _Trace()..rotate(-1, 0, 0, 175, steps: 200);
      expect(trace.controller.active, isFalse);
      expect(trace.value, _zero);
      trace.quiet(250);
      expect(trace.value, _zero);
      trace.repress();
      trace.rotate(-1, 0, 0, 15);
      expect(trace.value.x, greaterThan(.2));
    },
  );

  test(
    'one valid step crossing 170 and 180 degrees disarms without aliasing',
    () {
      final trace = _Trace(physicalGravity: true);
      for (var i = 0; i < 41; i++) {
        trace.tick(-7, 0, 0);
      }
      // Trapezoid + median warmup gives 158.4° here. One fresh 100ms sample
      // reaches 198.5°: abs(quaternion.w) would incorrectly report only 161.5°.
      expect(trace.controller.active, isTrue);
      expect(trace.value.x, closeTo(.6, 1e-10));
      trace.tick(-7, 0, 0, dt: 100000);
      expect(trace.controller.active, isFalse);
      expect(trace.value, _zero);
      trace.quiet(30);
      expect(trace.value, _zero);
      trace.repress();
      trace.rotate(-1, 0, 0, 15);
      expect(trace.value.x, greaterThan(.2));
    },
  );

  test('elapsed-time integration agrees across10ms and20ms sampling', () {
    final fast = _Trace()..rotate(-1, 0, 0, 15, steps: 100, dt: 10000);
    final slow = _Trace()..rotate(-1, 0, 0, 15, steps: 50, dt: 20000);
    // Flush intervals use10ms, so this allows <0.2° timing-boundary error.
    expect(fast.value.x, closeTo(slow.value.x, .01));
  });

  test('sensor timestamps preserve pose with jitter and same-time batches', () {
    ({double x, double y}) run(int reverseEnd, int Function(int) arrival) {
      final controller = VrMotionLookController();
      controller.updateGravity(_g, 0, 0, 0);
      controller.setActive(true, 0);
      for (var i = 1; i <= 160; i++) {
        final now = arrival(i);
        controller.updateGravity(_g, 0, 0, now);
        controller.updateGyroscope(
          i <= 40 ? -.75 : (i <= reverseEnd ? .75 : 0),
          0,
          0,
          now,
          sensorTimeUs: 1700000000000000 + i * 10000,
        );
        expect(controller.active, isTrue);
      }
      return controller.sample(arrival(160));
    }

    for (final reverseEnd in [60, 80]) {
      final regular = run(reverseEnd, (i) => i * 10000);
      final jitter = run(
        reverseEnd,
        (i) => i >= 36 && i <= 47 ? 470000 + (i - 36) * 100 : i * 10000,
      );
      final batch = run(
        reverseEnd,
        (i) => i >= 36 && i <= 47 ? 470000 : i * 10000,
      );
      expect(jitter, regular);
      expect(batch, regular);
      if (reverseEnd == 80) {
        expect(regular, _zero);
      } else {
        expect(regular.x, greaterThan(.1));
      }
    }
  });

  test(
    'invalid sensor deltas disarm and cannot preserve or revive old pose',
    () {
      for (final sourceDelta in [-1, 0, 150000, 500000]) {
        final trace = _Trace()..rotate(-1, 0, 0, 15);
        final previousSource = trace.now;
        expect(trace.value.x, greaterThan(.2));
        trace.now += 10000;
        trace.controller.updateGravity(_g, 0, 0, trace.now);
        trace.controller.updateGyroscope(
          0,
          0,
          0,
          trace.now,
          sensorTimeUs: previousSource + sourceDelta,
        );
        expect(trace.controller.active, isFalse);
        expect(trace.value, _zero);
        trace.quiet(10);
        expect(trace.value, _zero);
        trace.repress();
        trace.rotate(-1, 0, 0, 15);
        expect(trace.value.x, greaterThan(.2));
      }
    },
  );

  test('fresh source timestamps cannot conceal stale callback arrivals', () {
    final trace = _Trace()..rotate(-1, 0, 0, 15);
    final previousSource = trace.now;
    for (var i = 0; i < 15; i++) {
      trace.now += 10000;
      trace.controller.updateGravity(_g, 0, 0, trace.now);
    }
    trace.controller.updateGyroscope(
      0,
      0,
      0,
      trace.now,
      sensorTimeUs: previousSource + 10000,
    );
    expect(trace.controller.active, isFalse);
    expect(trace.value, _zero);
  });

  test(
    'backward/duplicate samples do not replace a newer pose; clock rollback disarms',
    () {
      final trace = _Trace()..rotate(-1, 0, 0, 15);
      final pose = trace.value;
      trace.controller.updateGyroscope(4, 0, 0, trace.now);
      trace.controller.updateGyroscope(4, 0, 0, trace.now - 1000);
      trace.controller.updateGravity(-_g, 0, 0, trace.now - 1000);
      expect(trace.value, pose);
      expect(trace.controller.sample(trace.now - 1), _zero);
      expect(trace.controller.active, isFalse);
    },
  );

  test(
    'lifecycle reset forgets the reference and never resumes a held tilt',
    () {
      final trace = _Trace()..rotate(-1, 0, 0, 15);
      trace.controller.reset();
      expect(trace.controller.active, isFalse);
      trace.quiet(3);
      expect(trace.value, _zero);
      trace.repress();
      expect(trace.value, _zero);
      trace.rotate(-1, 0, 0, 15);
      expect(trace.value.x, greaterThan(.2));
      trace.controller.setActive(true, -1);
      expect(trace.controller.active, isFalse);
      expect(trace.value, _zero);
    },
  );
}
