import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _CapturedLink implements VrControllerLink {
  // The real link buffers authenticated host messages until its sole listener
  // attaches. A broadcast fixture can silently drop the initial snapshot.
  final _incoming = StreamController<Object?>();
  final packets = <Map<String, dynamic>>[];
  bool _open = true;

  @override
  bool get isOpen => _open;
  void emit(Map<String, dynamic> message) => _incoming.add(jsonEncode(message));
  void disconnect() {
    _open = false;
    unawaited(_incoming.close());
  }

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void add(Object data) {
    if (data is String) {
      packets.add(jsonDecode(data) as Map<String, dynamic>);
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    await _incoming.close();
  }
}

Future<void> _pumpHostMessage(WidgetTester tester) async {
  // Stream delivery/setState and the frame displaying that state are separate
  // phases. Reading a widget after just the delivery pump sees its old fields.
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sensorChannels = [
    'dev.fluttercommunity.plus/sensors/method',
    'dev.fluttercommunity.plus/sensors/gyroscope',
    'dev.fluttercommunity.plus/sensors/accelerometer',
    'dev.fluttercommunity.plus/sensors/user_accel',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final channel in sensorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });

  tearDown(() {
    for (final channel in sensorChannels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), null);
    }
  });

  testWidgets(
    'visor feedback updates the bar without sending camera commands or replaying stale state',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final link = _CapturedLink();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            allowWifiConnection: false,
            transportType: VrTransportType.bluetoothLe,
            autoConnect: true,
            linkConnector: () async => link,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      void feedback(int revision, double mix, bool enabled) => link.emit({
        'type': 'vrlizate.passthrough.state',
        'revision': revision,
        'passthroughMix': mix,
        'cameraEnabled': enabled,
      });
      double shownMix() => tester
          .widget<VrBreakthroughCurtainBar>(
            find.byType(VrBreakthroughCurtainBar),
          )
          .passthroughMix;
      link.packets.clear();
      feedback(4, .65, true);
      await _pumpHostMessage(tester);
      expect(shownMix(), .65);
      expect(
        link.packets.where((p) => p['passthroughCommand'] == true),
        isEmpty,
      );
      expect(
        link.packets.where((p) => p['type'] == 'vrlizate.passthrough'),
        isEmpty,
      );
      feedback(5, 0, false);
      await _pumpHostMessage(tester);
      feedback(4, .65, true);
      await _pumpHostMessage(tester);
      expect(shownMix(), 0);
      feedback(99, 2, true); // Invalid values cannot consume the revision.
      feedback(6, .65, true);
      await _pumpHostMessage(tester);
      expect(shownMix(), .65);
      link.packets.clear();
      final heldStick = await tester.startGesture(
        tester.getCenter(
          find.byKey(const ValueKey(VrJoystickConstants.keyJoystickMoveStick)),
        ),
        pointer: 41,
      );
      await tester.tap(
        find.byKey(
          const ValueKey(VrJoystickConstants.keyBreakthroughCenterBar),
        ),
        pointer: 42,
      );
      await tester.pump();
      await heldStick.up();
      await tester.pump();
      final commands = link.packets.where(
        (p) => p['passthroughCommand'] == true,
      );
      expect(commands, hasLength(1));
      expect(commands.single['passthroughMix'], 1.0);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unconfirmed and offline controls never claim the visor is OFF', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final link = _CapturedLink();
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          allowWifiConnection: false,
          transportType: VrTransportType.bluetoothLe,
          autoConnect: true,
          linkConnector: () async => link,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final bar = find.byType(VrBreakthroughCurtainBar);
    final tap = find.byKey(
      const ValueKey(VrJoystickConstants.keyBreakthroughCenterBar),
    );
    expect(tester.widget<VrBreakthroughCurtainBar>(bar).synchronized, isFalse);
    link.packets.clear();
    await tester.tap(tap);
    await tester.pump();
    expect(link.packets.where((p) => p['passthroughCommand'] == true), isEmpty);
    link.emit({
      'type': 'vrlizate.passthrough.state',
      'revision': 1,
      'passthroughMix': .65,
      'cameraEnabled': true,
    });
    await _pumpHostMessage(tester);
    await tester.tap(tap); // Requested 100%; no visor acknowledgement.
    await tester.pump();
    await tester.tap(tap); // Requested OFF; still no acknowledgement.
    await tester.pump();
    expect(tester.widget<VrBreakthroughCurtainBar>(bar).pending, isTrue);
    expect(tester.widget<VrBreakthroughCurtainBar>(bar).passthroughMix, .65);
    expect(find.text('ESPERANDO VISOR'), findsOneWidget);
    link.disconnect();
    await _pumpHostMessage(tester);
    expect(tester.widget<VrBreakthroughCurtainBar>(bar).connected, isFalse);
    expect(find.text('SIN CONEXIÓN · RECONECTAR'), findsOneWidget);
    link.packets.clear();
    await tester.tap(tap);
    await tester.pump();
    expect(link.packets.where((p) => p['passthroughCommand'] == true), isEmpty);
    await tester.tap(find.byTooltip('Ajustes y Modo'));
    await tester.pump(const Duration(milliseconds: 100));
    final settingsSliders = tester.widgetList<Slider>(find.byType(Slider));
    expect(
      settingsSliders.any(
        (s) => s.max == 1 && s.min == 0 && s.onChanged == null,
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'open settings refresh on visor acknowledgement and disconnection',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(960, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final link = _CapturedLink();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            allowWifiConnection: false,
            transportType: VrTransportType.bluetoothLe,
            autoConnect: true,
            linkConnector: () async => link,
          ),
        ),
      );
      await _pumpHostMessage(tester);
      await tester.pump(const Duration(milliseconds: 100));
      void feedback(int revision, double mix) => link.emit({
        'type': 'vrlizate.passthrough.state',
        'revision': revision,
        'passthroughMix': mix,
        'cameraEnabled': mix > .01,
      });
      feedback(1, .65);
      await _pumpHostMessage(tester);
      await tester.tap(find.byTooltip('Ajustes y Modo'));
      await tester.pump(const Duration(milliseconds: 400));
      final sliderFinder = find.byKey(
        const ValueKey('joystick_passthrough_settings_slider'),
      );
      final statusFinder = find.byKey(
        const ValueKey('joystick_passthrough_settings_status'),
      );
      Slider slider() => tester.widget<Slider>(sliderFinder);
      String? status() => tester.widget<Text>(statusFinder).data;
      expect(slider().value, .65);
      expect(status(), '65%');
      slider().onChanged!(0);
      await _pumpHostMessage(tester);
      expect(status(), 'Esperando visor');
      feedback(2, 0);
      await _pumpHostMessage(tester);
      expect(status(), '0%');
      expect(slider().value, 0);
      feedback(3, .65);
      await _pumpHostMessage(tester);
      expect(status(), '65%');
      expect(slider().value, .65);
      link.disconnect();
      await _pumpHostMessage(tester);
      expect(status(), 'Sin conexión · reconectar');
      expect(slider().onChanged, isNull);
      expect(slider().onChangeEnd, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('only deliberate passthrough actions carry command intent', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final link = _CapturedLink();
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          allowWifiConnection: false,
          transportType: VrTransportType.bluetoothLe,
          autoConnect: true,
          linkConnector: () async => link,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    link.emit({
      'type': 'vrlizate.passthrough.state',
      'revision': 1,
      'passthroughMix': 0.0,
      'cameraEnabled': false,
    });
    await _pumpHostMessage(tester);
    expect(link.packets, isNotEmpty);
    expect(
      link.packets.where(
        (packet) => packet[VrJoystickConstants.fieldPassthroughCommand] == true,
      ),
      isEmpty,
      reason: 'Connecting reports retained state without opening a camera.',
    );

    link.packets.clear();
    await tester.tap(
      find.byKey(const ValueKey(VrJoystickConstants.keyBreakthroughCenterBar)),
    );
    await tester.pump();
    final explicitCommands = link.packets.where(
      (packet) => packet[VrJoystickConstants.fieldPassthroughCommand] == true,
    );
    expect(explicitCommands, hasLength(1));
    expect(
      explicitCommands.single[VrJoystickConstants.fieldPassthroughMix],
      closeTo(.65, .000001),
    );

    link.packets.clear();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      link.packets.where(
        (packet) => packet[VrJoystickConstants.fieldPassthroughCommand] == true,
      ),
      isEmpty,
      reason: 'Ordinary timer snapshots cannot replay the action.',
    );
    await tester.tap(
      find.byKey(const ValueKey(VrJoystickConstants.keySpatialHudToggle)),
    );
    await tester.pump();
    expect(
      link.packets.where(
        (packet) => packet[VrJoystickConstants.fieldPassthroughCommand] == true,
      ),
      isEmpty,
      reason: 'The HUD toggle does not express a camera command.',
    );

    await tester.tap(find.byTooltip('Ajustes y Modo'));
    await tester.pump(const Duration(milliseconds: 400));
    final mixSliders = tester
        .widgetList<Slider>(find.byType(Slider))
        .where((slider) => (slider.value - .65).abs() < .000001);
    expect(mixSliders, hasLength(1));
    link.packets.clear();
    // A release on the existing thumb is a fresh action even at the same mix.
    mixSliders.single.onChangeEnd!(.65);
    await tester.pump();
    expect(
      link.packets.where(
        (packet) => packet[VrJoystickConstants.fieldPassthroughCommand] == true,
      ),
      hasLength(1),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(tester.takeException(), isNull);
  });
}
