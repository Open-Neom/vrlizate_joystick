// Copyright 2026 Open Neom contributors.
// SPDX-License-Identifier: BSD-3-Clause
package io.flutter.plugins.camerax;

/** Plain JVM regression probe: no Android, Flutter, Gradle or JUnit required. */
public final class CameraFrameGateJvmTest {
  private static int checks;
  private static void check(boolean value, String message) {
    checks++;
    if (!value) throw new AssertionError(message);
  }
  private static void expectInvalid(CameraFrameGate gate, long interval) {
    try { gate.setIntervalMs(interval); }
    catch (IllegalArgumentException expected) { checks++; return; }
    throw new AssertionError("invalid interval accepted");
  }
  public static void main(String[] args) {
    CameraFrameGate legacy = new CameraFrameGate();
    check(legacy.intervalMs() == 0, "default interval must be zero");
    check(legacy.tryAcquire(0), "first legacy frame");
    check(legacy.tryAcquire(0), "zero interval never drops equal timestamp");
    check(legacy.tryAcquire(1), "zero interval never drops later frame");
    check(legacy.skippedFrames() == 0, "no legacy skips");
    check(legacy.deliveredFrames() == 3, "legacy delivered count");

    CameraFrameGate visor = new CameraFrameGate();
    visor.setIntervalMs(333);
    check(visor.tryAcquire(100), "first throttled frame immediate");
    check(!visor.tryAcquire(333000099L), "frame before deadline dropped");
    check(visor.tryAcquire(333000100L), "exact deadline accepted");
    check(!visor.tryAcquire(400000000L), "do not drift deadline on drop");
    check(visor.tryAcquire(666000100L), "deadline counted from delivery");
    check(visor.deliveredFrames() == 3 && visor.skippedFrames() == 2, "accurate counters");

    CameraFrameGate mando = new CameraFrameGate();
    mando.setIntervalMs(140);
    check(mando.tryAcquire(0), "second owner first frame");
    check(!mando.tryAcquire(83333333), "second owner drop");
    check(mando.tryAcquire(166666666), "second owner two 12fps periods");
    check(visor.intervalMs() == 333, "second owner must not alter visor");
    check(visor.deliveredFrames() == 3, "second owner independent counters");

    visor.restart();
    check(visor.tryAcquire(666000101L), "stream restart first frame immediate");
    check(visor.intervalMs() == 333, "restart keeps configured budget");
    visor.setIntervalMs(200);
    check(visor.tryAcquire(666000102L), "changed budget first frame immediate");
    check(!visor.tryAcquire(666000103L), "changed budget applied");
    visor.setIntervalMs(0);
    check(visor.tryAcquire(666000104L), "explicit zero disables budget");
    check(visor.tryAcquire(666000105L), "disabled budget delivers each frame");
    expectInvalid(visor, -1);
    expectInvalid(visor, 10001);

    mando.reset();
    check(mando.intervalMs() == 0, "dispose resets budget");
    check(mando.deliveredFrames() == 0 && mando.skippedFrames() == 0, "dispose resets counters");
    check(mando.tryAcquire(1), "reused owner starts clean");
    check(visor.deliveredFrames() > 0, "disposing one owner preserves another");
    check(mando.tryAcquire(0), "clock rollback cannot lock out stream");
    System.out.println("CameraFrameGate: " + checks + " checks passed");
  }
}
