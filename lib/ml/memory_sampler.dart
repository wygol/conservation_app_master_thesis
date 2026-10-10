/// Samples the process' memory from a separate isolate while the main isolate
/// classifies, so the sampling never waits for (or delays) the work it watches.
library;

import 'dart:async';
import 'dart:isolate';

import 'native_probe.dart';

class MemorySampler {
  MemorySampler._(this._control, this._summary, this._port);

  final SendPort _control;
  final Future<Map<String, Object?>> _summary;
  final ReceivePort _port;

  /// Starts sampling `/proc/self/smaps_rollup` (Pss, Rss) and
  /// `/proc/self/status` (VmRSS) every [intervalMs].
  static Future<MemorySampler> start({int intervalMs = 100}) async {
    final port = ReceivePort();
    final control = Completer<SendPort>();
    final summary = Completer<Map<String, Object?>>();
    port.listen((message) {
      if (message is SendPort && !control.isCompleted) {
        control.complete(message);
      } else if (message is Map && !summary.isCompleted) {
        summary.complete(Map<String, Object?>.from(message));
      }
    });
    await Isolate.spawn(_samplerMain, <Object>[port.sendPort, intervalMs]);
    return MemorySampler._(await control.future, summary.future, port);
  }

  /// Stops sampling and returns peaks plus the sampled series.
  Future<Map<String, Object?>> stop() async {
    _control.send('stop');
    try {
      return await _summary.timeout(const Duration(seconds: 10));
    } finally {
      _port.close();
    }
  }
}

void _samplerMain(List<Object> args) {
  final out = args[0] as SendPort;
  final intervalMs = args[1] as int;
  final control = ReceivePort();
  out.send(control.sendPort);

  final watch = Stopwatch()..start();
  final series = <List<int>>[]; // [t_ms, pss_kb, rss_kb, vm_rss_kb]
  var maxPss = -1, maxRss = -1, maxVmRss = -1;

  void sample() {
    final smaps = ProcMemory.smapsRollupKb();
    final status = ProcMemory.statusKb();
    final pss = smaps['Pss'] ?? -1;
    final rss = smaps['Rss'] ?? -1;
    final vmRss = status['VmRSS'] ?? -1;
    if (pss > maxPss) maxPss = pss;
    if (rss > maxRss) maxRss = rss;
    if (vmRss > maxVmRss) maxVmRss = vmRss;
    series.add([watch.elapsedMilliseconds, pss, rss, vmRss]);
  }

  sample();
  final timer = Timer.periodic(Duration(milliseconds: intervalMs), (_) => sample());
  control.listen((message) {
    if (message != 'stop') return;
    timer.cancel();
    sample();
    out.send(<String, Object?>{
      'method': 'in-app sampler isolate reading /proc/self/smaps_rollup and '
          '/proc/self/status every $intervalMs ms',
      'samples': series.length,
      'duration_ms': watch.elapsedMilliseconds,
      'max_pss_kb': maxPss,
      'max_rss_kb': maxRss,
      'max_vm_rss_kb': maxVmRss,
      'series_t_ms_pss_rss_vmrss_kb': series,
    });
    control.close();
  });
}
