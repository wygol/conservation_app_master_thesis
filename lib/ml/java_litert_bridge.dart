/// Dart side of the LiteRT Java-API reference configuration
/// (android/.../LiteRtJavaBench.kt, ADR 009).
library;

import 'package:flutter/services.dart';

class JavaLiteRtBench {
  static const _channel = MethodChannel('conservation_app/litert_java_bench');

  /// Builds a Java-API interpreter on the bench thread. Returns, among other
  /// things, `tid` — the kernel id of that thread, for CPU pinning.
  Future<Map<String, Object?>> create(Uint8List model,
      {int threads = 1, bool useXnnpack = false}) async {
    final result = await _channel.invokeMapMethod<String, Object?>('create', {
      'model': model,
      'threads': threads,
      'useXnnpack': useXnnpack,
    });
    return result ?? const {};
  }

  /// [warmup] untimed + [runs] timed native Invoke() calls on [input].
  /// Returns `nativeNanos` (per run), `cpus` (core after each run),
  /// `logits` (of the last run) and `tid`.
  Future<Map<String, Object?>> run(Uint8List input,
      {int warmup = 20, int runs = 100}) async {
    final result = await _channel.invokeMapMethod<String, Object?>('run', {
      'input': input,
      'warmup': warmup,
      'runs': runs,
    });
    return result ?? const {};
  }

  Future<void> close() => _channel.invokeMethod<void>('close');
}
