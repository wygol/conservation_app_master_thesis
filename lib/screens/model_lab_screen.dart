import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;

import '../ml/measurement_protocol.dart';
import '../ml/offline_model.dart';
import '../services/identification_service.dart';
import '../services/offline_model_identification_service.dart';

/// The app's first window onto the offline model — for now a model lab for the
/// measurement round (ADR 009); later this tab becomes the capture flow.
///
/// Works without a login and without a network: the model is bundled
/// (sovereignty tier 3). With `autorun` (set via
/// `--dart-define=MODEL_LAB_AUTORUN=true` by tools/measure_model.ps1) the full
/// protocol starts by itself in a fresh process, before anything else loads
/// the model — which the XNNPACK attribution depends on.
class ModelLabScreen extends StatefulWidget {
  const ModelLabScreen({super.key, this.autorun = false});

  final bool autorun;

  @override
  State<ModelLabScreen> createState() => _ModelLabScreenState();
}

class _ModelLabScreenState extends State<ModelLabScreen> {
  OfflineModel? _model;
  String? _loadError;
  bool _busy = false;
  String _status = '';
  Map<String, Object?>? _correctness;
  Map<String, Object?>? _report;
  IdentificationResult? _identification;

  @override
  void initState() {
    super.initState();
    if (widget.autorun) {
      // Do NOT load the model here: the protocol must create it itself,
      // between its own markers, as the first interpreter of the process.
      WidgetsBinding.instance.addPostFrameCallback((_) => _runFull());
    } else {
      _loadModel();
    }
  }

  Future<void> _loadModel() async {
    try {
      final model = await OfflineModel.shared();
      if (mounted) setState(() => _model = model);
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  Future<void> _guarded(String label, Future<void> Function() action) async {
    if (_busy) return;
    if (MeasurementProtocol.isRunning) {
      // A run started from another (since disposed) instance of this screen.
      setState(() => _status = 'A measurement is still running in the background.');
      return;
    }
    setState(() {
      _busy = true;
      _status = label;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed: $e');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) setState(() => _status = '$label — done');
  }

  Future<void> _runCorrectness() => _guarded('Correctness check', () async {
        final result = await MeasurementProtocol().runCorrectnessOnly();
        if (mounted) setState(() => _correctness = result);
      });

  Future<void> _runFull() => _guarded('Full measurement', () async {
        final protocol = MeasurementProtocol(
          onProgress: (m) {
            if (mounted) setState(() => _status = m);
          },
        );
        final report = await protocol.run();
        final model = await OfflineModel.shared();
        if (mounted) {
          setState(() {
            _report = report;
            _correctness = report['correctness'] as Map<String, Object?>?;
            _model = model;
          });
        }
      });

  Future<void> _identifyReference() => _guarded('Identification', () async {
        final data = await rootBundle.load('assets/model_check/ref_01.jpg');
        final bytes =
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        final result = await const OfflineModelIdentificationService()
            .identify([IdentificationInput(bytes: Uint8List.fromList(bytes))]);
        if (mounted) setState(() => _identification = result);
      });

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('On-device model')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_status, style: text.bodyMedium),
            ),
          _modelCard(text),
          _correctnessCard(text),
          _measurementCard(text),
          _identificationCard(text),
        ],
      ),
    );
  }

  Widget _section(TextTheme text, String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: text.titleMedium),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  Widget _modelCard(TextTheme text) {
    final m = _model;
    if (m == null) {
      return _section(text, 'Model', [
        Text(_loadError ?? (widget.autorun ? 'Loaded by the measurement run…' : 'Loading…')),
      ]);
    }
    String version;
    try {
      version = tfl.version;
    } catch (_) {
      version = 'unavailable';
    }
    return _section(text, 'Model', [
      Text(OfflineModelAssets.name),
      Text('${(m.modelBytes.length / 1e6).toStringAsFixed(2)} MB · '
          '${m.labels.length} classes · input ${m.classifier.inputShape} → '
          'output ${m.classifier.outputShape}'),
      Text('SHA-256 ${m.modelSha256.substring(0, 16)}…  '
          '${m.modelHashMatches ? '✓ the thesis file' : '✗ NOT the thesis file'}'),
      Text('labels.csv ${m.labelsHashMatches ? '✓' : '✗'} · LiteRT runtime $version'),
      const Text('Interpreter: 1 thread, no explicit delegate, kept alive.'),
    ]);
  }

  Widget _correctnessCard(TextTheme text) {
    final cases = (_correctness?['cases'] as List?)?.cast<Map<String, Object?>>();
    return _section(text, 'Correctness check (vs. phone_reference.json)', [
      const Text('Means ±0.01 · top-1 identical · ≥4 of top-5 · logits ±0.1'),
      const SizedBox(height: 8),
      if (cases != null) ...[
        for (final c in cases) _caseRow(c),
        const SizedBox(height: 6),
        Text(
          _correctness?['all_pass'] == true ? 'ALL PASS' : 'NOT ALL PASS',
          style: text.titleSmall,
        ),
      ],
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.tonal(
          onPressed: _busy ? null : _runCorrectness,
          child: const Text('Run check'),
        ),
      ),
    ]);
  }

  Widget _caseRow(Map<String, Object?> c) {
    final stages = c['stages'] as Map<String, Object?>?;
    String flag(String key) => stages == null
        ? ''
        : (stages[key] == true ? '✓' : (stages[key] == false ? '✗' : '?'));
    final top5 = (c['top5_app'] as List?)?.cast<Map<String, Object?>>();
    final best = top5 == null || top5.isEmpty ? '' : '${top5.first['label']}';
    final verdict = c['pass'] == true ? 'PASS' : 'FAIL';
    final decode = flag('decoded_identical_to_pillow');
    final resize = flag('resized_identical_to_pillow');
    final crop = flag('cropped_identical_to_pillow');
    final stageText =
        stages == null ? '' : ' · decode $decode resize $resize crop $crop';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        '$verdict  ${c['image']}\n'
        '  Δmean ${c['max_abs_mean_diff']} · top-5 ${c['top5_overlap']}/5 · '
        'Δlogit ${c['max_abs_logit_diff']}$stageText\n'
        '  → $best',
      ),
    );
  }

  Widget _measurementCard(TextTheme text) {
    final lines = <String>[];
    final r = _report;
    if (r != null) {
      if (r['error'] != null) lines.add('RUN ENDED WITH AN ERROR: ${r['error']}');
      final latency = r['o3c_latency'] as Map<String, Object?>?;
      for (final cfg in ((latency?['configs'] as List?) ?? const []).cast<Map<String, Object?>>()) {
        final s = cfg['stats'] as Map<String, Object?>?;
        lines.add('${cfg['id']}: median ${_ms(s?['median_us'])}, p90 ${_ms(s?['p90_us'])}'
            '${cfg['all_runs_on_pinned_cpu'] == true ? '' : '  (not all runs on the pinned core!)'}');
      }
      final verdict = (latency?['xnnpack_attribution_in_app'] as Map?)?['verdict'];
      if (verdict != null) lines.add('Attribution (latency only): $verdict');
      final mem = r['o3b_memory'] as Map<String, Object?>?;
      final sampler = mem?['in_app_sampler'] as Map<String, Object?>?;
      lines.add('O3b: VmHWM ${_mb(mem?['vm_hwm_kb_after_loop'])}, '
          'max sampled PSS ${_mb(sampler?['max_pss_kb'])} (in-app)');
      final big = r['large_image'] as Map<String, Object?>?;
      final bigSampler = big?['in_app_sampler'] as Map<String, Object?>?;
      lines.add('12 MP image: max sampled PSS ${_mb(bigSampler?['max_pss_kb'])}, '
          'VmHWM ${_mb(big?['vm_hwm_kb_after'])}');
    }
    return _section(text, 'Measurement round (O3b, O3c)', [
      const Text('For the thesis numbers run tools/measure_model.ps1 — it adds '
          'dumpsys meminfo, the APK size (O3a) and the logcat-based delegate check.'),
      const SizedBox(height: 8),
      for (final l in lines) Text(l),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: _busy ? null : _runFull,
          child: const Text('Run full measurement'),
        ),
      ),
    ]);
  }

  Widget _identificationCard(TextTheme text) {
    final result = _identification;
    return _section(text, 'Identification service (offline)', [
      const Text('Scores are an UNCALIBRATED softmax (T = 1). No threshold, no '
          'decision — the thesis supplies both later.'),
      if (result != null)
        for (final c in result.candidates)
          Text('${(c.score * 100).toStringAsFixed(1)} %  ${c.scientificName}  (${c.rank})'),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton.tonal(
          onPressed: _busy ? null : _identifyReference,
          child: const Text('Identify ref_01.jpg'),
        ),
      ),
    ]);
  }

  static String _ms(Object? micros) =>
      micros is num ? '${(micros / 1000).toStringAsFixed(1)} ms' : '–';

  static String _mb(Object? kb) =>
      kb is num ? '${(kb / 1024).toStringAsFixed(1)} MiB' : '–';
}
