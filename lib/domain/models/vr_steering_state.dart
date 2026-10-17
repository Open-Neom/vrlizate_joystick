/// Normalized driving controls. Positive steering means turn right.
class VrSteeringState {
  final double steering;
  final double throttle;
  final double brake;
  final bool paused;

  const VrSteeringState({
    this.steering = 0,
    this.throttle = 0,
    this.brake = 0,
    this.paused = false,
  });
}
