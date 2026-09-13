/// An IPv4 address reported for a local network interface.
/// Kept independent of platform interface enumeration for deterministic tests.
class VrLocalAddressCandidate {
  const VrLocalAddressCandidate(this.interfaceName, this.address);

  final String interfaceName;
  final String address;
}

/// Selects an address suitable for a nearby controller's pairing invitation.
/// Wi-Fi/hotspot wins over Ethernet, then an unknown private LAN interface.
/// Cellular and VPN interfaces are rejected even when they use private IPv4.
///
/// This is an advertisement policy, not proof of peer reachability: routers can
/// still isolate clients. The WebSocket server remains bound to any IPv4.
abstract final class VrLocalNetworkAddress {
  static final _excluded = RegExp(
    r'^(?:lo(?:\d|$)|(?:v4-)?rmnet|r_rmnet|ccmni|pdp_ip|wwan|mobile|cellular|'
    r'radio|rev_rmnet|usb_rmnet|seth|tun|tap|utun|ppp|ipsec|wg(?:\d|[-_]|$)|vpn|'
    r'tailscale|zerotier|zt[a-z0-9]|clat|v4-|dummy|docker|veth|virbr|'
    r'vboxnet|vmnet|awdl|llw|vti|ip_vti|ip6tnl|sit\d|gre|p2p)',
  );
  static final _wifi = RegExp(
    r'^(?:wlan|wifi|wi-fi|wl[a-z0-9]|ap\d|swlan|softap|hotspot)',
  );
  static final _ethernet = RegExp(r'^(?:eth|en\d|enp|ens|eno)');

  static String? select(Iterable<VrLocalAddressCandidate> candidates) {
    String? selectedAddress;
    String? selectedName;
    var selectedRank = 3;
    var selectedNumber = 0;
    for (final candidate in candidates) {
      final name = candidate.interfaceName.toLowerCase();
      if (_excluded.hasMatch(name)) continue;
      final octets = candidate.address.split('.');
      if (octets.length != 4) continue;
      final bytes = <int>[];
      for (final octet in octets) {
        final value = int.tryParse(octet);
        if (value == null || value < 0 || value > 255 || '$value' != octet) {
          break;
        }
        bytes.add(value);
      }
      if (bytes.length != 4) continue;
      final a = bytes[0], b = bytes[1];
      if (a == 0 || a == 127 || a >= 224 || (a == 169 && b == 254)) {
        continue;
      }
      final privateLan =
          a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
      final rank = _wifi.hasMatch(name)
          ? 0
          : (_ethernet.hasMatch(name) ? 1 : 2);
      // Unknown interfaces only qualify when their address is private LAN.
      if (rank == 2 && !privateLan) continue;
      final number = (a << 24) | (b << 16) | (bytes[2] << 8) | bytes[3];
      final nameOrder = selectedName == null
          ? -1
          : name.compareTo(selectedName);
      if (selectedAddress == null ||
          rank < selectedRank ||
          (rank == selectedRank &&
              (nameOrder < 0 || (nameOrder == 0 && number < selectedNumber)))) {
        selectedAddress = candidate.address;
        selectedName = name;
        selectedRank = rank;
        selectedNumber = number;
      }
    }
    return selectedAddress;
  }
}
