# Release-build (R8) rules for the on-device model (ADR 009).
# Flutter's Gradle plugin adds this file to release builds automatically; it is
# also listed explicitly in build.gradle.kts.

# tflite_flutter 0.12.1 declares com.google.ai.edge.litert:litert-gpu, whose
# classes reference org.tensorflow.lite.gpu.GpuDelegateFactory$Options, which the
# published AAR does not ship -> R8 stops with "Missing class". The GPU delegate
# is not used in this app (CPU measurements only).
-dontwarn org.tensorflow.lite.gpu.**

# LiteRT's native library calls back into its Java classes via JNI, and the
# measurement round uses the Java API directly (LiteRtJavaBench.kt). Keep them
# intact rather than risk R8 renaming something the runtime looks up by name.
-keep class org.tensorflow.lite.** { *; }
