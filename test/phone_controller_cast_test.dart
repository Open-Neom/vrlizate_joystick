import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class Link implements VrControllerLink {
  final input = StreamController<Object?>();
  final packets = <Object>[];
  bool open = true;
  @override
  bool get isOpen => open;
  @override
  Stream<Object?> get messages => input.stream;
  @override
  void add(Object data) => packets.add(data);
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!open) return;
    open = false;
    unawaited(input.close());
  }

  void offer(Object? url) =>
      input.add(jsonEncode({'type': 'cast_preview', 'url': url}));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channels = [
    'dev.fluttercommunity.plus/sensors/method',
    'dev.fluttercommunity.plus/sensors/gyroscope',
    'dev.fluttercommunity.plus/sensors/accelerometer',
    'dev.fluttercommunity.plus/sensors/user_accel',
  ];
  final uri = 'http://192.168.100.14:12345/?token=${'ab' * 32}';
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });
  tearDown(() {
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });
  Future<Link> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(850, 390));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final link = Link();
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          allowWifiConnection: false,
          autoConnect: true,
          linkConnector: () async => link,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(link.packets, isNotEmpty);
    return link;
  }

  testWidgets(
    'BLE offer starts video automatically; closing it leaves controller connected',
    (tester) async {
      final link = await mount(tester);
      link.offer(uri);
      await tester.pump();
      await tester.pump();
      expect(find.byType(VrCastPreview), findsOneWidget);
      expect(find.byKey(const ValueKey('right_mode_laser')), findsOneWidget);
      final count = link.packets.length;
      await tester.pump(const Duration(milliseconds: 2100));
      expect(link.isOpen, isTrue);
      await tester.tap(find.byKey(const ValueKey('right_mode_laser')));
      await tester.pump();
      expect(
        link.packets.length,
        greaterThan(count),
        reason: 'Control commands survive a failed video request.',
      );
      await tester.tap(find.byKey(const ValueKey('controller-cast-toggle')));
      await tester.pump();
      expect(find.byType(VrCastPreview), findsNothing);
      expect(link.isOpen, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('invalid offers cannot replace session; null stops video only', (
    tester,
  ) async {
    final link = await mount(tester);
    link.offer(uri);
    await tester.pump();
    link.offer('http://public.example:1234/?token=${'ab' * 32}');
    await tester.pump();
    expect(
      tester.widget<VrCastPreview>(find.byType(VrCastPreview)).uri.toString(),
      uri,
    );
    link.offer(null);
    await tester.pump();
    await tester.pump();
    expect(find.byType(VrCastPreview), findsNothing);
    expect(link.isOpen, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  for (final mode in [RemoteControllerMode.nes, RemoteControllerMode.driving]) {
    testWidgets('automatic preview remains embedded in ${mode.name} controls', (
      tester,
    ) async {
      final link = await mount(tester);
      link.input.add(
        jsonEncode(VrControllerModeRequest(mode: mode, revision: 1).toJson()),
      );
      await tester.pump();
      await tester.pump();
      link.offer(uri);
      await tester.pump();
      await tester.pump();
      expect(find.byType(VrCastPreview), findsOneWidget);
      expect(
        find.byKey(
          ValueKey(
            mode == RemoteControllerMode.nes
                ? 'nes_button_A'
                : 'driving_throttle_pedal',
          ),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Proyectar en otro dispositivo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
