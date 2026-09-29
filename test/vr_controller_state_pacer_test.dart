import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/src/vr_controller_state_pacer.dart';

Map<String, Object?> controls({
  double x = 0,
  bool pressed = false,
  String mode = 'joystick',
  int revision = 0,
}) => {
  'stickX': x,
  'btnA': pressed,
  'mode': mode,
  'hostModeRevision': revision,
};

void main() {
  test('physical tilt release bypasses BLE analog pacing', () {
    final pacer = VrControllerStatePacer();
    expect(
      pacer.shouldSend({'drivingTilt': .6}, nowUs: 0, bluetooth: true),
      isTrue,
    );
    expect(
      pacer.shouldSend({'drivingTilt': .8}, nowUs: 1000, bluetooth: true),
      isFalse,
    );
    expect(
      pacer.shouldSend({'drivingTilt': 0.0}, nowUs: 2000, bluetooth: true),
      isTrue,
    );
  });

  test('idle and held states keep alive below the 500 ms safety watchdog', () {
    for (final pressed in [false, true]) {
      final pacer = VrControllerStatePacer();
      final sentAt = <int>[];
      for (var now = 0; now < 1000000; now += 16000) {
        if (pacer.shouldSend(
          controls(pressed: pressed),
          nowUs: now,
          bluetooth: true,
        )) {
          sentAt.add(now);
        }
      }
      // Five refreshes in one simulated second instead of 63 identical ones.
      expect(sentAt, hasLength(5));
      for (var i = 1; i < sentAt.length; i++) {
        expect(sentAt[i] - sentAt[i - 1], lessThan(500000));
      }
    }
  });

  test(
    'continuous BLE axes are paced; latest sample replaces unsent motion',
    () {
      final pacer = VrControllerStatePacer();
      final sentAt = <int>[];
      for (var now = 0; now < 1000000; now += 1000) {
        if (pacer.shouldSend(
          controls(x: (now + 1) / 1000001),
          nowUs: now,
          bluetooth: true,
        )) {
          sentAt.add(now);
        }
      }
      expect(sentAt.length, lessThanOrEqualTo(31));
      for (var i = 1; i < sentAt.length; i++) {
        expect(sentAt[i] - sentAt[i - 1], greaterThanOrEqualTo(33333));
      }
      expect(
        pacer.shouldSend(controls(x: .8), nowUs: 1100000, bluetooth: true),
        isTrue,
      );
      expect(
        pacer.shouldSend(controls(x: .2), nowUs: 1101000, bluetooth: true),
        isFalse,
      );
      // Returning to the sent position cancels the obsolete .2 sample.
      expect(
        pacer.shouldSend(controls(x: .8), nowUs: 1140000, bluetooth: true),
        isFalse,
      );
      expect(
        pacer.shouldSend(controls(x: .7), nowUs: 1141000, bluetooth: true),
        isTrue,
      );
    },
  );

  test('button edges, neutral release and host mode ACK bypass BLE pacing', () {
    final pacer = VrControllerStatePacer();
    bool send(Map<String, Object?> state, int us) =>
        pacer.shouldSend(state, nowUs: us, bluetooth: true);
    expect(send(controls(x: .8), 0), isTrue);
    expect(send(controls(x: .8, pressed: true), 1000), isTrue);
    expect(send(controls(x: .8), 2000), isTrue);
    expect(send(controls(), 3000), isTrue);
    expect(send(controls(mode: 'driving'), 4000), isTrue);
    expect(send(controls(mode: 'driving', revision: 1), 5000), isTrue);
  });

  test('resume force and reconnect emit fresh state without stale pacing', () {
    final pacer = VrControllerStatePacer();
    expect(pacer.shouldSend(controls(), nowUs: 0, bluetooth: true), isTrue);
    expect(pacer.shouldSend(controls(), nowUs: 1000, bluetooth: true), isFalse);
    expect(
      pacer.shouldSend(controls(), nowUs: 1001, bluetooth: true, force: true),
      isTrue,
    );
    pacer.reset();
    expect(pacer.shouldSend(controls(), nowUs: 1002, bluetooth: true), isTrue);
  });

  test('Wi-Fi retains a 16 ms analog interval', () {
    final pacer = VrControllerStatePacer();
    expect(
      pacer.shouldSend(controls(x: .1), nowUs: 0, bluetooth: false),
      isTrue,
    );
    expect(
      pacer.shouldSend(controls(x: .2), nowUs: 15999, bluetooth: false),
      isFalse,
    );
    expect(
      pacer.shouldSend(controls(x: .3), nowUs: 16000, bluetooth: false),
      isTrue,
    );
  });
}
