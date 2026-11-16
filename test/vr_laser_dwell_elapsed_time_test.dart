import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  for (final intervalUs in const [8000, 16000, 33000]) {
    test('five-second dwell follows elapsed time at $intervalUs us ticks', () {
      final dwell = VrLaserSteadyDwellController();
      const durationUs = 5000000;
      var clicks = 0;
      int? firstClickUs;
      expect(
        dwell.update(angularSpeedRadiansPerSec: .05, dtSeconds: 0),
        isFalse,
      );
      expect(dwell.elapsedSeconds, 0);
      final steps = (durationUs + intervalUs - 1) ~/ intervalUs + 2;
      for (var step = 1; step <= steps; step++) {
        final elapsedUs = step * intervalUs;
        final triggered = dwell.update(
          angularSpeedRadiansPerSec: .05,
          dtSeconds: intervalUs / 1000000,
        );
        if (elapsedUs < durationUs) {
          expect(
            triggered,
            isFalse,
            reason: 'A faster timer must not count a 16 ms minimum per tick.',
          );
        }
        if (triggered) {
          clicks++;
          firstClickUs ??= elapsedUs;
        }
        expect(
          dwell.elapsedSeconds,
          closeTo(math.min(elapsedUs / 1000000, 5.0), 1e-9),
        );
      }
      expect(clicks, 1);
      expect(firstClickUs, isNotNull);
      expect(firstClickUs, greaterThanOrEqualTo(durationUs));
      // Allow one timer tick for threshold quantization/Float64 rounding.
      expect(firstClickUs, lessThanOrEqualTo(durationUs + intervalUs));
      for (var repeat = 0; repeat < 10; repeat++) {
        expect(
          dwell.update(
            angularSpeedRadiansPerSec: .05,
            dtSeconds: intervalUs / 1000000,
          ),
          isFalse,
        );
      }
    });
  }
}
