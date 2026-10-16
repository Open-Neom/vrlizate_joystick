import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/src/vr_progressive_stick.dart';

void main() {
  void hold(VrProgressiveStick stick, double seconds, {int fps = 60}) {
    for (var i = 0; i < (seconds * fps).round(); i++) {
      stick.advance(1 / fps);
    }
  }

  test(
    'firm movement starts reduced and reaches full scale without overshoot',
    () {
      final stick = VrProgressiveStick()..setInput(1, 0);
      expect(stick.output, (x: .5, y: 0));
      hold(stick, .9);
      expect(stick.output.x, closeTo(.75, 1e-10));
      hold(stick, 1);
      expect(stick.output, (x: 1, y: 0));
      hold(stick, 10);
      expect(stick.output, (x: 1, y: 0));
    },
  );

  test('continuous deadzone and light deflections never amplify drift', () {
    final stick = VrProgressiveStick()..setInput(.10, 0);
    expect(stick.output, (x: 0, y: 0));
    stick.setInput(.10001, 0);
    expect(stick.output.x, inExclusiveRange(0, 1e-6));
    stick.setInput(.25, 0);
    final precise = stick.output;
    expect(precise.x, lessThan(.04));
    for (var i = 0; i < 600; i++) {
      stick.setInput(.25, 0);
      stick.advance(1 / 60);
    }
    expect(stick.output, precise);
    stick.setInput(.03, -.04);
    expect(stick.output, (x: 0, y: 0));
  });

  test('event cadence and frame rate do not alter elapsed-time gain', () {
    final slow = VrProgressiveStick()..setInput(.8, .6);
    final fast = VrProgressiveStick()..setInput(.8, .6);
    for (var i = 0; i < 72; i++) {
      slow.advance(1 / 60);
    }
    for (var i = 0; i < 144; i++) {
      for (var event = 0; event < 8; event++) {
        fast.setInput(.8, .6);
      }
      fast.advance(1 / 120);
    }
    expect(fast.output.x, closeTo(slow.output.x, 1e-10));
    expect(fast.output.y, closeTo(slow.output.y, 1e-10));
  });

  test(
    'reversal, large turn and accumulated direction changes restart gain',
    () {
      final stick = VrProgressiveStick()..setInput(1, 0);
      hold(stick, 2);
      stick.setInput(-1, 0);
      expect(stick.output.x, -.5);
      hold(stick, 2);
      stick.setInput(0, 1);
      expect(stick.output.y, .5);
      stick.setInput(1, 0);
      hold(stick, 2);
      for (final degrees in [20, 40]) {
        final angle = degrees * math.pi / 180;
        stick.setInput(math.cos(angle), math.sin(angle));
        expect(
          math.sqrt(math.pow(stick.output.x, 2) + math.pow(stick.output.y, 2)),
          closeTo(1, 1e-10),
        );
      }
      const turn = math.pi / 3;
      stick.setInput(math.cos(turn), math.sin(turn));
      expect(stick.output.x, closeTo(.25, 1e-10));
    },
  );

  test(
    'center, release and leaving the firm region clear gain immediately',
    () {
      final stick = VrProgressiveStick()..setInput(0, 1);
      for (final resetKind in ['center', 'release', 'light']) {
        hold(stick, 2);
        expect(stick.output.y, 1);
        if (resetKind == 'release') {
          stick.reset();
        } else {
          stick.setInput(0, resetKind == 'center' ? 0 : .3);
        }
        if (resetKind != 'light') expect(stick.output, (x: 0, y: 0));
        stick.setInput(0, 1);
        expect(stick.output.y, .5);
      }
    },
  );

  test(
    'long stalls are capped and invalid frame times do not advance gain',
    () {
      final stick = VrProgressiveStick()..setInput(1, 0);
      stick.advance(30);
      expect(stick.output.x, closeTo(.5 + .5 * .1 / 1.8, 1e-10));
      final before = stick.output;
      for (final dt in [0.0, -1.0, double.nan, double.infinity]) {
        stick.advance(dt);
      }
      expect(stick.output, before);
      stick.reset();
      stick.advance(30);
      stick.setInput(1, 0);
      expect(stick.output.x, .5);
    },
  );

  test(
    'radial diagonal bounds preserve angle, including out of range inputs',
    () {
      final stick = VrProgressiveStick()..setInput(1, 1);
      hold(stick, 2);
      expect(stick.output.x, closeTo(math.sqrt(.5), 1e-10));
      expect(stick.output.y, closeTo(math.sqrt(.5), 1e-10));
      expect(
        stick.output.x * stick.output.x + stick.output.y * stick.output.y,
        lessThanOrEqualTo(1 + 1e-12),
      );
      stick.setInput(double.maxFinite, double.maxFinite / 2);
      expect(stick.output.x / stick.output.y, closeTo(2, 1e-10));
      expect(stick.output.x.isFinite && stick.output.y.isFinite, isTrue);
    },
  );

  test('look profile can cap gain while malformed input releases movement', () {
    final stick = VrProgressiveStick(initialGain: .4, maxGain: .8)
      ..setInput(1, 0);
    expect(stick.output.x, .4);
    hold(stick, 2);
    expect(stick.output.x, .8);
    stick.setInput(double.nan, 0);
    expect(stick.output, (x: 0, y: 0));
    stick.setInput(1, double.infinity);
    expect(stick.output, (x: 0, y: 0));
    stick.setInput(1, 0);
    expect(stick.output.x, .4);
    expect(() => VrProgressiveStick(rampSeconds: 0), throwsArgumentError);
    expect(() => VrProgressiveStick(maxGain: 1.1), throwsArgumentError);
  });
}
