import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _RealHttpOverrides extends HttpOverrides {}

Uint8List binaryPose(int sequence, {int buttons = 0, double? x, double? y}) =>
    const VrRemoteBinaryCodec().encodePose(
      VrRemotePoseFrame(
        sequence: sequence,
        senderTimestampMicroseconds: sequence * 16000,
        orientation: vm.Quaternion.identity(),
        buttonsBitset: buttons,
        touchX: x,
        touchY: y,
      ),
    );

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

  test(
    'controller visibility survives timeout and repeats without toggling',
    () async {
      final socket = await connect();
      expect(service.latestState.controllerVisible, isTrue);
      socket.add(
        jsonEncode({'sequence': 1, 'controllerVisible': false, 'btnA': true}),
      );
      await waitUntil(() => service.latestState.btnA);
      expect(service.latestState.controllerVisible, isFalse);
      socket.add(jsonEncode({'sequence': 2, 'controllerVisible': false}));
      await waitUntil(() => !service.latestState.btnA);
      expect(service.latestState.controllerVisible, isFalse);
      await waitUntil(() => service.latestState.isNeutralized);
      expect(service.latestState.controllerVisible, isFalse);
      socket.add(jsonEncode({'sequence': 3, 'controllerVisible': false}));
      await waitUntil(() => !service.latestState.isNeutralized);
      expect(service.latestState.controllerVisible, isFalse);
      socket.add(jsonEncode({'sequence': 4, 'controllerVisible': true}));
      await waitUntil(() => service.latestState.controllerVisible);
    },
  );

  test(
    'visibility validates boolean strictly and ignores stale snapshots',
    () async {
      final socket = await connect();
      for (final value in [null, 0, 1, 'false', <Object>[]]) {
        socket.add(
          jsonEncode({'sequence': 1, 'controllerVisible': value, 'btnA': true}),
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(service.latestState.btnA, isFalse);
      expect(service.latestState.controllerVisible, isTrue);
      socket.add(jsonEncode({'sequence': 2, 'controllerVisible': false}));
      await waitUntil(() => !service.latestState.controllerVisible);
      socket.add(jsonEncode({'sequence': 1, 'controllerVisible': true}));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(service.latestState.controllerVisible, isFalse);
    },
  );

  test(
    'new controller resets visibility while legacy snapshots default visible',
    () async {
      final first = await connect();
      first.add(jsonEncode({'sequence': 1, 'controllerVisible': false}));
      await waitUntil(() => !service.latestState.controllerVisible);
      await first.close();
      await waitUntil(() => !service.isConnected);
      expect(service.latestState.controllerVisible, isFalse);
      final second = await connect();
      expect(service.latestState.controllerVisible, isTrue);
      second.add(jsonEncode({'sequence': 1, 'btnA': true}));
      await waitUntil(() => service.latestState.btnA);
      expect(service.latestState.controllerVisible, isTrue);
      second.add(jsonEncode({'sequence': 2, 'controllerVisible': false}));
      await waitUntil(() => !service.latestState.controllerVisible);
    },
  );

  test('publishes the bound port and a per-service random pairing secret', () {
    final url = Uri.parse(service.serverUrl!);
    expect(url.port, service.serverPort);
    expect(url.queryParameters['token'], service.sessionToken);
    expect(base64Url.decode(service.sessionToken), hasLength(24));
    final other = VrRemoteControllerService();
    expect(other.sessionToken, isNot(service.sessionToken));
    other.dispose();
  });

  test(
    'driving JSON preserves axes, clamps ranges and neutralizes on pause',
    () async {
      final socket = await connect();
      socket.add(
        jsonEncode({
          'sequence': 0,
          'mode': 'driving',
          'steering': -0.7,
          'throttle': 0.6,
          'brake': 0.2,
          'motionAvailable': true,
          'btnR': true,
          'btnL': true,
        }),
      );
      await waitUntil(
        () => service.latestState.mode == RemoteControllerMode.driving,
      );
      expect(service.latestState.steering, -0.7);
      expect(service.latestState.throttle, 0.6);
      expect(service.latestState.brake, 0.2);
      expect(service.latestState.motionAvailable, isTrue);
      expect(service.latestState.btnA, isFalse);
      expect(service.latestState.btnR && service.latestState.btnL, isTrue);
      socket.add(
        jsonEncode({
          'sequence': 1,
          'mode': 'driving',
          'steering': 3,
          'throttle': 2,
          'brake': -1,
        }),
      );
      await waitUntil(() => service.latestState.steering == 1);
      expect(service.latestState.throttle, 1);
      expect(service.latestState.brake, 0);
      socket.add(
        jsonEncode({
          'sequence': 2,
          'mode': 'driving',
          'drivingPaused': true,
          'steering': 1,
          'throttle': 1,
          'brake': 1,
        }),
      );
      await waitUntil(() => service.latestState.drivingPaused);
      expect(service.latestState.steering, 0);
      expect(service.latestState.throttle, 0);
      expect(service.latestState.brake, 0);
    },
  );

  test(
    'driving timeout releases pedals and legacy states default to zero',
    () async {
      final socket = await connect();
      socket.add(jsonEncode({'sequence': 0, 'mode': 'driving', 'throttle': 1}));
      await waitUntil(() => service.latestState.throttle == 1);
      await waitUntil(() => service.latestState.drivingPaused);
      expect(service.latestState.throttle, 0);
      socket.add(
        jsonEncode({'sequence': 1, 'btnA': true, 'steering': 1, 'throttle': 1}),
      );
      await waitUntil(() => service.latestState.btnA);
      expect(service.latestState.mode, RemoteControllerMode.joystick);
      expect(service.latestState.steering, 0);
      expect(service.latestState.throttle, 0);
      expect(service.latestState.drivingPaused, isFalse);
      expect(service.latestState.motionAvailable, isFalse);
    },
  );

  test(
    'malformed driving fields cannot mutate accepted state or sequence',
    () async {
      final socket = await connect();
      socket.add(
        jsonEncode({'sequence': 0, 'mode': 'driving', 'steering': 0.4}),
      );
      await waitUntil(() => service.latestState.steering == 0.4);
      for (final invalid in [
        '"steering":1e400',
        '"throttle":"1"',
        '"brake":false',
        '"drivingPaused":1',
        '"motionAvailable":"true"',
      ]) {
        socket.add('{"sequence":1,"mode":"driving",$invalid}');
      }
      // Same sequence remains legal only if every preceding malformed frame
      // was rejected before mutating the accepted sequence.
      socket.add(
        jsonEncode({'sequence': 1, 'mode': 'driving', 'steering': -0.4}),
      );
      await waitUntil(() => service.latestState.steering == -0.4);
      expect(service.latestState.throttle, 0);
      expect(service.latestState.brake, 0);
    },
  );

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
        'laserX': 0.35,
        'laserY': -0.75,
        'laserSlideActive': true,
        'recenter': true,
      }),
    );
    await waitUntil(() => service.latestState.turnRate == 0.65);
    expect(service.latestState.stickX, -0.5);
    expect(service.latestState.stickY, 0.8);
    expect(service.latestState.turnRate, 0.65);
    expect(service.latestState.pitchRate, -0.4);
    expect(service.latestState.laserX, 0.35);
    expect(service.latestState.laserY, -0.75);
    expect(service.latestState.laserSlideActive, isTrue);
    expect(service.latestState.recenter, isTrue);

    // Alternative packet keys (lookX / lookY / aimX / aimY)
    socket.add(
      jsonEncode({
        'sequence': 2,
        'lookX': 0.25,
        'lookY': 0.5,
        'aimX': -0.15,
        'aimY': 0.9,
        'recenter': false,
      }),
    );
    await waitUntil(() => service.latestState.turnRate == 0.25);
    expect(service.latestState.turnRate, 0.25);
    expect(service.latestState.pitchRate, 0.5);
    expect(service.latestState.laserX, -0.15);
    expect(service.latestState.laserY, 0.9);
    expect(service.latestState.recenter, isFalse);
    expect(service.latestState.laserSlideActive, isFalse);
  });

  test('A, L, R and explicit trigger remain independent', () async {
    final socket = await connect();
    socket.add(jsonEncode({'sequence': 0, 'btnL': true}));
    await waitUntil(() => service.latestState.btnL);
    expect(service.latestState.btnA, isFalse);
    expect(service.latestState.isTriggerPressed, isFalse);

    socket.add(jsonEncode({'sequence': 1, 'btnR': true}));
    await waitUntil(() => service.latestState.btnR);
    expect(service.latestState.btnA, isFalse);
    expect(service.latestState.btnL, isFalse);
    expect(service.latestState.isTriggerPressed, isTrue);

    socket.add(jsonEncode({'sequence': 2, 'btnA': true}));
    await waitUntil(() => service.latestState.btnA);
    expect(service.latestState.btnR, isFalse);
    expect(service.latestState.isTriggerPressed, isFalse);

    socket.add(jsonEncode({'sequence': 3, 'trigger': true}));
    await waitUntil(() => service.latestState.isTriggerPressed);
    expect(service.latestState.btnA, isFalse);
    expect(service.latestState.btnR, isFalse);
  });

  test('new axes and aliases reject nonfinite and nonnumeric values', () async {
    final received = <RemoteControllerState>[];
    final subscription = service.onState.listen(received.add);
    addTearDown(subscription.cancel);
    final socket = await connect();
    socket.add(jsonEncode({'sequence': 0}));
    for (final key in [
      'turn',
      'turnRate',
      'lookX',
      'pitchRate',
      'lookPitch',
      'lookY',
      'laserX',
      'laserY',
      'aimX',
      'aimY',
    ]) {
      for (final invalid in ['1e999', '-1e999', '"invalid"', 'true']) {
        socket.add('{"sequence":1,"$key":$invalid,"btnA":true}');
      }
    }
    for (final invalid in ['null', '1', '"true"']) {
      socket.add('{"sequence":1,"laserSlideActive":$invalid,"btnA":true}');
    }
    socket.add(jsonEncode({'sequence': 1, 'btnGrip': true}));
    await waitUntil(() => service.latestState.btnGrip);
    expect(received.any((state) => state.btnA), isFalse);
  });

  test(
    'watchdog releases the active center pad, buttons, and both sticks',
    () async {
      final socket = await connect();
      socket.add(
        jsonEncode({
          'sequence': 0,
          'laserSlideActive': true,
          'btnL': true,
          'btnR': true,
          'btnX': true,
          'btnY': true,
          'stickX': 0.8,
          'lookX': -0.6,
        }),
      );
      await waitUntil(() => service.latestState.laserSlideActive);
      expect(service.latestState.laserX, 0);
      await waitUntil(() => !service.latestState.laserSlideActive);
      final neutral = service.latestState;
      expect(
        neutral.btnL || neutral.btnR || neutral.btnX || neutral.btnY,
        isFalse,
      );
      expect(neutral.isTriggerPressed, isFalse);
      expect(neutral.stickX, 0);
      expect(neutral.lookX, 0);
    },
  );

  test(
    'binary pose preserves full stick endpoints and trigger is not A',
    () async {
      final socket = await connect();
      socket.add(binaryPose(0, buttons: 1, x: 1.0, y: 0.5));
      await waitUntil(() => service.latestState.isTriggerPressed);
      expect(service.latestState.btnA, isFalse);
      expect(service.latestState.stickX, 1.0);
      expect(service.latestState.stickY, 0);
      expect(service.latestState.mode, RemoteControllerMode.joystick);
      expect(service.latestState.laserSlideActive, isFalse);
      socket.add(binaryPose(1, buttons: 4, x: 1.0, y: 1.0));
      await waitUntil(() => service.latestState.btnA);
      expect(service.latestState.isTriggerPressed, isFalse);
      expect(service.latestState.stickX, 1.0);
      expect(service.latestState.stickY, 1.0);
      socket.add(binaryPose(2, buttons: 16));
      await waitUntil(() => service.latestState.btnGrip);
      expect(service.latestState.stickX, 0);
      expect(service.latestState.stickY, 0);
    },
  );

  test(
    'binary wrap accepts release and rejects stale and duplicate frames',
    () async {
      final socket = await connect();
      socket.add(binaryPose(65535, buttons: 1));
      await waitUntil(() => service.latestState.isTriggerPressed);
      socket.add(binaryPose(65536));
      await waitUntil(() => !service.latestState.isTriggerPressed);
      final received = <RemoteControllerState>[];
      final subscription = service.onState.listen(received.add);
      addTearDown(subscription.cancel);
      for (final sequence in [65536, 65535, 32768]) {
        socket.add(binaryPose(sequence, buttons: 4));
      }
      socket.add(binaryPose(65537, buttons: 16));
      await waitUntil(() => service.latestState.btnGrip);
      expect(received.any((state) => state.btnA), isFalse);
      expect(service.isConnected, isTrue);
    },
  );

  test('oversized binary pose closes the socket and releases input', () async {
    final socket = await connect();
    socket.add(binaryPose(0, buttons: 1));
    await waitUntil(() => service.latestState.isTriggerPressed);
    socket.add(Uint8List(8192)..setRange(0, 28, binaryPose(1, buttons: 1)));
    await waitUntil(() => !service.isConnected);
    expect(service.latestState.isTriggerPressed, isFalse);
  });

  test(
    'a connection cannot switch format to reset replay protection',
    () async {
      final received = <RemoteControllerState>[];
      final subscription = service.onState.listen(received.add);
      addTearDown(subscription.cancel);
      final socket = await connect();
      socket.add(binaryPose(0, buttons: 16));
      await waitUntil(() => service.latestState.btnGrip);
      socket.add(jsonEncode({'sequence': 100, 'btnA': true}));
      socket.add(binaryPose(1, buttons: 8));
      await waitUntil(() => service.latestState.btnB);
      expect(received.any((state) => state.btnA), isFalse);

      final replacement = await connect();
      replacement.add(jsonEncode({'sequence': 0, 'btnX': true}));
      await waitUntil(() => service.latestState.btnX);
      replacement.add(binaryPose(1, buttons: 4));
      replacement.add(jsonEncode({'sequence': 1, 'btnY': true}));
      await waitUntil(() => service.latestState.btnY);
      expect(received.any((state) => state.btnA), isFalse);
    },
  );
}
