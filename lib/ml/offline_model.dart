/// The bundled offline model, loaded once per process and kept alive.
///
/// Constraint of the handover: "load the model once and keep the interpreter
/// alive; do not reload per image". [OfflineModel.shared] returns the same
/// instance — and therefore the same interpreter — for the whole app lifetime.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'labels.dart';
import 'preprocess.dart';
import 'tflite_classifier.dart';

/// Asset locations and the identities the thesis published for them
/// (assets/model_check/phone_reference.json).
class OfflineModelAssets {
  OfflineModelAssets._();

  static const model = 'assets/model/large075_plain_int8_weight_only.tflite';
  static const labels = 'assets/model/labels.csv';
  static const expectedModelSha256 =
      'e0e182a8fbbc75fc632840bdc59bbf004d7179350f5d630691a28522748eb12d';
  static const expectedLabelsSha256 =
      'a215ae1b81c7bd902159c586c5801dd0d37a4097d72b1bab2bdf2ce64b12e48e';

  /// Display/provenance name of the artefact (thesis decisions D-045, D-051).
  static const name = 'Arm 2 — MobileNetV3-Large 0.75, weight-only INT8';
}

class OfflineModel {
  OfflineModel._({
    required this.modelBytes,
    required this.modelSha256,
    required this.labels,
    required this.labelsSha256,
    required this.classifier,
  });

  /// The shipped bytes (kept for the measurement round, which builds extra
  /// interpreters of the same file in other configurations).
  final Uint8List modelBytes;
  final String modelSha256;
  final LabelTable labels;
  final String labelsSha256;

  /// The production interpreter: 1 thread, no explicit delegate. Which CPU
  /// configuration the capture flow finally uses is decided after the
  /// measurement round (ADR 009); this one is created FIRST in the process so
  /// LiteRT's once-per-process XNNPACK log line can be attributed to it.
  final TfliteClassifier classifier;

  bool get modelHashMatches =>
      modelSha256 == OfflineModelAssets.expectedModelSha256;
  bool get labelsHashMatches =>
      labelsSha256 == OfflineModelAssets.expectedLabelsSha256;

  static Future<OfflineModel>? _shared;

  /// True once the shared instance has been created in this process.
  static bool get isLoaded => _shared != null;

  static Future<OfflineModel> shared() => _shared ??= _load();

  static Future<OfflineModel> _load() async {
    final modelData = await rootBundle.load(OfflineModelAssets.model);
    final modelBytes = modelData.buffer
        .asUint8List(modelData.offsetInBytes, modelData.lengthInBytes);
    final labelData = await rootBundle.load(OfflineModelAssets.labels);
    final labelBytes = labelData.buffer
        .asUint8List(labelData.offsetInBytes, labelData.lengthInBytes);

    final labels = LabelTable.parse(utf8.decode(labelBytes));
    final classifier = TfliteClassifier.create(
      modelBytes,
      execution: CpuExecution.noExplicitDelegate,
      threads: 1,
    );
    if (classifier.outputLength != labels.length) {
      classifier.close();
      throw StateError('Model has ${classifier.outputLength} outputs but '
          'labels.csv has ${labels.length} rows — files do not belong together.');
    }
    return OfflineModel._(
      modelBytes: modelBytes,
      modelSha256: sha256.convert(modelBytes).toString(),
      labels: labels,
      labelsSha256: sha256.convert(labelBytes).toString(),
      classifier: classifier,
    );
  }

  /// Encoded photograph (JPEG/PNG) -> logits, through the reference
  /// preprocessing and the production interpreter.
  Future<Float32List> classifyEncoded(Uint8List encoded) async {
    final decoded = await decodeImage(encoded);
    final prepared = preprocessLikeReference(decoded);
    return classifier.run(prepared.input);
  }
}
