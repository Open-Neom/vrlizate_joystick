import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate/vrlizate.dart' show VrPinchFinger;
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

List<Map<String, double>> _nativeLandmarks({
  required double cx,
  required double cy,
  required double palmSpan,
  int? pinchTipIdx,
}) {
  final pts = List<Map<String, double>>.generate(
    21,
    (i) => {'x': cx + (i % 4) * 0.01, 'y': cy, 'z': 0.0},
  );
  pts[0] = {'x': cx, 'y': cy + palmSpan * 0.5, 'z': 0.0};
  pts[9] = {'x': cx, 'y': cy - palmSpan * 0.5, 'z': 0.0};
  pts[4] = {'x': cx - palmSpan * 0.12, 'y': cy - palmSpan * 0.3, 'z': 0.0};
  pts[8] = {'x': cx + palmSpan * 0.5, 'y': cy - palmSpan * 0.85, 'z': 0.0};
  pts[12] = {'x': cx + palmSpan * 0.6, 'y': cy - palmSpan * 0.90, 'z': 0.0};
  pts[16] = {'x': cx + palmSpan * 0.7, 'y': cy - palmSpan * 0.80, 'z': 0.0};
  pts[20] = {'x': cx + palmSpan * 0.8, 'y': cy - palmSpan * 0.70, 'z': 0.0};
  if (pinchTipIdx != null) {
    pts[pinchTipIdx] = {
      'x': pts[4]['x']! + 0.004,
      'y': pts[4]['y']! + 0.002,
      'z': 0.0,
    };
  }
  return pts;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Joystick camera vision parses native 21-pt left+right hands, palm depth, and 4-finger pinch into compact wire telemetry',
    () async {
      var nowUs = 1000000;
      final vision = VrJoystickCameraVisionService(
        monotonicMicroseconds: () => nowUs,
      );
      addTearDown(vision.dispose);

      await vision.setHandDetectionEnabled(true);
      expect(vision.handDetectionEnabled, isTrue);

      vision.ingestHandResultForTesting({
        'status': 'ok',
        'handsStatus': 'ok',
        'inferenceMs': 11.4,
        'hands': [
          {
            'handedness': 'left',
            'score': 0.91,
            'landmarks': _nativeLandmarks(
              cx: 0.30,
              cy: 0.52,
              palmSpan: 0.16,
              pinchTipIdx: 12, // middle pinch
            ),
          },
          {
            'handedness': 'right',
            'score': 0.94,
            'landmarks': _nativeLandmarks(
              cx: 0.72,
              cy: 0.48,
              palmSpan: 0.22,
              pinchTipIdx: 8, // index pinch
            ),
          },
        ],
      }, capturedAtUs: nowUs);

      expect(vision.hasFreshMlHandSample, isTrue);
      expect(vision.mlLeftHandConfidence, greaterThan(0.85));
      expect(vision.mlRightHandConfidence, greaterThan(0.85));
      expect(vision.mlLeftHandPinchFinger, VrPinchFinger.middleFinger);
      expect(vision.mlRightHandPinchFinger, VrPinchFinger.indexFinger);
      expect(vision.mlLeftHandPinchStrength, greaterThan(0.8));
      expect(vision.mlRightHandPinchStrength, greaterThan(0.8));
      // Right palm is larger in frame -> closer metric depth than left palm.
      expect(
        vision.mlRightHandDepthMeters!,
        lessThan(vision.mlLeftHandDepthMeters!),
      );

      final payload = vision.buildVisionTelemetryPayload(includeMiniFrame: false);
      expect(payload, isNotNull);
      expect(payload!['opticalSource'], 'mediapipe_hand_21');
      expect(payload[VrJoystickConstants.fieldHandSource], 'mediapipe_21');
      expect(
        payload[VrJoystickConstants.fieldRightHandPinchFinger],
        'indexFinger',
      );
      expect(
        payload[VrJoystickConstants.fieldLeftHandPinchFinger],
        'middleFinger',
      );
      expect(
        (payload[VrJoystickConstants.fieldLeftHandConfidence] as num)
            .toDouble(),
        greaterThan(0.85),
      );
    },
  );
}
