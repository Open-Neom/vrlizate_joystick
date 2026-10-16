import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

/// Transport-independent link: the BLE bridge feeds the same authenticated
/// service entry point, without opening an HTTP server or a controller UI.
class _NesLink implements VrControllerLink {
  final inbound = StreamController<Object?>();
  final sent = <Object>[];
  var open = true;
  @override
  Stream<Object?> get messages => inbound.stream;
  @override
  bool get isOpen => open;
  @override
  void add(Object data) => sent.add(data);
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!open) return;
    open = false;
    unawaited(inbound.close());
  }
}

Future<void> _until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('NES protocol condition timed out.');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VrRemoteControllerService service;
  late _NesLink link;
  var sequence = 0;
  const actions = {
    'A': 'A',
    'X': 'B',
    'Y': 'Start',
    'L': 'Select',
    'B': 'Home',
  };

  VrControllerModeRequest request() =>
      VrControllerModeRequest.tryParse(link.sent.last)!;

  Future<void> send(
    Map<String, Object> fields, {
    int? revision,
    String mode = 'nes',
    bool legacy = false,
  }) async {
    final before =
        service.telemetry.acceptedStates + service.telemetry.rejectedStates;
    link.inbound.add(
      jsonEncode({
        'sequence': sequence++,
        'mode': mode,
        if (!legacy) 'hostModeRevision': revision ?? request().revision,
        ...fields,
      }),
    );
    await _until(
      () =>
          service.telemetry.acceptedStates + service.telemetry.rejectedStates >
          before,
    );
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    service = VrRemoteControllerService(
      inputTimeout: const Duration(seconds: 3),
    );
    service.requestControllerMode(RemoteControllerMode.nes, actions: actions);
    link = _NesLink();
    sequence = 0;
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

  test(
    'NES request requires the current revision and a neutral first state',
    () async {
      expect(service.isRunning, isFalse);
      expect(service.recommendedMode, RemoteControllerMode.nes);
      expect(request().mode, RemoteControllerMode.nes);
      expect(request().actions, actions);
      await send({}, revision: request().revision - 1);
      await send({}, mode: 'joystick');
      await send({'btnX': true});
      await send({'stickY': 1});
      expect(service.telemetry.rejectedStates, 4);
      expect(service.latestState.isNeutralized, isTrue);
      await send({});
      expect(service.latestState.mode, RemoteControllerMode.nes);
      expect(service.latestState.isNeutralized, isFalse);
      expect(service.latestState.btnA, isFalse);
      expect(service.latestState.btnX, isFalse);
      expect(service.latestState.stickY, 0);
    },
  );

  test(
    'NES visible B uses btnX while Home alone uses btnB and action',
    () async {
      await send({});
      for (final field in ['btnA', 'btnX', 'btnY', 'btnL', 'btnB']) {
        await send({field: true});
        final state = service.latestState;
        expect(state.mode, RemoteControllerMode.nes);
        expect(state.btnA, field == 'btnA');
        expect(state.btnX, field == 'btnX');
        expect(state.btnY, field == 'btnY');
        expect(state.btnL, field == 'btnL');
        expect(state.btnB, field == 'btnB');
        expect(state.isActionPressed, field == 'btnB');
        expect(state.isTriggerPressed, isFalse);
        expect(state.btnR, isFalse);
        expect(state.btnGrip, isFalse);
        expect(state.steering, 0);
        expect(state.throttle, 0);
        expect(state.brake, 0);
        await send({});
        expect(
          service.latestState.btnA ||
              service.latestState.btnX ||
              service.latestState.btnY ||
              service.latestState.btnL ||
              service.latestState.btnB,
          isFalse,
        );
      }
    },
  );

  test(
    'NES D-pad preserves digital diagonals and positive Y means up',
    () async {
      await send({});
      for (final (x, y) in [
        (0, 1),
        (0, -1),
        (-1, 0),
        (1, 0),
        (-1, 1),
        (1, 1),
        (-1, -1),
        (1, -1),
        (0, 0),
      ]) {
        await send({'stickX': x, 'stickY': y});
        expect(service.latestState.stickX, x);
        expect(service.latestState.stickY, y);
        expect(service.latestState.touchX, x);
        expect(service.latestState.touchY, y);
        expect(service.latestState.turnRate, 0);
        expect(service.latestState.pitchRate, 0);
      }
    },
  );

  test(
    'leaving NES releases held buttons and rejects queued old states',
    () async {
      await send({});
      final previousRevision = request().revision;
      await send({'btnX': true, 'btnY': true, 'stickX': 1});
      service.requestControllerMode(RemoteControllerMode.joystick);
      expect(service.latestState.isNeutralized, isTrue);
      expect(service.latestState.btnX, isFalse);
      expect(service.latestState.btnY, isFalse);
      expect(service.latestState.stickX, 0);
      await send({'btnX': true}, revision: previousRevision);
      await send({'btnA': true}, mode: 'joystick');
      expect(service.telemetry.rejectedStates, 2);
      await send({}, mode: 'joystick');
      expect(service.latestState.mode, RemoteControllerMode.joystick);
      expect(service.latestState.isNeutralized, isFalse);
      await send({'btnA': true}, mode: 'joystick');
      expect(service.latestState.btnA, isTrue);
    },
  );

  test(
    'NES captions can change without remapping or releasing held B',
    () async {
      await send({});
      await send({'btnX': true});
      service.requestControllerMode(
        RemoteControllerMode.nes,
        actions: {...actions, 'X': 'Disparo'},
      );
      expect(service.latestState.isNeutralized, isFalse);
      expect(service.latestState.btnX, isTrue);
      await send({'btnX': true});
      expect(service.telemetry.rejectedStates, 0);
      expect(service.latestState.btnX, isTrue);
      expect(service.latestState.btnB, isFalse);
    },
  );

  test(
    'reconnect resends NES and requires release even after caption update',
    () async {
      await send({});
      await send({'btnX': true, 'stickY': 1});
      service.requestControllerMode(
        RemoteControllerMode.nes,
        actions: {...actions, 'X': 'Disparo'},
      );
      final revision = request().revision;
      await link.close();
      await _until(() => !service.isConnected);
      expect(service.latestState.mode, RemoteControllerMode.nes);
      expect(service.latestState.isNeutralized, isTrue);
      expect(service.latestState.btnX, isFalse);
      expect(service.latestState.stickY, 0);
      link = _NesLink();
      sequence = 0;
      expect(
        service.attachControllerLink(link, sessionToken: service.sessionToken),
        isTrue,
      );
      expect(request().mode, RemoteControllerMode.nes);
      expect(request().revision, revision);
      await send({'btnX': true, 'stickY': 1});
      expect(service.latestState.isNeutralized, isTrue);
      expect(service.telemetry.rejectedStates, 1);
      await send({});
      expect(service.latestState.isNeutralized, isFalse);
      expect(service.latestState.mode, RemoteControllerMode.nes);
    },
  );

  test(
    'legacy joystick states remain compatible until opting into the host ACK',
    () async {
      await send({'btnX': true}, mode: 'joystick', legacy: true);
      expect(service.latestState.mode, RemoteControllerMode.joystick);
      expect(service.latestState.btnX, isTrue);
      await send({});
      expect(service.latestState.mode, RemoteControllerMode.nes);
      await send({'btnX': true}, mode: 'joystick', legacy: true);
      expect(service.latestState.mode, RemoteControllerMode.nes);
      expect(service.latestState.btnX, isFalse);
      expect(service.telemetry.rejectedStates, 1);
    },
  );
}
