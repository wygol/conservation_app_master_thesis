/// Small numeric helpers shared by the identification service and the
/// measurement protocol.
library;

import 'dart:math' as math;

/// Numerically stable softmax in double precision.
///
/// [temperature] is 1.0 for now: the calibration temperature is fitted by the
/// thesis on the quantised model and supplied later (decision D-018). Until
/// then every probability shown by the app is UNCALIBRATED and must be
/// labelled as such. No threshold is applied anywhere in the app.
List<double> softmax(List<double> logits, {double temperature = 1.0}) {
  var maxLogit = double.negativeInfinity;
  for (final v in logits) {
    if (v > maxLogit) maxLogit = v;
  }
  final exps = List<double>.filled(logits.length, 0.0);
  var sum = 0.0;
  for (var i = 0; i < logits.length; i++) {
    final e = math.exp((logits[i] - maxLogit) / temperature);
    exps[i] = e;
    sum += e;
  }
  return [for (final e in exps) e / sum];
}

/// Indices of the [k] largest values, largest first (ties: lower index first).
List<int> topKIndices(List<double> values, int k) {
  final order = List<int>.generate(values.length, (i) => i)
    ..sort((a, b) {
      final c = values[b].compareTo(values[a]);
      return c != 0 ? c : a.compareTo(b);
    });
  return order.sublist(0, math.min(k, order.length));
}

/// Summary statistics of a latency series, with the estimators named so the
/// thesis can state exactly what was computed.
Map<String, Object?> latencyStats(List<int> micros) {
  if (micros.isEmpty) return {'n': 0};
  final s = [...micros]..sort();
  final n = s.length;
  final median =
      n.isOdd ? s[n ~/ 2].toDouble() : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
  // Nearest rank, computed in integers: ceil(0.9 * n) = (9n + 9) ~/ 10.
  // (0.9 * 100 in floating point is 90.00000000000001, whose ceil is 91.)
  final p90 = s[(9 * n + 9) ~/ 10 - 1];
  final mean = s.fold<int>(0, (a, b) => a + b) / n;
  var squares = 0.0;
  for (final x in s) {
    squares += (x - mean) * (x - mean);
  }
  return {
    'n': n,
    'median_us': median,
    'p90_us': p90,
    'mean_us': mean,
    'sd_us': n > 1 ? math.sqrt(squares / (n - 1)) : 0.0,
    'min_us': s.first,
    'max_us': s.last,
    'median_method': 'mean of the two middle values for even n '
        '(as Python statistics.median)',
    'p90_method': 'nearest rank: the value at rank ceil(0.9 n) of the sorted runs',
  };
}
