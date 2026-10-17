import 'dart:io';

import 'vr_controller_link.dart';

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
