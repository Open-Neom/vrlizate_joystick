/// An IPv4 address reported for a local network interface.
/// Kept independent of platform interface enumeration for deterministic tests.
class VrLocalAddressCandidate {
  const VrLocalAddressCandidate(this.interfaceName, this.address);

  final String interfaceName;
  final String address;
}
