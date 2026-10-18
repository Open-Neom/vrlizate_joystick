import 'package:flutter/services.dart';
import 'package:vrlizate/vrlizate.dart';

/// Bridges Flutter's [HardwareKeyboard] events (Bluetooth Gamepads, USB controllers,
/// and physical keyboards) directly into a [VrGamepadDriver].
///
/// Supports:
/// - Standard Bluetooth Gamepad buttons (A, B, X, Y, L2, R2).
/// - Keyboard navigation fallbacks (WASD, Arrow Keys, Enter, Space, Escape).
/// - Automatic Zero-GC emission through [VrInputArbiter] with [VrInputPriority.medium].
class HardwareGamepadAdapter {
  final VrGamepadDriver driver;

  // Track virtual stick state from directional keys
  double _keyStickX = 0.0;
  double _keyStickY = 0.0;

  HardwareGamepadAdapter({VrGamepadDriver? driver})
    : driver = driver ?? VrGamepadDriver();

  void attachToHardware() {
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
  }

  void detachFromHardware() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (!driver.isAttached) return false;

    final isRepeat = event is KeyRepeatEvent;
    final isDown = event is KeyDownEvent || isRepeat;
    final isUp = event is KeyUpEvent;
    final key = event.logicalKey;

    // 1. Standard Gamepad & Keyboard Face Buttons
    if (key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      if (isRepeat) return true;
      return driver.updateButton(VrGamepadButton.a, isDown);
    }

    if (key == LogicalKeyboardKey.gameButtonB ||
        key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace) {
      if (isRepeat) return true;
      return driver.updateButton(VrGamepadButton.b, isDown);
    }

    if (key == LogicalKeyboardKey.gameButtonX) {
      if (isRepeat) return true;
      return driver.updateButton(VrGamepadButton.x, isDown);
    }

    if (key == LogicalKeyboardKey.gameButtonY) {
      if (isRepeat) return true;
      return driver.updateButton(VrGamepadButton.y, isDown);
    }

    // 2. Triggers
    if (key == LogicalKeyboardKey.gameButtonLeft1 ||
        key == LogicalKeyboardKey.gameButtonLeft2) {
      if (isRepeat) return true;
      return driver.updateTrigger(VrGamepadButton.l2, isDown ? 1.0 : 0.0);
    }

    if (key == LogicalKeyboardKey.gameButtonRight1 ||
        key == LogicalKeyboardKey.gameButtonRight2) {
      if (isRepeat) return true;
      return driver.updateTrigger(VrGamepadButton.r2, isDown ? 1.0 : 0.0);
    }

    // 3. Directional Locomotion (D-Pad, Arrow Keys, WASD)
    bool stickChanged = false;
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.keyW ||
        key == LogicalKeyboardKey.gameButtonSelect) {
      _keyStickY = isDown ? 1.0 : (isUp ? 0.0 : _keyStickY);
      stickChanged = true;
    } else if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.keyS) {
      _keyStickY = isDown ? -1.0 : (isUp ? 0.0 : _keyStickY);
      stickChanged = true;
    }

    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyA) {
      _keyStickX = isDown ? -1.0 : (isUp ? 0.0 : _keyStickX);
      stickChanged = true;
    } else if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.keyD) {
      _keyStickX = isDown ? 1.0 : (isUp ? 0.0 : _keyStickX);
      stickChanged = true;
    }

    if (stickChanged) {
      return driver.updateStick(_keyStickX, _keyStickY, edgeTurnEnabled: false);
    }

    return false;
  }

  /// Test hook for raw edge handling without registering a process-wide
  /// [HardwareKeyboard] callback.
  bool debugHandleKeyEvent(KeyEvent event) => _handleKeyEvent(event);
}
