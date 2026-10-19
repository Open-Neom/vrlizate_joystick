import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  group('VrPassthroughSplitGestureController', () {
    test('arms when both thumbs tap inside center zone within sync window', () {
      final controller = VrPassthroughSplitGestureController();
      expect(controller.mode, VrPassthroughSplitGestureMode.idle);
      expect(controller.passthroughMix, 0.0);

      final changed1 = controller.onPointerDown(
        pointerId: 1,
        normX: 0.44,
        normY: 0.50,
        timestampUs: 100000,
      );
      expect(changed1, isFalse);
      expect(controller.mode, VrPassthroughSplitGestureMode.idle);

      final changed2 = controller.onPointerDown(
        pointerId: 2,
        normX: 0.56,
        normY: 0.50,
        timestampUs: 140000,
      );
      expect(changed2, isTrue);
      expect(controller.mode, VrPassthroughSplitGestureMode.armedCenterTap);
      expect(controller.isGestureActive, isTrue);
    });

    test('fast outward slide toggles passthrough 0% -> 100% -> 0%', () {
      final controller = VrPassthroughSplitGestureController();

      // First fast outward flick: 0% -> 100%
      controller.onPointerDown(
        pointerId: 1,
        normX: 0.46,
        normY: 0.50,
        timestampUs: 0,
      );
      controller.onPointerDown(
        pointerId: 2,
        normX: 0.54,
        normY: 0.50,
        timestampUs: 20000,
      );

      // Slide both thumbs rapidly outward within 200 ms (200,000 us)
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.14,
        normY: 0.50,
        timestampUs: 180000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.86,
        normY: 0.50,
        timestampUs: 200000,
      );
      expect(controller.mode, VrPassthroughSplitGestureMode.fastToggleSwipe);
      expect(controller.passthroughMix, 1.0);
      expect(controller.passthroughActive, isTrue);

      controller.onPointerUpOrCancel(pointerId: 1, timestampUs: 220000);
      controller.onPointerUpOrCancel(pointerId: 2, timestampUs: 230000);
      expect(controller.passthroughMix, 1.0);

      // Second fast outward flick: 100% -> 0%
      controller.onPointerDown(
        pointerId: 3,
        normX: 0.46,
        normY: 0.50,
        timestampUs: 500000,
      );
      controller.onPointerDown(
        pointerId: 4,
        normX: 0.54,
        normY: 0.50,
        timestampUs: 520000,
      );
      controller.onPointerMove(
        pointerId: 3,
        normX: 0.12,
        normY: 0.50,
        timestampUs: 680000,
      );
      controller.onPointerMove(
        pointerId: 4,
        normX: 0.88,
        normY: 0.50,
        timestampUs: 700000,
      );
      controller.onPointerUpOrCancel(pointerId: 3, timestampUs: 720000);
      expect(controller.passthroughMix, 0.0);
      expect(controller.passthroughActive, isFalse);
    });

    test('slow outward slide blends virtual world and passthrough at mix %', () {
      final controller = VrPassthroughSplitGestureController();

      controller.onPointerDown(
        pointerId: 1,
        normX: 0.46,
        normY: 0.50,
        timestampUs: 0,
      );
      controller.onPointerDown(
        pointerId: 2,
        normX: 0.54,
        normY: 0.50,
        timestampUs: 20000,
      );

      // Moderate-slow outward slide (spread ~0.50 over 550 ms -> speed ~0.91/s)
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.27,
        normY: 0.50,
        timestampUs: 550000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.73,
        normY: 0.50,
        timestampUs: 570000,
      );

      expect(controller.mode, VrPassthroughSplitGestureMode.slowMixBlend);
      expect(controller.passthroughMix, closeTo(0.50, 0.08));

      // Release thumbs: mix stays latched at ~50%
      controller.onPointerUpOrCancel(pointerId: 1, timestampUs: 600000);
      expect(controller.passthroughMix, closeTo(0.50, 0.08));
      expect(controller.passthroughActive, isTrue);
    });

    test('ultra-slow outward traversal sweeps passthrough 0% -> 100% -> 0%', () {
      final controller = VrPassthroughSplitGestureController();

      controller.onPointerDown(
        pointerId: 1,
        normX: 0.46,
        normY: 0.50,
        timestampUs: 0,
      );
      controller.onPointerDown(
        pointerId: 2,
        normX: 0.54,
        normY: 0.50,
        timestampUs: 10000,
      );

      // 1) Halfway to edges (spread = 0.50) reached slowly at t = 1.2s -> 100% mix
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.27,
        normY: 0.50,
        timestampUs: 1200000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.73,
        normY: 0.50,
        timestampUs: 1210000,
      );
      expect(
        controller.mode,
        VrPassthroughSplitGestureMode.ultraSlowCycleZeroToHundredToZero,
      );
      expect(controller.passthroughMix, closeTo(1.0, 0.05));

      // 2) Continue ultra-slowly to outer edges (spread = 1.0) at t = 2.4s -> 0% mix
      controller.onPointerMove(
        pointerId: 1,
        normX: 0.08,
        normY: 0.50,
        timestampUs: 2400000,
      );
      controller.onPointerMove(
        pointerId: 2,
        normX: 0.92,
        normY: 0.50,
        timestampUs: 2410000,
      );
      expect(
        controller.mode,
        VrPassthroughSplitGestureMode.ultraSlowCycleZeroToHundredToZero,
      );
      expect(controller.passthroughMix, closeTo(0.0, 0.02));
      expect(controller.passthroughActive, isFalse);
    });
  });
}
