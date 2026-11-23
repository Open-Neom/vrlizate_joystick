import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate/vrlizate.dart' show VrHandPosture;
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

Map<String, dynamic> _fakeHandPayload({
  required String handedness,
  required bool openPalm,
}) {
  final pts = List<Map<String, double>>.generate(21, (_) => {'x': 0.5, 'y': 0.7, 'z': 0.0});
  pts[0] = {'x': 0.50, 'y': 0.70, 'z': 0.0};
  pts[1] = {'x': 0.46, 'y': 0.67, 'z': 0.0};
  pts[2] = {'x': 0.43, 'y': 0.64, 'z': 0.0};
  pts[3] = {'x': openPalm ? 0.40 : 0.45, 'y': openPalm ? 0.61 : 0.63, 'z': 0.0};
  pts[4] = {'x': openPalm ? 0.37 : 0.47, 'y': openPalm ? 0.58 : 0.62, 'z': 0.0};
  void setF(int m, int p, int d, int t, double x) {
    pts[m] = {'x': x, 'y': 0.60, 'z': 0.0};
    pts[p] = {'x': x, 'y': openPalm ? 0.56 : 0.58, 'z': 0.0};
    pts[d] = {'x': x, 'y': openPalm ? 0.53 : 0.61, 'z': 0.0};
    pts[t] = {'x': x, 'y': openPalm ? 0.50 : 0.63, 'z': 0.0};
  }

  setF(5, 6, 7, 8, 0.465);
  setF(9, 10, 11, 12, 0.50);
  setF(13, 14, 15, 16, 0.535);
  setF(17, 18, 19, 20, 0.568);

  return {
    'handedness': handedness,
    'score': 0.94,
    'landmarks': pts,
  };
}

void main() {
  group('NEON-037 · Full-Screen Contoured 2D Joystick & Sculpted Yin-Yang Cradle', () {
    test('stretches decks full screen height with enlarged sticks & disjoint concave lobes', () {
      final layout = Vr2dYinYangDeckLayout.fit(const Size(915, 412));

      // Full vertical stretch: nearly 100% of 412 dp height used.
      expect(layout.leftDeck.height, greaterThanOrEqualTo(404.0));
      expect(layout.rightDeck.height, closeTo(layout.leftDeck.height, 0.1));

      // Oversized symmetrical MOVER & MIRAR sticks (>= 185 dp on 915x412).
      expect(layout.stickSize, greaterThanOrEqualTo(185.0));
      expect(layout.leftStickRect.width, closeTo(layout.rightStickRect.width, 0.1));

      // Sculpted concave bottom & top Yin-Yang lobes remain strictly disjoint
      // and contain their label anchors.
      for (final edge in [
        VrYinYangCradleEdge.bottom,
        VrYinYangCradleEdge.top,
      ]) {
        final s = layout.leftTopPairRect.size;
        final paths = VrYinYangGeometry.buildPaths(s, cradleEdge: edge);
        expect(
          Path.combine(
            PathOperation.intersect,
            paths.lowerLeft,
            paths.upperRight,
          ).computeMetrics(),
          isEmpty,
        );
        expect(paths.lowerLeft.contains(VrYinYangGeometry.lowerLeftCenter(s)), isTrue);
        expect(paths.upperRight.contains(VrYinYangGeometry.upperRightCenter(s)), isTrue);
      }
    });

    testWidgets('PhoneControllerPage renders full-height decks and 1-tap Manos 2D telemetry strip', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(915, 412));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: PhoneControllerPage(
            targetHost: '127.0.0.1',
            isChildRole: true,
          ),
        ),
      );
      await tester.pump();

      final leftDeck = tester.getRect(find.byKey(const ValueKey('joystick_deck_left')));
      final moveStick = tester.getRect(find.byKey(const ValueKey('joystick_move_stick')));
      expect(leftDeck.height, greaterThanOrEqualTo(404.0));
      expect(moveStick.width, greaterThanOrEqualTo(185.0));
      expect(
        find.byKey(const ValueKey(VrJoystickConstants.keyJoystickHandsToggle)),
        findsOneWidget,
      );
    });
  });

  group('NEON-037 · 2nd Phone Hand Ademán Analysis & Telemetry', () {
    test('classifies left/right postures, builds live summary, and serializes rhG/lhG/rhO/lhO', () async {
      var nowUs = 1000000;
      final vision = VrJoystickCameraVisionService(
        monotonicMicroseconds: () => nowUs,
      );
      addTearDown(vision.dispose);

      await vision.setHandDetectionEnabled(true);
      vision.ingestHandResultForTesting({
        'status': 'ok',
        'inferenceMs': 15.0,
        'hands': [
          _fakeHandPayload(handedness: 'left', openPalm: true),
          _fakeHandPayload(handedness: 'right', openPalm: false),
        ],
      }, capturedAtUs: nowUs);

      expect(vision.mlLeftHandPosture, VrHandPosture.openPalm);
      expect(vision.mlRightHandPosture, VrHandPosture.fist);
      expect(vision.liveHandsStatusSummary, contains('2D→Visor'));
      expect(vision.liveHandsStatusSummary, contains('✋'));
      expect(vision.liveHandsStatusSummary, contains('✊'));

      final payload = vision.buildVisionTelemetryPayload(includeMiniFrame: false);
      expect(payload, isNotNull);
      expect(payload![VrJoystickConstants.fieldLeftHandGesture], 'open_palm');
      expect(payload[VrJoystickConstants.fieldRightHandGesture], 'fist');
      expect(payload[VrJoystickConstants.fieldLeftHandOpenness], isA<double>());
      expect(payload[VrJoystickConstants.fieldRightHandOpenness], isA<double>());
    });
  });
}
