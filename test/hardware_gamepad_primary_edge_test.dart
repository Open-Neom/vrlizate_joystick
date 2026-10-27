import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate/vrlizate.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

void main() {
  test('physical A held repeats cannot confirm the next focused action', () {
    final arbiter = VrInputArbiter();
    final driver = VrGamepadDriver();
    final adapter = HardwareGamepadAdapter(driver: driver);
    arbiter.attachDriver(driver);
    var confirms = 0;
    arbiter.addListener((event) {
      if (event.type == VrInputType.select && event.active) {
        confirms++;
        event.consume();
      }
    });
    const physical = PhysicalKeyboardKey.gameButtonA;
    const logical = LogicalKeyboardKey.gameButtonA;
    adapter.debugHandleKeyEvent(
      const KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: Duration.zero,
      ),
    );
    for (var i = 0; i < 60; i++) {
      adapter.debugHandleKeyEvent(
        const KeyRepeatEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: Duration.zero,
        ),
      );
    }
    expect(confirms, 1);
    adapter.debugHandleKeyEvent(
      const KeyUpEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: Duration.zero,
      ),
    );
    adapter.debugHandleKeyEvent(
      const KeyDownEvent(
        physicalKey: physical,
        logicalKey: logical,
        timeStamp: Duration.zero,
      ),
    );
    expect(confirms, 2);
    arbiter.dispose();
  });
}
