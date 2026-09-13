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

  test(
    'Riviera enter/exit rejects stale and held ACK until neutral without auto-accelerating',
    () async {
      final socket = await connect();
      send(socket, 0, 0, 'joystick');
      await _until(() => !service.latestState.isNeutralized);
      service.requestControllerMode(RemoteControllerMode.driving);
      await _until(() => messages.length == 2);
      send(socket, 1, 1, 'driving', paused: true);
      await _until(
        () =>
            service.latestState.mode == RemoteControllerMode.driving &&
            !service.latestState.isNeutralized,
      );
      expect(service.latestState.drivingPaused, isTrue);
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
