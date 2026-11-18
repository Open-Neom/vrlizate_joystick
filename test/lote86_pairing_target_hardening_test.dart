import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  group('Lote 86 — vrlizate_joystick pairing SSRF & local interface hardening', () {
    test('VrControllerConnectionTarget.parse blocks cloud metadata, pre-trim CRLF & dot-homoglyphs', () {
      expect(
        () => VrControllerConnectionTarget.parse(
          'ws://169.254.169.254:8080/?token=secret123',
        ),
        throwsFormatException,
      );
      expect(
        () => VrControllerConnectionTarget.parse(
          'ws://metadata.google.internal:8080/?token=secret123',
        ),
        throwsFormatException,
      );
      expect(
        () => VrControllerConnectionTarget.parse(
          '\r\nws://192.168.1.15:8080/?token=secret123',
        ),
        throwsFormatException,
      );
      expect(
        () => VrControllerConnectionTarget.parse(
          '169.254.169.254',
          pairedHost: '169.254.169.254',
          pairedPort: 8080,
          sessionToken: 'secret123',
        ),
        throwsFormatException,
      );

      final ok = VrControllerConnectionTarget.parse(
        'ws://192.168.1.15:8080/?token=secret123',
      );
      expect(ok.host, equals('192.168.1.15'));
      expect(ok.port, equals(8080));
    });

    test('VrLocalNetworkAddress rejects C0/Bidi interface names and TEST-NET/benchmarking blocks', () {
      final selected = VrLocalNetworkAddress.select(const <VrLocalAddressCandidate>[
        VrLocalAddressCandidate('wlan0\u202E', '192.168.1.10'),
        VrLocalAddressCandidate('eth0', '198.18.0.5'),
        VrLocalAddressCandidate('eth1', '192.0.2.10'),
        VrLocalAddressCandidate('en0', '192.168.1.42'),
      ]);
      expect(selected, equals('192.168.1.42'));
    });
  });
}
