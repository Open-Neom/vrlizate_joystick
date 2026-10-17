import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/vr_pairing_camera_state.dart';

/// Owned by one pairing page. Injectable so lifecycle/navigation tests do not
/// need camera permission, a native camera texture, or GPU resources.
abstract class VrPairingCameraSession {
  ValueListenable<VrPairingCameraState> get state;
  Stream<String> get codes;
  Widget buildPreview(BuildContext context);
  Future<void> start();
  Future<void> stop();
  Future<void> toggleTorch();
  Future<void> dispose();
}
