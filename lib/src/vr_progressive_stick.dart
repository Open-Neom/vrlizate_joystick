import 'dart:math' as math;

/// Radial precision near center, with a time-based gain for a firm, steady hold.
///
/// Call [setInput] for raw normalized coordinates, [advance] once per foreground
/// frame, and [reset] on release, pause, disconnect or change of controller mode.
/// Input event frequency does not advance the ramp. Long frame gaps contribute
/// at most 100 ms, so resuming cannot apply a whole background interval.
class VrProgressiveStick {
  final double deadzone;
  final double exponent;
  final double initialGain;
  final double maxGain;
  final double rampSeconds;
  final double firmThreshold;
  final double directionResetDegrees;

  double _x = 0;
  double _y = 0;
  double _radius = 0;
  double _heldSeconds = 0;
  double? _anchorX;
  double? _anchorY;

  VrProgressiveStick({
    this.deadzone = .10,
    this.exponent = 1.5,
    this.initialGain = .5,
    this.maxGain = 1,
    this.rampSeconds = 1.8,
    this.firmThreshold = .65,
    this.directionResetDegrees = 55,
  }) {
    if (!deadzone.isFinite ||
        deadzone < 0 ||
        deadzone >= 1 ||
        !exponent.isFinite ||
        exponent < 1 ||
        !initialGain.isFinite ||
        initialGain < 0 ||
        !maxGain.isFinite ||
        maxGain < initialGain ||
        maxGain > 1 ||
        !rampSeconds.isFinite ||
        rampSeconds <= 0 ||
        !firmThreshold.isFinite ||
        firmThreshold <= deadzone ||
        firmThreshold > 1 ||
        !directionResetDegrees.isFinite ||
        directionResetDegrees <= 0 ||
        directionResetDegrees > 180) {
      throw ArgumentError('Invalid progressive stick configuration.');
    }
  }

  void setInput(double x, double y) {
    if (!x.isFinite || !y.isFinite) {
      reset();
      return;
    }
    // Scaling before hypot avoids overflow and preserves the supplied angle.
    final largest = math.max(x.abs(), y.abs());
    if (largest > 1) {
      x /= largest;
      y /= largest;
    }
    final length = math.sqrt(x * x + y * y);
    if (length <= deadzone) {
      reset();
      return;
    }
    _x = x / length;
    _y = y / length;
    _radius = length.clamp(0, 1);
    if (_radius < firmThreshold) {
      _clearRamp();
      return;
    }
    final anchorX = _anchorX;
    final anchorY = _anchorY;
    if (anchorX == null ||
        anchorY == null ||
        _x * anchorX + _y * anchorY <
            math.cos(directionResetDegrees * math.pi / 180)) {
      _heldSeconds = 0;
      _anchorX = _x;
      _anchorY = _y;
    }
  }

  void advance(double dtSeconds) {
    if (_anchorX == null || !dtSeconds.isFinite || dtSeconds <= 0) return;
    _heldSeconds = math.min(
      rampSeconds,
      _heldSeconds + math.min(dtSeconds, .1),
    );
  }

  ({double x, double y}) get output {
    if (_radius <= deadzone) return (x: 0, y: 0);
    final radial = math.pow((_radius - deadzone) / (1 - deadzone), exponent);
    final gain =
        initialGain + (maxGain - initialGain) * (_heldSeconds / rampSeconds);
    final magnitude = radial * gain;
    return (x: _x * magnitude, y: _y * magnitude);
  }

  void reset() {
    _x = 0;
    _y = 0;
    _radius = 0;
    _clearRamp();
  }

  void _clearRamp() {
    _heldSeconds = 0;
    _anchorX = null;
    _anchorY = null;
  }
}
