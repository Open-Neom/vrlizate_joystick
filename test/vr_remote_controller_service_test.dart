import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _RealHttpOverrides extends HttpOverrides {}

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the controller state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VrRemoteControllerService service;
  final sockets = <WebSocket>[];

  Uri endpoint({String? token}) => Uri(
    scheme: 'ws',
    host: '127.0.0.1',
    port: service.serverPort!,
    queryParameters: token == null ? null : {'token': token},
  );

  Future<WebSocket> connect() async {
    // Flutter's widget binding replaces HttpClient; these are real loopback
    // protocol tests, so restore the normal client just for the connection.
    final socket = await HttpOverrides.runWithHttpOverrides(
      () => WebSocket.connect(endpoint(token: service.sessionToken).toString()),
      _RealHttpOverrides(),
    );
    socket.listen((_) {});
    sockets.add(socket);
    await waitUntil(() => service.isConnected);
    return socket;
  }

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    service = VrRemoteControllerService(
      inputTimeout: const Duration(milliseconds: 200),
      watchdogInterval: const Duration(milliseconds: 10),
    );
    expect(await service.startServer(port: 0), isTrue);
  });

  tearDown(() async {
    service.dispose();
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('publishes the bound port and a per-service random pairing secret', () {
    final url = Uri.parse(service.serverUrl!);
    expect(url.port, service.serverPort);
    expect(url.queryParameters['token'], service.sessionToken);
    expect(base64Url.decode(service.sessionToken), hasLength(24));
    final other = VrRemoteControllerService();
    expect(other.sessionToken, isNot(service.sessionToken));
    other.dispose();
  });

  test('rejects missing and incorrect token before accepting input', () async {
    for (final token in [null, 'incorrect']) {
      await expectLater(
        HttpOverrides.runWithHttpOverrides(
          () => WebSocket.connect(endpoint(token: token).toString()),
          _RealHttpOverrides(),
        ),
        throwsA(isA<WebSocketException>()),
      );
    }
    expect(service.isConnected, isFalse);
    final socket = await connect();
    socket.add(jsonEncode({'sequence': 0, 'btnA': true, 'stickX': 2.0}));
    await waitUntil(() => service.latestState.btnA);
    expect(service.latestState.stickX, 1.0);
    expect(service.isConnected, isTrue);
  });

  test(
    'disconnect releases held buttons and locomotion and invalidates pose',
    () async {
      final socket = await connect();
      socket.add(
        jsonEncode({
          'sequence': 0,
          'btnA': true,
          'btnGrip': true,
          'stickY': 1.0,
        }),
      );
      await waitUntil(() => service.latestState.btnA);
      expect(service.predictOrientationTo(vm.Quaternion.identity()), isTrue);

      await socket.close();
      await waitUntil(() => !service.isConnected);
      expect(service.latestState.btnA, isFalse);
      expect(service.latestState.isTriggerPressed, isFalse);
      expect(service.latestState.btnGrip, isFalse);
      expect(service.latestState.stickY, 0.0);
      expect(service.predictOrientationTo(vm.Quaternion.identity()), isFalse);
    },
  );

  test(
    'silence neutralizes input even while the WebSocket stays open',
    () async {
      final socket = await connect();
      socket.add(jsonEncode({'sequence': 0, 'btnB': true, 'stickX': -1.0}));
      await waitUntil(() => service.latestState.btnB);
      await waitUntil(() => !service.latestState.btnB);
      expect(service.isConnected, isTrue);
      expect(service.latestState.stickX, 0.0);
      expect(service.predictOrientationTo(vm.Quaternion.identity()), isFalse);

      socket.add(jsonEncode({'sequence': 1, 'stickX': 0.5}));
      await waitUntil(() => service.latestState.stickX == 0.5);
    },
  );

  test(
    'a replacement socket accepts sequence zero and survives the old close',
    () async {
      final oldSocket = await connect();
      oldSocket.add(jsonEncode({'sequence': 100, 'btnA': true}));
      await waitUntil(() => service.latestState.btnA);
      final replacement = await connect();
      await waitUntil(() => !service.latestState.btnA);
      replacement.add(jsonEncode({'sequence': 0, 'btnB': true}));
      await waitUntil(() => service.latestState.btnB);
      await oldSocket.close();
      expect(service.isConnected, isTrue);
      expect(service.latestState.btnB, isTrue);
      replacement.add(
        jsonEncode({'sequence': 1, 'btnB': false, 'btnGrip': true}),
      );
      await waitUntil(() => service.latestState.btnGrip);
    },
  );

  test(
    'old and malformed packets cannot replay buttons or poison accepted state',
    () async {
      final received = <RemoteControllerState>[];
      final subscription = service.onState.listen(received.add);
      addTearDown(subscription.cancel);
      final socket = await connect();
      socket.add(jsonEncode({'sequence': 10, 'stickX': 0.25}));
      await waitUntil(() => service.latestState.stickX == 0.25);

      socket.add(jsonEncode({'sequence': 9, 'btnA': true}));
      socket.add(jsonEncode({'sequence': 10, 'btnA': true}));
      socket.add(jsonEncode({'btnA': true}));
      socket.add('{"sequence":11,"stickX":1e999,"btnA":true}');
      socket.add(jsonEncode({'sequence': 11, 'wx': 1e30, 'btnA': true}));
      socket.add(
        jsonEncode({
          'sequence': 11,
          'qx': 0,
          'qy': 0,
          'qz': 0,
          'qw': 0,
          'btnA': true,
        }),
      );
      socket.add(jsonEncode({'sequence': -1, 'btnA': true}));
      socket.add('[]');
      socket.add(jsonEncode({'sequence': 11, 'btnGrip': true, 'stickX': 0.75}));
      await waitUntil(() => service.latestState.btnGrip);
      expect(service.latestState.btnA, isFalse);
      expect(received.any((state) => state.btnA), isFalse);
      expect(service.latestState.stickX, 0.75);
      expect(service.latestState.orientation.length, closeTo(1, 1e-6));
    },
  );

  test(
    'oversized input disconnects and releases the active controller',
    () async {
      final socket = await connect();
      socket.add(jsonEncode({'sequence': 0, 'btnA': true}));
      await waitUntil(() => service.latestState.btnA);
      socket.add('x' * 4097);
      await waitUntil(() => !service.isConnected);
      expect(service.latestState.btnA, isFalse);
    },
  );

  test('packet floods are bounded and cannot leave movement active', () async {
    final socket = await connect();
    for (var sequence = 0; sequence < 241; sequence++) {
      socket.add(jsonEncode({'sequence': sequence, 'stickY': 1.0}));
    }
    await waitUntil(() => !service.isConnected);
    expect(service.latestState.stickY, 0.0);
  });

  test(
    'stop and disposal close active sockets without late stream writes',
    () async {
      final socket = await connect();
      socket.add(jsonEncode({'sequence': 0, 'btnA': true}));
      await waitUntil(() => service.latestState.btnA);
      service.stop();
      expect(service.latestState.btnA, isFalse);
      expect(service.isConnected, isFalse);
      expect(service.serverUrl, isNull);
      expect(service.serverPort, isNull);
      service.dispose();
      service.dispose();
      await socket.close();
      expect(await service.startServer(port: 0), isFalse);
    },
  );

  test(
    'stop during startup does not resurrect the listener or beacon',
    () async {
      final starting = VrRemoteControllerService();
      final start = starting.startServer(port: 0);
      starting.stop();
      expect(await start, isFalse);
      expect(starting.isRunning, isFalse);
      expect(starting.serverPort, isNull);
      starting.dispose();
    },
  );

  test('parses dual stick look yaw/pitch rates and recenter signals', () async {
    final socket = await connect();
    socket.add(
      jsonEncode({
        'sequence': 1,
        'stickX': -0.5,
        'stickY': 0.8,
        'turnRate': 0.65,
        'pitchRate': -0.4,
        'recenter': true,
      }),
    );
    await waitUntil(() => service.latestState.turnRate == 0.65);
    expect(service.latestState.stickX, -0.5);
    expect(service.latestState.stickY, 0.8);
    expect(service.latestState.turnRate, 0.65);
    expect(service.latestState.pitchRate, -0.4);
    expect(service.latestState.recenter, isTrue);

    // Alternative packet keys (lookX / lookY)
    socket.add(
      jsonEncode({
        'sequence': 2,
        'lookX': 0.25,
        'lookY': 0.5,
        'recenter': false,
      }),
    );
    await waitUntil(() => service.latestState.turnRate == 0.25);
    expect(service.latestState.turnRate, 0.25);
    expect(service.latestState.pitchRate, 0.5);
    expect(service.latestState.recenter, isFalse);
  });
}
