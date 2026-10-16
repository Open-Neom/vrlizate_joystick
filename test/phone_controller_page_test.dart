import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/src/vr_controller_region.dart';
import 'package:vrlizate_joystick/src/nes_controller_layout.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _CapturedControllerLink implements VrControllerLink {
  final inbound = StreamController<Object?>();
  final packets = <Map<String, dynamic>>[];
  bool _open = true;

  @override
  bool get isOpen => _open;
  @override
  Stream<Object?> get messages => inbound.stream;
  @override
  void add(Object data) =>
      packets.add(jsonDecode(data as String) as Map<String, dynamic>);
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_open) return;
    _open = false;
    await inbound.close();
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String reason = 'controller state',
}) async {
  // Real sockets progress outside fake async. Bound elapsed wall time instead
  // of assuming 100 pumps is enough when other Flutter suites run in parallel.
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 5)) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $reason.');
}

Offset _buttonPoint(WidgetTester tester, String button) {
  final finder = find.byKey(ValueKey('joystick_button_$button'));
  final region = tester.widget(finder);
  return region is VrControllerRegion
      ? tester.getTopLeft(finder) + region.labelPosition
      : tester.getCenter(finder);
}

Future<void> _selectRightMode(
  WidgetTester tester, {
  required bool laser,
}) async {
  await tester.tap(
    find.byKey(ValueKey(laser ? 'right_mode_laser' : 'right_mode_view')),
    pointer: 99,
  );
  await tester.pump();
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

  Future<void> nesHostRequest(
    WidgetTester tester,
    _CapturedControllerLink link,
    int revision,
    RemoteControllerMode mode, {
    Map<String, String> actions = const {},
  }) async {
    link.inbound.add(
      jsonEncode(
        VrControllerModeRequest(
          mode: mode,
          revision: revision,
          actions: actions,
        ).toJson(),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          link.packets.any((packet) => packet['hostModeRevision'] == revision),
    );
  }

  Future<_CapturedControllerLink> openNes(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final link = _CapturedControllerLink();
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          initialMode: RemoteControllerMode.joystick,
          allowWifiConnection: false,
          linkConnector: () async => link,
          autoConnect: true,
        ),
      ),
    );
    await _pumpUntil(tester, () => link.packets.isNotEmpty);
    await nesHostRequest(tester, link, 1, RemoteControllerMode.nes);
    await tester.pump(const Duration(milliseconds: 150));
    return link;
  }

  testWidgets(
    'NES host profile exposes exact cartridge button mappings and Home',
    (tester) async {
      final link = await openNes(tester);
      expect(find.byType(VirtualThumbstick), findsNothing);
      expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
      expect(find.byKey(const ValueKey('joystick_recenter')), findsNothing);
      for (final (label, wire) in [
        ('A', 'btnA'),
        ('B', 'btnX'),
        ('start', 'btnY'),
        ('select', 'btnL'),
        ('home', 'btnB'),
      ]) {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('nes_button_$label'))),
        );
        await tester.pump();
        final packet = link.packets.last;
        expect(packet['mode'], 'nes');
        expect(packet[wire], isTrue);
        for (final other in [
          'btnA',
          'btnB',
          'btnX',
          'btnY',
          'btnL',
          'btnR',
          'btnGrip',
        ]) {
          expect(packet[other], other == wire);
        }
        expect(packet['action'], label == 'home');
        expect(packet['trigger'], isFalse);
        expect(packet['lookX'], 0);
        expect(packet['lookY'], 0);
        await gesture.up();
        await tester.pump();
        expect(link.packets.last[wire], isFalse);
      }
      final home = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('nes_button_home'))),
      );
      await tester.pump();
      expect(link.packets.last['btnB'], isTrue);
      await nesHostRequest(tester, link, 2, RemoteControllerMode.joystick);
      expect(find.byType(VirtualThumbstick), findsNWidgets(2));
      expect(link.packets.last['btnB'], isFalse);
      await home.up();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'NES cruceta supports two fingers, diagonals, opposing inputs and independent releases',
    (tester) async {
      final link = await openNes(tester);
      final pad = tester.getRect(find.byKey(const ValueKey('nes_dpad')));
      final up = await tester.startGesture(
        Offset(pad.center.dx, pad.top + pad.height * .13),
        pointer: 1,
      );
      final right = await tester.startGesture(
        Offset(pad.left + pad.width * .86, pad.center.dy),
        pointer: 2,
      );
      final a = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('nes_button_A'))),
        pointer: 3,
      );
      await tester.pump();
      expect(link.packets.last['stickX'], 1);
      expect(link.packets.last['stickY'], 1);
      expect(link.packets.last['btnA'], isTrue);
      await up.up();
      await tester.pump();
      expect(link.packets.last['stickX'], 1);
      expect(link.packets.last['stickY'], 0);
      final secondRight = await tester.startGesture(
        Offset(pad.right - 12, pad.center.dy),
        pointer: 4,
      );
      await right.up();
      await tester.pump();
      expect(link.packets.last['stickX'], 1);
      final left = await tester.startGesture(
        Offset(pad.left + 12, pad.center.dy),
        pointer: 5,
      );
      await tester.pump();
      expect(link.packets.last['stickX'], 0);
      await left.cancel();
      await tester.pump();
      expect(link.packets.last['stickX'], 1);
      await secondRight.cancel();
      await a.up();
      await tester.pump();
      expect(link.packets.last['stickX'], 0);
      expect(link.packets.last['btnA'], isFalse);
      final diagonal = await tester.startGesture(
        Offset(pad.left + pad.width * .85, pad.top + pad.height * .15),
        pointer: 6,
      );
      await tester.pump();
      expect(
        (link.packets.last['stickX'], link.packets.last['stickY']),
        (1.0, 1.0),
      );
      await diagonal.moveTo(
        Offset(pad.left + pad.width * .15, pad.top + pad.height * .85),
      );
      await tester.pump();
      expect(
        (link.packets.last['stickX'], link.packets.last['stickY']),
        (-1.0, -1.0),
      );
      await diagonal.moveTo(Offset(pad.right + 20, pad.center.dy));
      await tester.pump();
      expect(
        (link.packets.last['stickX'], link.packets.last['stickY']),
        (0.0, 0.0),
      );
      await diagonal.up();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'NES captions preserve holds, transitions and lifecycle discard old fingers',
    (tester) async {
      final link = await openNes(tester);
      final pad = tester.getRect(find.byKey(const ValueKey('nes_dpad')));
      final up = await tester.startGesture(
        Offset(pad.center.dx, pad.top + 15),
        pointer: 1,
      );
      final a = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('nes_button_A'))),
        pointer: 2,
      );
      await tester.pump();
      await nesHostRequest(
        tester,
        link,
        2,
        RemoteControllerMode.nes,
        actions: const {'A': 'Saltar', 'X': 'Disparar'},
      );
      expect(find.text('Saltar'), findsOneWidget);
      expect(find.text('Disparar'), findsOneWidget);
      expect(link.packets.last['btnA'], isTrue);
      expect(link.packets.last['stickY'], 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(link.packets.last['btnA'], isFalse);
      expect(link.packets.last['stickY'], 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await up.moveBy(const Offset(1, 1));
      await a.up();
      await up.up();
      await tester.pump();
      expect(link.packets.last['btnA'], isFalse);
      expect(link.packets.last['stickY'], 0);
      final b = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('nes_button_B'))),
        pointer: 4,
      );
      await tester.pump();
      expect(link.packets.last['btnX'], isTrue);
      await nesHostRequest(tester, link, 3, RemoteControllerMode.driving);
      expect(link.packets.last['btnX'], isFalse);
      expect(find.byKey(const ValueKey('nes_dpad')), findsNothing);
      await b.up();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('NES disconnect replaces the surface with neutral controls', (
    tester,
  ) async {
    final link = await openNes(tester);
    final a = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('nes_button_A'))),
    );
    await tester.pump();
    expect(link.packets.last['btnA'], isTrue);
    link.inbound.addError(StateError('Disconnected test transport'));
    await _pumpUntil(
      tester,
      () => !tester
          .widget<NesControllerLayout>(find.byType(NesControllerLayout))
          .connected,
    );
    final surface = tester.widget<NesControllerLayout>(
      find.byType(NesControllerLayout),
    );
    expect(surface.connected, isFalse);
    expect(surface.pressed, isEmpty);
    await a.up();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'NES resize invalidates old gestures before the first new button press',
    (tester) async {
      final link = await openNes(tester);
      final pad = tester.getRect(find.byKey(const ValueKey('nes_dpad')));
      final oldPad = await tester.startGesture(
        Offset(pad.center.dx, pad.top + 10),
        pointer: 1,
      );
      await tester.pump();
      expect(link.packets.last['stickY'], 1);
      await tester.binding.setSurfaceSize(const Size(640, 320));
      await tester.pump();
      expect(link.packets.last['stickY'], 0);
      final first = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('nes_button_B'))),
        pointer: 2,
      );
      await tester.pump();
      expect(link.packets.last['btnX'], isTrue);
      final second = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('nes_button_B'))),
        pointer: 3,
      );
      await tester.pump();
      await first.up();
      await oldPad.moveBy(const Offset(5, 0));
      await oldPad.up();
      await tester.pump();
      expect(link.packets.last['btnX'], isTrue);
      expect(link.packets.last['stickY'], 0);
      await second.up();
      await tester.pump();
      expect(link.packets.last['btnX'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(480, 280),
    const Size(800, 360),
    const Size(1024, 768),
  ]) {
    testWidgets('NES controls fit $size with large text and a notch', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.8),
              padding: const EdgeInsets.only(left: 28),
              viewPadding: const EdgeInsets.only(left: 28),
            ),
            child: child!,
          ),
          home: const PhoneControllerPage(
            initialMode: RemoteControllerMode.nes,
            allowWifiConnection: false,
          ),
        ),
      );
      await tester.pump();
      final surface = tester.getRect(find.byKey(const ValueKey('nes_surface')));
      for (final key in [
        'nes_dpad',
        'nes_button_A',
        'nes_button_B',
        'nes_button_select',
        'nes_button_start',
        'nes_button_home',
      ]) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(surface.contains(rect.topLeft), isTrue);
        expect(
          surface.contains(rect.bottomRight - const Offset(.1, .1)),
          isTrue,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  for (final (size, insets, textScale) in [
    (const Size(480, 280), EdgeInsets.zero, 1.2),
    (const Size(640, 320), EdgeInsets.zero, 1.2),
    (const Size(800, 360), EdgeInsets.zero, 1.2),
    (const Size(960, 420), EdgeInsets.zero, 1.2),
    (const Size(1024, 768), EdgeInsets.zero, 1.2),
    (const Size(640, 320), const EdgeInsets.only(left: 48), 2.0),
    (const Size(640, 320), const EdgeInsets.only(right: 48), 2.0),
  ]) {
    testWidgets('edge bands fit landscape $size, $insets, $textScale', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              padding: insets,
              viewPadding: insets,
              textScaler: TextScaler.linear(textScale),
            ),
            child: child!,
          ),
          home: const PhoneControllerPage(
            targetHost: '127.0.0.1',
            isChildRole: true,
          ),
        ),
      );
      await tester.pump();
      final bounds = tester.getRect(
        find.byKey(const ValueKey('joystick_surface')),
      );
      final regions = <String, Rect>{};
      final paths = <String, Path>{};
      for (final key in [
        'joystick_button_L',
        'joystick_button_R',
        'joystick_button_Y',
        'joystick_button_X',
        'joystick_button_B',
        'joystick_button_A',
        'joystick_move_stick',
        'joystick_look_stick',
        'joystick_recenter',
      ]) {
        final finder = find.byKey(ValueKey(key));
        expect(finder, findsOneWidget, reason: key);
        final region = tester.getRect(finder);
        expect(region.left, greaterThanOrEqualTo(bounds.left - 1e-6));
        expect(region.top, greaterThanOrEqualTo(bounds.top - 1e-6));
        expect(region.right, lessThanOrEqualTo(bounds.right + 1e-6));
        expect(region.bottom, lessThanOrEqualTo(bounds.bottom + 1e-6));
        final Path path;
        if (key.startsWith('joystick_button_')) {
          final widget = tester.widget<VrControllerRegion>(finder);
          path = widget.path.shift(region.topLeft);
          expect(widget.path.contains(widget.labelPosition), isTrue);
          expect(
            tester.hitTestOnBinding(region.topLeft + widget.labelPosition).path,
            isNotEmpty,
          );
        } else if (key.endsWith('_stick')) {
          path = Path()..addOval(region);
        } else {
          path = Path()..addRect(region);
        }
        for (final existing in paths.entries) {
          expect(
            Path.combine(
              PathOperation.intersect,
              path,
              existing.value,
            ).computeMetrics(),
            isEmpty,
            reason: '$key overlaps ${existing.key}',
          );
        }
        regions[key] = region;
        paths[key] = path;
      }
      expect(bounds, Offset.zero & size);
      for (final (key, point) in [
        ('L', const Offset(1, 1)),
        ('R', Offset(size.width - 1, 1)),
        ('X', Offset(1, size.height - 1)),
        ('A', Offset(size.width - 1, size.height - 1)),
        ('Y', Offset(1, regions['joystick_move_stick']!.center.dy)),
        (
          'B',
          Offset(size.width - 1, regions['joystick_look_stick']!.center.dy),
        ),
      ]) {
        expect(paths['joystick_button_$key']!.contains(point), isTrue);
      }
      expect(
        tester
                .widget<VrControllerRegion>(
                  find.byKey(const ValueKey('joystick_button_Y')),
                )
                .labelPosition
                .dx +
            regions['joystick_button_Y']!.left,
        lessThan(regions['joystick_move_stick']!.left),
      );
      expect(
        tester
                .widget<VrControllerRegion>(
                  find.byKey(const ValueKey('joystick_button_B')),
                )
                .labelPosition
                .dx +
            regions['joystick_button_B']!.left,
        greaterThan(regions['joystick_look_stick']!.right),
      );
      expect(
        tester.getCenter(find.text('L')).dy,
        lessThan(regions['joystick_button_Y']!.top),
      );
      expect(
        regions['joystick_button_X']!.top,
        greaterThan(regions['joystick_button_Y']!.bottom),
      );
      expect(
        regions['joystick_button_A']!.shortestSide,
        greaterThanOrEqualTo(44),
      );
      expect(find.text('GATILLO (CLIC)'), findsNothing);
      expect(find.byType(VirtualThumbstick), findsNWidgets(2));
      expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
      expect(
        find.byKey(const ValueKey('controller_center_panel')),
        findsOneWidget,
      );
      expect(
        regions['joystick_look_stick']!.width,
        lessThan(regions['joystick_move_stick']!.width),
      );
      await _selectRightMode(tester, laser: true);
      expect(find.byKey(const ValueKey('joystick_look_stick')), findsNothing);
      expect(find.byType(VirtualThumbstick), findsOneWidget);
      final laserRect = tester.getRect(
        find.byKey(const ValueKey('laser_slide_pad')),
      );
      expect(laserRect, regions['joystick_look_stick']);
      await _selectRightMode(tester, laser: false);
      expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'controller requests landscape on entry and leaves orientation alone on dispose',
    (tester) async {
      final orientationRequests = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'SystemChrome.setPreferredOrientations') {
              orientationRequests.add(call.arguments);
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        const MaterialApp(home: PhoneControllerPage(targetHost: '127.0.0.1')),
      );
      await tester.pump();
      expect(orientationRequests.single, [
        'DeviceOrientation.landscapeLeft',
        'DeviceOrientation.landscapeRight',
      ]);
      orientationRequests.clear();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(orientationRequests, isEmpty);
    },
  );

  for (final laserMode in [false, true]) {
    testWidgets(
      '${laserMode ? 'Laser' : 'View'} controls support four fingers and release each owner safely',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 360));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = VrRemoteControllerService(
          inputTimeout: const Duration(seconds: 10),
        );
        addTearDown(service.dispose);
        expect(
          await tester.runAsync(() => service.startServer(port: 0)),
          isTrue,
        );
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
        await _pumpUntil(
          tester,
          () =>
              service.isConnected &&
              find.text('RECONECTAR').evaluate().isNotEmpty,
        );
        if (laserMode) await _selectRightMode(tester, laser: true);
        final movement = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('joystick_move_stick'))),
          pointer: 1,
        );
        await movement.moveBy(const Offset(25, 0));
        await movement.moveBy(const Offset(15, 0));
        final look = await tester.startGesture(
          tester.getCenter(
            find.byKey(
              ValueKey(laserMode ? 'laser_slide_pad' : 'joystick_look_stick'),
            ),
          ),
          pointer: 2,
        );
        await look.moveBy(const Offset(0, -25));
        await look.moveBy(const Offset(0, -15));
        final a = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('joystick_button_A'))),
          pointer: 3,
        );
        final l = await tester.startGesture(
          tester.getCenter(find.text('L')),
          pointer: 4,
        );
        await tester.pump(const Duration(milliseconds: 350));
        await _pumpUntil(
          tester,
          () =>
              service.latestState.stickX > .2 &&
              (laserMode
                  ? service.latestState.laserY > .2
                  : service.latestState.lookY > .2) &&
              service.latestState.btnA &&
              service.latestState.btnL &&
              service.latestState.btnGrip == laserMode,
        );
        expect(service.latestState.laserSlideActive, laserMode);
        expect(service.latestState.lookX, 0);
        if (laserMode) expect(service.latestState.lookY, 0);
        expect(service.latestState.btnR, isFalse);

        await a.cancel();
        await _pumpUntil(tester, () => !service.latestState.btnA);
        expect(service.latestState.btnL, isTrue);
        expect(service.latestState.btnGrip, laserMode);
        expect(service.latestState.stickX, greaterThan(.2));
        await look.cancel();
        await _pumpUntil(
          tester,
          () =>
              service.latestState.lookY == 0 &&
              !service.latestState.laserSlideActive &&
              !service.latestState.btnGrip,
        );
        expect(service.latestState.stickX, greaterThan(.2));

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await _pumpUntil(
          tester,
          () =>
              !service.latestState.btnL &&
              !service.latestState.btnGrip &&
              !service.latestState.laserSlideActive &&
              service.latestState.stickX == 0,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await movement.up();
        await l.up();
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          service.latestState.btnA ||
              service.latestState.btnL ||
              service.latestState.btnGrip,
          isFalse,
        );
        expect(service.latestState.stickX, 0);
        expect(service.latestState.lookY, 0);
        final heldA = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('joystick_button_A'))),
          pointer: 6,
        );
        final heldMove = await tester.startGesture(
          tester.getCenter(find.byKey(const ValueKey('joystick_move_stick'))),
          pointer: 7,
        );
        await heldMove.moveBy(const Offset(40, 0));
        await _pumpUntil(
          tester,
          () => service.latestState.btnA && service.latestState.stickX > .2,
        );
        await tester.tap(find.byTooltip('Ajustes y Modo'));
        await tester.pumpAndSettle();
        await _pumpUntil(
          tester,
          () => !service.latestState.btnA && service.latestState.stickX == 0,
          reason: 'settings neutralizes held inputs without watchdog',
        );
        await heldMove.moveBy(const Offset(15, 0));
        await tester.tap(find.byIcon(Icons.close_rounded));
        await tester.pumpAndSettle();
        await heldA.up();
        await heldMove.up();
        expect(service.latestState.btnA, isFalse);
        expect(service.latestState.stickX, 0);
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpUntil(tester, () => !service.isConnected);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'right-mode changes release held controls and stale gestures without reconnecting',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final link = _CapturedControllerLink();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            allowWifiConnection: false,
            linkConnector: () async => link,
            autoConnect: true,
          ),
        ),
      );
      await _pumpUntil(tester, () => link.packets.isNotEmpty);
      await tester.pump();
      final rightBounds = tester.getRect(
        find.byKey(const ValueKey('joystick_look_stick')),
      );
      final movement = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('joystick_move_stick'))),
        pointer: 1,
      );
      await movement.moveBy(const Offset(70, 0));
      final view = await tester.startGesture(rightBounds.center, pointer: 2);
      await view.moveBy(const Offset(15, -25));
      final action = await tester.startGesture(
        _buttonPoint(tester, 'A'),
        pointer: 3,
      );
      await tester.pump(const Duration(milliseconds: 350));
      await _pumpUntil(
        tester,
        () =>
            (link.packets.last['stickX'] as num) > .2 &&
            (link.packets.last['lookY'] as num) > .1 &&
            link.packets.last['btnA'] == true,
      );
      expect(link.packets.last['lookX'], 0);
      expect(link.packets.last['moveAtEdge'], isTrue);

      void expectNeutral() {
        final packet = link.packets.last;
        for (final field in [
          'stickX',
          'stickY',
          'lookX',
          'lookY',
          'laserX',
          'laserY',
        ]) {
          expect(packet[field], 0, reason: field);
        }
        for (final field in [
          'btnA',
          'btnB',
          'btnL',
          'btnR',
          'btnGrip',
          'laserSlideActive',
          'moveAtEdge',
        ]) {
          expect(packet[field], isFalse, reason: field);
        }
        expect(packet['mode'], 'joystick');
        expect(link.isOpen, isTrue);
      }

      await _selectRightMode(tester, laser: true);
      expect(find.byKey(const ValueKey('joystick_look_stick')), findsNothing);
      expect(
        tester.getRect(find.byKey(const ValueKey('laser_slide_pad'))),
        rightBounds,
      );
      expectNeutral();
      await movement.moveBy(const Offset(-15, 0));
      await view.moveBy(const Offset(0, 15));
      await action.up();
      await movement.up();
      await view.up();
      await tester.pump(const Duration(milliseconds: 100));
      expectNeutral();

      // Cover both a pending hold timer and an already-active grip. Changing
      // mode must invalidate the old pointer before either can alter the view.
      for (final holdMs in [100, 350]) {
        await _selectRightMode(tester, laser: true);
        final laser = await tester.startGesture(rightBounds.center, pointer: 4);
        await laser.moveBy(const Offset(15, -15));
        await tester.pump(Duration(milliseconds: holdMs));
        await _pumpUntil(
          tester,
          () => link.packets.last['laserSlideActive'] == true,
        );
        expect(link.packets.last['btnGrip'], holdMs >= 280);
        expect(link.packets.last['lookX'], 0);
        expect(link.packets.last['lookY'], 0);
        await _selectRightMode(tester, laser: false);
        expectNeutral();
        await laser.moveBy(const Offset(20, 10));
        await laser.up();
        await tester.pump(const Duration(milliseconds: 350));
        expectNeutral();
      }

      final nextView = await tester.startGesture(
        rightBounds.center,
        pointer: 5,
      );
      await nextView.moveBy(const Offset(20, -25));
      await tester.pump(const Duration(milliseconds: 100));
      await _pumpUntil(tester, () => (link.packets.last['lookY'] as num) > .1);
      expect(link.packets.last['lookX'], 0);
      expect(link.packets.last['laserX'], 0);
      expect(link.packets.last['laserY'], 0);
      expect(link.packets.last['laserSlideActive'], isFalse);
      await nextView.up();
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('inner shoulders send L/R while outer edges still send Y/B', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = VrRemoteControllerService(
      inputTimeout: const Duration(seconds: 10),
    );
    addTearDown(service.dispose);
    expect(await tester.runAsync(() => service.startServer(port: 0)), isTrue);
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
    // Complete the connection's short double-pulse haptic feedback.
    await tester.pump(const Duration(milliseconds: 160));
    final leftStick = tester.getRect(
      find.byKey(const ValueKey('joystick_move_stick')),
    );
    final rightStick = tester.getRect(
      find.byKey(const ValueKey('joystick_look_stick')),
    );
    final leftRegion = tester.getRect(
      find.byKey(const ValueKey('joystick_button_L')),
    );
    final rightRegion = tester.getRect(
      find.byKey(const ValueKey('joystick_button_R')),
    );
    Set<String> active() => {
      if (service.latestState.btnL) 'L',
      if (service.latestState.btnR) 'R',
      if (service.latestState.btnY) 'Y',
      if (service.latestState.btnB) 'B',
    };
    for (final (key, point) in [
      ('L', Offset(leftRegion.right - 6, leftStick.top - 6)),
      ('R', Offset(rightRegion.left + 6, rightStick.top - 6)),
      ('Y', Offset(1, leftStick.center.dy)),
      ('B', Offset(799, rightStick.center.dy)),
    ]) {
      final finger = await tester.startGesture(point);
      await _pumpUntil(
        tester,
        () => active().contains(key),
        reason: '$key at $point',
      );
      expect(active(), {key}, reason: 'the region must emit exactly its owner');
      await finger.up();
      await _pumpUntil(tester, () => active().isEmpty);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(tester, () => !service.isConnected);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native controller opens joystick, sends A, and releases on pause',
    (tester) async {
      // A long watchdog means this test can only pass if the client actually
      // sends neutral input on pause; the watchdog has its own service test.
      final service = VrRemoteControllerService(
        inputTimeout: const Duration(seconds: 10),
      );
      addTearDown(service.dispose);
      expect(await tester.runAsync(() => service.startServer(port: 0)), isTrue);
      VrControllerConnectionTarget? authenticatedTarget;
      await HttpOverrides.runWithHttpOverrides(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: PhoneControllerPage(
              targetHost: '127.0.0.1',
              targetPort: service.serverPort!,
              sessionToken: service.sessionToken,
              autoConnect: true,
              onConnected: (target) => authenticatedTarget = target,
            ),
          ),
        );
        // The server accepts the upgrade before the client completes its
        // connect future and rebuilds. Wait for both ends, not server-only.
        await _pumpUntil(
          tester,
          () =>
              service.isConnected &&
              find.text('RECONECTAR').evaluate().isNotEmpty,
          reason: 'authenticated server and connected controller UI',
        );
        expect(find.text('RECONECTAR'), findsOneWidget);
        expect(authenticatedTarget?.host, '127.0.0.1');
        expect(authenticatedTarget?.port, service.serverPort);
        expect(authenticatedTarget?.token, service.sessionToken);
        expect(authenticatedTarget?.secure, isFalse);

        final gesture = await tester.startGesture(
          tester.getCenter(find.text('A')),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await _pumpUntil(
          tester,
          () => service.latestState.btnA,
          reason: 'primary A press packet',
        );

        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await _pumpUntil(
          tester,
          () => !service.latestState.btnA,
          reason: 'client neutral packet on pause',
        );
        expect(service.isConnected, isTrue);
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

  for (final (size, insets, scale) in [
    (const Size(480, 280), EdgeInsets.zero, 1.0),
    (const Size(640, 320), EdgeInsets.zero, 1.0),
    (const Size(800, 360), EdgeInsets.zero, 1.0),
    (const Size(640, 360), const EdgeInsets.only(left: 48), 1.3),
    (const Size(640, 360), const EdgeInsets.only(right: 48), 1.3),
  ]) {
    testWidgets(
      'driving pedals fit without touch steering at $size, $insets, $scale',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final previewPath =
            Platform.environment['VRLIZATE_DRIVING_PREVIEW_PATH'];
        final previewFont = Platform.environment['VRLIZATE_PREVIEW_FONT'];
        final capturePreview =
            size == const Size(800, 360) &&
            previewPath?.isNotEmpty == true &&
            previewFont?.isNotEmpty == true;
        if (capturePreview) {
          await tester.runAsync(() async {
            final bytes = await File(previewFont!).readAsBytes();
            final loader = FontLoader('DrivingPreview')
              ..addFont(Future.value(bytes.buffer.asByteData()));
            await loader.load();
          });
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              fontFamily: capturePreview ? 'DrivingPreview' : null,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: size,
                padding: insets,
                viewPadding: insets,
                textScaler: TextScaler.linear(scale),
              ),
              child: child!,
            ),
            home: const RepaintBoundary(
              key: ValueKey('driving_layout_capture'),
              child: PhoneControllerPage(
                targetHost: '127.0.0.1',
                initialMode: RemoteControllerMode.driving,
              ),
            ),
          ),
        );
        await tester.pump();
        for (final key in [
          for (final button in ['L', 'R', 'Y', 'X', 'B', 'A'])
            'joystick_button_$button',
          'driving_throttle_pedal',
          'driving_brake_pedal',
          'driving_wheel',
          'joystick_recenter',
        ]) {
          final finder = find.byKey(ValueKey(key));
          expect(finder, findsOneWidget);
          final bounds = tester.getRect(finder);
          expect(bounds.left, greaterThanOrEqualTo(insets.left));
          expect(bounds.right, lessThanOrEqualTo(size.width - insets.right));
          expect(bounds.top, greaterThanOrEqualTo(0));
          expect(bounds.bottom, lessThanOrEqualTo(size.height));
        }
        final wheel = tester.getRect(
          find.byKey(const ValueKey('driving_wheel')),
        );
        final brake = tester.getRect(
          find.byKey(const ValueKey('driving_brake_pedal')),
        );
        final throttle = tester.getRect(
          find.byKey(const ValueKey('driving_throttle_pedal')),
        );
        expect(brake.right, lessThan(wheel.left));
        expect(throttle.left, greaterThan(wheel.right));
        expect(brake.height, greaterThan(100));
        expect(throttle.height, greaterThan(100));
        expect(find.byType(VirtualThumbstick), findsNothing);
        expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
        expect(find.text('CENTRAR VOLANTE'), findsOneWidget);
        expect(find.text('PAUSAR').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capturePreview) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('driving_layout_capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            try {
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                previewPath!,
              ).writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('driving A pauses and resumes once while clearing old pedals', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = VrRemoteControllerService(
      inputTimeout: const Duration(seconds: 10),
    );
    addTearDown(service.dispose);
    expect(await tester.runAsync(() => service.startServer(port: 0)), isTrue);
    service.requestControllerMode(RemoteControllerMode.driving);
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
    await _pumpUntil(
      tester,
      () =>
          service.isConnected &&
          service.latestState.mode == RemoteControllerMode.driving &&
          find.text('CENTRAR VOLANTE').evaluate().isNotEmpty,
    );
    expect(service.latestState.drivingPaused, isFalse);
    final states = <RemoteControllerState>[];
    final subscription = service.onState.listen(states.add);
    addTearDown(subscription.cancel);
    final throttle = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('driving_throttle_pedal'))),
      pointer: 1,
    );
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.throttle > .05);
    final brake = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('driving_brake_pedal'))),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.brake > .05);

    states.clear();
    await tester.tapAt(_buttonPoint(tester, 'A'), pointer: 3);
    await _pumpUntil(tester, () => service.latestState.drivingPaused);
    expect(service.latestState.btnA, isFalse);
    expect(service.latestState.throttle, 0);
    expect(service.latestState.brake, 0);
    expect(service.latestState.btnL || service.latestState.btnR, isFalse);
    // Releasing or moving fingers from the old surface cannot restore pedals.
    await throttle.moveBy(const Offset(8, 0));
    await throttle.up();
    await brake.cancel();
    await tester.pump(const Duration(milliseconds: 200));
    await _pumpUntil(tester, () => !service.latestState.btnA);
    expect(service.latestState.drivingPaused, isTrue);
    expect(service.latestState.throttle, 0);
    expect(service.latestState.brake, 0);
    expect(states.any((state) => state.drivingPaused), isTrue);
    await tester.tapAt(_buttonPoint(tester, 'A'));
    await _pumpUntil(tester, () => !service.latestState.drivingPaused);
    await tester.pump(const Duration(milliseconds: 180));
    await _pumpUntil(tester, () => !service.latestState.btnA);
    var edges = 0;
    var previousA = false;
    for (final state in states) {
      if (state.btnA && !previousA) edges++;
      previousA = state.btnA;
    }
    expect(edges, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(tester, () => !service.isConnected);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable gyro keeps joystick mode but warns in driving', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: PhoneControllerPage(targetHost: '127.0.0.1')),
    );
    await tester.pump();
    tester.binding.channelBuffers.push(
      'dev.fluttercommunity.plus/sensors/gyroscope',
      const StandardMethodCodec().encodeErrorEnvelope(code: 'NO_SENSOR'),
      (_) {},
    );
    await _pumpUntil(
      tester,
      () => find
          .textContaining('Sin giroscopio disponible')
          .evaluate()
          .isNotEmpty,
      reason: 'sensor error produces a touch fallback',
    );
    expect(find.textContaining('Sin giroscopio disponible'), findsOneWidget);
    expect(find.byType(VirtualThumbstick), findsNWidgets(2));
    expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
    await tester.tap(find.byTooltip('Ajustes y Modo'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('CONDUCCIÓN'));
    await tester.tap(find.text('CONDUCCIÓN'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('joystick_button_R')), findsOneWidget);
    expect(
      find.text('SIN GIROSCOPIO · DIRECCIÓN NO DISPONIBLE'),
      findsOneWidget,
    );
    expect(find.byType(VirtualThumbstick), findsNothing);
    expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
    expect(
      find.byKey(const ValueKey('driving_throttle_pedal')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('driving_brake_pedal')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('driving pedals are separate from views and pause immediately', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = VrRemoteControllerService(
      inputTimeout: const Duration(seconds: 10),
    );
    addTearDown(service.dispose);
    expect(await tester.runAsync(() => service.startServer(port: 0)), isTrue);
    service.requestControllerMode(RemoteControllerMode.driving);
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          initialMode: RemoteControllerMode.driving,
          targetHost: '127.0.0.1',
          targetPort: service.serverPort!,
          sessionToken: service.sessionToken,
          autoConnect: true,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          service.isConnected &&
          find.text('CONTINUAR').evaluate().isNotEmpty &&
          service.latestState.mode == RemoteControllerMode.driving &&
          service.latestState.drivingPaused,
    );
    expect(service.latestState.throttle, 0);
    expect(service.latestState.btnA, isFalse);
    await tester.tap(find.text('CONTINUAR'));
    await _pumpUntil(tester, () => !service.latestState.drivingPaused);
    final observed = <RemoteControllerState>[];
    final subscription = service.onState.listen(observed.add);
    addTearDown(subscription.cancel);

    expect(find.byType(VirtualThumbstick), findsNothing);
    final wheel = find.byKey(const ValueKey('driving_wheel'));
    await tester.drag(wheel, const Offset(65, 0), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 110));
    expect(service.latestState.steering, 0);
    expect(service.latestState.stickX, 0);
    expect(service.latestState.stickY, 0);
    final accelerator = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('driving_throttle_pedal'))),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.throttle > 0.1);
    expect(service.latestState.mode, RemoteControllerMode.driving);
    expect(service.latestState.btnR, isFalse);
    final view = await tester.startGesture(
      _buttonPoint(tester, 'R'),
      pointer: 3,
    );
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.btnR);
    expect(service.latestState.throttle, greaterThan(0.1));
    expect(service.latestState.brake, 0);
    await view.up();
    await _pumpUntil(tester, () => !service.latestState.btnR);
    expect(service.latestState.throttle, greaterThan(0.1));

    // Shake cannot recenter the visor while steering. Explicit wheel centering
    // also calibrates locally instead of emitting the global recenter flag.
    tester.binding.channelBuffers.push(
      'dev.fluttercommunity.plus/sensors/accelerometer',
      const StandardMethodCodec().encodeSuccessEnvelope(<double>[
        30,
        0,
        0,
        10000,
      ]),
      (_) {},
    );
    await tester.tap(find.text('CENTRAR VOLANTE'), pointer: 10);
    await tester.pump();
    expect(observed.any((state) => state.recenter), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _pumpUntil(tester, () => service.latestState.drivingPaused);
    expect(service.latestState.throttle, 0);
    expect(service.latestState.brake, 0);
    expect(service.latestState.btnR, isFalse);
    expect(service.latestState.steering, 0);
    await accelerator.up();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('CONTINUAR'), findsOneWidget);
    expect(service.latestState.drivingPaused, isTrue);
    await tester.tap(find.text('CONTINUAR'));
    await _pumpUntil(tester, () => !service.latestState.drivingPaused);
    expect(service.latestState.throttle, 0);
    expect(service.latestState.btnA, isTrue);
    tester.binding.channelBuffers.push(
      'dev.fluttercommunity.plus/sensors/gyroscope',
      const StandardMethodCodec().encodeSuccessEnvelope(<double>[
        0,
        0,
        0,
        10000,
      ]),
      (_) {},
    );
    await _pumpUntil(tester, () => service.latestState.motionAvailable);
    final resumedPedal = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('driving_throttle_pedal'))),
      pointer: 20,
    );
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.throttle > 0.1);
    tester.binding.channelBuffers.push(
      'dev.fluttercommunity.plus/sensors/gyroscope',
      const StandardMethodCodec().encodeErrorEnvelope(code: 'SENSOR_LOST'),
      (_) {},
    );
    await _pumpUntil(tester, () => service.latestState.drivingPaused);
    expect(service.latestState.throttle, 0);
    expect(service.latestState.motionAvailable, isFalse);
    expect(
      find.text('SIN GIROSCOPIO · DIRECCIÓN NO DISPONIBLE'),
      findsOneWidget,
    );
    expect(find.byType(VirtualThumbstick), findsNothing);
    await resumedPedal.up();
    await tester.tapAt(_buttonPoint(tester, 'X'));
    await _pumpUntil(tester, () => service.latestState.btnX);
    expect(service.latestState.drivingPaused, isTrue);
    expect(service.latestState.btnA, isFalse);
    await tester.pump(const Duration(milliseconds: 160));
    await _pumpUntil(tester, () => !service.latestState.btnX);
    final home = await tester.startGesture(_buttonPoint(tester, 'B'));
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.btnB);
    expect(service.latestState.drivingPaused, isTrue);
    expect(service.latestState.throttle, 0);
    await home.up();
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(tester, () => !service.isConnected);
    expect(tester.takeException(), isNull);
  });

  testWidgets('legacy laser initial mode opens the full joystick', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PhoneControllerPage(
          initialMode: RemoteControllerMode.laser,
          targetHost: '127.0.0.1',
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(VirtualThumbstick), findsNWidgets(2));
    expect(find.text('A'), findsOneWidget);
    expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
    expect(find.byKey(const ValueKey('right_mode_laser')), findsOneWidget);
    expect(find.text('GATILLO (CLIC)'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('gyro steers driving without changing laser aim or look', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = VrRemoteControllerService(
      inputTimeout: const Duration(seconds: 10),
    );
    addTearDown(service.dispose);
    expect(await tester.runAsync(() => service.startServer(port: 0)), isTrue);
    service.requestControllerMode(RemoteControllerMode.driving);
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          initialMode: RemoteControllerMode.driving,
          targetHost: '127.0.0.1',
          targetPort: service.serverPort!,
          sessionToken: service.sessionToken,
          autoConnect: true,
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () =>
          service.isConnected &&
          service.latestState.mode == RemoteControllerMode.driving,
    );
    await tester.tapAt(_buttonPoint(tester, 'A'));
    await _pumpUntil(tester, () => !service.latestState.drivingPaused);
    await tester.pump(const Duration(milliseconds: 180));
    await _pumpUntil(tester, () => !service.latestState.btnA);

    var timestamp = 1000000.0;
    Future<void> gyro(double z) async {
      timestamp += 16000;
      tester.binding.channelBuffers.push(
        'dev.fluttercommunity.plus/sensors/gyroscope',
        const StandardMethodCodec().encodeSuccessEnvelope(<double>[
          0,
          0,
          z,
          timestamp,
        ]),
        (_) {},
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    await gyro(0);
    await _pumpUntil(tester, () => service.latestState.motionAvailable);
    for (var i = 0; i < 12; i++) {
      await gyro(-3);
    }
    await _pumpUntil(tester, () => service.latestState.steering > .4);
    final rightSteering = service.latestState.steering;
    expect(service.latestState.orientation.x, closeTo(0, 1e-6));
    expect(service.latestState.orientation.y, closeTo(0, 1e-6));
    expect(service.latestState.orientation.z, closeTo(0, 1e-6));
    expect(service.latestState.angularVelocity.length, 0);
    expect(service.latestState.lookX, 0);
    expect(service.latestState.lookY, 0);

    // The wheel is feedback only. Neither dragging it nor a view button can
    // replace the sensor, move the player, or rotate the visor/laser.
    await tester.drag(
      find.byKey(const ValueKey('driving_wheel')),
      const Offset(40, -20),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(service.latestState.steering, closeTo(rightSteering, 1e-6));
    expect(find.byType(VirtualThumbstick), findsNothing);
    expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
    final view = await tester.startGesture(_buttonPoint(tester, 'L'));
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.btnL);
    expect(service.latestState.throttle, 0);
    expect(service.latestState.brake, 0);
    await view.up();
    for (var i = 0; i < 24; i++) {
      await gyro(3);
    }
    await _pumpUntil(tester, () => service.latestState.steering < -.4);
    expect(service.latestState.orientation.x, closeTo(0, 1e-6));
    expect(service.latestState.orientation.y, closeTo(0, 1e-6));
    expect(service.latestState.orientation.z, closeTo(0, 1e-6));
    expect(service.latestState.lookX, 0);
    expect(service.latestState.lookY, 0);
    expect(service.latestState.stickX, 0);
    expect(service.latestState.stickY, 0);
    await tester.tap(find.text('CENTRAR VOLANTE'));
    await _pumpUntil(tester, () => service.latestState.steering == 0);
    expect(service.latestState.recenter, isFalse);
    expect(service.latestState.orientation.y, closeTo(0, 1e-6));
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(tester, () => !service.isConnected);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'matching driving UI still neutralizes new host modes and fresh sessions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final link = _CapturedControllerLink();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            initialMode: RemoteControllerMode.driving,
            linkConnector: () async => link,
            autoConnect: true,
          ),
        ),
      );
      await _pumpUntil(tester, () => link.packets.isNotEmpty);
      Future<Map<String, dynamic>> request(
        int revision,
        RemoteControllerMode mode,
      ) async {
        link.inbound.add(
          jsonEncode(
            VrControllerModeRequest(
              mode: mode,
              revision: revision,
              actions: const {'R': 'Vista +'},
            ).toJson(),
          ),
        );
        await _pumpUntil(
          tester,
          () => link.packets.any(
            (packet) => packet['hostModeRevision'] == revision,
          ),
        );
        return link.packets.firstWhere(
          (packet) => packet['hostModeRevision'] == revision,
        );
      }

      // Even if the UI already matches, the first host request preserves the
      // reconnect pause and acknowledges with neutral controls.
      final first = await request(1, RemoteControllerMode.driving);
      expect(first['drivingPaused'], isTrue);
      expect(first['throttle'], 0);
      await tester.tap(find.text('CONTINUAR'));
      await tester.pump(const Duration(milliseconds: 180));
      final pedal = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('driving_throttle_pedal'))),
      );
      await tester.pump(const Duration(milliseconds: 110));
      await _pumpUntil(
        tester,
        () => (link.packets.last['throttle'] as num) > .05,
      );
      final captions = await request(2, RemoteControllerMode.driving);
      expect(captions['throttle'], greaterThan(.05));

      await request(3, RemoteControllerMode.joystick);
      expect(find.byType(VirtualThumbstick), findsNWidgets(2));
      await pedal.up();
      // The user can preselect driving locally before the host enters Riviera.
      await tester.tap(find.byTooltip('Ajustes y Modo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CONDUCCIÓN'));
      await tester.pumpAndSettle();
      final held = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('driving_throttle_pedal'))),
      );
      await tester.pump(const Duration(milliseconds: 110));
      await _pumpUntil(
        tester,
        () => (link.packets.last['throttle'] as num) > .05,
      );
      final changedHost = await request(4, RemoteControllerMode.driving);
      expect(changedHost['throttle'], 0);
      expect(changedHost['brake'], 0);
      expect(changedHost['steering'], 0);
      expect(changedHost['drivingTilt'], 0);
      expect(changedHost['stickX'], 0);
      expect(changedHost['stickY'], 0);
      expect(changedHost['drivingPaused'], isFalse);
      await held.up();
      await request(5, RemoteControllerMode.joystick);
      expect(find.byType(VirtualThumbstick), findsNWidgets(2));
      expect(
        find.byKey(const ValueKey('driving_throttle_pedal')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'fresh foreground driving mode is neutral and ready without synthesizing A',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = VrRemoteControllerService(
        inputTimeout: const Duration(seconds: 10),
      );
      addTearDown(service.dispose);
      expect(await tester.runAsync(() => service.startServer(port: 0)), isTrue);
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
      await _pumpUntil(
        tester,
        () =>
            service.isConnected &&
            find.text('RECONECTAR').evaluate().isNotEmpty,
      );
      await _selectRightMode(tester, laser: true);
      final pad = find.byKey(const ValueKey('laser_slide_pad'));
      final oldPadGesture = await tester.startGesture(
        tester.getCenter(pad),
        pointer: 1,
      );
      await oldPadGesture.moveBy(const Offset(20, -20));
      await tester.pump(const Duration(milliseconds: 350));
      await _pumpUntil(tester, () => service.latestState.btnGrip);
      final oldButtonGesture = await tester.startGesture(
        tester.getCenter(find.text('A')),
        pointer: 2,
      );
      await tester.pump(const Duration(milliseconds: 110));
      await _pumpUntil(tester, () => service.latestState.btnA);

      final drivingPackets = <RemoteControllerState>[];
      final subscription = service.onState.listen((state) {
        if (state.mode == RemoteControllerMode.driving) {
          drivingPackets.add(state);
        }
      });
      addTearDown(subscription.cancel);
      service.requestControllerMode(RemoteControllerMode.driving);
      await _pumpUntil(
        tester,
        () =>
            drivingPackets.isNotEmpty &&
            find.text('PAUSAR').evaluate().isNotEmpty,
      );
      expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
      expect(
        find.byKey(const ValueKey('driving_throttle_pedal')),
        findsOneWidget,
      );
      expect(find.byType(VirtualThumbstick), findsNothing);
      // The first ACK is ready but cannot carry old inputs or synthesize A.
      for (final state in drivingPackets) {
        expect(state.drivingPaused, isFalse);
        expect(state.steering, 0);
        expect(state.throttle, 0);
        expect(state.brake, 0);
        expect(state.btnA || state.btnGrip || state.btnR, isFalse);
        expect(state.stickX, 0);
        expect(state.stickY, 0);
        expect(state.lookX, 0);
        expect(state.lookY, 0);
        expect(state.laserSlideActive || state.recenter, isFalse);
      }
      await oldPadGesture.moveBy(const Offset(30, 0));
      await oldPadGesture.up();
      await oldButtonGesture.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(service.latestState.btnA || service.latestState.btnGrip, isFalse);
      expect(service.latestState.drivingPaused, isFalse);

      await tester.tap(find.text('PAUSAR'));
      await _pumpUntil(tester, () => service.latestState.drivingPaused);
      service.requestControllerMode(
        RemoteControllerMode.driving,
        actions: const {'R': 'Siguiente vista'},
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(service.latestState.drivingPaused, isTrue);

      // A live socket remains valid across suspension even though pending
      // connection generations are cancelled. It must ACK a newer mode safely.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      service.requestControllerMode(RemoteControllerMode.joystick);
      await _pumpUntil(
        tester,
        () =>
            service.latestState.mode == RemoteControllerMode.joystick &&
            find
                .byKey(const ValueKey('joystick_surface'))
                .evaluate()
                .isNotEmpty,
      );
      expect(service.latestState.btnA || service.latestState.btnGrip, isFalse);
      expect(service.latestState.stickX, 0);
      service.requestControllerMode(RemoteControllerMode.driving);
      await _pumpUntil(
        tester,
        () => service.latestState.mode == RemoteControllerMode.driving,
      );
      expect(service.latestState.drivingPaused, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(service.latestState.drivingPaused, isTrue);
      expect(find.text('A'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpUntil(tester, () => !service.isConnected);
      expect(tester.takeException(), isNull);
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

  testWidgets(
    'dual joystick layout renders 4 action buttons, navigation and view sticks, and settings modal opens',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: PhoneControllerPage(targetHost: '127.0.0.1')),
      );
      await tester.pump();

      // Verify left column: L, Y, stick, X
      expect(find.text('L'), findsOneWidget);
      expect(find.text('Y'), findsOneWidget);
      expect(find.text('X'), findsOneWidget);
      expect(find.byKey(const ValueKey('joystick_move_stick')), findsOneWidget);

      // The center stays available for experience information. The right
      // control has explicit view/laser modes, never two overlapping owners.
      expect(find.text('RECENTRAR VISTA'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('controller_center_panel')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('right_mode_view')), findsOneWidget);
      expect(find.byKey(const ValueKey('right_mode_laser')), findsOneWidget);
      expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);

      // Verify right column: R, B, stick, A
      expect(find.text('R'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.byKey(const ValueKey('joystick_look_stick')), findsOneWidget);

      // Open settings modal via gear icon
      await tester.tap(find.byIcon(Icons.settings_rounded));
      await tester.pumpAndSettle();

      expect(find.text('AJUSTES DEL MANDO VR'), findsOneWidget);
      expect(find.text('JOYSTICK DUAL'), findsOneWidget);
      expect(find.text('PUNTERO LÁSER'), findsNothing);
      expect(find.text('CONDUCCIÓN'), findsOneWidget);
      expect(find.text('Mostrar mando en visor'), findsOneWidget);
      expect(
        find.text('Sacudir para mostrar/ocultar el mando'),
        findsOneWidget,
      );
      expect(find.text('Vibración háptica del mando'), findsOneWidget);

      // Toggle vibration switch off and on
      await tester.ensureVisible(find.text('Vibración háptica del mando'));
      await tester.tap(find.text('Vibración háptica del mando'));
      await tester.pumpAndSettle();

      // Close settings modal
      await tester.ensureVisible(find.byIcon(Icons.close_rounded));
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

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

      await _selectRightMode(tester, laser: true);
      // Find the right control in laser mode.
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

  testWidgets(
    'laser slide gestures produce correct directional orientation and laser coordinates',
    (tester) async {
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

        await _selectRightMode(tester, laser: true);
        final padFinder = find.byKey(const ValueKey('laser_slide_pad'));
        final padCenter = tester.getCenter(padFinder);
        final padTop = tester.getTopLeft(padFinder) + const Offset(20, 5);

        // Drag towards top of the pad (swipe UP)
        final gesture = await tester.startGesture(padCenter);
        await gesture.moveTo(padTop);
        await tester.pump(const Duration(milliseconds: 50));
        await _pumpUntil(tester, () => service.latestState.laserY > 0.5);

        // laserY > 0 means pointing upwards in cartesian coordinates
        expect(service.latestState.laserY, greaterThan(0.5));
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpUntil(tester, () => !service.isConnected);
        service.dispose();
        expect(tester.takeException(), isNull);
      }, _RealHttpOverrides());
    },
  );

  testWidgets('native L is utility, R triggers, and A stays independent', (
    tester,
  ) async {
    final service = VrRemoteControllerService();
    addTearDown(service.dispose);
    await tester.runAsync(() => service.startServer(port: 0));
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
    // Server-side WS acceptance happens before the phone finishes connecting
    // and releases the previous surface. Start the gesture only after its
    // first full snapshot, otherwise the connection reset cancels that tap.
    await _pumpUntil(
      tester,
      () => service.isConnected && service.telemetry.acceptedStates > 0,
      reason: 'first ready controller snapshot',
    );
    final left = await tester.startGesture(
      tester.getCenter(find.text('L')),
      pointer: 1,
    );
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.btnL);
    expect(service.latestState.btnA, isFalse);
    expect(service.latestState.isTriggerPressed, isFalse);

    final right = await tester.startGesture(
      tester.getCenter(find.text('R')),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.btnR);
    expect(service.latestState.btnL, isTrue);
    expect(service.latestState.isTriggerPressed, isTrue);
    expect(service.latestState.btnA, isFalse);
    await right.up();
    await _pumpUntil(tester, () => !service.latestState.btnR);
    expect(service.latestState.btnL, isTrue);
    expect(service.latestState.isTriggerPressed, isFalse);
    await left.up();

    final a = await tester.startGesture(
      tester.getCenter(find.text('A')),
      pointer: 3,
    );
    await tester.pump(const Duration(milliseconds: 110));
    await _pumpUntil(tester, () => service.latestState.btnA);
    expect(service.latestState.isTriggerPressed, isFalse);
    expect(service.latestState.btnL || service.latestState.btnR, isFalse);
    await a.up();
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpUntil(tester, () => !service.isConnected);
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.takeException(), isNull);
  });

  for (final mode in [
    RemoteControllerMode.joystick,
    RemoteControllerMode.driving,
  ]) {
    testWidgets(
      'shake toggles viewer feedback, never recenter, in ${mode.name}',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 360));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = VrRemoteControllerService(
          inputTimeout: const Duration(seconds: 10),
        );
        addTearDown(service.dispose);
        await tester.runAsync(() => service.startServer(port: 0));
        service.requestControllerMode(mode);
        await tester.pumpWidget(
          MaterialApp(
            home: PhoneControllerPage(
              initialMode: mode,
              targetHost: '127.0.0.1',
              targetPort: service.serverPort!,
              sessionToken: service.sessionToken,
              autoConnect: true,
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () => service.isConnected && service.latestState.mode == mode,
        );
        final states = <RemoteControllerState>[];
        final subscription = service.onState.listen(states.add);
        addTearDown(subscription.cancel);
        Future<void> accel(double x, double y, double z) async {
          tester.binding.channelBuffers.push(
            'dev.fluttercommunity.plus/sensors/accelerometer',
            const StandardMethodCodec().encodeSuccessEnvelope(<double>[
              x,
              y,
              z,
              10000,
            ]),
            (_) {},
          );
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
        }

        expect(service.latestState.controllerVisible, isTrue);
        await accel(0, 0, 9.80665);
        await accel(-30, 0, 9.80665);
        await accel(-30, 0, 9.80665);
        await _pumpUntil(tester, () => !service.latestState.controllerVisible);
        await accel(30, 0, 9.80665);
        expect(service.latestState.controllerVisible, isFalse);
        expect(states.any((state) => state.recenter), isFalse);
        expect(states.any((state) => state.btnA || state.btnB), isFalse);

        // Manual fallback remains available even without working accelerometer.
        await tester.tap(find.byIcon(Icons.settings_rounded));
        await tester.pumpAndSettle();
        final visibility = find.byKey(
          const ValueKey('controller_visibility_toggle'),
        );
        await tester.ensureVisible(visibility);
        await tester.tap(visibility);
        await _pumpUntil(tester, () => service.latestState.controllerVisible);
        final shake = find.byKey(const ValueKey('controller_shake_toggle'));
        await tester.ensureVisible(shake);
        await tester.tap(shake);
        await tester.pump();
        expect(tester.widget<SwitchListTile>(shake).value, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
        await _pumpUntil(tester, () => !service.isConnected);
        await tester.pump(const Duration(milliseconds: 150));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'right laser pad owns pose over IMU during touch and after release',
    (tester) async {
      final service = VrRemoteControllerService();
      addTearDown(service.dispose);
      await tester.runAsync(() => service.startServer(port: 0));
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
      await _selectRightMode(tester, laser: true);
      final center = tester.getCenter(
        find.byKey(const ValueKey('laser_slide_pad')),
      );
      final owner = await tester.startGesture(center, pointer: 1);
      await _pumpUntil(tester, () => service.latestState.laserSlideActive);
      expect(service.latestState.laserX, closeTo(0, 1e-6));
      expect(service.latestState.laserY, closeTo(0, 1e-6));

      void gyro() {
        tester.binding.channelBuffers.push(
          'dev.fluttercommunity.plus/sensors/gyroscope',
          const StandardMethodCodec().encodeSuccessEnvelope(<double>[
            0,
            1,
            0,
            10000,
          ]),
          (_) {},
        );
      }

      for (var i = 0; i < 3; i++) {
        gyro();
        await tester.pump(const Duration(milliseconds: 30));
      }
      // A second finger must neither steal the pose nor release the first grip.
      final other = await tester.startGesture(
        center + const Offset(20, 10),
        pointer: 2,
      );
      await other.moveBy(const Offset(20, 10));
      await other.up();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(service.latestState.laserSlideActive, isTrue);
      expect(service.latestState.laserX, closeTo(0, 1e-6));
      expect(service.latestState.laserY, closeTo(0, 1e-6));
      expect(service.latestState.orientation.x, closeTo(0, 1e-6));
      expect(service.latestState.orientation.y, closeTo(0, 1e-6));
      expect(service.latestState.angularVelocity.length, 0);

      await owner.up();
      await _pumpUntil(tester, () => !service.latestState.laserSlideActive);
      gyro();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      expect(service.latestState.angularVelocity.length, 0);
      expect(service.latestState.orientation.x, closeTo(0, 1e-6));
      expect(service.latestState.orientation.y, closeTo(0, 1e-6));
      expect(service.latestState.laserX, closeTo(0, 1e-6));
      expect(service.latestState.laserY, closeTo(0, 1e-6));
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpUntil(tester, () => !service.isConnected);
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.takeException(), isNull);
    },
  );
}
