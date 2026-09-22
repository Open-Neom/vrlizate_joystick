import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

const _code =
    'vrlizate://pair?host=192.168.1.12&port=8080&token=private-test-token'
    '&role=child&transport=localSocket';

class _FakeCamera implements VrPairingCameraSession {
  _FakeCamera({VrPairingCameraError? error, bool torch = false})
    : state = ValueNotifier(
        VrPairingCameraState(error: error, torchAvailable: torch),
      );

  @override
  final ValueNotifier<VrPairingCameraState> state;
  final detections = StreamController<String>.broadcast(sync: true);
  Completer<void>? startGate;
  Completer<void>? stopGate;
  Completer<void>? disposeGate;
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  int torchChanges = 0;
  bool disposalCompleted = false;

  @override
  Stream<String> get codes => detections.stream;
  @override
  Widget buildPreview(BuildContext context) => const ColoredBox(
    key: ValueKey('fake_camera_preview'),
    color: Colors.black,
  );
  @override
  Future<void> start() async {
    starts++;
    await startGate?.future;
    final old = state.value;
    state.value = VrPairingCameraState(
      running: old.error == null,
      torchAvailable: old.torchAvailable,
      torchOn: old.torchOn,
      error: old.error,
    );
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopGate?.future;
    final old = state.value;
    state.value = VrPairingCameraState(
      torchAvailable: old.torchAvailable,
      error: old.error,
    );
  }

  @override
  Future<void> toggleTorch() async {
    torchChanges++;
    final old = state.value;
    state.value = VrPairingCameraState(
      running: old.running,
      torchAvailable: old.torchAvailable,
      torchOn: !old.torchOn,
      error: old.error,
    );
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await disposeGate?.future;
    disposalCompleted = true;
    await detections.close();
    state.dispose();
  }
}

class _Routes extends NavigatorObserver {
  int replacements = 0;
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    replacements++;
  }
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    // Broadcast subscription cancellation can return Dart's shared completed
    // Future from the real zone. Drain that zone as well as fake frame time;
    // otherwise awaiting cancel never completes until the widget test exits.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _settle(WidgetTester tester) async {
  await _flush(tester);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('accepts canonical child localSocket credentials faithfully', () {
    final invitation = parseVrControllerPairingCode('  $_code  ');
    expect(invitation.host, '192.168.1.12');
    expect(invitation.port, 8080);
    expect(invitation.sessionToken, 'private-test-token');
    expect(invitation.role, VrDeviceRole.child);
    expect(invitation.transportType, VrTransportType.localSocket);
  });

  test('rejects malformed/foreign/web QR without echoing the secret', () {
    for (final raw in [
      '',
      'javascript:alert(1)',
      'https://192.168.1.12/?token=private-test-token',
      _code.replaceFirst('vrlizate://pair', '/pair'),
      _code.replaceFirst('pair?', 'pair/extra?'),
      _code.replaceFirst('pair?', 'user@pair?'),
      _code.replaceFirst('pair?', 'pair:123?'),
      '$_code#',
      '$_code&token=duplicate',
      _code.replaceFirst('token=private-test-token', 'token='),
      _code.replaceFirst('&role=child', ''),
      _code.replaceFirst('192.168.1.12', 'host%2Fpath'),
      _code.replaceFirst('port=8080', 'port=999999'),
    ]) {
      expect(
        () => parseVrControllerPairingCode(raw),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'safe explanation',
            isNot(contains('private-test-token')),
          ),
        ),
      );
    }
  });

  test('rejects parent invitations and unimplemented transports clearly', () {
    expect(
      () => parseVrControllerPairingCode(
        _code.replaceFirst('role=child', 'role=parent'),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'role',
          contains('mando'),
        ),
      ),
    );
    for (final (transport, label) in [
      ('bluetoothLe', 'Bluetooth LE'),
      ('wifiDirect', 'Wi-Fi Direct'),
    ]) {
      expect(
        () => parseVrControllerPairingCode(
          _code.replaceFirst('localSocket', transport),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'transport',
            contains(label),
          ),
        ),
      );
    }
  });

  testWidgets(
    'scanner owns portrait only while its route is current and resumed',
    (tester) async {
      const portraitSize = Size(360, 800);
      await tester.binding.setSurfaceSize(portraitSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final camera = _FakeCamera();
      final orientations = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setPreferredOrientations') {
              orientations.add(call.arguments);
            }
            return null;
          });
      final navigation = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigation,
          home: VrControllerPairingPage(cameraFactory: () => camera),
        ),
      );
      await _settle(tester);
      expect(orientations.last, ['DeviceOrientation.portraitUp']);
      final preview = tester.getRect(
        find.byKey(const ValueKey('fake_camera_preview')),
      );
      final viewport = Offset.zero & portraitSize;
      expect(viewport.contains(preview.topLeft), isTrue);
      expect(
        viewport.contains(preview.bottomRight),
        isTrue,
        reason: 'The whole QR preview must be visible on a portrait phone.',
      );

      orientations.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(orientations, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(orientations.last, ['DeviceOrientation.portraitUp']);

      unawaited(
        navigation.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covering_route')),
          ),
        ),
      );
      await _settle(tester);
      orientations.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(orientations, isEmpty);

      navigation.currentState!.pop();
      await _settle(tester);
      expect(orientations.last, ['DeviceOrientation.portraitUp']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
    },
  );

  testWidgets(
    'camera starts only after opening page; duplicate QR opens once after stop/dispose',
    (tester) async {
      final camera = _FakeCamera()
        ..stopGate = Completer<void>()
        ..disposeGate = Completer<void>();
      final routes = _Routes();
      var factories = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => VrControllerPairingPage(
                    cameraFactory: () {
                      factories++;
                      return camera;
                    },
                    controllerBuilder: (_, payload) {
                      expect(camera.disposalCompleted, isTrue);
                      expect(payload.sessionToken, 'private-test-token');
                      return const Scaffold(
                        body: Text('controller_destination'),
                      );
                    },
                  ),
                ),
              ),
              child: const Text('open_pairing'),
            ),
          ),
        ),
      );
      expect(factories, 0);
      expect(camera.starts, 0);
      await tester.tap(find.text('open_pairing'));
      await _settle(tester);
      expect(factories, 1);
      expect(camera.starts, 1);
      camera.detections.add(_code);
      camera.detections.add(_code);
      await _flush(tester);
      expect(camera.stops, 1);
      expect(find.text('controller_destination'), findsNothing);
      expect(find.byKey(const ValueKey('fake_camera_preview')), findsNothing);
      camera.stopGate!.complete();
      await _flush(tester);
      expect(camera.disposals, 1);
      expect(find.text('controller_destination'), findsNothing);
      camera.disposeGate!.complete();
      await _settle(tester);
      expect(find.text('controller_destination'), findsOneWidget);
      expect(routes.replacements, 1);
      expect(camera.disposals, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'permission denial keeps manual pairing usable and invalid QR does not navigate',
    (tester) async {
      final camera = _FakeCamera(error: VrPairingCameraError.permissionDenied);
      await tester.pumpWidget(
        MaterialApp(
          home: VrControllerPairingPage(
            cameraFactory: () => camera,
            controllerBuilder: (_, _) =>
                const Scaffold(body: Text('paired_manually')),
          ),
        ),
      );
      await _flush(tester);
      expect(find.textContaining('Permiso de cámara denegado'), findsOneWidget);
      camera.detections.add('https://example.com');
      camera.detections.add('https://example.com');
      await tester.pump();
      expect(camera.stops, 0);
      expect(find.byKey(const ValueKey('vr_pairing_error')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('vr_pairing_link')),
        _code,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('vr_pairing_connect')),
      );
      await tester.tap(find.byKey(const ValueKey('vr_pairing_connect')));
      await _settle(tester);
      expect(find.text('paired_manually'), findsOneWidget);
      expect(camera.disposalCompleted, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unsupported platform reads clipboard only after explicit paste',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        var clipboardReads = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.getData') {
                clipboardReads++;
                return {'text': _code};
              }
              return null;
            });
        await tester.pumpWidget(
          MaterialApp(
            home: VrControllerPairingPage(
              controllerBuilder: (_, _) =>
                  const Scaffold(body: Text('pasted_pairing')),
            ),
          ),
        );
        await tester.pump();
        expect(clipboardReads, 0);
        expect(
          find.textContaining('El escáner integrado está disponible'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('vr_pairing_paste')));
        await _settle(tester);
        expect(clipboardReads, 1);
        expect(find.text('pasted_pairing'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        // Flutter checks foundation overrides before ordinary tearDown runs.
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'pause stops camera, ignores stale detections and resumes safely',
    (tester) async {
      final camera = _FakeCamera();
      await tester.pumpWidget(
        MaterialApp(
          home: VrControllerPairingPage(
            cameraFactory: () => camera,
            controllerBuilder: (_, _) => const Text('should_not_open'),
          ),
        ),
      );
      await _flush(tester);
      expect(camera.starts, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _flush(tester);
      expect(camera.state.value.running, isFalse);
      camera.detections.add(_code);
      await tester.pump();
      expect(find.text('should_not_open'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _flush(tester);
      expect(camera.starts, 2);
      expect(camera.state.value.running, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      expect(camera.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving during pending start waits and releases without late navigation',
    (tester) async {
      final camera = _FakeCamera()..startGate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: VrControllerPairingPage(
            cameraFactory: () => camera,
            controllerBuilder: (_, _) => const Text('should_not_open'),
          ),
        ),
      );
      await tester.pump();
      expect(camera.starts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      camera.startGate!.complete();
      await _flush(tester);
      expect(camera.disposals, 1);
      expect(camera.disposalCompleted, isTrue);
      expect(find.text('should_not_open'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'completed camera shutdown waits for an uncovered route before navigation',
    (tester) async {
      final camera = _FakeCamera()..stopGate = Completer<void>();
      final navigation = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigation,
          home: VrControllerPairingPage(
            cameraFactory: () => camera,
            controllerBuilder: (_, _) =>
                const Scaffold(body: Text('ready_after_uncover')),
          ),
        ),
      );
      await _flush(tester);
      camera.detections.add(_code);
      await _flush(tester);
      expect(camera.stops, 1);
      unawaited(
        navigation.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covering_route')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await _flush(tester);
      camera.stopGate!.complete();
      await _flush(tester);
      expect(camera.disposalCompleted, isTrue);
      expect(find.text('ready_after_uncover'), findsNothing);
      expect(find.text('covering_route'), findsOneWidget);
      navigation.currentState!.pop();
      await _settle(tester);
      expect(find.text('ready_after_uncover'), findsOneWidget);
      expect(camera.disposals, 1);
      expect(camera.starts, 1, reason: 'A closed camera must never restart.');
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'torch is shown only when available and never toggles when stopped',
    (tester) async {
      final camera = _FakeCamera(torch: true);
      await tester.pumpWidget(
        MaterialApp(home: VrControllerPairingPage(cameraFactory: () => camera)),
      );
      await _flush(tester);
      final torch = find.byKey(const ValueKey('vr_pairing_torch'));
      await tester.ensureVisible(torch);
      await tester.tap(torch);
      await _flush(tester);
      expect(camera.torchChanges, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _flush(tester);
      expect(tester.widget<TextButton>(torch).onPressed, isNull);
      camera.state.value = const VrPairingCameraState();
      await tester.pump();
      expect(torch, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      await _flush(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
