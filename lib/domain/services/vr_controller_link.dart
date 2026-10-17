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
