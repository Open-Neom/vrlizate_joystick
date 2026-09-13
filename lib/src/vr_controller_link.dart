import 'dart:io';

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

/// Adapts the existing local WebSocket transport without changing its protocol.
class VrWebSocketControllerLink implements VrControllerLink {
  VrWebSocketControllerLink(this.socket);

  final WebSocket socket;

  @override
  Stream<Object?> get messages => socket.cast<Object?>();

  @override
  bool get isOpen => socket.readyState == WebSocket.open;

  @override
  void add(Object data) => socket.add(data);

  @override
  Future<void> close([int? code, String? reason]) async {
    await socket.close(code, reason);
  }
}
