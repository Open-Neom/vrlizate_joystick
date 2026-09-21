import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  test('host request round trips joystick/driving with explicit version', () {
    for (final mode in [
      RemoteControllerMode.joystick,
      RemoteControllerMode.driving,
    ]) {
      final request = VrControllerModeRequest(mode: mode, revision: 12);
      final parsed = VrControllerModeRequest.tryParse(
        jsonEncode(request.toJson()),
      )!;
      expect(parsed.mode, mode);
      expect(parsed.revision, 12);
      expect(request.toJson()['type'], 'vrlizate.controllerMode');
      expect(request.toJson()['version'], 1);
    }
  });

  test('malformed, unsupported and unsafe revision messages are ignored', () {
    final valid = const VrControllerModeRequest(
      mode: RemoteControllerMode.joystick,
      revision: 1,
    ).toJson();
    for (final input in [
      null,
      false,
      [],
      '{',
      'x' * 4097,
      {...valid, 'type': 'input'},
      {...valid, 'version': 2},
      {...valid, 'mode': 'laser'},
      {...valid, 'mode': 'unknown'},
      {...valid, 'revision': -1},
      {...valid, 'revision': 1.5},
      {...valid, 'revision': '1'},
      {...valid, 'revision': VrControllerModeRequest.maxRevision + 1},
    ]) {
      expect(VrControllerModeRequest.tryParse(input), isNull, reason: '$input');
    }
    expect(
      () => const VrControllerModeRequest(
        mode: RemoteControllerMode.laser,
        revision: 0,
      ).toJson(),
      throwsArgumentError,
    );
  });

  test(
    'socket session rejects duplicate and stale modes but resets on reconnect',
    () {
      final session = VrControllerModeSession();
      Map<String, Object> request(int revision, RemoteControllerMode mode) =>
          VrControllerModeRequest(mode: mode, revision: revision).toJson();
      expect(session.revision, isNull);
      expect(
        session.accept(request(7, RemoteControllerMode.driving))!.mode,
        RemoteControllerMode.driving,
      );
      expect(session.accept(request(7, RemoteControllerMode.joystick)), isNull);
      expect(session.accept(request(6, RemoteControllerMode.joystick)), isNull);
      expect(session.accept('not JSON'), isNull);
      expect(session.revision, 7);
      expect(
        session.accept(request(8, RemoteControllerMode.joystick))!.mode,
        RemoteControllerMode.joystick,
      );
      session.reset();
      expect(session.revision, isNull);
      expect(
        session.accept(request(0, RemoteControllerMode.joystick))!.revision,
        0,
      );
    },
  );

  group('button captions', () {
    test('round trip known keys, drop unknown ones, cap length', () {
      const request = VrControllerModeRequest(
        mode: RemoteControllerMode.joystick,
        revision: 3,
        actions: {
          'A': 'Disparar',
          'x': ' Cambiar arma ',
          'GRIP': 'Abrir puerta',
          'Z': 'no existe',
          'Y': '',
          'L': 'Una etiqueta larguísima que no cabe en un botón',
        },
      );
      final json = request.toJson();
      final parsed = VrControllerModeRequest.tryParse(jsonEncode(json))!;
      expect(parsed.actions, {
        'A': 'Disparar',
        'X': 'Cambiar arma',
        'GRIP': 'Abrir puerta',
        'L': 'Una etiqueta larguísima',
      });
      expect(
        parsed.actions['L']!.length,
        lessThanOrEqualTo(VrControllerModeRequest.maxActionLength),
      );
    });

    test('are optional on the wire and ignored when malformed', () {
      const plain = VrControllerModeRequest(
        mode: RemoteControllerMode.driving,
        revision: 1,
      );
      expect(plain.toJson().containsKey('actions'), isFalse);
      final base = plain.toJson();
      for (final actions in [
        null,
        'text',
        7,
        [],
        {'A': 1},
        {'A': null},
      ]) {
        final parsed = VrControllerModeRequest.tryParse({
          ...base,
          'actions': actions,
        });
        expect(parsed, isNotNull, reason: '$actions');
        expect(parsed!.actions, isEmpty, reason: '$actions');
      }
    });

    test('hostile keys cannot reach the layout', () {
      final parsed = VrControllerModeRequest.tryParse({
        ...const VrControllerModeRequest(
          mode: RemoteControllerMode.joystick,
          revision: 1,
        ).toJson(),
        'actions': {
          '__proto__': 'x',
          'constructor': 'y',
          'A<script>': 'z',
          'B': '<b>Atrás</b>',
        },
      })!;
      expect(parsed.actions.keys, ['B']);
      // Captions are plain text; rendering must never interpret markup.
      expect(parsed.actions['B'], '<b>Atrás</b>');
    });
  });
}
