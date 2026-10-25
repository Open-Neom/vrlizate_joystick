import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_cast/vrlizate_cast.dart';
import 'package:vrlizate_joystick/vrlizate_joystick.dart';

class _Consent extends VrCastRealtimeHost {
  bool awaiting = false;
  @override
  bool get isAwaitingConsent => awaiting;
  @override
  void setSource({required bool active, bool stereo = true}) {}
  void resolve(bool pending) {
    awaiting = pending;
    notifyListeners();
  }
}

class _Host extends VrCastHost {
  _Host(_Consent consent) : super(realtime: consent);
  VrCastSourceHandle? lease;
  int revocations = 0;
  @override
  VrCastSourceHandle registerSource(
    VrCastFrameProvider provider, {
    bool realtimeStereo = true,
  }) => lease = super.registerSource(provider, realtimeStereo: realtimeStereo);
  @override
  void unregisterSource(VrCastSourceHandle handle) {
    revocations++;
    lease = null;
    super.unregisterSource(handle);
  }
}

void main() {
  testWidgets(
    'experience active rebuild preserves the permission return lease',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final consent = _Consent();
      final host = _Host(consent);
      final cast = VrAppCast(host: host);
      final active = ValueNotifier(true);
      addTearDown(() async {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(const SizedBox.shrink());
        cast.dispose();
        active.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: VrCastScope(
            cast: cast,
            child: ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, value, _) => VrCastExperience(
                active: value,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      final originalLease = host.lease;
      consent.resolve(true);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      active.value = false;
      await tester.pump();
      consent.resolve(false);
      await tester.pump();
      expect(host.lease, same(originalLease));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(host.lease, same(originalLease));
      expect(host.revocations, 0);
    },
  );
}
