import 'dart:math' as math;

/// Frame admission based on observed end-to-end inference latency, not a claim
/// of measured CPU utilization. Native/GPU work can overlap this wall duration.
/// One request is retained until completion, including through a reset.
class VrVisionInferenceBudget {
  VrVisionInferenceBudget({
    this.minIntervalUs = 500000,
    this.searchIntervalUs = 1000000,
    this.maxIntervalUs = 1500000,
    this.targetDuty = .15,
  }) : assert(minIntervalUs >= 500000),
       assert(searchIntervalUs >= minIntervalUs),
       assert(maxIntervalUs >= searchIntervalUs),
       assert(targetDuty > 0 && targetDuty <= 1);

  final int minIntervalUs;
  final int searchIntervalUs;
  final int maxIntervalUs;
  final double targetDuty;
  int _epoch = 0;
  int _activeEpoch = 0;
  int? _activeStartedUs;
  int? _nextStartUs;
  double _costEmaUs = 0;
  int? _lastIntervalUs;
  int? _deferredUntilUs;
  int? _deferredIntervalUs;

  bool get isInFlight => _activeStartedUs != null;
  int get intervalUs => _lastIntervalUs ?? searchIntervalUs;
  double get effectiveMaxHz => 1000000 / intervalUs;

  bool tryStart(int nowUs) {
    if (nowUs < 0 ||
        isInFlight ||
        (_nextStartUs != null && nowUs < _nextStartUs!)) {
      return false;
    }
    _activeStartedUs = nowUs;
    _activeEpoch = _epoch;
    if (_deferredUntilUs != null && nowUs >= _deferredUntilUs!) {
      _deferredUntilUs = null;
      _deferredIntervalUs = null;
    }
    return true;
  }

  /// Native thermal refusal is a pause, not an empty inference. This override
  /// deliberately exceeds the normal 1.5s cadence cap; callers expire poses.
  void deferFor(int nowUs, {required int retryAfterUs}) {
    final delay = retryAfterUs.clamp(2000000, 60000000);
    _deferredUntilUs = math.max(_deferredUntilUs ?? nowUs, nowUs + delay);
    _deferredIntervalUs = delay;
    _lastIntervalUs = math.max(intervalUs, delay);
    _nextStartUs = math.max(_nextStartUs ?? nowUs, _deferredUntilUs!);
  }

  void recordCompletion({
    required int startedUs,
    required int finishedUs,
    required bool confirmedBody,
  }) {
    if (_activeStartedUs != startedUs) return;
    _activeStartedUs = null;
    if (_activeEpoch != _epoch) return;
    final elapsed = math.max(0, finishedUs - startedUs);
    _costEmaUs = _costEmaUs == 0
        ? elapsed.toDouble()
        : _costEmaUs * .8 + elapsed * .2;
    final base = confirmedBody ? minIntervalUs : searchIntervalUs;
    final latencyBudget = (math.max(_costEmaUs, elapsed) / targetDuty).ceil();
    final normalInterval = math
        .max(base, latencyBudget)
        .clamp(minIntervalUs, maxIntervalUs);
    _lastIntervalUs = math.max(normalInterval, _deferredIntervalUs ?? 0);
    _nextStartUs = math.max(
      math.max(finishedUs, startedUs + normalInterval),
      _deferredUntilUs ?? 0,
    );
  }

  void reset() {
    _epoch++;
    _nextStartUs = null;
    _costEmaUs = 0;
    _lastIntervalUs = null;
    _deferredUntilUs = null;
    _deferredIntervalUs = null;
    // Keep activeStartedUs until its real completion: reset is not cancellation.
  }
}
