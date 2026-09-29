import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _RealHttp extends HttpOverrides {}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Host mode handshake timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VrRemoteControllerService service;
  final sockets = <WebSocket>[];
  final messages = <VrControllerModeRequest>[];
  final states = <RemoteControllerState>[];

  Future<WebSocket> connect() async {
    final count = messages.length;
    final socket = await HttpOverrides.runWithHttpOverrides(
      () => WebSocket.connect(
        Uri(
          scheme: 'ws',
          host: '127.0.0.1',
          port: service.serverPort!,
          queryParameters: {'token': service.sessionToken},
        ).toString(),
      ),
      _RealHttp(),
    );
    sockets.add(socket);
    socket.listen((wire) {
      final request = VrControllerModeRequest.tryParse(wire);
      if (request != null) messages.add(request);
    });
    await _until(() => messages.length > count);
    return socket;
  }

  void send(
    WebSocket socket,
    int sequence,
    int revision,
    String mode, {
    bool pressed = false,
    bool paused = false,
  }) {
    socket.add(
      jsonEncode({
        'sequence': sequence,
        'hostModeRevision': revision,
        'mode': mode,
        'btnA': mode == 'joystick' && pressed,
        'btnR': mode == 'driving' && pressed,
        'throttle': mode == 'driving' && pressed ? 1 : 0,
        'drivingPaused': paused,
      }),
    );
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    service = VrRemoteControllerService(
      inputTimeout: const Duration(seconds: 3),
    );
    service.onState.listen(states.add);
    expect(await service.startServer(port: 0), isTrue);
  });

  tearDown(() async {
    service.dispose();
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    messages.clear();
    states.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test(
    'connection receives joystick by default; app mode request is authenticated and retained',
    () async {
      final socket = await connect();
      expect(messages.single.mode, RemoteControllerMode.joystick);
      expect(messages.single.revision, 0);
      send(socket, 0, 0, 'joystick');
      await _until(() => !service.latestState.isNeutralized);
      service.requestControllerMode(RemoteControllerMode.driving);
      await _until(() => messages.length == 2);
      expect(messages.last.mode, RemoteControllerMode.driving);
      expect(messages.last.revision, 1);
      expect(service.recommendedMode, RemoteControllerMode.driving);
      expect(service.latestState.isNeutralized, isTrue);
      service.requestControllerMode(RemoteControllerMode.driving);
      expect(
        () => service.requestControllerMode(RemoteControllerMode.laser),
        throwsArgumentError,
      );
    },
  );

  test('caption-only request relabels without releasing held inputs', () async {
    final socket = await connect();
    send(socket, 0, 0, 'joystick');
    await _until(() => !service.latestState.isNeutralized);
    send(socket, 1, 0, 'joystick', pressed: true);
    await _until(() => service.latestState.btnA);
    service.requestControllerMode(
      RemoteControllerMode.joystick,
      actions: const {'A': 'Disparar', 'X': 'Cambiar arma'},
    );
    await _until(() => messages.length == 2);
    expect(messages.last.mode, RemoteControllerMode.joystick);
    expect(messages.last.revision, 1);
    expect(messages.last.actions, {'A': 'Disparar', 'X': 'Cambiar arma'});
    // Same layout: the host keeps the live state instead of neutralizing.
    expect(service.latestState.isNeutralized, isFalse);
    expect(service.latestState.btnA, isTrue);
    final acceptedBeforeAck = service.telemetry.acceptedStates;
    send(socket, 2, 1, 'joystick', pressed: true);
    await _until(
      () => service.telemetry.acceptedStates == acceptedBeforeAck + 1,
    );
    expect(service.latestState.btnA, isTrue);
    // Queued state from before the relabel cannot override the new revision.
    final rejectedBeforeStale = service.telemetry.rejectedStates;
    send(socket, 3, 0, 'joystick');
    await _until(
      () => service.telemetry.rejectedStates == rejectedBeforeStale + 1,
    );
    expect(service.latestState.btnA, isTrue);
    send(socket, 4, 1, 'joystick');
    await _until(() => !service.latestState.btnA);
    send(socket, 5, 1, 'joystick', pressed: true);
    await _until(() => service.latestState.btnA);
    // Identical captions again: nothing new on the wire.
    service.requestControllerMode(
      RemoteControllerMode.joystick,
      actions: const {'X': 'Cambiar arma', 'A': 'Disparar'},
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(messages.length, 2);
    // A layout change still releases inputs, captions included.
    service.requestControllerMode(
      RemoteControllerMode.driving,
      actions: const {'B': 'Salir del coche'},
    );
    await _until(() => messages.length == 3);
    expect(messages.last.revision, 2);
    expect(messages.last.actions, {'B': 'Salir del coche'});
    expect(service.latestState.isNeutralized, isTrue);
  });

  test('driving caption ACK preserves a held pedal on the same link', () async {
    service.requestControllerMode(RemoteControllerMode.driving);
    final socket = await connect();
    send(socket, 0, 1, 'driving');
    await _until(() => !service.latestState.isNeutralized);
    send(socket, 1, 1, 'driving', pressed: true);
    await _until(() => service.latestState.throttle == 1);
    service.requestControllerMode(
      RemoteControllerMode.driving,
      actions: const {'R': 'Accelerate'},
    );
    await _until(() => messages.length == 2);
    final acceptedBeforeAck = service.telemetry.acceptedStates;
    send(socket, 2, 2, 'driving', pressed: true);
    await _until(
      () => service.telemetry.acceptedStates == acceptedBeforeAck + 1,
    );
    expect(service.latestState.throttle, 1);
    expect(service.latestState.btnR, isTrue);
  });

  test('initial caption request still needs a neutral ACK', () async {
    service.requestControllerMode(
      RemoteControllerMode.joystick,
      actions: const {'A': 'Fire'},
    );
    final socket = await connect();
    send(socket, 0, 1, 'joystick', pressed: true);
    await _until(() => service.telemetry.rejectedStates == 1);
    expect(service.latestState.isNeutralized, isTrue);
    send(socket, 1, 1, 'joystick');
    await _until(() => !service.latestState.isNeutralized);
    expect(service.latestState.btnA, isFalse);
  });

  test('caption update before a mode ACK does not bypass neutral', () async {
    final socket = await connect();
    send(socket, 0, 0, 'joystick');
    await _until(() => !service.latestState.isNeutralized);
    service.requestControllerMode(RemoteControllerMode.driving);
    service.requestControllerMode(
      RemoteControllerMode.driving,
      actions: const {'R': 'Accelerate'},
    );
    await _until(() => messages.length == 3);
    send(socket, 1, 2, 'driving', pressed: true);
    await _until(() => service.telemetry.rejectedStates == 1);
    expect(service.latestState.isNeutralized, isTrue);
    send(socket, 2, 2, 'driving');
    await _until(() => !service.latestState.isNeutralized);
    expect(service.latestState.throttle, 0);
  });

  test('reconnecting invalidates a pending held caption ACK', () async {
    service.requestControllerMode(RemoteControllerMode.driving);
    var socket = await connect();
    send(socket, 0, 1, 'driving');
    await _until(() => !service.latestState.isNeutralized);
    send(socket, 1, 1, 'driving', pressed: true);
    await _until(() => service.latestState.throttle == 1);
    service.requestControllerMode(
      RemoteControllerMode.driving,
      actions: const {'R': 'Accelerate'},
    );
    await _until(() => messages.length == 2);
    await socket.close();
    await _until(() => !service.isConnected);
    socket = await connect();
    expect(messages.last.revision, 2);
    final rejectedBeforeAck = service.telemetry.rejectedStates;
    send(socket, 0, 2, 'driving', pressed: true);
    await _until(
      () => service.telemetry.rejectedStates == rejectedBeforeAck + 1,
    );
    expect(service.latestState.isNeutralized, isTrue);
    expect(service.latestState.throttle, 0);
    send(socket, 1, 2, 'driving');
    await _until(() => !service.latestState.isNeutralized);
    send(socket, 2, 2, 'driving', pressed: true);
    await _until(() => service.latestState.throttle == 1);
  });

  test('caption request after a manual layout change needs neutral', () async {
    final socket = await connect();
    send(socket, 0, 0, 'joystick');
    await _until(() => !service.latestState.isNeutralized);
    send(socket, 1, 0, 'driving', pressed: true);
    await _until(() => service.latestState.throttle == 1);
    service.requestControllerMode(
      RemoteControllerMode.joystick,
      actions: const {'A': 'Fire'},
    );
    await _until(() => messages.length == 2);
    send(socket, 2, 1, 'joystick', pressed: true);
    await _until(() => service.telemetry.rejectedStates == 1);
    expect(service.latestState.btnA, isFalse);
    send(socket, 3, 1, 'joystick');
    await _until(
      () => service.latestState.mode == RemoteControllerMode.joystick,
    );
    expect(service.latestState.btnA, isFalse);
  });

  test(
    'Riviera enter/exit rejects stale and held ACK until neutral without auto-accelerating',
    () async {
      final socket = await connect();
      send(socket, 0, 0, 'joystick');
      await _until(() => !service.latestState.isNeutralized);
      service.requestControllerMode(RemoteControllerMode.driving);
      await _until(() => messages.length == 2);
      send(socket, 1, 1, 'driving');
      await _until(
        () =>
            service.latestState.mode == RemoteControllerMode.driving &&
            !service.latestState.isNeutralized,
      );
      expect(service.latestState.drivingPaused, isFalse);
      expect(service.latestState.throttle, 0);
      send(socket, 2, 1, 'driving', pressed: true);
      await _until(() => service.latestState.throttle == 1);
      service.requestControllerMode(RemoteControllerMode.joystick);
      await _until(() => messages.length == 3);
      final stateStart = states.length;
      send(socket, 3, 1, 'driving', pressed: true); // queued old-layout pedal
      send(
        socket,
        4,
        2,
        'joystick',
        pressed: true,
      ); // new revision, old held finger
      send(socket, 5, 2, 'joystick');
      await _until(
        () =>
            service.latestState.mode == RemoteControllerMode.joystick &&
            !service.latestState.isNeutralized,
      );
      expect(
        states
            .skip(stateStart)
            .every(
              (state) =>
                  !state.btnA && !state.isTriggerPressed && state.throttle == 0,
            ),
        isTrue,
      );
      send(
        socket,
        6,
        2,
        'joystick',
        pressed: true,
      ); // genuine new press after release
      await _until(() => service.latestState.btnA);
    },
  );

  test('ready driving ACK still rejects a held stick before neutral', () async {
    service.requestControllerMode(RemoteControllerMode.driving);
    final socket = await connect();
    socket.add(
      jsonEncode({
        'sequence': 0,
        'hostModeRevision': 1,
        'mode': 'driving',
        'drivingPaused': false,
        'stickY': 1,
      }),
    );
    send(socket, 1, 1, 'driving');
    await _until(() => !service.latestState.isNeutralized);
    expect(service.latestState.drivingPaused, isFalse);
    expect(service.latestState.stickY, 0);
    expect(states.every((state) => state.stickY == 0), isTrue);
  });

  test(
    'reconnect resends current driving request and requires a fresh paused ACK',
    () async {
      service.requestControllerMode(RemoteControllerMode.driving);
      var socket = await connect();
      send(socket, 0, 1, 'driving', paused: true);
      await _until(() => !service.latestState.isNeutralized);
      send(socket, 1, 1, 'driving', pressed: true);
      await _until(() => service.latestState.throttle == 1);
      await socket.close();
      await _until(() => !service.isConnected);
      socket = await connect();
      expect(messages.last.mode, RemoteControllerMode.driving);
      expect(messages.last.revision, 1);
      final stateStart = states.length;
      send(socket, 0, 1, 'driving', pressed: true);
      send(socket, 1, 1, 'driving', paused: true);
      await _until(() => !service.latestState.isNeutralized);
      expect(
        states
            .skip(stateStart)
            .every((state) => state.throttle == 0 && !state.btnR),
        isTrue,
      );
      expect(service.latestState.drivingPaused, isTrue);
    },
  );

  test(
    'acknowledged client can switch manually, legacy laser wire stays readable',
    () async {
      final socket = await connect();
      socket.add(jsonEncode({'sequence': 0, 'mode': 'laser', 'btnA': true}));
      await _until(() => service.latestState.btnA);
      expect(service.latestState.mode, RemoteControllerMode.laser);
      send(socket, 1, 0, 'joystick');
      await _until(() => !service.latestState.btnA);
      send(socket, 2, 0, 'driving', paused: true);
      await _until(
        () => service.latestState.mode == RemoteControllerMode.driving,
      );
      expect(service.recommendedMode, RemoteControllerMode.joystick);
    },
  );
}
