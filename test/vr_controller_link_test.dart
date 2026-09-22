import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _Link implements VrControllerLink {
  final inbound = StreamController<Object?>();
  final sent = <Object>[];
  _Link? peer;
  var open = true;
  var closeCount = 0;
  int? closeCode;

  @override
  Stream<Object?> get messages => inbound.stream;
  @override
  bool get isOpen => open;
  @override
  void add(Object data) {
    if (!open) throw StateError('Closed link');
    sent.add(data);
    final other = peer;
    if (other != null && other.open) other.inbound.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!open) return;
    open = false;
    closeCount++;
    closeCode = code;
    unawaited(inbound.close());
    final other = peer;
    if (other != null && other.open) {
      other.open = false;
      unawaited(other.inbound.close());
    }
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('Controller condition was not met');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channels = [
    'dev.fluttercommunity.plus/sensors/method',
    'dev.fluttercommunity.plus/sensors/gyroscope',
    'dev.fluttercommunity.plus/sensors/accelerometer',
    'dev.fluttercommunity.plus/sensors/user_accel',
  ];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  test(
    'external authentication rejects without replacing or owning links',
    () async {
      final service = VrRemoteControllerService();
      addTearDown(service.dispose);
      final first = _Link(), rejected = _Link();
      addTearDown(rejected.close);
      expect(
        service.attachControllerLink(rejected, sessionToken: 'wrong'),
        isFalse,
      );
      expect(rejected.isOpen, isTrue);
      expect(rejected.inbound.hasListener, isFalse);
      expect(service.isConnected, isFalse);
      expect(
        service.attachControllerLink(first, sessionToken: service.sessionToken),
        isTrue,
      );
      expect(
        service.attachControllerLink(first, sessionToken: service.sessionToken),
        isTrue,
      );
      expect(first.sent, hasLength(1)); // No duplicate host-mode handshake.
      expect(
        service.attachControllerLink(rejected, sessionToken: 'wrong'),
        isFalse,
      );
      expect(first.closeCount, 0);
      expect(service.isConnected, isTrue);
    },
  );

  test(
    'external channel shares parser and watchdog without HTTP startup',
    () async {
      final service = VrRemoteControllerService(
        inputTimeout: const Duration(milliseconds: 50),
        watchdogInterval: const Duration(milliseconds: 5),
      );
      addTearDown(service.dispose);
      final link = _Link();
      expect(
        service.attachControllerLink(link, sessionToken: service.sessionToken),
        isTrue,
      );
      expect(service.isRunning, isFalse);
      expect(service.serverUrl, isNull);
      expect(service.isConnected, isTrue);
      final applied = service.onState.firstWhere((state) => state.btnA);
      link.inbound.add(
        '{"sequence":1,"controllerVisible":"false","btnA":true}',
      );
      link.inbound.add(
        '{"sequence":1,"controllerVisible":false,"btnA":true,"stickX":2}',
      );
      final state = await applied.timeout(const Duration(seconds: 2));
      expect(state.stickX, 1);
      expect(state.controllerVisible, isFalse);
      final neutralized = service.onState.firstWhere(
        (state) => state.isNeutralized,
      );
      await neutralized.timeout(const Duration(seconds: 2));
      expect(service.latestState.btnA, isFalse);
      expect(service.latestState.controllerVisible, isFalse);
      expect(service.isConnected, isTrue);
    },
  );

  test('mode commands require neutral ACK over external channel too', () async {
    final service = VrRemoteControllerService();
    addTearDown(service.dispose);
    final link = _Link();
    service.requestControllerMode(RemoteControllerMode.driving);
    service.attachControllerLink(link, sessionToken: service.sessionToken);
    final command =
        jsonDecode(link.sent.single as String) as Map<String, dynamic>;
    expect(command['mode'], 'driving');
    final revision = command['revision'];
    link.inbound.add(
      jsonEncode({
        'sequence': 1,
        'hostModeRevision': revision,
        'mode': 'driving',
        'btnA': true,
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(service.latestState.btnA, isFalse);
    final ack = service.onState.firstWhere((state) => !state.isNeutralized);
    link.inbound.add(
      jsonEncode({
        'sequence': 2,
        'hostModeRevision': revision,
        'mode': 'driving',
        'drivingPaused': true,
      }),
    );
    expect((await ack).drivingPaused, isTrue);
    final selection = service.onState.firstWhere((state) => state.btnA);
    link.inbound.add(
      jsonEncode({
        'sequence': 3,
        'hostModeRevision': revision,
        'mode': 'driving',
        'drivingPaused': true,
        'btnA': true,
      }),
    );
    await selection.timeout(const Duration(seconds: 2));
  });

  test(
    'replacement owns only current channel and errors release inputs',
    () async {
      final service = VrRemoteControllerService();
      final events = <bool>[];
      final sub = service.onConnectionChanged.listen(events.add);
      addTearDown(sub.cancel);
      addTearDown(service.dispose);
      final first = _Link(), second = _Link();
      service.attachControllerLink(first, sessionToken: service.sessionToken);
      service.attachControllerLink(second, sessionToken: service.sessionToken);
      expect(first.closeCount, 1);
      expect(first.inbound.hasListener, isFalse);
      final action = service.onState.firstWhere((state) => state.btnB);
      second.inbound.add('{"sequence":1,"btnB":true}');
      await action;
      final disconnected = service.onConnectionChanged.firstWhere(
        (value) => !value,
      );
      second.inbound.addError(StateError('Provider disconnected'));
      await disconnected;
      expect(service.latestState.btnB, isFalse);
      expect(second.closeCount, 1);
      expect(events, [true, false]);
      service.dispose();
      final rejected = _Link();
      expect(
        service.attachControllerLink(
          rejected,
          sessionToken: service.sessionToken,
        ),
        isFalse,
      );
      expect(rejected.closeCount, 0);
      await rejected.close();
    },
  );

  test('invalid oversized external message closes its owner', () async {
    final service = VrRemoteControllerService();
    addTearDown(service.dispose);
    final link = _Link();
    service.attachControllerLink(link, sessionToken: service.sessionToken);
    final disconnect = service.onConnectionChanged.firstWhere(
      (value) => !value,
    );
    link.inbound.add('x' * 4097);
    await disconnect;
    expect(link.closeCode, 1008);
    expect(service.latestState.isNeutralized, isTrue);
    expect(service.telemetry.rejectedStates, 1);
    expect(
      service.telemetry.lastDisconnectReason,
      VrControllerDisconnectReason.inputLimitExceeded,
    );
  });

  testWidgets('telemetry measures local age, rejected input and watchdog once', (
    tester,
  ) async {
    var nowUs = 0;
    final service = VrRemoteControllerService(
      nowMicroseconds: () => nowUs,
      inputTimeout: const Duration(milliseconds: 50),
      watchdogInterval: const Duration(milliseconds: 10),
    );
    addTearDown(service.dispose);
    final first = _Link();
    service.attachControllerLink(first, sessionToken: service.sessionToken);
    expect(service.telemetry.isConnected, isTrue);
    expect(service.telemetry.inputAge, isNull);
    expect(service.telemetry.acceptedStates, 0);
    // A sender clock far ahead must never become a negative/network "latency".
    first.inbound.add(
      '{"sequence":1,"timestampUs":9000000000000000,"btnA":true}',
    );
    await tester.pump();
    expect(service.telemetry.inputAge, Duration.zero);
    expect(service.telemetry.acceptedStates, 1);
    nowUs = 40000;
    first.inbound.add('{"sequence":1,"btnA":false}'); // Duplicate.
    first.inbound.add('{"sequence":2,"stickX":"not a number"}');
    await tester.pump(const Duration(milliseconds: 10));
    expect(service.telemetry.inputAge, const Duration(milliseconds: 40));
    expect(service.telemetry.rejectedStates, 2);
    expect(service.latestState.btnA, isTrue);
    final snapshot = service.telemetry;
    nowUs = 50000;
    await tester.pump(const Duration(milliseconds: 10));
    expect(service.latestState.isNeutralized, isTrue);
    expect(service.telemetry.watchdogNeutralizations, 1);
    expect(service.telemetry.inputAge, const Duration(milliseconds: 50));
    expect(snapshot.inputAge, const Duration(milliseconds: 40));
    nowUs = 150000;
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.telemetry.watchdogNeutralizations, 1);
    first.inbound.add('{"sequence":2}');
    await tester.pump();
    expect(service.telemetry.acceptedStates, 2);
    expect(service.telemetry.inputAge, Duration.zero);
    final replacement = _Link();
    service.attachControllerLink(
      replacement,
      sessionToken: service.sessionToken,
    );
    expect(service.telemetry.inputAge, isNull);
    expect(service.telemetry.acceptedStates, 2);
    expect(
      service.telemetry.lastDisconnectReason,
      VrControllerDisconnectReason.replaced,
    );
    replacement.inbound.addError(StateError('private transport detail'));
    await tester.pump();
    expect(service.telemetry.isConnected, isFalse);
    expect(service.telemetry.inputAge, isNull);
    expect(
      service.telemetry.lastDisconnectReason,
      VrControllerDisconnectReason.transportError,
    );
    service.attachControllerLink(_Link(), sessionToken: service.sessionToken);
    service.stop();
    expect(
      service.telemetry.lastDisconnectReason,
      VrControllerDisconnectReason.serviceStopped,
    );
    service.dispose();
  });

  testWidgets('native external link bypasses IP, exchanges A/B and mode ACK', (
    tester,
  ) async {
    final service = VrRemoteControllerService();
    addTearDown(service.dispose);
    final host = _Link(), controller = _Link();
    host.peer = controller;
    controller.peer = host;
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          transportType: VrTransportType.bluetoothLe,
          connectionLabel: 'Bluetooth LE · Visor QA',
          autoConnect: true,
          linkConnector: () async {
            attempts++;
            expect(
              service.attachControllerLink(
                host,
                sessionToken: service.sessionToken,
              ),
              isTrue,
            );
            return controller;
          },
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => !service.latestState.isNeutralized && service.isConnected,
    );
    // The in-memory ACK arrives during the pump's trailing microtasks. Commit
    // its new surface epoch before touching a button from the previous frame.
    await tester.pump();
    expect(attempts, 1);
    expect(find.textContaining('La IP sola'), findsNothing);
    final a = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.btnA);
    expect(
      service.latestState.btnB || service.latestState.isTriggerPressed,
      isFalse,
    );
    await a.up();
    final b = await tester.startGesture(tester.getCenter(find.text('B')));
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.btnB);
    await b.up();
    service.requestControllerMode(RemoteControllerMode.driving);
    await _pumpUntil(
      tester,
      () => service.latestState.mode == RemoteControllerMode.driving,
    );
    expect(service.latestState.drivingPaused, isTrue);
    expect(service.latestState.btnA || service.latestState.btnB, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    expect(service.isConnected, isFalse);
    expect(tester.takeException(), isNull);
    // This test owns the host, independently of the controller widget tree.
    // Stop its watchdog before the widget-test pending-timer invariant runs.
    service.dispose();
  });

  testWidgets(
    'external late connector closes after timeout and after dispose',
    (tester) async {
      final pending = Completer<VrControllerLink>();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            autoConnect: true,
            connectionLabel: 'Bluetooth LE',
            connectionTimeout: const Duration(milliseconds: 80),
            linkConnector: () => pending.future,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.textContaining('No se pudo vincular por Bluetooth LE'),
        findsOneWidget,
      );
      final late = _Link();
      pending.complete(late);
      await tester.pump();
      expect(late.closeCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      final afterDispose = Completer<VrControllerLink>();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            autoConnect: true,
            linkConnector: () => afterDispose.future,
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      final abandoned = _Link();
      afterDispose.complete(abandoned);
      await tester.pump();
      expect(abandoned.closeCount, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelled connector cannot replace a newer successful retry', (
    tester,
  ) async {
    final first = Completer<VrControllerLink>();
    final second = Completer<VrControllerLink>();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          autoConnect: true,
          connectionLabel: 'Bluetooth LE',
          linkConnector: () => attempts++ == 0 ? first.future : second.future,
        ),
      ),
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    // Resuming now recovers the cancelled attempt without requiring a tap.
    expect(attempts, 2);
    final active = _Link();
    second.complete(active);
    await _pumpUntil(tester, () => active.sent.isNotEmpty);
    final stale = _Link();
    first.complete(stale);
    await tester.pump();
    expect(stale.closeCount, 1);
    expect(active.isOpen, isTrue);
    expect(active.closeCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    expect(active.closeCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transport loss retries with a neutral new session', (
    tester,
  ) async {
    final links = <_Link>[];
    final authenticated = <VrControllerConnectionTarget?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          autoConnect: true,
          onConnected: authenticated.add,
          linkConnector: () async {
            final link = _Link();
            links.add(link);
            return link;
          },
        ),
      ),
    );
    await tester.pump();
    final held = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 110));
    expect(
      links.single.sent
          .map((p) => jsonDecode(p as String))
          .any((p) => p['btnA'] == true),
      isTrue,
    );
    await links.single.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 499));
    expect(links, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(links, hasLength(2));
    expect(authenticated, [null, null]);
    final first = jsonDecode(links.last.sent.first as String);
    expect(first['sequence'], 0);
    for (final button in [
      'btnA',
      'btnB',
      'btnX',
      'btnY',
      'btnL',
      'btnR',
      'btnGrip',
    ]) {
      expect(first[button], isFalse, reason: button);
    }
    expect(first['stickX'], 0);
    expect(first['stickY'], 0);
    expect(first['lookX'], 0);
    expect(first['lookY'], 0);
    await held.up();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    expect(links.last.closeCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a controller created while paused waits for resume to connect', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final link = _Link();
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          autoConnect: true,
          linkConnector: () async {
            attempts++;
            return link;
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 10));
    expect(attempts, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    expect(attempts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    expect(link.closeCount, 1);
  });

  testWidgets('background keeps a live link and resume recovers a lost one', (
    tester,
  ) async {
    final links = <_Link>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          autoConnect: true,
          linkConnector: () async {
            final link = _Link();
            links.add(link);
            return link;
          },
        ),
      ),
    );
    await tester.pump();
    final held = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump(const Duration(milliseconds: 110));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(links.single.closeCount, 0);
    expect(jsonDecode(links.single.sent.last as String)['btnA'], isFalse);
    final sentInBackground = links.single.sent.length;
    await tester.pump(const Duration(seconds: 2));
    expect(links.single.sent.length, sentInBackground);
    await links.single.close();
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(links, hasLength(1), reason: 'Never reconnect while suspended');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(links, hasLength(2));
    expect(jsonDecode(links.last.sent.first as String)['btnA'], isFalse);
    await held.up();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry backoff is bounded and resets on returning to the app', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          autoConnect: true,
          linkConnector: () async {
            attempts++;
            throw const SocketException('Network unavailable');
          },
        ),
      ),
    );
    await tester.pump();
    expect(attempts, 1);
    for (final delay in [500, 1000, 2000, 4000, 8000, 10000]) {
      final before = attempts;
      await tester.pump(Duration(milliseconds: delay - 1));
      expect(attempts, before);
      await tester.pump(const Duration(milliseconds: 1));
      expect(attempts, before + 1);
    }
    await tester.pump(const Duration(minutes: 1));
    expect(attempts, 7);
    expect(find.textContaining('Visor no disponible'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1));
    expect(attempts, 8);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
    expect(attempts, 8, reason: 'Leaving the controller cancels recovery');
    expect(tester.takeException(), isNull);
  });

  for (final error in [
    const WebSocketException('token must not be shown', 401),
    const WebSocketException('token must not be shown', 403),
    const VrControllerConnectionException(
      'token must not be shown',
      isSessionExpired: true,
    ),
    const VrControllerConnectionException('permission denied', canRetry: false),
  ]) {
    testWidgets('permanent rejection does not retry: $error', (tester) async {
      var attempts = 0;
      var expired = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            autoConnect: true,
            onSessionExpired: (target) {
              expect(target, isNull);
              expired++;
            },
            linkConnector: () async {
              attempts++;
              throw error;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(minutes: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(attempts, 1);
      expect(
        expired,
        error is VrControllerConnectionException && !error.isSessionExpired
            ? 0
            : 1,
      );
      expect(find.textContaining('token must not be shown'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switching transport cancels an automatic reconnect', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          autoConnect: true,
          connectionLabel: 'Bluetooth LE',
          linkConnector: () async {
            attempts++;
            throw const SocketException('Network unavailable');
          },
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('Wi-Fi local'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(attempts, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'external provider failure never prints credentials or Wi-Fi instructions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            autoConnect: true,
            connectionLabel: 'Bluetooth LE',
            linkConnector: () async =>
                throw StateError('secret token must not be displayed'),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('No se pudo vincular por Bluetooth LE'),
        findsOneWidget,
      );
      expect(find.textContaining('secret token'), findsNothing);
      expect(find.textContaining('red Wi-Fi'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings modal allows switching between BLE and Wi-Fi local when external linkConnector provided',
    (tester) async {
      final link = _Link();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            initialMode: RemoteControllerMode.joystick,
            connectionLabel: 'Bluetooth LE · Visor',
            linkConnector: () async => link,
          ),
        ),
      );
      await tester.pump();

      // Tap gear button to open settings
      final gearFinder = find.byIcon(Icons.settings_rounded);
      await tester.tap(gearFinder);
      await tester.pumpAndSettle();

      expect(find.text('AJUSTES DEL MANDO VR'), findsOneWidget);
      // Initially shows Bluetooth LE with BLE description
      expect(
        find.byKey(const ValueKey('controller_transport_selector')),
        findsOneWidget,
      );
      expect(find.text('Bluetooth LE'), findsOneWidget);
      expect(find.text('Wi-Fi local'), findsOneWidget);
      expect(
        find.text('Vínculo directo BLE sin router ni contraseña.'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);

      // Switch to Wi-Fi local
      await tester.tap(find.text('Wi-Fi local'));
      await tester.pumpAndSettle();

      // Now TextField is visible for entering IP
      expect(find.byType(TextField), findsOneWidget);

      // Switch back to Bluetooth LE
      await tester.tap(find.text('Bluetooth LE'));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsNothing);
      expect(
        find.text('Vínculo directo BLE sin router ni contraseña.'),
        findsOneWidget,
      );

      // Close settings modal
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 150));
      await link.close();
      expect(tester.takeException(), isNull);
    },
  );
}
