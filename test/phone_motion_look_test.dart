import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _Link implements VrControllerLink {
  final inbound = StreamController<Object?>();
  final packets = <Map<String, dynamic>>[];
  bool open = true;
  @override
  Stream<Object?> get messages => inbound.stream;
  @override
  bool get isOpen => open;
  @override
  void add(Object data) => packets.add(jsonDecode(data as String));
  @override
  Future<void> close([int? code, String? reason]) async {
    if (!open) return;
    open = false;
    unawaited(inbound.close());
  }

  Map<String, dynamic> get last => packets.last;
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
    SharedPreferences.setMockInitialValues({'vrlizate_haptics_enabled': false});
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

  Future<void> tick(WidgetTester tester, [int ms = 12]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await tester.pump(Duration(milliseconds: ms));
  }

  Future<_Link> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final link = _Link();
    await tester.pumpWidget(
      MaterialApp(
        home: PhoneControllerPage(
          allowWifiConnection: false,
          autoConnect: true,
          linkConnector: () async => link,
        ),
      ),
    );
    for (var i = 0; i < 20 && link.packets.isEmpty; i++) {
      await tick(tester);
    }
    expect(link.packets, isNotEmpty);
    await tester.pump();
    return link;
  }

  var timestamp = 0.0;
  Future<void> rotate(
    WidgetTester tester, {
    double pitch = 1,
    int samples = 22,
  }) async {
    // Landscape: gravity along +X; screen-right axis is -Y (pitch up).
    for (var i = 0; i < samples; i++) {
      timestamp += 16000;
      for (final (channel, values) in [
        ('accelerometer', [9.81, 0.0, 0.0, timestamp]),
        ('gyroscope', [0.0, -pitch, 0.0, timestamp]),
      ]) {
        tester.binding.channelBuffers.push(
          'dev.fluttercommunity.plus/sensors/$channel',
          const StandardMethodCodec().encodeSuccessEnvelope(values),
          (_) {},
        );
      }
      await tick(tester);
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  }

  final right = find.byKey(const ValueKey('joystick_look_stick'));
  final left = find.byKey(const ValueKey('joystick_move_stick'));

  testWidgets(
    'native game profile retains horizontal look and releases on walking profile',
    (tester) async {
      final link = await open(tester);
      link.inbound.add(
        jsonEncode(
          const VrControllerModeRequest(
            mode: RemoteControllerMode.joystick,
            revision: 1,
            horizontalLook: true,
          ).toJson(),
        ),
      );
      await tick(tester, 40);
      final old = await tester.startGesture(tester.getCenter(right));
      await old.moveBy(Offset(tester.getSize(right).width, 0));
      await tick(tester, 40);
      expect(link.last['lookX'], greaterThan(.1));
      link.inbound.add(
        jsonEncode(
          const VrControllerModeRequest(
            mode: RemoteControllerMode.joystick,
            revision: 2,
            horizontalLook: false,
          ).toJson(),
        ),
      );
      await tick(tester, 40);
      expect(link.last['lookX'], 0);
      await old.moveBy(const Offset(5, 0));
      await old.up();
      expect(link.last['lookX'], 0);
      final fresh = await tester.startGesture(tester.getCenter(right));
      await fresh.moveBy(Offset(tester.getSize(right).width, 0));
      await tick(tester, 40);
      expect(link.last['lookX'], 0);
      await fresh.up();
      await finish(tester);
    },
  );

  testWidgets(
    'right view ignores horizontal thumb input; left keeps rim intent',
    (tester) async {
      final link = await open(tester);
      final hold = await tester.startGesture(tester.getCenter(right));
      await hold.moveBy(Offset(tester.getSize(right).width, 0));
      await tick(tester, 80);
      expect(link.last['lookX'], 0);
      expect(link.last['lookY'], 0);
      expect(link.last['laserX'], 0);
      await hold.up();
      final walk = await tester.startGesture(tester.getCenter(left));
      await walk.moveBy(Offset(0, tester.getSize(left).height));
      await tick(tester, 80);
      expect(link.last['stickY'], lessThan(0));
      expect(link.last['moveAtEdge'], isTrue);
      expect(link.last['lookX'], 0);
      await walk.up();
      await finish(tester);
    },
  );

  testWidgets(
    'same right area switches to laser without camera or stale gestures',
    (tester) async {
      final link = await open(tester);
      final viewBounds = tester.getRect(right);
      final oldLook = await tester.startGesture(tester.getCenter(right));
      await oldLook.moveBy(Offset(0, -tester.getSize(right).height));
      await tick(tester, 50);
      expect(link.last['lookY'], greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('right_mode_laser')));
      await tester.pump();
      expect(link.last['lookY'], 0);
      expect(right, findsNothing);
      final laser = find.byKey(const ValueKey('laser_slide_pad'));
      expect(tester.getRect(laser), viewBounds);
      final aim = await tester.startGesture(
        tester.getCenter(laser),
        pointer: 999,
      );
      await aim.moveBy(Offset(viewBounds.width * .25, -viewBounds.height * .2));
      await rotate(tester);
      expect(link.last['laserX'], greaterThan(.1));
      expect(link.last['laserY'], greaterThan(.1));
      expect(link.last['laserSlideActive'], isTrue);
      expect(link.last['lookX'], 0);
      expect(link.last['lookY'], 0);
      await oldLook.up();
      expect(link.last['laserSlideActive'], isTrue);
      await tester.tap(find.byKey(const ValueKey('right_mode_view')));
      await tester.pump();
      expect(link.last['laserX'], 0);
      expect(link.last['laserY'], 0);
      expect(link.last['laserSlideActive'], isFalse);
      expect(link.last['btnGrip'], isFalse);
      await aim.up();
      await rotate(tester);
      expect(link.last['lookY'], 0);
      expect(link.last['laserSlideActive'], isFalse);
      await finish(tester);
    },
  );

  testWidgets(
    'view press adds vertical motion only while held, never yaw or laser pose',
    (tester) async {
      final link = await open(tester);
      await rotate(tester);
      expect(link.last['lookY'], 0);
      final hold = await tester.startGesture(tester.getCenter(right));
      await rotate(tester);
      expect(link.last['lookY'], greaterThan(.1));
      // Still inclined, but no longer physically rotating: fresh zero-rate
      // samples must preserve the requested turn beyond the 150 ms watchdog.
      await rotate(tester, pitch: 0, samples: 8);
      final sustained = link.last['lookY'] as double;
      await rotate(tester, pitch: 0, samples: 45);
      expect(link.last['lookY'], closeTo(sustained, .0001));
      expect(link.last['lookY'], greaterThan(.1));
      expect(link.last['lookX'], 0);
      expect(link.last['stickX'], 0);
      for (final key in [
        'qx',
        'qy',
        'qz',
        'wx',
        'wy',
        'wz',
        'laserX',
        'laserY',
      ]) {
        expect(link.last[key], 0, reason: key);
      }
      expect(link.last['qw'], 1);
      await hold.up();
      await tester.pump();
      expect(link.last['lookY'], 0);
      await rotate(tester);
      expect(link.last['lookY'], 0);
      // Repressing at the new physical pose makes that pose the new center.
      final centered = await tester.startGesture(tester.getCenter(right));
      await rotate(tester, pitch: 0, samples: 16);
      expect(link.last['lookY'], 0);
      await centered.up();
      await finish(tester);
    },
  );

  testWidgets(
    'soft touch and gyro add, stale sensor falls back to held thumb',
    (tester) async {
      final link = await open(tester);
      final hold = await tester.startGesture(tester.getCenter(right));
      await hold.moveBy(Offset(0, -tester.getSize(right).height * .16));
      await tick(tester, 40);
      final touch = link.last['lookY'] as double;
      expect(touch, inExclusiveRange(0, .3));
      await rotate(tester);
      expect(link.last['lookY'], greaterThan(touch + .1));
      expect(link.last['lookY'], lessThanOrEqualTo(1));
      await tick(tester, 200);
      expect(link.last['lookY'], closeTo(touch, .01));
      // Sensor recovery cannot silently resume the old inclined gesture.
      await rotate(tester, pitch: 0);
      expect(link.last['lookY'], closeTo(touch, .01));
      await hold.up();
      expect(link.last['lookY'], 0);
      await finish(tester);
    },
  );

  testWidgets('move stick starts softer and releases without residual ramp', (
    tester,
  ) async {
    final link = await open(tester);
    final hold = await tester.startGesture(tester.getCenter(left));
    await hold.moveBy(Offset(tester.getSize(left).width, 0));
    await tick(tester, 40);
    expect(link.last['stickX'], inExclusiveRange(.45, .65));
    expect(link.last['moveAtEdge'], isTrue);
    await hold.up();
    expect(link.last['stickX'], 0);
    expect(link.last['moveAtEdge'], isFalse);
    await rotate(tester);
    expect(link.last['stickX'], 0);
    expect(link.last['lookY'], 0);
    await finish(tester);
  });

  testWidgets('left rim intent uses raw contact and hysteresis', (
    tester,
  ) async {
    final link = await open(tester);
    final center = tester.getCenter(left);
    final stick = tester.widget<VirtualThumbstick>(left);
    final radius = stick.size / 2 - stick.knobRadius;
    final hold = await tester.startGesture(center);
    await hold.moveTo(center + Offset(radius * .9, 0));
    await tick(tester, 40);
    expect(link.last['moveAtEdge'], isFalse);

    await hold.moveTo(center + Offset(radius * .95, 0));
    expect(link.last['moveAtEdge'], isTrue);
    expect(link.last['stickX'], lessThan(.7));

    await hold.moveTo(center + Offset(radius * .88, 0));
    await tick(tester, 40);
    expect(link.last['moveAtEdge'], isTrue);

    await hold.moveTo(center + Offset(radius * .8, 0));
    expect(link.last['moveAtEdge'], isFalse);
    await hold.moveTo(center + Offset(0, radius));
    expect(link.last['moveAtEdge'], isTrue);
    expect(link.last['stickY'], lessThan(0));
    await hold.up();
    expect(link.last['moveAtEdge'], isFalse);
    await finish(tester);
  });

  testWidgets('invalid gyro immediately clears motion while preserving thumb', (
    tester,
  ) async {
    final link = await open(tester);
    final hold = await tester.startGesture(tester.getCenter(right));
    await hold.moveBy(Offset(0, -tester.getSize(right).height * .16));
    await tick(tester, 40);
    final touch = link.last['lookY'] as double;
    await rotate(tester);
    expect(link.last['lookY'], greaterThan(touch + .1));
    tester.binding.channelBuffers.push(
      'dev.fluttercommunity.plus/sensors/gyroscope',
      const StandardMethodCodec().encodeSuccessEnvelope([
        double.nan,
        0.0,
        0.0,
        timestamp + 16000,
      ]),
      (_) {},
    );
    await tester.pump();
    expect(link.last['lookY'], closeTo(touch, .01));
    await rotate(tester);
    expect(link.last['lookY'], closeTo(touch, .01));
    await hold.up();
    final fresh = await tester.startGesture(tester.getCenter(right));
    await rotate(tester);
    expect(link.last['lookY'], greaterThan(.1));
    await fresh.up();
    await finish(tester);
  });

  testWidgets('NES profile releases motion and ignores old thumb callbacks', (
    tester,
  ) async {
    final link = await open(tester);
    final hold = await tester.startGesture(tester.getCenter(right));
    await rotate(tester);
    expect(link.last['lookY'], greaterThan(.1));
    link.inbound.add(
      jsonEncode(
        const VrControllerModeRequest(
          mode: RemoteControllerMode.nes,
          revision: 1,
        ).toJson(),
      ),
    );
    await tick(tester, 40);
    expect(link.last['mode'], 'nes');
    expect(link.last['lookY'], 0);
    await hold.up();
    await rotate(tester);
    expect(link.last['lookY'], 0);
    expect(find.byKey(const ValueKey('nes_surface')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('background and resize require a fresh look press', (
    tester,
  ) async {
    final link = await open(tester);
    final hold = await tester.startGesture(tester.getCenter(right));
    await rotate(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(link.last['lookY'], 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await hold.up();
    await rotate(tester);
    expect(link.last['lookY'], 0);
    final old = await tester.startGesture(tester.getCenter(right), pointer: 3);
    await rotate(tester);
    expect(link.last['lookY'], greaterThan(.1));
    await tester.binding.setSurfaceSize(const Size(760, 360));
    await tester.pump();
    expect(link.last['lookY'], 0);
    final fresh = await tester.startGesture(
      tester.getCenter(right),
      pointer: 4,
    );
    await rotate(tester);
    await old.up();
    await rotate(tester);
    expect(link.last['lookY'], greaterThan(.1));
    await fresh.up();
    expect(link.last['lookY'], 0);
    await finish(tester);
  });

  testWidgets(
    'saved motion preference disables sensors while preserving touch',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'vrlizate_haptics_enabled': false,
        'vrlizate_motion_look_enabled': false,
      });
      final link = await open(tester);
      final hold = await tester.startGesture(tester.getCenter(right));
      await rotate(tester);
      expect(link.last['lookY'], 0);
      await hold.moveBy(Offset(0, -tester.getSize(right).height * .2));
      await tick(tester, 40);
      expect(link.last['lookY'], greaterThan(0));
      await hold.up();
      await finish(tester);
    },
  );
}
