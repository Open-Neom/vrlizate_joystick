/// Tracks a single thumb pointer's normalized coordinates and timestamps during
/// a dual-thumb Passthrough split gesture.
class VrThumbPointerTrack {
  VrThumbPointerTrack({
    required this.pointerId,
    required this.startNormX,
    required this.startNormY,
    required this.downTimestampUs,
  }) : currentNormX = startNormX,
       currentNormY = startNormY,
       lastUpdateTimestampUs = downTimestampUs;

  final int pointerId;
  final double startNormX;
  final double startNormY;
  final int downTimestampUs;

  double currentNormX;
  double currentNormY;
  int lastUpdateTimestampUs;
}
