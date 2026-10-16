import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _NoHttp extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('A Bluetooth-only page must not open an HTTP socket.');
  }
}

class _Link implements VrControllerLink {
  final incoming = StreamController<Object?>.broadcast();
  int packets = 0, closes = 0;
  bool open = true;
  @override
  bool get isOpen => open;
  @override
  Stream<Object?> get messages => incoming.stream;
  @override
  void add(Object data) => packets++;
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!open) return;
    open = false;
    closes++;
    await incoming.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorChannels = [
    'dev.fluttercommunity.plus/sensors/method',
    'dev.fluttercommunity.plus/sensors/gyroscope',
    'dev.fluttercommunity.plus/sensors/accelerometer',
    'dev.fluttercommunity.plus/sensors/user_accel',
  ];
  late _NoHttp http;
  HttpOverrides? previousOverrides;
  setUp(() {
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = http = _NoHttp();
    SharedPreferences.setMockInitialValues({
      'vrlizate_host_ip': '192.168.1.12',
    });
    for (final channel in sensorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });
  tearDown(() {
    HttpOverrides.global = previousOverrides;
    for (final channel in sensorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  Future<void> prepareView(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
  }

  Future<void> settings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Ajustes y Modo'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Bluetooth-only ignores legacy IP and cannot open a socket', (
    tester,
  ) async {
    await prepareView(tester);
    await tester.pumpWidget(
      const MaterialApp(
        home: PhoneControllerPage(
          allowWifiConnection: false,
          targetHost: '127.0.0.1',
          sessionToken: 'old-wifi-token',
          autoConnect: true,
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await settings(tester);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byKey(const ValueKey('controller_transport_selector')),
      findsNothing,
    );
    expect(find.text('Wi-Fi local'), findsNothing);
    expect(find.textContaining('192.168.1.12'), findsNothing);
    expect(find.textContaining('127.0.0.1'), findsNothing);
    expect(find.textContaining('Escanea el QR Bluetooth'), findsWidgets);
    expect(http.attempts, 0);
    final connectButtons = find.ancestor(
      of: find.text('CONECTAR'),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );
    expect(connectButtons, findsWidgets);
    for (final button in tester.widgetList<ButtonStyleButton>(connectButtons)) {
      expect(button.onPressed, isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Bluetooth-only keeps injected input and removes Wi-Fi settings',
    (tester) async {
      await prepareView(tester);
      final link = _Link();
      var connections = 0;
      final connectedTargets = <VrControllerConnectionTarget?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            allowWifiConnection: false,
            transportType: VrTransportType.bluetoothLe,
            autoConnect: true,
            linkConnector: () async {
              connections++;
              return link;
            },
            onConnected: connectedTargets.add,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(connections, 1);
      expect(connectedTargets, [null]);
      expect(link.packets, greaterThan(0));
      expect(find.byIcon(Icons.bluetooth_rounded), findsWidgets);
      await settings(tester);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.byKey(const ValueKey('controller_transport_selector')),
        findsNothing,
      );
      expect(find.text('Wi-Fi local'), findsNothing);
      expect(http.attempts, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(link.closes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disabling Wi-Fi preserves an already connected external link', (
    tester,
  ) async {
    await prepareView(tester);
    final link = _Link();
    var connections = 0;
    Future<VrControllerLink> connect() async {
      connections++;
      return link;
    }

    Widget page(bool wifi) => MaterialApp(
      home: PhoneControllerPage(
        key: const ValueKey('same-controller'),
        allowWifiConnection: wifi,
        transportType: VrTransportType.bluetoothLe,
        autoConnect: true,
        linkConnector: connect,
      ),
    );
    await tester.pumpWidget(page(true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final state = tester.state(find.byType(PhoneControllerPage));
    await tester.pumpWidget(page(false));
    expect(tester.state(find.byType(PhoneControllerPage)), same(state));
    expect(connections, 1);
    expect(link.isOpen, isTrue);
    await settings(tester);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byKey(const ValueKey('controller_transport_selector')),
      findsNothing,
    );
    expect(http.attempts, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(tester.takeException(), isNull);
  });
}
