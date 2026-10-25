import 'dart:math' as math;

/// A model landmark in rotated, unmirrored image coordinates. z is relative
/// model depth in image units, not metres or a calibrated world coordinate.
class VrBodyLandmark {
  const VrBodyLandmark({
    required this.type,
    required this.u,
    required this.v,
    required this.zImagePixels,
    required this.inFrameLikelihood,
  });
  final int type;
  final double u;
  final double v;
  final double zImagePixels;
  final double inFrameLikelihood;

  static List<VrBodyLandmark> fromNative(
    dynamic raw, {
    required int imageWidth,
    required int imageHeight,
  }) {
    if (raw is! List || imageWidth <= 0 || imageHeight <= 0) return const [];
    final points = <int, VrBodyLandmark>{};
    for (final entry in raw) {
      if (entry is! Map) continue;
      final type = entry['type'];
      final x = entry['x'];
      final y = entry['y'];
      final z = entry['z'];
      final likelihood = entry['inFrameLikelihood'];
      if (type is! int ||
          type < 0 ||
          type > 32 ||
          x is! num ||
          !x.isFinite ||
          y is! num ||
          !y.isFinite ||
          z is! num ||
          !z.isFinite ||
          likelihood is! num ||
          !likelihood.isFinite ||
          likelihood < 0 ||
          likelihood > 1) {
        continue;
      }
      points[type] = VrBodyLandmark(
        type: type,
        u: x / imageWidth,
        v: y / imageHeight,
        zImagePixels: z.toDouble(),
        inFrameLikelihood: likelihood.toDouble(),
      );
    }
    return List.unmodifiable(points.values);
  }
}

class VrBodyPoseGateResult {
  const VrBodyPoseGateResult({
    required this.accepted,
    required this.reason,
    required this.stableFrames,
    required this.rawCount,
  });
  final bool accepted;
  final String reason;
  final int stableFrames;
  final int rawCount;
}

/// Conservative quality gate for a single, mostly visible body proposal.
///
/// Thresholds are policy checks, not a trained person classifier or a new ML
/// confidence score. Even an accepted proposal can be a model false positive.
/// Partial/occluded bodies are intentionally rejected before physical tuning.
class VrBodyPoseGate {
  VrBodyPoseGate({
    this.requiredStableFrames = 3,
    this.minStableDurationUs = 600000,
    this.maxGapUs = 1800000,
  });

  final int requiredStableFrames;
  final int minStableDurationUs;
  final int maxGapUs;
  String? _source;
  int? _rotation;
  int? _width;
  int? _height;
  int? _lastUs;
  int? _firstStableUs;
  int _stableFrames = 0;
  _Point? _lastCenter;
  double? _lastTorso;

  void reset() {
    _source = null;
    _rotation = null;
    _width = null;
    _height = null;
    _lastUs = null;
    _firstStableUs = null;
    _stableFrames = 0;
    _lastCenter = null;
    _lastTorso = null;
  }

  VrBodyPoseGateResult evaluate({
    required List<VrBodyLandmark> landmarks,
    required String sourceId,
    required int rotationDegrees,
    required int capturedAtUs,
    required int imageWidth,
    required int imageHeight,
    bool present = true,
  }) {
    final rawCount = landmarks.length;
    VrBodyPoseGateResult reject(String reason) {
      reset();
      return VrBodyPoseGateResult(
        accepted: false,
        reason: reason,
        stableFrames: 0,
        rawCount: rawCount,
      );
    }

    if (!present || landmarks.isEmpty) return reject('no_pose');
    if (imageWidth <= 0 ||
        imageHeight <= 0 ||
        sourceId.isEmpty ||
        !const [0, 90, 180, 270].contains(rotationDegrees) ||
        capturedAtUs < 0) {
      return reject('invalid_metadata');
    }
    final previousUs = _lastUs;
    if (_source != sourceId ||
        _rotation != rotationDegrees ||
        _width != imageWidth ||
        _height != imageHeight ||
        previousUs == null ||
        capturedAtUs <= previousUs ||
        capturedAtUs - previousUs > maxGapUs) {
      reset();
    }
    final byType = <int, VrBodyLandmark>{};
    for (final point in landmarks) {
      if (point.type < 0 ||
          point.type > 32 ||
          byType.containsKey(point.type) ||
          !point.u.isFinite ||
          !point.v.isFinite ||
          !point.zImagePixels.isFinite ||
          !point.inFrameLikelihood.isFinite ||
          point.inFrameLikelihood < 0 ||
          point.inFrameLikelihood > 1) {
        return reject('invalid_landmarks');
      }
      byType[point.type] = point;
    }
    bool reliable(int type, [double threshold = .75]) {
      final point = byType[type];
      return point != null &&
          point.inFrameLikelihood >= threshold &&
          point.u >= .02 &&
          point.u <= .98 &&
          point.v >= .02 &&
          point.v <= .98;
    }

    const core = [11, 12, 23, 24];
    if (!core.every((type) => reliable(type, .85))) return reject('weak_torso');
    if (!reliable(0) ||
        ![25, 26, 27, 28].every(reliable) ||
        !((reliable(13) && reliable(15)) || (reliable(14) && reliable(16)))) {
      return reject('incomplete_body');
    }
    if (byType.keys.where(reliable).length < 15) {
      return reject('insufficient_support');
    }

    // Use true image aspect ratio: distance in a 16:9 image is not distance in
    // a square plot. A unit here is the image's shorter side, never metres.
    final shortSide = math.min(imageWidth, imageHeight);
    _Point point(int type) {
      final value = byType[type]!;
      return _Point(
        value.u * imageWidth / shortSide,
        value.v * imageHeight / shortSide,
      );
    }

    final shoulders = point(11).midpoint(point(12));
    final hips = point(23).midpoint(point(24));
    final torso = shoulders.distance(hips);
    final shoulderWidth = point(11).distance(point(12));
    final hipWidth = point(23).distance(point(24));
    if (torso < .12 ||
        torso > .75 ||
        shoulderWidth < .08 ||
        hipWidth < .06 ||
        shoulderWidth / hipWidth < .45 ||
        shoulderWidth / hipWidth > 2.5 ||
        shoulderWidth / torso < .25 ||
        shoulderWidth / torso > 2.5) {
      return reject('collapsed_torso');
    }
    final headDistance = point(0).distance(shoulders);
    if (headDistance < torso * .15 || headDistance > torso * 1.6) {
      return reject('implausible_head');
    }
    bool limb(int a, int b, int c) {
      final upper = point(a).distance(point(b));
      final lower = point(b).distance(point(c));
      return upper >= torso * .18 &&
          lower >= torso * .18 &&
          upper <= torso * 2.3 &&
          lower <= torso * 2.3 &&
          upper / lower >= .25 &&
          upper / lower <= 4;
    }

    if (!limb(23, 25, 27) ||
        !limb(24, 26, 28) ||
        !((reliable(13) && reliable(15) && limb(11, 13, 15)) ||
            (reliable(14) && reliable(16) && limb(12, 14, 16)))) {
      return reject('implausible_limbs');
    }
    final center = shoulders.midpoint(hips);
    final priorCenter = _lastCenter;
    final priorTorso = _lastTorso;
    final jumped =
        priorCenter != null &&
        (center.distance(priorCenter) > .18 ||
            (priorTorso != null &&
                (torso / priorTorso < .6 || torso / priorTorso > 1.65)));
    if (jumped) {
      _stableFrames = 0;
      _firstStableUs = null;
    }
    _source = sourceId;
    _rotation = rotationDegrees;
    _width = imageWidth;
    _height = imageHeight;
    _lastUs = capturedAtUs;
    _lastCenter = center;
    _lastTorso = torso;
    _firstStableUs ??= capturedAtUs;
    _stableFrames++;
    final accepted =
        _stableFrames >= math.max(2, requiredStableFrames) &&
        capturedAtUs - _firstStableUs! >= minStableDurationUs;
    return VrBodyPoseGateResult(
      accepted: accepted,
      reason: accepted
          ? 'accepted_proposal'
          : jumped
          ? 'motion_discontinuity'
          : 'warming_up',
      stableFrames: _stableFrames,
      rawCount: rawCount,
    );
  }
}

class _Point {
  const _Point(this.x, this.y);
  final double x;
  final double y;
  _Point midpoint(_Point other) => _Point((x + other.x) / 2, (y + other.y) / 2);
  double distance(_Point other) =>
      math.sqrt(math.pow(x - other.x, 2) + math.pow(y - other.y, 2));
}
