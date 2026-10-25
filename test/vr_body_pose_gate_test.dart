import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/domain/services/vr_body_pose_gate.dart';

import 'fixtures/body_pose_fixture.dart';

void main() {
  late VrBodyPoseGate gate;
  setUp(() => gate = VrBodyPoseGate());
  VrBodyPoseGateResult evaluate(
    List<VrBodyLandmark> points,
    int time, {
    String source = 'rear/0',
    int rotation = 0,
    int width = 640,
    int height = 480,
    bool present = true,
  }) => gate.evaluate(
    landmarks: points,
    sourceId: source,
    rotationDegrees: rotation,
    capturedAtUs: time,
    imageWidth: width,
    imageHeight: height,
    present: present,
  );

  test(
    'never accepts one frame; requires temporal support and coherent geometry',
    () {
      expect(evaluate(bodyPoseFixture(), 0).accepted, isFalse);
      expect(evaluate(bodyPoseFixture(), 500000).accepted, isFalse);
      final third = evaluate(bodyPoseFixture(), 1000000);
      expect(third.accepted, isTrue);
      expect(third.stableFrames, 3);
      expect(third.rawCount, 33);
      expect(third.reason, 'accepted_proposal');
    },
  );

  test(
    'low-confidence furniture proposal, collapsed points and partial body are rejected',
    () {
      expect(evaluate(bodyPoseFixture(confidence: .5), 0).reason, 'weak_torso');
      final collapsed = [
        for (final point in bodyPoseFixture())
          VrBodyLandmark(
            type: point.type,
            u: .5,
            v: .5,
            zImagePixels: 0,
            inFrameLikelihood: .99,
          ),
      ];
      expect(evaluate(collapsed, 1000000).reason, 'collapsed_torso');
      expect(
        evaluate(
          bodyPoseFixture().where((p) => p.type < 23).toList(),
          2000000,
        ).reason,
        'weak_torso',
      );
      expect(evaluate(bodyPoseFixture(dv: .3), 3000000).accepted, isFalse);
    },
  );

  test('a large jump starts a new track instead of retaining acceptance', () {
    for (final time in [0, 500000, 1000000]) {
      evaluate(bodyPoseFixture(), time);
    }
    final jump = evaluate(bodyPoseFixture(du: .19), 1500000);
    expect(jump.accepted, isFalse);
    expect(jump.reason, 'motion_discontinuity');
    expect(jump.stableFrames, 1);
    expect(evaluate(bodyPoseFixture(du: .19), 2000000).accepted, isFalse);
    expect(evaluate(bodyPoseFixture(du: .19), 2500000).accepted, isTrue);
  });

  test(
    'no-person, gap, source, rotation, dimensions and backwards time reset',
    () {
      for (final change in [
        'none',
        'gap',
        'source',
        'rotation',
        'dimensions',
        'clock',
      ]) {
        gate.reset();
        for (final time in [0, 500000, 1000000]) {
          evaluate(bodyPoseFixture(), time);
        }
        if (change == 'none') {
          expect(evaluate([], 1500000, present: false).accepted, isFalse);
          expect(evaluate(bodyPoseFixture(), 2000000).stableFrames, 1);
        } else {
          final result = evaluate(
            bodyPoseFixture(),
            change == 'gap'
                ? 3000000
                : change == 'clock'
                ? 900000
                : 1500000,
            source: change == 'source' ? 'front/1' : 'rear/0',
            rotation: change == 'rotation' ? 90 : 0,
            width: change == 'dimensions' ? 720 : 640,
          );
          expect(result.accepted, isFalse, reason: change);
          expect(result.stableFrames, 1, reason: change);
        }
      }
    },
  );

  test(
    'native parsing is finite, scale-aware and rejects unknown zero dimensions',
    () {
      final raw = [
        {'type': 11, 'x': 320, 'y': 240, 'z': -3, 'inFrameLikelihood': .9},
        {
          'type': 12,
          'x': double.nan,
          'y': 240,
          'z': 0,
          'inFrameLikelihood': .9,
        },
      ];
      expect(
        VrBodyLandmark.fromNative(raw, imageWidth: 0, imageHeight: 480),
        isEmpty,
      );
      final parsed = VrBodyLandmark.fromNative(
        raw,
        imageWidth: 640,
        imageHeight: 480,
      );
      expect(parsed.length, 1);
      expect(parsed.single.u, .5);
      expect(parsed.single.v, .5);
      expect(parsed.single.zImagePixels, -3);
    },
  );
}
