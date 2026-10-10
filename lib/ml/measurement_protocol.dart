/// The on-device measurement round of the thesis' offline model
/// (ml-pipeline/arm2_export/README_for_app_agent.md; objectives O3a–O3c).
///
/// Order, and why:
///   1. setup + C1 interpreter FIRST in the process (LiteRT logs its XNNPACK
///      line once per process, so only the first interpreter can be judged
///      from logcat);
///   2. correctness check against the thesis' phone_reference.json, with
///      stage diagnostics (decode / resize / crop) against Pillow;
///   3. O3b: peak memory while classifying (full pipeline, 5 photos x N);
///   4. O3c: latency of invoke() only, per configuration, pinned to one core,
///      1 thread, batch 1, warm-up then timed runs — nothing else runs then;
///   5. large-image memory reading (synthetic 12 MP JPEG), last, so its spike
///      cannot contaminate anything before it;
///   6. the report goes to logcat in checksummed chunks for
///      tools/measure_model.ps1, which adds dumpsys meminfo, APK sizes,
///      device facts and the logcat-based XNNPACK attribution.
///
/// Nothing here estimates a number. What could not be measured is recorded
/// as missing, and the report carries how every value was taken.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;

import 'inference_math.dart';
import 'java_litert_bridge.dart';
import 'memory_sampler.dart';
import 'native_probe.dart';
import 'offline_model.dart';
import 'preprocess.dart';
import 'tflite_classifier.dart';

/// Keep equal to the pin in pubspec.yaml.
const String kTfliteFlutterVersion = '0.12.1';

/// Keep equal to the pins in android/app/build.gradle.kts, which raise the
/// plugin's bundled 1.4.0 (ADR 010). The report also carries the version the
/// runtime reports itself, as an independent check of what actually loaded.
const String kLiteRtArtifact = 'com.google.ai.edge.litert:litert:1.4.2';
const String kReportSchema = 'conservation_app.model_measurement/1';
const String kModelCheckDir = 'assets/model_check';
const String kLargeImage = 'synthetic_12mp.jpg';

/// One marker line for tools/measure_model.ps1, which reads logcat.
void labLog(String message) {
  // ignore: avoid_print
  print('MODEL_LAB|$message');
}

typedef ProgressCallback = void Function(String message);

class _PreparedCase {
  _PreparedCase(this.name, this.refCase, this.input, this.encoded);

  final String name;
  final Map<String, dynamic> refCase;
  final Float32List input;
  final Uint8List? encoded; // null for the grey image
}

class _CorrectnessResult {
  _CorrectnessResult(this.report, this.cases);

  final Map<String, Object?> report;
  final List<_PreparedCase> cases;
}

class MeasurementProtocol {
  MeasurementProtocol({
    this.onProgress,
    this.warmupRuns = 20,
    this.timedRuns = 100,
    this.memoryRounds = 20,
    this.largeImageRounds = 3,
    this.snapshotPauseMs = 2500,
    this.configPauseMs = 2000,
  });

  final ProgressCallback? onProgress;

  /// 20 + 100 satisfies both the Oct-2026 handover (>= 10 + >= 50) and the
  /// Sept-2026 spike protocol (20 + 100).
  final int warmupRuns;
  final int timedRuns;
  final int memoryRounds;
  final int largeImageRounds;

  /// Idle time after each snapshot marker, so the script can take its
  /// `dumpsys meminfo` reading while the app does nothing.
  final int snapshotPauseMs;

  /// Settling time between latency configurations.
  final int configPauseMs;

  final _clock = Stopwatch();
  final _snapshots = <Map<String, Object?>>[];

  void _progress(String message) {
    labLog('PROGRESS|$message');
    onProgress?.call(message);
  }

  // ---------------------------------------------------------------- public

  static bool _running = false;

  /// True while any protocol run is in progress in this process. Screens are
  /// disposed on tab switches, so this guard lives here, not in widget state.
  static bool get isRunning => _running;

  /// Only the correctness check (for the button on the model screen).
  Future<Map<String, Object?>> runCorrectnessOnly() async {
    if (_running) throw StateError('A measurement is already running');
    _running = true;
    try {
      _clock
        ..reset()
        ..start();
      final model = await OfflineModel.shared();
      final result = await _correctness(model, await _loadJson('phone_reference.json'),
          await _loadJson('stage_expectations.json'));
      return result.report;
    } finally {
      _running = false;
    }
  }

  /// The full protocol. Returns the report and also writes it to logcat —
  /// also when a phase fails: the report then carries `error` and everything
  /// measured up to that point, so the script never waits for nothing.
  Future<Map<String, Object?>> run() async {
    if (_running) throw StateError('A measurement is already running');
    _running = true;
    final report = <String, Object?>{};
    try {
      await _runPhases(report);
    } catch (e, stack) {
      report['error'] = e.toString();
      report['error_stack'] = stack.toString().split('\n').take(20).join('\n');
      labLog('ERROR|${e.toString().replaceAll('\n', ' ')}');
    } finally {
      report['memory_snapshots_in_app'] = List<Map<String, Object?>>.of(_snapshots);
      report['finished_utc'] = DateTime.now().toUtc().toIso8601String();
      report['elapsed_ms'] = _clock.elapsedMilliseconds;
      labLog('DONE');
      try {
        await emitReport(report);
      } finally {
        _running = false;
      }
    }
    return report;
  }

  Future<void> _runPhases(Map<String, Object?> report) async {
    _clock
      ..reset()
      ..start();
    _snapshots.clear();
    report.addAll(<String, Object?>{
      'schema': kReportSchema,
      'started_utc': DateTime.now().toUtc().toIso8601String(),
      'build': {
        'mode': kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
        'model_lab_autorun': const bool.fromEnvironment('MODEL_LAB_AUTORUN'),
      },
      'protocol': {
        'warmup_runs': warmupRuns,
        'timed_runs': timedRuns,
        'memory_rounds': memoryRounds,
        'large_image_rounds': largeImageRounds,
        'threads': 1,
        'batch': 1,
      },
    });

    labLog('PHASE|SETUP|START');
    _progress('Reading CPU topology');
    final topology = CpuTopology.read();
    final cores = CpuTopology.pickLargeCores(topology);
    final wasLoaded = OfflineModel.isLoaded;
    final xnnpackBefore = TfliteClassifier.xnnpackInterpretersCreated;
    report['device_in_app'] = {
      'os': Platform.operatingSystemVersion,
      'number_of_processors': Platform.numberOfProcessors,
      'cpus': topology,
      'prime_cpu': cores.prime,
      'big_cpu': cores.big,
      'process_affinity_at_start': CpuAffinity.get(0),
    };
    labLog('PHASE|SETUP|END');

    _snapshots.add(await _snapshot('M0_idle_before_model_load'));

    _progress('Loading the model (C1: tflite_flutter, 1 thread, no explicit delegate)');
    labLog('IFACE_CREATE|C1|START');
    final model = await OfflineModel.shared();
    labLog('IFACE_CREATE|C1|END');
    report['model'] = _modelInfo(model);
    report['runtime'] = {
      'binding': 'tflite_flutter',
      'binding_version': kTfliteFlutterVersion,
      'android_runtime_artifact': kLiteRtArtifact,
      'runtime_version_reported_by_litert': _safeVersion(),
      'dart': Platform.version,
      'c1_created_in_this_run': !wasLoaded,
      'explicit_xnnpack_interpreters_before_c1':
          wasLoaded ? 'unknown (model was loaded earlier in this process)' : xnnpackBefore,
      'c1_create_ms': model.classifier.createMicros / 1000.0,
    };
    _snapshots.add(await _snapshot('M1_after_model_load'));

    _progress('Correctness check against phone_reference.json');
    final correctness = await _correctness(model, await _loadJson('phone_reference.json'),
        await _loadJson('stage_expectations.json'));
    report['correctness'] = correctness.report;
    _snapshots.add(await _snapshot('M2_after_correctness'));

    report['o3b_memory'] = await _memoryPhase(model, correctness.cases);
    report['o3c_latency'] = await _latencyPhase(model, correctness.cases, cores);
    report['large_image'] = await _largeImagePhase(model);
    report['notes'] = [
      'tflite_flutter builds each interpreter from a native copy of the model '
          'bytes (Model.fromBuffer). The LiteRT C API requires that buffer to '
          'outlive the interpreter, and Interpreter.close() releases only the '
          'interpreter — so the C2 interpreter leaves about the model size '
          '(4.4 MB) resident after close(). Absolute readings of the large-image '
          'phase include it; differences within that phase do not.',
    ];
  }

  // ----------------------------------------------------------- correctness

  Future<_CorrectnessResult> _correctness(OfflineModel model,
      Map<String, dynamic> reference, Map<String, dynamic> expectations) async {
    final expected = {
      for (final c in (expectations['cases'] as List).cast<Map<String, dynamic>>())
        c['image'] as String: c,
    };
    final cases = <_PreparedCase>[];
    final rows = <Map<String, Object?>>[];

    for (final refCase in (reference['cases'] as List).cast<Map<String, dynamic>>()) {
      final image = refCase['image'] as String;
      final file = refCase['file'] as Map<String, dynamic>?;
      if (file == null) {
        // The grey image: built directly as tensor values, no preprocessing.
        final input = greyInput();
        final logits = model.classifier.run(input);
        rows.add({
          'image': image,
          ..._evaluate(refCase, inputChannelMeans(input), logits, model),
        });
        cases.add(_PreparedCase(image, refCase, input, null));
        continue;
      }
      final bytes = await _loadBytes('$kModelCheckDir/$image');
      final decodeWatch = Stopwatch()..start();
      final decoded = await decodeImage(bytes);
      decodeWatch.stop();
      final prepWatch = Stopwatch()..start();
      final prepared = preprocessLikeReference(decoded);
      prepWatch.stop();
      final logits = model.classifier.run(prepared.input);
      rows.add({
        'image': image,
        'file_sha256_matches_reference':
            sha256.convert(bytes).toString() == file['sha256'],
        ..._evaluate(refCase, prepared.channelMeans, logits, model),
        'stages': _stageDiagnostics(decoded, prepared, expected[image]),
        'decode_ms': decodeWatch.elapsedMicroseconds / 1000.0,
        'preprocess_ms': prepWatch.elapsedMicroseconds / 1000.0,
      });
      cases.add(_PreparedCase(image, refCase, prepared.input, bytes));
    }

    return _CorrectnessResult({
      'configuration': 'C1 — tflite_flutter, 1 thread, no explicit delegate',
      'reference': 'assets/model_check/phone_reference.json (thesis, generated '
          '${reference['generated_utc']})',
      'criteria': {
        'channel_means_within_0_01': 'max |app - reference| over R, G, B <= 0.01',
        'top1_identical': 'index of the largest logit equal',
        'top5_overlap_at_least_4': '|top-5(app) ∩ top-5(reference)| >= 4',
        'logits_within_0_1': 'max |app - reference| over the reference top-5 indices <= 0.1',
      },
      'cases': rows,
      'all_pass': rows.every((r) => r['pass'] == true),
    }, cases);
  }

  Map<String, Object?> _evaluate(Map<String, dynamic> refCase, List<double> means,
      Float32List logits, OfflineModel model) {
    final refMeans = [
      for (final v in refCase['preprocessed_channel_means_rgb'] as List) (v as num).toDouble()
    ];
    final refTop = (refCase['top5'] as List).cast<Map<String, dynamic>>();
    final refIndices = [for (final t in refTop) t['index'] as int];

    var maxMeanDiff = 0.0;
    for (var c = 0; c < 3; c++) {
      maxMeanDiff = math.max(maxMeanDiff, (means[c] - refMeans[c]).abs());
    }
    final top5 = topKIndices(logits, 5);
    final overlap = top5.toSet().intersection(refIndices.toSet()).length;
    var maxLogitDiff = 0.0;
    final pairs = <Map<String, Object?>>[];
    for (final t in refTop) {
      final index = t['index'] as int;
      final refLogit = (t['logit'] as num).toDouble();
      final diff = (logits[index] - refLogit).abs();
      maxLogitDiff = math.max(maxLogitDiff, diff);
      pairs.add({
        'index': index,
        'reference': refLogit,
        'app': _round(logits[index], 4),
        'abs_diff': _round(diff, 5),
      });
    }
    final probabilities = softmax(logits);
    final criteria = <String, bool>{
      'channel_means_within_0_01': maxMeanDiff <= 0.01,
      'top1_identical': top5.first == refIndices.first,
      'top5_overlap_at_least_4': overlap >= 4,
      'logits_within_0_1': maxLogitDiff <= 0.1,
    };
    return {
      'channel_means_app': [for (final m in means) _round(m, 5)],
      'channel_means_reference': refMeans,
      'max_abs_mean_diff': _round(maxMeanDiff, 6),
      'top5_app': [
        for (final i in top5)
          {
            'index': i,
            'label': model.labels[i].label,
            'logit': _round(logits[i], 4),
            'softmax_uncalibrated': _round(probabilities[i], 5),
          }
      ],
      'top5_reference': refIndices,
      'top5_overlap': overlap,
      'logits_at_reference_top5': pairs,
      'max_abs_logit_diff': _round(maxLogitDiff, 5),
      'criteria': criteria,
      'pass': criteria.values.every((ok) => ok),
    };
  }

  Map<String, Object?> _stageDiagnostics(
      DecodedRgba decoded, PreprocessedImage p, Map<String, dynamic>? expected) {
    final decodedDigest = digestRgbaAsRgb(decoded.rgba, decoded.width, decoded.height);
    final resizedDigest = digestRgb(p.resizedRgb, p.targetWidth, p.targetHeight);
    final croppedDigest = digestRgb(p.croppedRgb, kModelInputSize, kModelInputSize);
    final result = <String, Object?>{
      'target_size': [p.targetWidth, p.targetHeight],
      'crop_offset_left_top': [p.cropLeft, p.cropTop],
      'decoded': decodedDigest.toJson(),
      'resized': resizedDigest.toJson(),
      'cropped': croppedDigest.toJson(),
    };
    if (expected == null) {
      result['comparison'] = 'no expectation available';
      return result;
    }
    final d = decodedDigest.matches(expected['decoded'] as Map<String, dynamic>);
    final r = resizedDigest.matches(expected['resized'] as Map<String, dynamic>);
    final c = croppedDigest.matches(expected['cropped'] as Map<String, dynamic>);
    result['decoded_identical_to_pillow'] = d;
    result['resized_identical_to_pillow'] = r;
    result['cropped_identical_to_pillow'] = c;
    result['interpretation'] = d && r && c
        ? 'bit-identical to the Pillow reference at every stage'
        : !d
            ? 'decoded pixels differ from Pillow (JPEG decoder difference); later '
                'stages cannot be bit-identical — the logit criterion shows whether it matters'
            : !r
                ? 'decoder identical but resize differs: defect in the resample port'
                : 'decode and resize identical but crop differs: defect in the crop';
    return result;
  }

  // -------------------------------------------------------------- O3b memory

  Future<Map<String, Object?>> _memoryPhase(
      OfflineModel model, List<_PreparedCase> cases) async {
    final photos = cases.where((c) => c.encoded != null).toList();
    _progress('O3b: $memoryRounds rounds x ${photos.length} photographs, full pipeline');
    final before = ProcMemory.statusKb();
    labLog('PHASE|O3B_CLASSIFY|START');
    final sampler = await MemorySampler.start(intervalMs: 100);
    final perImageUs = <int>[];
    for (var round = 0; round < memoryRounds; round++) {
      for (final photo in photos) {
        final watch = Stopwatch()..start();
        final logits = await model.classifyEncoded(photo.encoded!);
        softmax(logits);
        watch.stop();
        perImageUs.add(watch.elapsedMicroseconds);
      }
    }
    final sampled = await sampler.stop();
    labLog('PHASE|O3B_CLASSIFY|END');
    final after = ProcMemory.statusKb();
    await Future<void>.delayed(const Duration(milliseconds: 3000));
    return {
      'what': 'memory of the app process while classifying: decode -> reference '
          'preprocessing -> invoke (C1) -> softmax, repeated over the five reference photographs',
      'classifications': perImageUs.length,
      'vm_hwm_kb_after_loop': after['VmHWM'],
      'vm_hwm_meaning': 'peak resident set size since process start (includes app '
          'startup and model load), read right after the loop and before any later phase; '
          'an upper bound of the process peak',
      'status_kb_before': before,
      'status_kb_after': after,
      'in_app_sampler': sampled,
      'end_to_end_per_image': latencyStats(perImageUs),
    };
  }

  // ------------------------------------------------------------- O3c latency

  Future<Map<String, Object?>> _latencyPhase(OfflineModel model,
      List<_PreparedCase> cases, ({int? prime, int? big}) cores) async {
    final timing = cases.firstWhere((c) => c.encoded != null);
    final targets = <(String, int?)>[('prime', cores.prime), ('big', cores.big)];
    final configs = <Map<String, Object?>>[];
    final result = <String, Object?>{
      'timing_input': '${timing.name} after the app preprocessing (latency does not '
          'depend on image content for this network)',
      'configs': configs,
    };

    // C1 — the production interpreter: tflite_flutter, no explicit delegate.
    for (final (label, cpu) in targets) {
      if (cpu == null) continue;
      await _pause();
      _progress('O3c C1 (no explicit delegate) on the $label core, cpu$cpu');
      labLog('PHASE|O3C_C1_$label|START');
      final timed = _timeTflite(model.classifier, timing.input, cpu);
      labLog('PHASE|O3C_C1_$label|END');
      configs.add({
        'id': 'C1_$label',
        'binding': 'tflite_flutter $kTfliteFlutterVersion (dart:ffi -> LiteRT C API)',
        'delegate': 'none added by the app (runtime default; see xnnpack_attribution)',
        'threads': 1,
        'core': label,
        ...timed,
      });
    }

    // C2 — XNNPACK, explicitly. Its own try/catch: if it fails, C3 still runs.
    await _pause();
    _progress('Creating C2 (XNNPACK delegate, single-threaded)');
    TfliteClassifier? c2;
    try {
      labLog('IFACE_CREATE|C2|START');
      c2 = TfliteClassifier.create(model.modelBytes,
          execution: CpuExecution.xnnpack, threads: 1);
      labLog('IFACE_CREATE|C2|END');
      final xnn = c2;
      result['c2_correctness'] = [
        for (final c in cases)
          {
            'image': c.name,
            ..._evaluate(c.refCase, inputChannelMeans(c.input), xnn.run(c.input), model),
          }
      ];
      for (final (label, cpu) in targets) {
        if (cpu == null) continue;
        await _pause();
        _progress('O3c C2 (XNNPACK) on the $label core, cpu$cpu');
        labLog('PHASE|O3C_C2_$label|START');
        final timed = _timeTflite(xnn, timing.input, cpu);
        labLog('PHASE|O3C_C2_$label|END');
        configs.add({
          'id': 'C2_$label',
          'binding': 'tflite_flutter $kTfliteFlutterVersion (dart:ffi -> LiteRT C API)',
          'delegate': 'XNNPACK, added explicitly with LiteRT\'s default options '
              '(nullptr -> TfLiteXNNPackDelegateOptionsDefault: no thread pool, '
              'i.e. single-threaded on the calling thread)',
          'threads': 1,
          'core': label,
          'create_ms': xnn.createMicros / 1000.0,
          ...timed,
        });
      }
    } catch (e) {
      labLog('IFACE_CREATE|C2|FAILED');
      result['c2_error'] = e.toString();
    } finally {
      c2?.close();
    }

    // C3 — LiteRT Java API with XNNPACK explicitly disabled.
    await _pause();
    final bench = JavaLiteRtBench();
    try {
      _progress('Creating C3 (LiteRT Java API, XNNPACK off)');
      labLog('IFACE_CREATE|C3|START');
      final info = await bench.create(model.modelBytes, threads: 1, useXnnpack: false);
      labLog('IFACE_CREATE|C3|END');
      final tid = info['tid'] as int;
      result['c3_interpreter'] = {
        'runtime_version': info['runtimeVersion'],
        'create_ms': ((info['createNanos'] as int?) ?? -1) / 1e6,
        'input_shape': info['inputShape'],
        'output_shape': info['outputShape'],
      };
      final c3Rows = <Map<String, Object?>>[];
      for (final c in cases) {
        final res = await bench.run(_bytesOf(c.input), warmup: 0, runs: 1);
        c3Rows.add({
          'image': c.name,
          ..._evaluate(c.refCase, inputChannelMeans(c.input),
              Float32List.fromList((res['logits'] as List).cast<double>()), model),
        });
      }
      result['c3_correctness'] = c3Rows;
      for (final (label, cpu) in targets) {
        if (cpu == null) continue;
        await _pause();
        _progress('O3c C3 (Java API, XNNPACK off) on the $label core, cpu$cpu');
        final pinErrno = CpuAffinity.set(tid, [cpu]);
        labLog('PHASE|O3C_C3_$label|START');
        final res = await bench.run(_bytesOf(timing.input),
            warmup: warmupRuns, runs: timedRuns);
        labLog('PHASE|O3C_C3_$label|END');
        final nanos = (res['nativeNanos'] as List).cast<int>();
        final micros = [for (final n in nanos) (n / 1000).round()];
        final cpus = (res['cpus'] as List).cast<int>();
        configs.add({
          'id': 'C3_$label',
          'binding': 'LiteRT Java API ($kLiteRtArtifact) via MethodChannel',
          'delegate': 'none — Interpreter.Options.setUseXNNPACK(false)',
          'threads': 1,
          'core': label,
          'tid': tid,
          'pinned_cpu': cpu,
          'pin_errno': pinErrno,
          'timer': 'Interpreter.getLastNativeInferenceDurationNanoseconds() '
              '(LiteRT brackets the native Invoke() only)',
          'runs_us': micros,
          'runs_native_ns': nanos,
          'cpu_per_run': cpus,
          'all_runs_on_pinned_cpu': cpus.every((c) => c == cpu),
          'stats': latencyStats(micros),
        });
      }
    } catch (e) {
      result['c3_error'] = e.toString();
    } finally {
      try {
        await bench.close();
      } catch (_) {}
    }

    result['xnnpack_attribution_in_app'] = _attribution(configs);
    return result;
  }

  /// Times invoke() on the calling (root-isolate) thread, pinned to [cpu].
  /// Synchronous on purpose: no other Dart code can run in between, and the
  /// thread cannot change while the loop runs.
  Map<String, Object?> _timeTflite(TfliteClassifier clf, Float32List input, int cpu) {
    final tid = CpuAffinity.currentTid();
    final before = CpuAffinity.get(0);
    final pinErrno = CpuAffinity.set(0, [cpu]);
    final cpuAtStart = CpuAffinity.currentCpu();
    clf.setInput(input);
    for (var i = 0; i < warmupRuns; i++) {
      clf.invokeTimed();
    }
    final micros = List<int>.filled(timedRuns, 0);
    final cpus = List<int>.filled(timedRuns, -1);
    for (var i = 0; i < timedRuns; i++) {
      micros[i] = clf.invokeTimed();
      cpus[i] = CpuAffinity.currentCpu(); // outside the timed region
    }
    final restoreErrno = before.isEmpty ? -1 : CpuAffinity.set(0, before);
    return {
      'tid': tid,
      'pinned_cpu': cpu,
      'pin_errno': pinErrno,
      'cpu_at_start': cpuAtStart,
      'affinity_before': before,
      'restore_errno': restoreErrno,
      'timer': 'Dart Stopwatch (monotonic) around Interpreter.invoke() only',
      'runs_us': micros,
      'cpu_per_run': cpus,
      'all_runs_on_pinned_cpu': cpus.every((c) => c == cpu),
      'stats': latencyStats(micros),
    };
  }

  /// Corroboration from latency alone; the decisive evidence is the logcat
  /// line, which the script attributes.
  Map<String, Object?> _attribution(List<Map<String, Object?>> configs) {
    double? median(String id) {
      for (final c in configs) {
        if (c['id'] == id) {
          final stats = c['stats'] as Map<String, Object?>?;
          return (stats?['median_us'] as num?)?.toDouble();
        }
      }
      return null;
    }

    final c1 = median('C1_prime'), c2 = median('C2_prime'), c3 = median('C3_prime');
    String verdict = 'insufficient data';
    if (c1 != null && c2 != null && c3 != null) {
      final nearC3 = (c1 - c3).abs() / c3 <= 0.10;
      final nearC2 = (c1 - c2).abs() / c2 <= 0.10;
      if (nearC3 && !nearC2) {
        verdict = 'C1 behaves like the XNNPACK-off Java reference: no default delegate';
      } else if (nearC2 && !nearC3) {
        verdict = 'C1 behaves like explicit XNNPACK: the runtime applies XNNPACK by default';
      } else {
        verdict = 'ambiguous from latency alone (C2 and C3 too close, or C1 near neither)';
      }
    }
    return {
      'median_us_prime': {'C1': c1, 'C2': c2, 'C3': c3},
      'rule': 'C1 counts as matching a configuration when its median is within 10 % of it',
      'verdict': verdict,
    };
  }

  // ------------------------------------------------------------- large image

  Future<Map<String, Object?>> _largeImagePhase(OfflineModel model) async {
    final expectations = await _loadJson('stage_expectations.json');
    final expected = (expectations['cases'] as List)
        .cast<Map<String, dynamic>>()
        .where((c) => c['image'] == kLargeImage)
        .toList();
    final bytes = await _loadBytes('$kModelCheckDir/$kLargeImage');
    await _pause();
    _snapshots.add(await _snapshot('B0_before_large_image'));
    _progress('Large image: $largeImageRounds x decode + preprocess + invoke of a 12 MP JPEG');
    final before = ProcMemory.statusKb();
    labLog('PHASE|BIGIMG_CLASSIFY|START');
    final sampler = await MemorySampler.start(intervalMs: 100);
    final rounds = <Map<String, Object?>>[];
    Map<String, Object?>? stages;
    List<int>? top5;
    for (var r = 0; r < largeImageRounds; r++) {
      final decodeWatch = Stopwatch()..start();
      final decoded = await decodeImage(bytes);
      decodeWatch.stop();
      final prepWatch = Stopwatch()..start();
      final prepared = preprocessLikeReference(decoded);
      prepWatch.stop();
      final invokeWatch = Stopwatch()..start();
      final logits = model.classifier.run(prepared.input);
      invokeWatch.stop();
      top5 ??= topKIndices(logits, 5);
      if (r == 0 && expected.isNotEmpty) {
        stages = _stageDiagnostics(decoded, prepared, expected.first);
      }
      rounds.add({
        'decode_ms': decodeWatch.elapsedMicroseconds / 1000.0,
        'preprocess_ms': prepWatch.elapsedMicroseconds / 1000.0,
        'run_ms_incl_tensor_copies': invokeWatch.elapsedMicroseconds / 1000.0,
      });
    }
    final sampled = await sampler.stop();
    labLog('PHASE|BIGIMG_CLASSIFY|END');
    final after = ProcMemory.statusKb();
    await Future<void>.delayed(const Duration(milliseconds: 3000));
    _snapshots.add(await _snapshot('B1_after_large_image'));
    final expectedTop5 = expected.isEmpty
        ? null
        : [
            for (final t in ((expected.first['top5_by_resolver'] as Map)['auto'] as List))
              (t as Map)['index'] as int
          ];
    return {
      'what': 'memory and timing for a camera-sized photograph: synthetic 4000x3000 JPEG '
          '(${bytes.length} bytes; recipe in stage_expectations.json) — a memory stimulus, '
          'not an evaluation image',
      'rounds': rounds,
      'stages_vs_pillow': stages,
      'top5_app': top5,
      'top5_desktop_reference': expectedTop5,
      'status_kb_before': before,
      'status_kb_after': after,
      'vm_hwm_kb_after': after['VmHWM'],
      'in_app_sampler': sampled,
    };
  }

  // ---------------------------------------------------------------- helpers

  Future<Map<String, Object?>> _snapshot(String name) async {
    labLog('SNAPSHOT|$name');
    final snapshot = <String, Object?>{
      'name': name,
      't_ms': _clock.elapsedMilliseconds,
      'status_kb': ProcMemory.statusKb(),
      'smaps_rollup_kb': ProcMemory.smapsRollupKb(),
    };
    await Future<void>.delayed(Duration(milliseconds: snapshotPauseMs));
    return snapshot;
  }

  Future<void> _pause() => Future<void>.delayed(Duration(milliseconds: configPauseMs));

  Map<String, Object?> _modelInfo(OfflineModel model) => {
        'name': OfflineModelAssets.name,
        'asset': OfflineModelAssets.model,
        'bytes': model.modelBytes.length,
        'sha256_on_device': model.modelSha256,
        'sha256_expected': OfflineModelAssets.expectedModelSha256,
        'sha256_matches': model.modelHashMatches,
        'labels_asset': OfflineModelAssets.labels,
        'labels_rows': model.labels.length,
        'labels_sha256_matches': model.labelsHashMatches,
        'input_shape': model.classifier.inputShape,
        'output_shape': model.classifier.outputShape,
      };

  static String? _safeVersion() {
    try {
      return tfl.version;
    } catch (e) {
      return 'unavailable: $e';
    }
  }

  static Future<Map<String, dynamic>> _loadJson(String name) async =>
      jsonDecode(await rootBundle.loadString('$kModelCheckDir/$name'))
          as Map<String, dynamic>;

  static Future<Uint8List> _loadBytes(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static Uint8List _bytesOf(Float32List f) =>
      f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes);

  static double _round(double v, int digits) => double.parse(v.toStringAsFixed(digits));
}

/// Writes [report] to logcat as base64 chunks with a SHA-256 of the JSON, so
/// tools/measure_model.ps1 can reassemble it and prove it arrived complete.
Future<void> emitReport(Map<String, Object?> report) async {
  final bytes = utf8.encode(jsonEncode(report));
  final digest = sha256.convert(bytes).toString();
  final encoded = base64.encode(bytes);
  // Flutter's engine logs Dart `print` through __android_log_print, which
  // formats into liblog's 1024-byte buffer: every logcat message is cut at
  // 1023 bytes. 900 characters + the ~22-character prefix stay below that.
  const chunkSize = 900;
  final count = (encoded.length + chunkSize - 1) ~/ chunkSize;
  labLog('REPORT|BEGIN|$count|$digest|${bytes.length}');
  for (var i = 0; i < count; i++) {
    final end = math.min(encoded.length, (i + 1) * chunkSize);
    labLog('REPORT|${i + 1}|${encoded.substring(i * chunkSize, end)}');
    if (i % 4 == 3) await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  labLog('REPORT|END');
}
