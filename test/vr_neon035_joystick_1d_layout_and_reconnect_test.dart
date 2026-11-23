import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _TestLink implements VrControllerLink {
  final _incoming = StreamController<Object?>.broadcast();
  final packets = <Map<String, dynamic>>[];
  bool _open = true;

  @override
  bool get isOpen => _open;

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void add(Object data) {
    if (!_open) throw StateError('closed');
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) packets.add(decoded);
    }
  }

  void dropUnexpectedly() {
    _open = false;
    if (!_incoming.isClosed) _incoming.close();
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _open = false;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    const channels = [
      'dev.fluttercommunity.plus/sensors/method',
      'dev.fluttercommunity.plus/sensors/gyroscope',
      'dev.fluttercommunity.plus/sensors/accelerometer',
    ];
    for (final ch in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), (_) async => null);
    }
  });

  tearDown(() {
    const channels = [
      'dev.fluttercommunity.plus/sensors/method',
      'dev.fluttercommunity.plus/sensors/gyroscope',
      'dev.fluttercommunity.plus/sensors/accelerometer',
    ];
    for (final ch in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(ch), null);
    }
  });

  testWidgets(
    'NEON-035: Double-Tap MOVER toggles Turbo (btnZL) and Double-Tap MIRAR toggles Laser ON/OFF',
    (tester) async {
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final link = _TestLink();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            allowWifiConnection: false,
            connectionLabel: 'Visor Test',
            linkConnector: () async => link,
            autoConnect: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Verify 1D-matching structure: L & R shoulder pills, X/Y above sticks, A/B below sticks.
      expect(find.byType(VrDeckShoulderPill), findsNWidgets(2));
      expect(find.byType(VrYinYangButtonPair), findsNWidgets(4));
      final moveCenter = tester.getCenter(
        find.byKey(const ValueKey('joystick_move_stick')),
      );
      final lookCenter = tester.getCenter(
        find.byKey(const ValueKey('joystick_look_stick')),
      );

      // 1. Double-tap MOVER -> activates Turbo (btnZL = true, label TURBO ⚡).
      expect(link.packets.last['btnZL'], isFalse);
      await tester.tapAt(moveCenter);
      await tester.pump(const Duration(milliseconds: 90));
      await tester.tapAt(moveCenter);
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('TURBO ⚡'), findsOneWidget);
      expect(link.packets.last['btnZL'], isTrue);

      // 2. Second double-tap on MOVER -> turns Turbo back OFF.
      await tester.pump(const Duration(milliseconds: 420));
      await tester.tapAt(moveCenter);
      await tester.pump(const Duration(milliseconds: 90));
      await tester.tapAt(moveCenter);
      await tester.pump(const Duration(milliseconds: 60));

      expect(find.text('MOVER'), findsOneWidget);
      expect(link.packets.last['btnZL'], isFalse);

      // 3. Double-tap MIRAR -> switches right stick straight into Modo Láser!
      expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);
      await tester.tapAt(lookCenter);
      await tester.pump(const Duration(milliseconds: 90));
      await tester.tapAt(lookCenter);
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byKey(const ValueKey('laser_slide_pad')), findsOneWidget);
      expect(find.byKey(const ValueKey('joystick_look_stick')), findsNothing);

      // 4. Double-tap Laser pad -> toggles cleanly back to MIRAR!
      final laserCenter = tester.getCenter(
        find.byKey(const ValueKey('laser_slide_pad')),
      );
      await tester.tapAt(laserCenter);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(laserCenter);
      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byKey(const ValueKey('joystick_look_stick')), findsOneWidget);
      expect(find.byKey(const ValueKey('laser_slide_pad')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'NEON-035: Joystick auto-reconnects seamlessly after disconnect and transient HttpException',
    (tester) async {
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var attempts = 0;
      final links = <_TestLink>[];

      await tester.pumpWidget(
        MaterialApp(
          home: PhoneControllerPage(
            allowWifiConnection: false,
            connectionLabel: 'Visor AutoReconnect',
            linkConnector: () async {
              attempts++;
              if (attempts == 2) {
                throw const HttpException('Visor restarting handshake');
              }
              final link = _TestLink();
              links.add(link);
              return link;
            },
            autoConnect: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(attempts, 1);
      expect(links, hasLength(1));

      // Simulate unexpected disconnect (range blip / brief visor hiccup).
      links.first.dropUnexpectedly();
      await tester.pump();

      // First retry hits transient HttpException (350ms), second retry succeeds (900ms)!
      await tester.pump(const Duration(milliseconds: 400));
      expect(attempts, 2);
      await tester.pump(const Duration(milliseconds: 950));
      expect(attempts, 3);
      expect(links, hasLength(2));
      expect(links.last.isOpen, isTrue);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
