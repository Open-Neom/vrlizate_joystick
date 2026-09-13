import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _RouteObserver extends NavigatorObserver {
  final popped = <Route<dynamic>>[];
  final removed = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    popped.add(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    removed.add(route);
  }
}

Future<void> _waitFor(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the authenticated controller connection.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late VrRemoteControllerService service;
  late GlobalKey<NavigatorState> navigatorKey;
  late _RouteObserver observer;
  late List<bool> outcomes;
  final sockets = <WebSocket>[];

  setUp(() {
    service = VrRemoteControllerService();
    navigatorKey = GlobalKey<NavigatorState>();
    observer = _RouteObserver();
    outcomes = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
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

  Future<void> mountHome(
    WidgetTester tester, {
    bool closeOnConnected = true,
  }) async {
    tester.view.physicalSize = const Size(1000, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      expect(await service.startServer(port: 0), isTrue);
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [observer],
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                const Text('VR HOME'),
                TextButton(
                  onPressed: () async {
                    outcomes.add(
                      await RemoteControllerQrDialog.show(
                        context,
                        service: service,
                        closeOnConnected: closeOnConnected,
                      ),
                    );
                  },
                  child: const Text('SHOW QR'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openQr(WidgetTester tester) async {
    await tester.tap(find.text('SHOW QR'));
    await tester.pumpAndSettle();
  }

  Future<WebSocket> connect(WidgetTester tester, {String? token}) async {
    final socket = await tester.runAsync(() async {
      final endpoint = Uri(
        scheme: 'ws',
        host: '127.0.0.1',
        port: service.serverPort,
        queryParameters: {'token': token ?? service.sessionToken},
      );
      final connected = await HttpOverrides.runWithHttpOverrides(
        () => WebSocket.connect(endpoint.toString()),
        _RealHttpOverrides(),
      );
      connected.listen((_) {});
      sockets.add(connected);
      await _waitFor(() => service.isConnected);
      return connected;
    });
    return socket!;
  }

  testWidgets(
    'authenticated pairing returns to Home once and keeps server alive',
    (tester) async {
      await mountHome(tester);
      await openQr(tester);
      expect(find.text('Conectar otro teléfono'), findsOneWidget);
      expect(outcomes, isEmpty);

      final first = await connect(tester);
      await tester.pumpAndSettle();

      expect(find.text('VR HOME'), findsOneWidget);
      expect(find.byType(RemoteControllerQrDialog), findsNothing);
      expect(outcomes, [true]);
      expect(observer.popped, hasLength(1));
      expect(service.isRunning, isTrue);
      expect(service.isConnected, isTrue);
      await tester.runAsync(() async {
        await first.close();
        await _waitFor(() => !service.isConnected);
      });
      await connect(tester);
      await tester.pumpAndSettle();
      expect(outcomes, [true]);
      expect(observer.popped, hasLength(1));
      expect(navigatorKey.currentState!.canPop(), isFalse);
    },
  );

  testWidgets('bad QR token cannot complete setup or pop Home', (tester) async {
    await mountHome(tester);
    await openQr(tester);
    await tester.runAsync(() async {
      final endpoint = Uri(
        scheme: 'ws',
        host: '127.0.0.1',
        port: service.serverPort,
        queryParameters: {'token': 'not-the-pairing-secret'},
      );
      await expectLater(
        HttpOverrides.runWithHttpOverrides(
          () => WebSocket.connect(endpoint.toString()),
          _RealHttpOverrides(),
        ),
        throwsA(isA<WebSocketException>()),
      );
    });
    await tester.pumpAndSettle();
    expect(service.isConnected, isFalse);
    expect(find.byType(RemoteControllerQrDialog), findsOneWidget);
    expect(outcomes, isEmpty);
    expect(observer.popped, isEmpty);
  });

  testWidgets(
    'manual close returns false and a late connection cannot pop again',
    (tester) async {
      await mountHome(tester);
      await openQr(tester);
      await tester.tap(find.byTooltip('Cerrar'));
      await tester.pumpAndSettle();
      expect(outcomes, [false]);
      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('OTHER SCREEN')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await connect(tester);
      await tester.pumpAndSettle();
      expect(find.text('OTHER SCREEN'), findsOneWidget);
      expect(observer.popped, hasLength(1));
      expect(observer.removed, isEmpty);
      expect(outcomes, [false]);
    },
  );

  testWidgets(
    'pairing removes only its own QR when another route is above it',
    (tester) async {
      await mountHome(tester);
      await openQr(tester);
      unawaited(
        navigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('OTHER SCREEN')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await connect(tester);
      await tester.pumpAndSettle();
      expect(find.text('OTHER SCREEN'), findsOneWidget);
      expect(outcomes, [true]);
      expect(observer.popped, isEmpty);
      expect(observer.removed, hasLength(1));
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('VR HOME'), findsOneWidget);
      expect(navigatorKey.currentState!.canPop(), isFalse);
      expect(service.isRunning, isTrue);
    },
  );

  testWidgets(
    'already connected show completes safely after its initial frame',
    (tester) async {
      await mountHome(tester);
      await connect(tester);
      await openQr(tester);
      expect(outcomes, [true]);
      expect(observer.popped, hasLength(1));
      expect(find.text('VR HOME'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'auto return can be opted out; explicit close is not new pairing',
    (tester) async {
      await mountHome(tester, closeOnConnected: false);
      await openQr(tester);
      await connect(tester);
      await tester.pumpAndSettle();
      expect(find.text('Mando conectado'), findsOneWidget);
      expect(outcomes, isEmpty);
      await tester.tap(find.text('Continuar al visor'));
      await tester.pumpAndSettle();
      expect(outcomes, [false]);
      expect(service.isConnected, isTrue);
    },
  );

  testWidgets('embedded QR never pops its host without an explicit callback', (
    tester,
  ) async {
    await mountHome(tester);
    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: RemoteControllerQrDialog(
              service: service,
              closeOnConnected: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await connect(tester);
    await tester.pumpAndSettle();
    expect(find.text('Mando conectado'), findsOneWidget);
    expect(observer.popped, isEmpty);
    expect(observer.removed, isEmpty);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'Cerrar',
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('system Back returns false and disposes the setup listener', (
    tester,
  ) async {
    await mountHome(tester);
    await openQr(tester);
    await navigatorKey.currentState!.maybePop();
    await tester.pumpAndSettle();
    await connect(tester);
    await tester.pumpAndSettle();
    expect(outcomes, [false]);
    expect(observer.popped, hasLength(1));
    expect(find.text('VR HOME'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
