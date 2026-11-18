import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  group('VrLocalNetworkAddress Lote 55 JS-safe IPv4 ordering & CGNAT IMDS', () {
    test(
      'selects 10.x.x.x over 192.168.x.x on identical interface on both VM and Dart2JS',
      () {
        // Under the legacy `(a << 24)` signed 32-bit JS shift, `192 << 24`
        // overflowed to `-1073741824 < 167772160` (`10 << 24`), inverting tie-breaks.
        final pickedFrom192First = VrLocalNetworkAddress.select(const [
          VrLocalAddressCandidate('wlan0', '192.168.1.42'),
          VrLocalAddressCandidate('wlan0', '10.0.0.5'),
        ]);
        final pickedFrom10First = VrLocalNetworkAddress.select(const [
          VrLocalAddressCandidate('wlan0', '10.0.0.5'),
          VrLocalAddressCandidate('wlan0', '192.168.1.42'),
        ]);
        expect(pickedFrom192First, '10.0.0.5');
        expect(pickedFrom10First, '10.0.0.5');

        final picked172Vs192 = VrLocalNetworkAddress.select(const [
          VrLocalAddressCandidate('wlan0', '192.168.1.10'),
          VrLocalAddressCandidate('wlan0', '172.16.0.10'),
        ]);
        expect(picked172Vs192, '172.16.0.10');
      },
    );

    test('blocks Tailscale/cloud metadata IP 100.100.100.200 and link-local', () {
      final picked = VrLocalNetworkAddress.select(const [
        VrLocalAddressCandidate('wlan0', '100.100.100.200'),
        VrLocalAddressCandidate('wlan0', '169.254.169.254'),
        VrLocalAddressCandidate('wlan0', '127.0.0.1'),
        VrLocalAddressCandidate('eth0', '192.168.50.12'),
      ]);
      expect(picked, '192.168.50.12');
    });
  });
}
