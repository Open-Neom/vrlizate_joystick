import 'package:vrlizate_joystick/domain/services/vr_body_pose_gate.dart';

/// Geometrically coherent test fixture only; never evidence of a live person.
List<VrBodyLandmark> bodyPoseFixture({
  double du = 0,
  double dv = 0,
  double confidence = .95,
}) {
  const points = <(double, double)>[
    (.5, .15),
    (.48, .14),
    (.47, .14),
    (.46, .14),
    (.52, .14),
    (.53, .14),
    (.54, .14),
    (.44, .16),
    (.56, .16),
    (.48, .18),
    (.52, .18),
    (.38, .30),
    (.62, .30),
    (.30, .43),
    (.70, .43),
    (.25, .55),
    (.75, .55),
    (.24, .57),
    (.76, .57),
    (.25, .58),
    (.75, .58),
    (.26, .57),
    (.74, .57),
    (.42, .53),
    (.58, .53),
    (.41, .70),
    (.59, .70),
    (.40, .88),
    (.60, .88),
    (.39, .90),
    (.61, .90),
    (.38, .92),
    (.62, .92),
  ];
  return [
    for (var i = 0; i < points.length; i++)
      VrBodyLandmark(
        type: i,
        u: points[i].$1 + du,
        v: points[i].$2 + dv,
        zImagePixels: 0,
        inFrameLikelihood: confidence,
      ),
  ];
}
