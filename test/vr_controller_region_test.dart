import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/src/vr_controller_region.dart';

const _regionKey = ValueKey('tested_region');

Path _concavePath() => Path.combine(
  PathOperation.difference,
  Path()..addRect(const Rect.fromLTWH(0, 0, 200, 200)),
  Path()..addOval(Rect.fromCircle(center: const Offset(160, 100), radius: 70)),
);

Widget _app({
  required VoidCallback onDown,
  required VoidCallback onUp,
  VoidCallback? onUnderlyingDown,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 200,
        height: 200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => onUnderlyingDown?.call(),
              child: const ColoredBox(color: Colors.black),
            ),
            VrControllerRegion(
              key: _regionKey,
              path: _concavePath(),
              labelPosition: const Offset(40, 100),
              label: 'X',
              colors: const [Colors.blue, Colors.indigo],
              active: false,
              onDown: onDown,
              onUp: onUp,
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('visible concave hole passes down to the underlying surface', (
    tester,
  ) async {
    final events = <String>[];
    var underlying = 0;
    await tester.pumpWidget(
      _app(
        onDown: () => events.add('down'),
        onUp: () => events.add('up'),
        onUnderlyingDown: () => underlying++,
      ),
    );
    final origin = tester.getTopLeft(find.byKey(_regionKey));
    await tester.tapAt(origin + const Offset(160, 100));
    expect(events, isEmpty, reason: 'the transparent notch is not a button');
    expect(underlying, 1);
    await tester.tapAt(origin + const Offset(30, 100));
    expect(events, ['down', 'up']);
    expect(underlying, 1, reason: 'the solid region owns this down');
  });

  for (final secondReleasesFirst in [true, false]) {
    testWidgets('same-region second pointer cannot steal or release first '
        '(second releases first: $secondReleasesFirst)', (tester) async {
      final events = <String>[];
      await tester.pumpWidget(
        _app(onDown: () => events.add('down'), onUp: () => events.add('up')),
      );
      final origin = tester.getTopLeft(find.byKey(_regionKey));
      final first = await tester.createGesture(pointer: 11);
      final second = await tester.createGesture(pointer: 12);
      await first.down(origin + const Offset(25, 70));
      await second.down(origin + const Offset(40, 130));
      expect(events, ['down']);
      if (secondReleasesFirst) {
        await second.up();
        expect(events, ['down']);
        await first.up();
      } else {
        await first.up();
        expect(events, ['down', 'up']);
        await second.up();
      }
      expect(events, ['down', 'up']);
      final fresh = await tester.createGesture(pointer: 13);
      await fresh.down(origin + const Offset(40, 100));
      await fresh.up();
      expect(events, ['down', 'up', 'down', 'up']);
    });
  }

  testWidgets('dragging into the hole and outside keeps the original owner', (
    tester,
  ) async {
    final events = <String>[];
    var underlying = 0;
    await tester.pumpWidget(
      _app(
        onDown: () => events.add('down'),
        onUp: () => events.add('up'),
        onUnderlyingDown: () => underlying++,
      ),
    );
    final origin = tester.getTopLeft(find.byKey(_regionKey));
    final finger = await tester.createGesture(pointer: 21);
    await finger.down(origin + const Offset(30, 100));
    await finger.moveTo(origin + const Offset(160, 100));
    await finger.moveTo(origin + const Offset(250, 240));
    expect(events, ['down']);
    expect(underlying, 0);
    await finger.up();
    expect(events, ['down', 'up']);
  });

  testWidgets('cancellation releases only its owner and allows a fresh down', (
    tester,
  ) async {
    final events = <String>[];
    await tester.pumpWidget(
      _app(onDown: () => events.add('down'), onUp: () => events.add('up')),
    );
    final origin = tester.getTopLeft(find.byKey(_regionKey));
    final first = await tester.createGesture(pointer: 31);
    final ignored = await tester.createGesture(pointer: 32);
    await first.down(origin + const Offset(30, 70));
    await ignored.down(origin + const Offset(30, 130));
    await ignored.cancel();
    expect(events, ['down']);
    await first.cancel();
    expect(events, ['down', 'up']);
    final fresh = await tester.createGesture(pointer: 33);
    await fresh.down(origin + const Offset(30, 100));
    await fresh.up();
    expect(events, ['down', 'up', 'down', 'up']);
  });

  testWidgets('different regions retain independent simultaneous owners', (
    tester,
  ) async {
    final events = <String>[];
    Widget region(String label) => SizedBox(
      width: 200,
      height: 200,
      child: VrControllerRegion(
        key: ValueKey(label),
        path: _concavePath(),
        labelPosition: const Offset(40, 100),
        label: label,
        colors: const [Colors.blue, Colors.indigo],
        active: false,
        onDown: () => events.add('$label down'),
        onUp: () => events.add('$label up'),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [region('L'), region('A')],
            ),
          ),
        ),
      ),
    );
    final left = await tester.createGesture(pointer: 41);
    final right = await tester.createGesture(pointer: 42);
    await left.down(
      tester.getTopLeft(find.byKey(const ValueKey('L'))) +
          const Offset(30, 100),
    );
    await right.down(
      tester.getTopLeft(find.byKey(const ValueKey('A'))) +
          const Offset(30, 100),
    );
    expect(events, ['L down', 'A down']);
    await right.up();
    expect(events, ['L down', 'A down', 'A up']);
    await left.cancel();
    expect(events, ['L down', 'A down', 'A up', 'L up']);
  });

  testWidgets(
    'semantics tap emits one complete press when there is no finger',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final events = <String>[];
        await tester.pumpWidget(
          _app(onDown: () => events.add('down'), onUp: () => events.add('up')),
        );
        final semantics = find.descendant(
          of: find.byKey(_regionKey),
          matching: find.byWidgetPredicate(
            (widget) => widget is Semantics && widget.properties.label == 'X',
          ),
        );
        final node = tester.getSemantics(semantics);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        expect(events, ['down', 'up']);
      } finally {
        // Widget binding checks active handles before package:test teardown.
        handle.dispose();
      }
    },
  );

  testWidgets('semantics tap cannot release a currently held pointer', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      final events = <String>[];
      await tester.pumpWidget(
        _app(onDown: () => events.add('down'), onUp: () => events.add('up')),
      );
      final finger = await tester.createGesture(pointer: 51);
      await finger.down(
        tester.getTopLeft(find.byKey(_regionKey)) + const Offset(30, 100),
      );
      final semantics = find.descendant(
        of: find.byKey(_regionKey),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.label == 'X',
        ),
      );
      final node = tester.getSemantics(semantics);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      expect(events, ['down']);
      await finger.up();
      expect(events, ['down', 'up']);
    } finally {
      handle.dispose();
    }
  });
}
