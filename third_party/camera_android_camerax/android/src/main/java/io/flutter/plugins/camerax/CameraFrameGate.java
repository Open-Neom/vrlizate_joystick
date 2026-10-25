// Copyright 2026 Open Neom contributors.
// SPDX-License-Identifier: BSD-3-Clause
package io.flutter.plugins.camerax;

/** Per-ImageAnalysis monotonic budget; independent of preview/capture FPS. */
final class CameraFrameGate {
  private long intervalNs;
  private long lastDeliveredNs;
  private boolean hasDelivered;
  private long delivered;
  private long skipped;

  synchronized void setIntervalMs(long milliseconds) {
    if (milliseconds < 0 || milliseconds > 10000) {
      throw new IllegalArgumentException("interval_ms_out_of_range");
    }
    intervalNs = milliseconds * 1000000L;
    hasDelivered = false; // First frame after a budget change is immediate.
  }

  synchronized boolean tryAcquire(long nowNs) {
    if (hasDelivered && nowNs >= lastDeliveredNs
        && nowNs - lastDeliveredNs < intervalNs) {
      skipped++;
      return false;
    }
    hasDelivered = true;
    lastDeliveredNs = nowNs;
    delivered++;
    return true;
  }

  synchronized void restart() { hasDelivered = false; }
  synchronized long intervalMs() { return intervalNs / 1000000L; }
  synchronized long deliveredFrames() { return delivered; }
  synchronized long skippedFrames() { return skipped; }

  synchronized void reset() {
    intervalNs = 0;
    lastDeliveredNs = 0;
    hasDelivered = false;
    delivered = 0;
    skipped = 0;
  }
}
