import '../../utils/constants/vr_joystick_constants.dart';
import '../models/vr_local_address_candidate.dart';

/// Selects an address suitable for a nearby controller's pairing invitation.
/// Wi-Fi/hotspot wins over Ethernet, then an unknown private LAN interface.
/// Cellular and VPN interfaces are rejected even when they use private IPv4.
///
/// This is an advertisement policy, not proof of peer reachability: routers can
/// still isolate clients. The WebSocket server remains bound to any IPv4.
abstract final class VrLocalNetworkAddress {
  static final _unsafeIfaceChars = RegExp(
    r'[\x00-\x20\x7F-\x9F\u0085\u061C\u200B-\u200F\u2028-\u202E\u2060\u2066-\u2069\uFEFF]',
  );
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
      if (candidate.interfaceName.isEmpty ||
          candidate.interfaceName.length > 64 ||
          _unsafeIfaceChars.hasMatch(candidate.interfaceName)) {
        continue;
      }
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
      final a = bytes[0], b = bytes[1], c = bytes[2];
      if (a == 0 ||
          a == 127 ||
          a >= 224 ||
          (a == 169 && b == 254) ||
          (a == 100 && b == 100 && c == 100 && bytes[3] == 200) ||
          (a == 192 && b == 0 && (c == 0 || c == 2)) ||
          (a == 198 && (b == 18 || b == 19)) ||
          (a == 198 && b == 51 && c == 100) ||
          (a == 203 && b == 0 && c == 113)) {
        continue;
      }
      final privateLan =
          a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
      final rank = _wifi.hasMatch(name)
          ? 0
          : (_ethernet.hasMatch(name) ? 1 : 2);
      // Unknown interfaces only qualify when their address is private LAN.
      if (rank == 2 && !privateLan) continue;
      // 53-bit JS-safe unsigned IPv4 integer (`* 0x1000000` instead of `<< 24`
      // which overflows into negative 32-bit signed ints on Dart2JS when a >= 128).
      final number =
          a * 0x1000000 + b * 0x10000 + bytes[2] * 0x100 + bytes[3];
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
      if (candidate.interfaceName.isEmpty ||
          candidate.interfaceName.length > 64 ||
          _unsafeIfaceChars.hasMatch(candidate.interfaceName)) {
        continue;
      }
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
      final a = bytes[0], b = bytes[1], c = bytes[2];
      if (a == 0 ||
          a == 127 ||
          a >= 224 ||
          (a == 169 && b == 254) ||
          (a == 100 && b == 100 && c == 100 && bytes[3] == 200) ||
          (a == 192 && b == 0 && (c == 0 || c == 2)) ||
          (a == 198 && (b == 18 || b == 19)) ||
          (a == 198 && b == 51 && c == 100) ||
          (a == 203 && b == 0 && c == 113)) {
        continue;
      }
      final privateLan =
          a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
      final rank = _wifi.hasMatch(name)
          ? 0
          : (_ethernet.hasMatch(name) ? 1 : 2);
      if (rank == 2 && !privateLan) continue;
      if (!seen.add(candidate.address)) continue;
      final number =
          a * 0x1000000 + b * 0x10000 + bytes[2] * 0x100 + bytes[3];
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
