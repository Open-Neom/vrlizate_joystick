import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  test(
    'VrControllerModeRequest sanitizes control/Bidi chars while keeping < > and rejects non-finite revision',
    () {
      final sanitized = VrControllerModeRequest.sanitizeActions(
        const <String, String>{
          'A': 'Saltar\u202E\x00   <A>',
          'B': '   ',
        },
      );
      expect(sanitized, <String, String>{'A': 'Saltar <A>'});

      expect(
        VrControllerModeRequest.tryParse(<String, Object?>{
          'type': VrControllerModeRequest.type,
          'version': VrControllerModeRequest.version,
          'mode': 'nes',
          'revision': double.infinity,
        }),
        isNull,
      );
      expect(
        VrControllerModeRequest.tryParse(<String, Object?>{
          'type': VrControllerModeRequest.type,
          'version': VrControllerModeRequest.version,
          'mode': 'nes',
          'revision': double.nan,
        }),
        isNull,
      );
      expect(
        () => const VrControllerModeRequest(
          mode: RemoteControllerMode.nes,
          revision: -1,
        ).toJson(),
        throwsArgumentError,
      );
    },
  );

  test(
    'tryParseVrPairingUri and VrControllerConnectionTarget reject Bidi/oversized/backslash inputs',
    () {
      expect(
        tryParseVrPairingUri(
          'vrlizate://pair?host=192.168.1.2&port=8080&token=abc\u202E&role=parent&transport=localSocket',
        ),
        isNull,
      );
      expect(
        () => VrControllerConnectionTarget.parse(
          'ws://192.168.1.2:8080/?token=abc\u0000def',
        ),
        throwsFormatException,
      );
      expect(
        () => VrControllerConnectionTarget.parse(
          '192.168.1.2',
          pairedHost: '192.168.1.2',
          pairedPort: 70000,
          sessionToken: 'valid-token',
        ),
        throwsFormatException,
      );
      final target = VrControllerConnectionTarget.parse(
        'wss://visor.example.com:8443/?token=secret-123',
      );
      expect(target.secure, isTrue);
      expect(target.port, 8443);
      expect(target.token, 'secret-123');
    },
  );
}
