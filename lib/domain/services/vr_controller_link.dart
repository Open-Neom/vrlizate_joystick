/// A provider-neutral, already connected duplex controller channel.
///
/// Each message is a complete String JSON snapshot/command or `List<int>` binary
/// pose. BLE adapters own fragmentation/reassembly, authentication negotiation
/// and buffering until the single consumer listens. Close must be idempotent;
/// transport loss must complete/error [messages]. No native plugin is required.
abstract class VrControllerLink {
  Stream<Object?> get messages;
  bool get isOpen;
  void add(Object data);
  Future<void> close([int? code, String? reason]);
}

/// Optional capability implemented by high-speed links (such as the `3D Set`
/// `VRB1` UDP relay) that natively transport `46-byte` binary
/// `VrCompactGamepadFrame` snapshots without `jsonEncode`/`jsonDecode`.
abstract interface class VrCompactGamepadCapableLink {
  bool get supportsCompactGamepadFrames;
}

/// Optional sink implemented by duplex UDP controller links (such as
/// `VrBeaconVisorControllerLink` in a `3D Set`) to emit end-to-end cumulative
/// sequence acknowledgments when the Visor's `VrRemoteControllerService`
/// accepts (or deduplicates an already-accepted) `VrCompactGamepadFrame`.
abstract interface class VrCompactGamepadAckSink {
  void acknowledgeCompactGamepadSequence(int sequence);
}
