import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_joystick/src/vr_local_network_address.dart';

void main() {
  test('Samsung cellular listed before Wi-Fi advertises wlan0 LAN address', () {
    const candidates = [
      VrLocalAddressCandidate('rmnet_data2', '10.22.29.53'),
      VrLocalAddressCandidate('wlan0', '192.168.100.12'),
    ];
    expect(VrLocalNetworkAddress.select(candidates), '192.168.100.12');
    expect(VrLocalNetworkAddress.select(candidates.reversed), '192.168.100.12');
  });

  test('Wi-Fi/hotspot wins over Ethernet and unknown private adapters', () {
    for (final name in [
      'wlan0',
      'wlp2s0',
      'wifi0',
      'ap0',
      'swlan0',
      'softap0',
    ]) {
      expect(
        VrLocalNetworkAddress.select([
          const VrLocalAddressCandidate('unrecognized0', '10.0.0.3'),
          const VrLocalAddressCandidate('eth0', '192.168.1.4'),
          VrLocalAddressCandidate(name, '192.168.43.1'),
        ]),
        '192.168.43.1',
      );
    }
  });

  test('Ethernet and unknown private LAN remain supported', () {
    expect(
      VrLocalNetworkAddress.select(const [
        VrLocalAddressCandidate('unknown', '192.168.1.2'),
        VrLocalAddressCandidate('en0', '172.16.0.4'),
      ]),
      '172.16.0.4',
    );
    expect(
      VrLocalNetworkAddress.select(const [
        VrLocalAddressCandidate('unknown', '172.31.4.5'),
      ]),
      '172.31.4.5',
    );
  });

  test('cellular and VPN addresses never qualify even if private', () {
    for (final name in [
      'rmnet_data0',
      'r_rmnet_data0',
      'v4-rmnet_data0',
      'ccmni0',
      'pdp_ip0',
      'wwan0',
      'mobile0',
      'rev_rmnet0',
      'usb_rmnet0',
      'seth0',
      'tun0',
      'tap0',
      'utun3',
      'ppp0',
      'ipsec0',
      'wg0',
      'wg-mullvad',
      'vpn0',
      'tailscale0',
      'zerotier0',
      'ztabc123',
      'vti0',
      'ip_vti0',
      'ip6tnl0',
      'sit0',
      'gre0',
      'p2p0',
      'docker0',
      'veth0123',
    ]) {
      expect(
        VrLocalNetworkAddress.select([
          VrLocalAddressCandidate(name, '10.22.29.53'),
        ]),
        isNull,
        reason: name,
      );
    }
  });

  test(
    'rejects loopback/link-local/invalid IPv4 and unknown public adapters',
    () {
      for (final address in [
        '127.0.0.1',
        '127.3.4.5',
        '169.254.1.2',
        '0.0.0.0',
        '224.0.0.1',
        '255.255.255.255',
        '::1',
        'fe80::1',
        '192.168.1.256',
        '192.168.1',
        '192.168.01.1',
        '192.168.1.2 ',
        '',
      ]) {
        expect(
          VrLocalNetworkAddress.select([
            VrLocalAddressCandidate('wlan0', address),
          ]),
          isNull,
          reason: address,
        );
      }
      expect(
        VrLocalNetworkAddress.select(const [
          VrLocalAddressCandidate('unknown', '100.70.1.2'),
          VrLocalAddressCandidate('unknown', '8.8.8.8'),
          VrLocalAddressCandidate('lo', '10.1.2.3'),
        ]),
        isNull,
      );
      expect(VrLocalNetworkAddress.select(const []), isNull);
    },
  );

  test('same priority is deterministic by interface then numeric address', () {
    const candidates = [
      VrLocalAddressCandidate('wlan1', '192.168.1.2'),
      VrLocalAddressCandidate('wlan0', '192.168.1.100'),
      VrLocalAddressCandidate('wlan0', '192.168.1.12'),
    ];
    expect(VrLocalNetworkAddress.select(candidates), '192.168.1.12');
    expect(VrLocalNetworkAddress.select(candidates.reversed), '192.168.1.12');
  });
}
