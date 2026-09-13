// Opt-in raster of the actual Flutter controller, not a mockup or GPU scene.
// No phone/server/camera connection is opened. Normal test runs write nothing.
// flutter test --no-pub test/phone_controller_layout_preview_test.dart \
//   --dart-define=VRLIZATE_JOYSTICK_PREVIEW=/tmp/vrlizate-joystick-layout.png
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

const _output = String.fromEnvironment('VRLIZATE_JOYSTICK_PREVIEW');

Future<void> _loadFonts() async {
  final configFile = File('.dart_tool/package_config.json').absolute;
  final config =
      jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
  final flutter = (config['packages'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .singleWhere((package) => package['name'] == 'flutter');
  final flutterRoot = Uri.directory(
    Directory.fromUri(
      configFile.uri.resolve(flutter['rootUri'] as String),
    ).path,
  );
  final fonts = flutterRoot.resolve(
    '../../bin/cache/artifacts/material_fonts/',
  );
  for (final (family, file) in [
    ('Ahem', 'Roboto-Regular.ttf'),
    ('Roboto', 'Roboto-Regular.ttf'),
    ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ('Courier', 'Roboto-Regular.ttf'),
  ]) {
    // Native text has a monospace fallback; flutter_tester otherwise renders
    // the telemetry as Ahem blocks. Prefer the host Courier face for QA.
    final courier = File('/System/Library/Fonts/Courier.ttc');
    final fontFile = family == 'Courier' && await courier.exists()
        ? courier
        : File.fromUri(fonts.resolve(file));
    final bytes = await fontFile.readAsBytes();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}

void main() {
  testWidgets('capture real landscape controller for visual QA', (
    tester,
  ) async {
    expect(
      _output.startsWith('/'),
      isTrue,
      reason: 'Use an absolute output path.',
    );
    SharedPreferences.setMockInitialValues({});
    const channels = [
      'dev.fluttercommunity.plus/sensors/method',
      'dev.fluttercommunity.plus/sensors/gyroscope',
      'dev.fluttercommunity.plus/sensors/accelerometer',
    ];
    for (final channel in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
    addTearDown(() {
      for (final channel in channels) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(channel), null);
      }
    });
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(_loadFonts);
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(useMaterial3: true),
          home: const PhoneControllerPage(targetHost: '192.168.1.20'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 2200));
    expect(tester.takeException(), isNull);
    final boundary =
        boundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    try {
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          expect(png, isNotNull);
          await File(
            _output,
          ).writeAsBytes(png!.buffer.asUint8List(), flush: true);
        } finally {
          image.dispose();
        }
      });
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, skip: _output.isEmpty);
}
