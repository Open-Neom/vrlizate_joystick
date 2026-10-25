// Copyright 2026 Open Neom contributors.
// SPDX-License-Identifier: BSD-3-Clause
package io.flutter.plugins.camerax;

import androidx.annotation.Nullable;
import androidx.camera.core.ImageAnalysis;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.util.HashMap;
import java.util.Map;
import java.util.WeakHashMap;

/** Engine-scoped owner registry. Every analysis has its own disabled-by-default gate. */
final class CameraAnalysisBudget implements MethodChannel.MethodCallHandler {
  private final ProxyApiRegistrar registrar;
  private final MethodChannel channel;
  private final Map<Long, ImageAnalysis> owners = new HashMap<>();
  private final Map<ImageAnalysis, CameraFrameGate> gates = new WeakHashMap<>();

  CameraAnalysisBudget(BinaryMessenger messenger, ProxyApiRegistrar registrar) {
    this.registrar = registrar;
    channel = new MethodChannel(messenger, "vrlizate/camera_analysis_budget");
    channel.setMethodCallHandler(this);
  }

  @Nullable CameraFrameGate gateFor(ImageAnalysis analysis) { return gates.get(analysis); }

  private long integer(Map<?, ?> args, String key) {
    Object value = args.get(key);
    if (!(value instanceof Integer) && !(value instanceof Long)) {
      throw new IllegalArgumentException("invalid_" + key);
    }
    return ((Number) value).longValue();
  }

  @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    if (!(call.arguments instanceof Map)) {
      result.error("invalid_arguments", "Expected a map", null);
      return;
    }
    Map<?, ?> args = (Map<?, ?>) call.arguments;
    try {
      long cameraId = integer(args, "cameraId");
      if (cameraId < 0) throw new IllegalArgumentException("invalid_cameraId");
      if (call.method.equals("bindOwner")) {
        long identifier = integer(args, "imageAnalysisId");
        Object instance = registrar.getInstanceManager().getInstance(identifier);
        if (!(instance instanceof ImageAnalysis)) {
          throw new IllegalArgumentException("unknown_image_analysis");
        }
        ImageAnalysis analysis = (ImageAnalysis) instance;
        for (Map.Entry<Long, ImageAnalysis> owner : owners.entrySet()) {
          if (owner.getKey() != cameraId && owner.getValue() == analysis) {
            throw new IllegalArgumentException("analysis_already_owned");
          }
        }
        ImageAnalysis previous = owners.put(cameraId, analysis);
        if (previous != null && previous != analysis) removeGate(previous);
        if (!gates.containsKey(analysis)) gates.put(analysis, new CameraFrameGate());
        result.success(null);
      } else if (call.method.equals("unbindOwner")) {
        ImageAnalysis analysis = owners.remove(cameraId);
        if (analysis != null) removeGate(analysis);
        result.success(null);
      } else if (call.method.equals("setIntervalMs")) {
        CameraFrameGate gate = requireGate(cameraId);
        gate.setIntervalMs(integer(args, "intervalMs"));
        result.success(status(cameraId, "configured"));
      } else if (call.method.equals("getStatus")) {
        result.success(status(cameraId, "available"));
      } else {
        result.notImplemented();
      }
    } catch (IllegalArgumentException exception) {
      result.error("invalid_analysis_budget", exception.getMessage(), null);
    }
  }

  private CameraFrameGate requireGate(long cameraId) {
    CameraFrameGate gate = gates.get(owners.get(cameraId));
    if (gate == null) throw new IllegalArgumentException("unknown_camera_owner");
    return gate;
  }

  private Map<String, Object> status(long cameraId, String state) {
    CameraFrameGate gate = requireGate(cameraId);
    Map<String, Object> value = new HashMap<>();
    value.put("status", state);
    value.put("supported", true);
    value.put("configured", state.equals("configured"));
    value.put("cameraId", cameraId);
    value.put("intervalMs", gate.intervalMs());
    value.put("deliveredFrames", gate.deliveredFrames());
    value.put("skippedFrames", gate.skippedFrames());
    value.put("gateBeforePigeon", true);
    return value;
  }

  private void removeGate(ImageAnalysis analysis) {
    CameraFrameGate gate = gates.remove(analysis);
    if (gate != null) gate.reset();
  }

  void close() {
    channel.setMethodCallHandler(null);
    for (CameraFrameGate gate : gates.values()) gate.reset();
    gates.clear();
    owners.clear();
  }
}
