import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/domain/services/vr_vision_inference_budget.dart';

void main() {
  test('thermal defer survives completion and exceeds normal cadence', () {
    final budget = VrVisionInferenceBudget();
    budget.tryStart(0);
    budget.deferFor(1000, retryAfterUs: 2000000);
    budget.recordCompletion(
      startedUs: 0,
      finishedUs: 1000,
      confirmedBody: false,
    );
    expect(budget.intervalUs, 2000000);
    expect(budget.tryStart(2000000), isFalse);
    expect(budget.tryStart(2001000), isTrue);
    budget.reset();
    budget.recordCompletion(
      startedUs: 2001000,
      finishedUs: 2002000,
      confirmedBody: false,
    );
    expect(budget.intervalUs, 1000000);
    expect(budget.tryStart(2002000), isTrue);
  });
  test('starts at one-Hz search and never queues while work is inflight', () {
    final budget = VrVisionInferenceBudget();
    expect(budget.tryStart(0), isTrue);
    expect(budget.tryStart(900000), isFalse);
    budget.recordCompletion(
      startedUs: 0,
      finishedUs: 60000,
      confirmedBody: false,
    );
    expect(budget.intervalUs, 1000000);
    expect(budget.tryStart(999999), isFalse);
    expect(budget.tryStart(1000000), isTrue);
  });

  test(
    'confirmed proposals can reach two Hz, latency increases the interval',
    () {
      final budget = VrVisionInferenceBudget();
      budget.tryStart(0);
      budget.recordCompletion(
        startedUs: 0,
        finishedUs: 60000,
        confirmedBody: true,
      );
      expect(budget.intervalUs, 500000);
      expect(budget.tryStart(500000), isTrue);
      budget.recordCompletion(
        startedUs: 500000,
        finishedUs: 680000,
        confirmedBody: true,
      );
      expect(budget.intervalUs, 1200000);
      expect(budget.effectiveMaxHz, lessThan(1));
      expect(budget.tryStart(1699999), isFalse);
      expect(budget.tryStart(1700000), isTrue);
    },
  );

  test(
    'reset preserves the active slot and ignores its stale completion cost',
    () {
      final budget = VrVisionInferenceBudget();
      budget.tryStart(0);
      budget.reset();
      expect(budget.tryStart(1000000), isFalse);
      budget.recordCompletion(
        startedUs: 0,
        finishedUs: 1000000,
        confirmedBody: true,
      );
      expect(budget.isInFlight, isFalse);
      expect(budget.intervalUs, 1000000);
      expect(budget.tryStart(1000000), isTrue);
    },
  );

  test(
    'slow work backs off to bounded interval; unrelated completions cannot unlock',
    () {
      final budget = VrVisionInferenceBudget();
      budget.tryStart(0);
      budget.recordCompletion(
        startedUs: 7,
        finishedUs: 900000,
        confirmedBody: false,
      );
      expect(budget.isInFlight, isTrue);
      budget.recordCompletion(
        startedUs: 0,
        finishedUs: 900000,
        confirmedBody: false,
      );
      expect(budget.intervalUs, 1500000);
      expect(budget.tryStart(1499999), isFalse);
      expect(budget.tryStart(1500000), isTrue);
    },
  );
}
