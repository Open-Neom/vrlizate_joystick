import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _PreviewLink implements VrControllerLink {
  final inbound = StreamController<Object?>();
  final sent = <String>[];
  var open = true;

  List<Map<String, dynamic>> get messagesSent => [
    for (final message in sent) jsonDecode(message) as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> get previews => [
    for (final message in messagesSent)
      if (message['type'] == 'cast_preview') message,
  ];

  @override
  Stream<Object?> get messages => inbound.stream;

  @override
  bool get isOpen => open;

  @override
  void add(Object data) {
    if (!open) throw StateError('Closed link');
    sent.add(data as String);
  }

  void sendState(int sequence, {int revision = 0, bool held = false}) {
    inbound.add(
      jsonEncode({
        'sequence': sequence,
        'hostModeRevision': revision,
        'mode': 'joystick',
        'btnA': held,
        'stickY': held ? .8 : 0,
      }),
    );
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!open) return;
    open = false;
    unawaited(inbound.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final firstUri = Uri.parse(
    'http://192.168.1.8:9090/preview?token=viewer-one',
  );
  final secondUri = Uri.parse(
    'http://192.168.1.8:9090/preview?token=viewer-two',
  );
  late VrRemoteControllerService service;
  var nowUs = 0;

  setUp(() {
    nowUs = 0;
    service = VrRemoteControllerService(
      sessionToken: 'controller-secret',
      nowMicroseconds: () => nowUs,
      inputTimeout: const Duration(milliseconds: 50),
      watchdogInterval: const Duration(milliseconds: 10),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  tearDown(() {
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  _PreviewLink connect() {
    final link = _PreviewLink();
    expect(
      service.attachControllerLink(link, sessionToken: service.sessionToken),
      isTrue,
    );
    return link;
  }

  test(
    'preview is private until authenticated attach, without LAN startup',
    () {
      service.setCastPreviewUri(firstUri);
      final unauthorized = _PreviewLink();
      addTearDown(unauthorized.close);
      expect(
        service.attachControllerLink(unauthorized, sessionToken: 'wrong'),
        isFalse,
      );
      expect(unauthorized.sent, isEmpty);
      expect(unauthorized.inbound.hasListener, isFalse);
      expect(service.isConnected, isFalse);
      expect(service.isRunning, isFalse);
      expect(service.serverPort, isNull);
      expect(service.serverUrl, isNull);

      final paired = connect();
      expect(paired.messagesSent.first['type'], 'vrlizate.controllerMode');
      expect(paired.previews, [
        {'type': 'cast_preview', 'url': firstUri.toString()},
      ]);
      expect(paired.sent.join(), isNot(contains(service.sessionToken)));
      expect(
        service.attachControllerLink(unauthorized, sessionToken: 'wrong'),
        isFalse,
      );
      service.setCastPreviewUri(secondUri);
      expect(unauthorized.sent, isEmpty);
      expect(paired.previews.last['url'], secondUri.toString());
    },
  );

  test('changes and explicit stop are sent once without changing mode', () {
    final link = connect();
    expect(link.sent, hasLength(1));
    service.setCastPreviewUri(null);
    expect(link.sent, hasLength(1));
    service.setCastPreviewUri(firstUri);
    service.setCastPreviewUri(Uri.parse(firstUri.toString()));
    service.setCastPreviewUri(secondUri);
    service.setCastPreviewUri(null);
    service.setCastPreviewUri(null);
    expect(link.previews.map((message) => message['url']), [
      firstUri.toString(),
      secondUri.toString(),
      null,
    ]);
    expect(
      link.messagesSent.where(
        (message) => message['type'] == 'vrlizate.controllerMode',
      ),
      hasLength(1),
    );
  });

  testWidgets('reconnect receives current offer and old peer gets no updates', (
    tester,
  ) async {
    service.setCastPreviewUri(firstUri);
    final first = connect();
    service.attachControllerLink(first, sessionToken: service.sessionToken);
    expect(first.previews, hasLength(1));
    final replacement = connect();
    expect(first.isOpen, isFalse);
    expect(replacement.messagesSent.first['type'], 'vrlizate.controllerMode');
    expect(replacement.previews.single['url'], firstUri.toString());
    service.setCastPreviewUri(secondUri);
    expect(first.previews, hasLength(1));
    await replacement.close();
    await tester.pump();
    expect(service.isConnected, isFalse);
    final reconnected = connect();
    expect(reconnected.previews.single['url'], secondUri.toString());
    service.stop();
  });

  testWidgets('preview does not release held input or refresh its watchdog', (
    tester,
  ) async {
    final link = connect();
    link.sendState(0);
    await tester.pump();
    link.sendState(1, held: true);
    await tester.pump();
    final held = service.latestState;
    final accepted = service.telemetry.acceptedStates;
    nowUs = 40000;
    service.setCastPreviewUri(firstUri);
    service.setCastPreviewUri(null);
    expect(identical(service.latestState, held), isTrue);
    expect(service.telemetry.acceptedStates, accepted);
    expect(service.telemetry.inputAge, const Duration(milliseconds: 40));
    nowUs = 50000;
    await tester.pump(const Duration(milliseconds: 10));
    expect(service.latestState.isNeutralized, isTrue);
    expect(service.latestState.btnA, isFalse);
    expect(service.latestState.stickY, 0);
    expect(service.telemetry.watchdogNeutralizations, 1);
    expect(service.isConnected, isTrue);
    service.stop();
  });

  testWidgets(
    'preview never acknowledges or bypasses a changed control profile',
    (tester) async {
      final link = connect();
      link.sendState(0);
      await tester.pump();
      service.requestControllerMode(
        RemoteControllerMode.joystick,
        horizontalLook: true,
      );
      service.setCastPreviewUri(firstUri);
      link.sendState(1, revision: 0, held: true);
      link.sendState(2, revision: 1, held: true);
      await tester.pump();
      expect(service.latestState.isNeutralized, isTrue);
      link.sendState(3, revision: 1);
      await tester.pump();
      link.sendState(4, revision: 1, held: true);
      await tester.pump();
      expect(service.latestState.btnA, isTrue);
      expect(service.latestState.stickY, .8);
      service.stop();
    },
  );

  test(
    'stop forgets expired preview and disposed/closed links reveal nothing',
    () {
      service.setCastPreviewUri(firstUri);
      connect();
      service.stop();
      final replacement = connect();
      expect(replacement.previews, isEmpty);
      final closed = _PreviewLink()..open = false;
      expect(
        service.attachControllerLink(
          closed,
          sessionToken: service.sessionToken,
        ),
        isFalse,
      );
      expect(closed.sent, isEmpty);
      service.dispose();
      final rejected = _PreviewLink();
      addTearDown(rejected.close);
      service.setCastPreviewUri(secondUri);
      expect(
        service.attachControllerLink(
          rejected,
          sessionToken: service.sessionToken,
        ),
        isFalse,
      );
      expect(rejected.sent, isEmpty);
    },
  );

  test(
    'invalid and oversized offers cannot poison the current link or offer',
    () {
      final link = connect();
      service.setCastPreviewUri(firstUri);
      for (final uri in [
        Uri.parse('/preview'),
        Uri.parse('file:///private/preview'),
        Uri.parse('http://user:secret@192.168.1.8/preview'),
        Uri.parse('http://192.168.1.8/preview#fragment'),
        Uri.parse('http://192.168.1.8/preview?token=${'a' * 1024}'),
      ]) {
        expect(() => service.setCastPreviewUri(uri), throwsArgumentError);
        expect(service.isConnected, isTrue);
        expect(link.previews, hasLength(1));
      }
      final replacement = connect();
      expect(replacement.previews.single['url'], firstUri.toString());
      expect(
        utf8.encode(replacement.sent.last).length + 1,
        lessThanOrEqualTo(1024),
      );
    },
  );
}
