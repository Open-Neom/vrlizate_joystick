import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _TestLink implements VrControllerLink {
  final inbound = StreamController<Object?>.broadcast();
  final sent = <Object>[];
  bool open = true;

  @override
  Stream<Object?> get messages => inbound.stream;

  @override
  bool get isOpen => open;

  @override
  void add(Object data) {
    if (!open) throw StateError('Link closed');
    sent.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!open) return;
    open = false;
    await inbound.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorChannels = <String>[
    'dev.fluttercommunity.plus/sensors/method',
    'dev.fluttercommunity.plus/sensors/gyroscope',
    'dev.fluttercommunity.plus/sensors/accelerometer',
    'dev.fluttercommunity.plus/sensors/user_accel',
    'vrlizate/device_capabilities',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    for (final name in sensorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    for (final name in sensorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
  });

  testWidgets(
    'Faro Wi-Fi external link renders Wi-Fi tethering state instead of Bluetooth RECONECTAR',
    (tester) async {
      final link = _TestLink();
      addTearDown(link.close);

      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            autoConnect: true,
            allowWifiConnection: false,
            externalLinkOverWifi: true,
            connectionLabel: 'Faro Mac SAIA',
            linkConnector: () async => link,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byIcon(Icons.bluetooth_rounded), findsNothing);
      expect(find.text('RECONECTAR'), findsNothing);
      expect(find.byIcon(Icons.wifi_tethering_rounded), findsOneWidget);
      expect(find.text('FARO WI-FI · ACTIVO'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Faro Mac SAIA'), findsWidgets);
      expect(
        find.text(
          'Enlace Wi-Fi LAN coordinado por Estación Faro (Bluetooth LE inactivo).',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Vínculo directo Bluetooth con el visor.'),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Disconnected Faro Wi-Fi external link shows CONECTAR FARO and Wi-Fi off icon',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            autoConnect: false,
            allowWifiConnection: false,
            externalLinkOverWifi: true,
            connectionLabel: 'Faro Mac SAIA',
            linkConnector: () async => throw StateError('offline'),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.bluetooth_rounded), findsNothing);
      expect(find.byIcon(Icons.portable_wifi_off_rounded), findsOneWidget);
      expect(find.text('CONECTAR FARO'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'VrRemoteControllerService self-heals dropped UDP mode request when stale hostModeRevision frames arrive',
    () async {
      var fakeNowUs = 1000000;
      final service = VrRemoteControllerService(
        sessionToken: 'faro-token',
        nowMicroseconds: () => fakeNowUs,
      );
      addTearDown(service.dispose);

      final hostLink = _TestLink();
      addTearDown(hostLink.close);
      expect(
        service.attachControllerLink(hostLink, sessionToken: 'faro-token'),
        isTrue,
      );

      final initialModeMessages = hostLink.sent
          .map(VrControllerModeRequest.tryParse)
          .whereType<VrControllerModeRequest>()
          .toList();
      expect(initialModeMessages, hasLength(1));
      expect(initialModeMessages.single.revision, 0);

      // Controller acknowledges revision 0 in joystick mode.
      hostLink.inbound.add(
        VrCompactGamepadFrame(
          sequence: 1,
          senderTimestampMicroseconds: fakeNowUs,
          orientation: vm.Quaternion.identity(),
          angularVelocity: vm.Vector3.zero(),
          hostModeRevision: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.telemetry.acceptedStates, 1);

      // Visor enters Riviera Rush and requests driving (revision 1),
      // simulating a dropped UDP datagram on the Wi-Fi hop.
      fakeNowUs += 20000;
      service.requestControllerMode(RemoteControllerMode.driving);
      final countAfterInitialDrivingSend = hostLink.sent
          .map(VrControllerModeRequest.tryParse)
          .whereType<VrControllerModeRequest>()
          .length;
      expect(countAfterInitialDrivingSend, 2);

      // Within <120 ms, an in-flight old-revision packet is rejected without spamming resends.
      fakeNowUs += 40000;
      hostLink.inbound.add(
        VrCompactGamepadFrame(
          sequence: 2,
          senderTimestampMicroseconds: fakeNowUs,
          orientation: vm.Quaternion.identity(),
          angularVelocity: vm.Vector3.zero(),
          hostModeRevision: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        hostLink.sent
            .map(VrControllerModeRequest.tryParse)
            .whereType<VrControllerModeRequest>()
            .length,
        2,
      );

      // After >=120 ms with revision 1 still unacknowledged, the next stale packet triggers a self-healing resend!
      fakeNowUs += 90000;
      hostLink.inbound.add(
        VrCompactGamepadFrame(
          sequence: 3,
          senderTimestampMicroseconds: fakeNowUs,
          orientation: vm.Quaternion.identity(),
          angularVelocity: vm.Vector3.zero(),
          hostModeRevision: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final resentRequests = hostLink.sent
          .map(VrControllerModeRequest.tryParse)
          .whereType<VrControllerModeRequest>()
          .toList();
      expect(resentRequests, hasLength(3));
      expect(resentRequests.last.mode, RemoteControllerMode.driving);
      expect(resentRequests.last.revision, 1);

      // Controller receives the resent driving mode and sends neutral ACK for revision 1.
      fakeNowUs += 16000;
      hostLink.inbound.add(
        VrCompactGamepadFrame(
          sequence: 4,
          senderTimestampMicroseconds: fakeNowUs,
          orientation: vm.Quaternion.identity(),
          angularVelocity: vm.Vector3.zero(),
          modeIndex: 2,
          drivingPaused: true,
          hostModeRevision: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(service.latestState.mode, RemoteControllerMode.driving);

      // Late out-of-order revision 0 packet arriving >200 ms later never triggers extra resends once acknowledged.
      fakeNowUs += 250000;
      hostLink.inbound.add(
        VrCompactGamepadFrame(
          sequence: 5,
          senderTimestampMicroseconds: fakeNowUs,
          orientation: vm.Quaternion.identity(),
          angularVelocity: vm.Vector3.zero(),
          hostModeRevision: 0,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        hostLink.sent
            .map(VrControllerModeRequest.tryParse)
            .whereType<VrControllerModeRequest>()
            .length,
        3,
      );
    },
  );

  testWidgets(
    'SAIA-FARO-007 #1: BLE controller receiving Faro desktopBridge state over BLE keeps Bluetooth UX and ~30 Hz BLE analog pacing',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(960, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var fakeNowUs = 1000000;
      final link = _TestLink();
      addTearDown(link.close);

      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            autoConnect: true,
            allowWifiConnection: false,
            externalLinkOverWifi: false,
            transportType: VrTransportType.bluetoothLe,
            connectionLabel: 'Galaxy S25 BLE',
            linkConnector: () async => link,
            monotonicMicroseconds: () => fakeNowUs,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Visor forwards Estación Faro presence over the BLE link.
      link.inbound.add(
        const VrDesktopBridgeState(
          revision: 1,
          stationConnected: true,
          stationName: 'Faro Mac SAIA',
          castOffloadedToDesktop: true,
          visionOffloadedToDesktop: true,
          recommendedJoystickHz: 120,
        ).toJsonMessage(),
      );
      await tester.pump();

      // Transport stays Bluetooth LE — never relabeled FARO WI-FI!
      expect(find.byIcon(Icons.bluetooth_rounded), findsWidgets);
      expect(find.byIcon(Icons.wifi_tethering_rounded), findsNothing);
      expect(find.text('FARO WI-FI · ACTIVO'), findsNothing);

      // Drag left thumbstick across 200 ms (25 ticks of 8 ms): BLE pacing (~30 Hz = 33.3 ms) caps analog sends!
      final stickCenter = tester.getCenter(find.byType(VirtualThumbstick).first);
      final gesture = await tester.startGesture(stickCenter);
      fakeNowUs += 40000;
      await gesture.moveBy(const Offset(0, -14));
      await tester.pump(const Duration(milliseconds: 40));

      final baselineCount = link.sent.length;
      for (var i = 0; i < 25; i++) {
        fakeNowUs += 8000;
        await gesture.moveBy(const Offset(0, -1.0));
        await tester.pump(const Duration(milliseconds: 8));
      }
      final bleAnalogSends = link.sent.length - baselineCount;
      expect(bleAnalogSends, inInclusiveRange(4, 8));

      await gesture.up();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'SAIA-FARO-007 #2: Faro Wi-Fi external link without VrObservableControllerLink paces analog states at 8 ms (120 Hz)',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(960, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      var fakeNowUs = 1000000;
      final link = _TestLink();
      addTearDown(link.close);

      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            autoConnect: true,
            allowWifiConnection: false,
            externalLinkOverWifi: true,
            connectionLabel: 'Faro Mac SAIA',
            linkConnector: () async => link,
            monotonicMicroseconds: () => fakeNowUs,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      link.inbound.add(
        const VrDesktopBridgeState(
          revision: 1,
          stationConnected: true,
          stationName: 'Faro Mac SAIA',
          castOffloadedToDesktop: true,
          visionOffloadedToDesktop: true,
          recommendedJoystickHz: 120,
        ).toJsonMessage(),
      );
      await tester.pump();

      final stickCenter = tester.getCenter(find.byType(VirtualThumbstick).first);
      final gesture = await tester.startGesture(stickCenter);
      fakeNowUs += 40000;
      await gesture.moveBy(const Offset(0, -14));
      await tester.pump(const Duration(milliseconds: 40));

      final baselineCount = link.sent.length;
      for (var i = 0; i < 25; i++) {
        fakeNowUs += 8000;
        await gesture.moveBy(const Offset(0, -1.0));
        await tester.pump(const Duration(milliseconds: 8));
      }
      final faro120HzSends = link.sent.length - baselineCount;
      // With 8 ms customAnalogInterval, 25 distinct 8 ms moves produce >= 22 sends (vs <= 13 under the old 16 ms cap).
      expect(faro120HzSends, greaterThanOrEqualTo(22));

      await gesture.up();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
