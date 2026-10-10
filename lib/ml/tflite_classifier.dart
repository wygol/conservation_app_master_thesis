/// A thin, domain-agnostic wrapper around one LiteRT interpreter (via
/// tflite_flutter). Knows tensors, not plants.
library;

import 'dart:typed_data';

import 'package:tflite_flutter/tflite_flutter.dart';

/// How the CPU work of an interpreter is executed. Recorded verbatim in every
/// measurement, because it changes latency by a large factor.
enum CpuExecution {
  /// No delegate added by the app. tflite_flutter 0.12.1 has no option to
  /// REMOVE a delegate the runtime might apply by default, so whether this is
  /// truly "no delegate" (Howard et al.'s condition) is verified empirically:
  /// LiteRT logs "Created TensorFlow Lite XNNPACK delegate for CPU." once per
  /// process when XNNPACK is instantiated, and the latency is compared with the
  /// LiteRT Java API run with XNNPACK explicitly disabled.
  noExplicitDelegate,

  /// XNNPACK delegate added explicitly with LiteRT's DEFAULT options: the
  /// delegate is created without an options struct (nullptr), so LiteRT uses
  /// TfLiteXNNPackDelegateOptionsDefault() — no thread pool, i.e. it runs
  /// single-threaded on the calling thread. Deliberately not via
  /// tflite_flutter's XNNPackDelegateOptions: that binding struct predates
  /// LiteRT 1.4.0's larger TfLiteXNNPackDelegateOptions, so passing it would
  /// let the runtime read past the allocation (pre-flight review, ADR 009).
  xnnpack,
}

class TfliteClassifier {
  TfliteClassifier._(
    this._interpreter,
    this._options,
    this._xnnpack, {
    required this.execution,
    required this.threads,
    required this.inputShape,
    required this.outputShape,
    required this.createMicros,
  });

  final Interpreter _interpreter;
  final InterpreterOptions _options;
  final XNNPackDelegate? _xnnpack;
  bool _closed = false;

  final CpuExecution execution;
  final int threads;
  final List<int> inputShape;
  final List<int> outputShape;

  /// Wall time of interpreter creation incl. tensor allocation (and delegate
  /// graph rewriting, if any).
  final int createMicros;

  /// How many interpreters with an explicit XNNPACK delegate this process has
  /// created. LiteRT logs its "Created ... XNNPACK delegate" line only once
  /// per process, so attributing that line to the no-delegate interpreter is
  /// only valid while this is still 0.
  static int xnnpackInterpretersCreated = 0;

  /// Builds an interpreter from model bytes. tflite_flutter copies the bytes
  /// into native memory; the caller may drop its own copy afterwards.
  static TfliteClassifier create(
    Uint8List modelBytes, {
    required CpuExecution execution,
    int threads = 1,
  }) {
    final watch = Stopwatch()..start();
    final options = InterpreterOptions()..threads = threads;
    XNNPackDelegate? xnnpack;
    Interpreter? interpreter;
    try {
      if (execution == CpuExecution.xnnpack) {
        xnnpack = XNNPackDelegate(); // nullptr options -> LiteRT defaults
        options.addDelegate(xnnpack);
      }
      interpreter = Interpreter.fromBuffer(modelBytes, options: options);
      watch.stop();

      final input = interpreter.getInputTensor(0);
      final output = interpreter.getOutputTensor(0);
      if (input.type != TensorType.float32 ||
          output.type != TensorType.float32) {
        throw StateError('Expected float32 input/output, got '
            '${input.type}/${output.type} — wrong model file?');
      }
      if (xnnpack != null) xnnpackInterpretersCreated++;
      return TfliteClassifier._(
        interpreter,
        options,
        xnnpack,
        execution: execution,
        threads: threads,
        inputShape: input.shape,
        outputShape: output.shape,
        createMicros: watch.elapsedMicroseconds,
      );
    } catch (_) {
      interpreter?.close();
      xnnpack?.delete(); // only after the interpreter is gone
      options.delete();
      rethrow;
    }
  }

  int get outputLength => outputShape.fold(1, (a, b) => a * b);

  /// Copies [input] into the input tensor (size is checked by the runtime).
  void setInput(Float32List input) {
    _interpreter.getInputTensor(0).data =
        input.buffer.asUint8List(input.offsetInBytes, input.lengthInBytes);
  }

  /// Runs the model on the current input tensor and returns the elapsed time
  /// of `invoke()` alone in microseconds — the "model call" of objective O3c,
  /// excluding decode, resize and tensor copies. Monotonic clock (Stopwatch);
  /// tflite_flutter's own lastNativeInferenceDurationMicroSeconds uses the wall
  /// clock and is therefore not used.
  int invokeTimed() {
    final watch = Stopwatch()..start();
    _interpreter.invoke();
    watch.stop();
    return watch.elapsedMicroseconds;
  }

  /// Copies the output tensor out as float32 logits.
  Float32List readOutput() {
    final bytes = _interpreter.getOutputTensor(0).data;
    final view = ByteData.sublistView(bytes);
    final n = bytes.lengthInBytes ~/ 4;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = view.getFloat32(i * 4, Endian.host);
    }
    return out;
  }

  /// Full call: input in, logits out.
  Float32List run(Float32List input) {
    setInput(input);
    _interpreter.invoke();
    return readOutput();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _interpreter.close();
    _xnnpack?.delete(); // the delegate must outlive the interpreter
    _options.delete();
  }
}
