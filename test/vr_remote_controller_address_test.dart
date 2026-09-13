import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test(
    'refresh changes QR address without replacing token, port or client',
    () async {
      var candidates = const [
        VrLocalAddressCandidate('rmnet_data2', '10.22.29.53'),
        VrLocalAddressCandidate('wlan0', '192.168.100.12'),
      ];
      final service = VrRemoteControllerService(
        localAddressCandidates: () async => candidates,
      );
      addTearDown(service.dispose);
      expect(await service.startServer(port: 0), isTrue);
      expect(Uri.parse(service.serverUrl!).host, '192.168.100.12');
      final token = service.sessionToken;
      final port = service.serverPort;
      final endpoint = Uri(
        scheme: 'ws',
        host: '127.0.0.1',
        port: port!,
        queryParameters: {'token': token},
      );
      final connected = service.onConnectionChanged.firstWhere(
        (value) => value,
      );
      final socket = await HttpOverrides.runWithHttpOverrides(
        () => WebSocket.connect(endpoint.toString()),
        _RealHttpOverrides(),
      );
      socket.listen((_) {});
      addTearDown(socket.close);
      await connected.timeout(const Duration(seconds: 3));
      final received = service.onState.firstWhere((state) => state.btnA);
      socket.add('{"sequence":1,"btnA":true}');
      await received.timeout(const Duration(seconds: 3));

      candidates = const [VrLocalAddressCandidate('wlan0', '192.168.100.25')];
      expect(await service.refreshLocalAddress(), isTrue);
      final url = Uri.parse(service.serverUrl!);
      expect(url.host, '192.168.100.25');
      expect(url.port, port);
      expect(url.queryParameters['token'], token);
      expect(service.isConnected, isTrue);
      expect(service.latestState.btnA, isTrue);
      final released = service.onState.firstWhere(
        (state) => !state.btnA && !state.isNeutralized,
      );
      socket.add('{"sequence":2,"btnA":false}');
      await released.timeout(const Duration(seconds: 3));
    },
  );

  test(
    'no LAN suppresses invitation, recovering does not restart server',
    () async {
      var candidates = const [
        VrLocalAddressCandidate('rmnet_data0', '10.22.29.53'),
      ];
      final service = VrRemoteControllerService(
        localAddressCandidates: () async => candidates,
      );
      addTearDown(service.dispose);
      expect(await service.startServer(port: 0), isTrue);
      expect(service.isRunning, isTrue);
      expect(service.localIp, isNull);
      expect(service.serverUrl, isNull);
      final token = service.sessionToken;
      final port = service.serverPort;
      candidates = const [VrLocalAddressCandidate('ap0', '192.168.43.1')];
      expect(await service.refreshLocalAddress(), isTrue);
      expect(service.localIp, '192.168.43.1');
      candidates = const [VrLocalAddressCandidate('utun0', '10.0.0.2')];
      expect(await service.refreshLocalAddress(), isFalse);
      expect(service.serverUrl, isNull);
      expect(service.localIp, isNull);
      expect(service.serverPort, port);
      expect(service.sessionToken, token);
      expect(service.isRunning, isTrue);
    },
  );

  test(
    'lookup error clears stale advertised address without stopping socket',
    () async {
      var failLookup = false;
      final service = VrRemoteControllerService(
        localAddressCandidates: () async {
          if (failLookup) {
            throw const SocketException('Interface lookup failed');
          }
          return const [VrLocalAddressCandidate('wlan0', '192.168.100.12')];
        },
      );
      addTearDown(service.dispose);
      expect(await service.startServer(port: 0), isTrue);
      failLookup = true;
      expect(await service.refreshLocalAddress(), isFalse);
      expect(service.localIp, isNull);
      expect(service.serverUrl, isNull);
      expect(service.isRunning, isTrue);
    },
  );

  test('dispose invalidates pending address lookup', () async {
    final pending = Completer<Iterable<VrLocalAddressCandidate>>();
    final service = VrRemoteControllerService(
      localAddressCandidates: () => pending.future,
    );
    final refresh = service.refreshLocalAddress();
    service.dispose();
    pending.complete(const [
      VrLocalAddressCandidate('wlan0', '192.168.100.12'),
    ]);
    expect(await refresh, isFalse);
    expect(service.localIp, isNull);
    expect(service.serverUrl, isNull);
    expect(await service.refreshLocalAddress(), isFalse);
  });

  test('older lookup cannot overwrite more recent network result', () async {
    final first = Completer<Iterable<VrLocalAddressCandidate>>();
    var count = 0;
    final service = VrRemoteControllerService(
      localAddressCandidates: () {
        if (count++ == 0) return first.future;
        return Future.value(const [
          VrLocalAddressCandidate('wlan0', '192.168.100.25'),
        ]);
      },
    );
    addTearDown(service.dispose);
    final stale = service.refreshLocalAddress();
    expect(await service.refreshLocalAddress(), isTrue);
    first.complete(const [VrLocalAddressCandidate('wlan0', '192.168.100.12')]);
    expect(await stale, isFalse);
    expect(service.localIp, '192.168.100.25');
  });
}
