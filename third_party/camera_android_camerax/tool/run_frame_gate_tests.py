#!/usr/bin/env python3
"""Run the Android-independent frame budget tests with a local JDK."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
configured = os.environ.get("VRLIZATE_JAVA_HOME") or os.environ.get("JAVA_HOME")
candidates = [Path(configured) / "bin" if configured else None,
              Path("/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin")]
binary = next((p for p in candidates if p and (p / "javac").is_file()), None)
javac = str(binary / "javac") if binary else shutil.which("javac")
java = str(binary / "java") if binary else shutil.which("java")
if not javac or not java:
    raise SystemExit("JDK required; set VRLIZATE_JAVA_HOME to a local JDK")
with tempfile.TemporaryDirectory(prefix="vrlizate-camera-gate-") as output:
    subprocess.run([javac, "-d", output,
                    str(root / "android/src/main/java/io/flutter/plugins/camerax/CameraFrameGate.java"),
                    str(root / "tool/CameraFrameGateJvmTest.java")], check=True)
    subprocess.run([java, "-cp", output,
                    "io.flutter.plugins.camerax.CameraFrameGateJvmTest"], check=True)
