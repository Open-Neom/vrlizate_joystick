import '../../utils/constants/vr_joystick_constants.dart';
import '../models/vr_local_address_candidate.dart';

/// Selects an address suitable for a nearby controller's pairing invitation.
/// Wi-Fi/hotspot wins over Ethernet, then an unknown private LAN interface.
/// Cellular and VPN interfaces are rejected even when they use private IPv4.
///
/// This is an advertisement policy, not proof of peer reachability: routers can
/// still isolate clients. The WebSocket server remains bound to any IPv4.
abstract final class VrLocalNetworkAddress {
  static final _excluded = RegExp(
    VrJoystickConstants.excludedInterfacePattern,
  );
  static final _wifi = RegExp(VrJoystickConstants.wifiInterfacePattern);
  static final _ethernet = RegExp(
    VrJoystickConstants.ethernetInterfacePattern,
  );

  static String? select(Iterable<VrLocalAddressCandidate> candidates) {
    String? selectedAddress;
    String? selectedName;
    var selectedRank = 3;
    var selectedNumber = 0;
    for (final candidate in candidates) {
      final name = candidate.interfaceName.toLowerCase();
      if (_excluded.hasMatch(name)) continue;
      final octets = candidate.address.split(VrJoystickConstants.dotSeparator);
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

  /// Returns up to [limit] distinct valid LAN/Hotspot IPv4 addresses ordered by
  /// interface priority (Wi-Fi/Hotspot first, Ethernet second, private LAN
  /// third), excluding loopback, link-local, multicast, VPN, and cellular.
  static List<String> selectAll(
    Iterable<VrLocalAddressCandidate> candidates, {
    int limit = 4,
  }) {
    final scored = <({String address, String name, int rank, int number})>[];
    final seen = <String>{};
    for (final candidate in candidates) {
      final name = candidate.interfaceName.toLowerCase();
      if (_excluded.hasMatch(name)) continue;
      final octets = candidate.address.split(VrJoystickConstants.dotSeparator);
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
      if (rank == 2 && !privateLan) continue;
      if (!seen.add(candidate.address)) continue;
      final number = (a << 24) | (b << 16) | (bytes[2] << 8) | bytes[3];
      scored.add((
        address: candidate.address,
        name: name,
        rank: rank,
        number: number,
      ));
    }
    scored.sort((x, y) {
      final r = x.rank.compareTo(y.rank);
      if (r != 0) return r;
      final n = x.name.compareTo(y.name);
      if (n != 0) return n;
      return x.number.compareTo(y.number);
    });
    return [for (final item in scored.take(limit)) item.address];
  }
}
