import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _RealHttpOverrides extends HttpOverrides {}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  fail('Controller condition timed out.');
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
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });
  tearDown(() {
    for (final name in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  testWidgets(
    'native controller authenticates, sends trigger, and releases on pause',
    (tester) async {
      final service = VrRemoteControllerService();
      addTearDown(service.dispose);
      await tester.runAsync(() => service.startServer(port: 0));
      await HttpOverrides.runWithHttpOverrides(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: PhoneControllerPage(
              targetHost: '127.0.0.1',
              targetPort: service.serverPort!,
              sessionToken: service.sessionToken,
              autoConnect: true,
            ),
          ),
        );
        await _pumpUntil(tester, () => service.isConnected);
        await tester.pump();
        expect(find.text('RECONECTAR'), findsOneWidget);

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('GATILLO (CLIC)')),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await _pumpUntil(tester, () => service.latestState.isTriggerPressed);

        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await _pumpUntil(tester, () => !service.latestState.isTriggerPressed);
        expect(service.latestState.stickX, 0);
        expect(service.latestState.stickY, 0);
        await gesture.up();
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpUntil(tester, () => !service.isConnected);
        service.dispose();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
      }, _RealHttpOverrides());
    },
  );

  testWidgets('unsupported transport is explained without starting a socket', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PhoneControllerPage(
          targetHost: '127.0.0.1',
          sessionToken: 'token',
          transportType: VrTransportType.bluetoothLe,
          autoConnect: true,
        ),
      ),
    );
    await tester.pump();
    expect(
      find.textContaining('Bluetooth LE está pendiente de implementación'),
      findsOneWidget,
    );
    expect(find.text('CONECTAR'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a manual IP without credentials requests pairing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: PhoneControllerPage(targetHost: '127.0.0.1')),
    );
    await tester.tap(find.text('CONECTAR'));
    await tester.pump();
    expect(
      find.textContaining('La IP sola no autoriza la conexión'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('dual joystick layout renders 4 action buttons, navigation and view sticks, and settings modal opens', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PhoneControllerPage(
          initialMode: RemoteControllerMode.joystick,
        ),
      ),
    );
    await tester.pump();

    // Verify left column: L, Y, stick, X
    expect(find.text('L'), findsOneWidget);
    expect(find.text('Y'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    expect(find.text('NAVEGACIÓN 3D (DESPLAZAMIENTO)'), findsOneWidget);

    // Verify center column: Recentrar Vista button + Puntero Láser (Slide 180° · Hold Grip)
    expect(find.text('RECENTRAR VISTA'), findsOneWidget);
    expect(find.text('PUNTERO LÁSER (SLIDE 180° · HOLD GRIP)'), findsOneWidget);

    // Verify right column: R, B, stick, A
    expect(find.text('R'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('VISTA & GIRO (360° HORIZ / 180° VERT)'), findsOneWidget);

    // Open settings modal via gear icon
    await tester.tap(find.byIcon(Icons.settings_rounded));
    await tester.pumpAndSettle();

    expect(find.text('AJUSTES DEL MANDO VR'), findsOneWidget);
    expect(find.text('JOYSTICK DUAL'), findsOneWidget);
    expect(find.text('PUNTERO LÁSER'), findsOneWidget);
    expect(find.text('Recentrar con sacudida del celular'), findsOneWidget);
    expect(find.text('Vibración háptica del mando'), findsOneWidget);

    // Toggle vibration switch off and on
    await tester.tap(find.text('Vibración háptica del mando'));
    await tester.pumpAndSettle();

    // Close settings modal
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('laser slide pad onHold triggers grip and releasing clears it', (
    tester,
  ) async {
    final service = VrRemoteControllerService();
    addTearDown(service.dispose);
    await tester.runAsync(() => service.startServer(port: 0));
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            initialMode: RemoteControllerMode.joystick,
            targetHost: '127.0.0.1',
            targetPort: service.serverPort!,
            sessionToken: service.sessionToken,
            autoConnect: true,
          ),
        ),
      );
      await _pumpUntil(tester, () => service.isConnected);
      await tester.pump();

      // Find center laser slide pad
      final padFinder = find.byKey(const ValueKey('laser_slide_pad'));
      final gesture = await tester.startGesture(tester.getCenter(padFinder));
      await tester.pump(const Duration(milliseconds: 100));
      // Prior to 280ms threshold, grip is false
      expect(service.latestState.btnGrip, isFalse);

      // Wait past 280ms onHold threshold (100ms + 250ms = 350ms > 280ms)
      await tester.pump(const Duration(milliseconds: 250));
      await _pumpUntil(tester, () => service.latestState.btnGrip);
      expect(service.latestState.btnGrip, isTrue);
      expect(find.text('✊ GRIP (AGARRE) ACTIVO'), findsOneWidget);

      // Release gesture
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      await _pumpUntil(tester, () => !service.latestState.btnGrip);
      expect(service.latestState.btnGrip, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpUntil(tester, () => !service.isConnected);
      service.dispose();
      expect(tester.takeException(), isNull);
    }, _RealHttpOverrides());
  });
}
