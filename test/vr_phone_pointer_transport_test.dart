import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _Link implements VrControllerLink {
  final _incoming = StreamController<Object?>(sync: true);
  bool _open = true;

  @override
  Stream<Object?> get messages => _incoming.stream;
  @override
  bool get isOpen => _open;
  @override
  void add(Object data) {}
  void receive(Object data) => _incoming.add(data);
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    await _incoming.close();
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Controller event timed out.');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VrRemoteControllerService service;
  late _Link link;
  var nowUs = 0;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    nowUs = 0;
    service = VrRemoteControllerService(
      nowMicroseconds: () => nowUs,
      inputTimeout: const Duration(milliseconds: 20),
      watchdogInterval: const Duration(milliseconds: 2),
    );
    link = _Link();
    expect(
      service.attachControllerLink(link, sessionToken: service.sessionToken),
      isTrue,
    );
  });

  tearDown(() async {
    service.dispose();
    await link.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  for (final format in ['JSON', 'compact object', 'compact bytes']) {
    test('neutral host ACK accepts posture metadata in $format', () {
      void receive(int sequence, {bool pressed = false}) {
        if (format == 'JSON') {
          link.receive(
            jsonEncode({
              'sequence': sequence,
              'hostModeRevision': 0,
              'mode': 'joystick',
              'pointerPoseReady': true,
              'stickY': pressed ? .5 : 0.0,
              'btnA': pressed,
            }),
          );
          return;
        }
        final frame = VrCompactGamepadFrame(
          sequence: sequence,
          senderTimestampMicroseconds: sequence * 1000,
          orientation: vm.Quaternion.identity(),
          angularVelocity: vm.Vector3.zero(),
          hostModeRevision: 0,
          pointerPoseReady: true,
          stickY: pressed ? .5 : 0,
          btnA: pressed,
        );
        link.receive(
          format == 'compact object'
              ? frame
              : const VrCompactGamepadCodec().encode(frame),
        );
      }

      receive(1);
      expect(service.telemetry.acceptedStates, 1);
      expect(service.telemetry.rejectedStates, 0);
      expect(service.latestState.pointerPoseReady, isTrue);
      expect(service.latestState.stickY, 0);
      expect(service.latestState.btnA, isFalse);
      // Pose is metadata, so it must not prevent neutral acknowledgement or
      // leave later genuine input rejected while waiting for a new ACK.
      receive(2, pressed: true);
      expect(service.telemetry.acceptedStates, 2);
      expect(service.latestState.pointerPoseReady, isTrue);
      expect(service.latestState.stickY, closeTo(.5, .001));
      expect(service.latestState.btnA, isTrue);
    });
  }

  test('JSON requires a real bool and omission removes old qualification', () {
    for (final invalid in <Object?>[1, 'true', null]) {
      link.receive(jsonEncode({'sequence': 1, 'pointerPoseReady': invalid}));
    }
    expect(service.telemetry.acceptedStates, 0);
    expect(service.latestState.pointerPoseReady, isFalse);
    link.receive(jsonEncode({'sequence': 1, 'pointerPoseReady': true}));
    expect(service.latestState.pointerPoseReady, isTrue);
    // Aim, a quaternion and a held slide are not measurements of phone posture.
    link.receive(
      jsonEncode({
        'sequence': 2,
        'qw': .70710678,
        'qx': .70710678,
        'laserX': .8,
        'laserSlideActive': true,
      }),
    );
    expect(service.latestState.pointerPoseReady, isFalse);
    expect(service.latestState.laserSlideActive, isTrue);
  });

  test('JSON requires boolean shoulder flags', () {
    for (final key in ['btnZL', 'btnZR']) {
      for (final invalid in <Object?>[1, 'true', null]) {
        link.receive(jsonEncode({'sequence': 1, key: invalid}));
      }
    }
    expect(service.telemetry.acceptedStates, 0);
    link.receive(jsonEncode({'sequence': 1, 'btnZR': true}));
    expect(service.latestState.btnZR, isTrue);
    link.receive(jsonEncode({'sequence': 2}));
    expect(service.latestState.btnZR, isFalse);
  });

  test(
    'full compact object and bytes retain posture and shoulders; disconnect releases them',
    () async {
      for (final encodeBytes in [false, true]) {
        final frame = VrCompactGamepadFrame(
          sequence: encodeBytes ? 2 : 1,
          senderTimestampMicroseconds: 1000,
          orientation: vm.Quaternion.identity(),
          angularVelocity: vm.Vector3.zero(),
          pointerPoseReady: true,
          btnZL: !encodeBytes,
          btnZR: encodeBytes,
        );
        link.receive(
          encodeBytes ? const VrCompactGamepadCodec().encode(frame) : frame,
        );
        expect(service.latestState.pointerPoseReady, isTrue);
        expect(service.latestState.btnZL, !encodeBytes);
        expect(service.latestState.btnZR, encodeBytes);
        expect(service.latestState.isTriggerPressed, isFalse);
      }
      await link.close();
      expect(service.latestState.pointerPoseReady, isFalse);
      expect(service.latestState.btnZL, isFalse);
      expect(service.latestState.btnZR, isFalse);
      expect(service.latestState.isNeutralized, isTrue);
    },
  );

  test(
    'HUD and passthrough copies preserve live posture; safety and voice clear it',
    () {
      link.receive(jsonEncode({'sequence': 1, 'pointerPoseReady': true}));
      service.setSpatialHudVisible(true);
      expect(service.latestState.pointerPoseReady, isTrue);
      service.setPassthroughMix(.25);
      expect(service.latestState.pointerPoseReady, isTrue);
      service.setSystemOverlayCapture(true);
      expect(service.latestState.pointerPoseReady, isFalse);
      service.setSystemOverlayCapture(false);
      link.receive(jsonEncode({'sequence': 2, 'pointerPoseReady': true}));
      expect(service.latestState.pointerPoseReady, isTrue);
      service.pulsePrimarySelect();
      expect(service.latestState.pointerPoseReady, isFalse);
    },
  );

  test('input watchdog clears previously qualified physical posture', () async {
    link.receive(jsonEncode({'sequence': 1, 'pointerPoseReady': true}));
    expect(service.latestState.pointerPoseReady, isTrue);
    nowUs = 25000;
    await _waitUntil(() => service.latestState.isNeutralized);
    expect(service.latestState.pointerPoseReady, isFalse);
  });

  test(
    'nonidentity button mapping preserves posture and neutralization metadata',
    () {
      final source = RemoteControllerState(
        orientation: vm.Quaternion.identity(),
        pointerPoseReady: true,
        btnA: true,
      );
      final mapped = const VrButtonMapping(
        swapConfirmCancel: true,
      ).applyToState(source);
      expect(mapped.btnB, isTrue);
      expect(mapped.pointerPoseReady, isTrue);
      expect(mapped.isNeutralized, isFalse);
    },
  );

  test('posture entry and exit bypass BLE and Wi-Fi analog pacing', () {
    for (final bluetooth in [false, true]) {
      final pacer = VrControllerStatePacer();
      expect(
        pacer.shouldSend(
          {'pointerPoseReady': false},
          nowUs: 0,
          bluetooth: bluetooth,
        ),
        isTrue,
      );
      expect(
        pacer.shouldSend(
          {'pointerPoseReady': true},
          nowUs: 1000,
          bluetooth: bluetooth,
        ),
        isTrue,
      );
      expect(
        pacer.shouldSend(
          {'pointerPoseReady': false},
          nowUs: 2000,
          bluetooth: bluetooth,
        ),
        isTrue,
      );
      expect(
        pacer.shouldSend(
          {'pointerPoseReady': false},
          nowUs: 2500,
          bluetooth: bluetooth,
        ),
        isFalse,
      );
    }
  });
}
