/// The first real implementation of the [IdentificationService] seam: the
/// bundled offline model (sovereignty tier 3 — nothing leaves the device).
///
/// What it deliberately does NOT do yet:
///  * no calibration — scores are a plain softmax at temperature 1, i.e.
///    UNCALIBRATED; the thesis supplies the temperature later (D-018);
///  * no threshold and no accept/decline decision — the thesis fits per-species
///    thresholds; the app will only display that decision, never invent one;
///  * no checklist masking — `checklistMasked` stays false;
///  * no multi-image fusion — only the first photograph is classified; how
///    several photographs of one plant are combined is a thesis decision.
library;

import 'dart:typed_data';

import '../ml/inference_math.dart';
import '../ml/offline_model.dart';
import 'identification_service.dart';

class OfflineModelIdentificationService implements IdentificationService {
  const OfflineModelIdentificationService({this.topK = 5});

  /// How many candidates are returned (the whole list is stored in
  /// `identifications.top_k`, so top-5 accuracy stays computable).
  final int topK;

  @override
  String get source => 'offline_model';

  @override
  String get provider => 'thesis-offline';

  @override
  Future<bool> get isAvailable async {
    try {
      await OfflineModel.shared();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<IdentificationResult> identify(List<IdentificationInput> images) async {
    if (images.isEmpty) {
      return IdentificationResult(
          source: source, provider: provider, candidates: const []);
    }
    final model = await OfflineModel.shared();
    final logits =
        await model.classifyEncoded(Uint8List.fromList(images.first.bytes));
    final probabilities = softmax(logits); // temperature 1: uncalibrated
    final candidates = [
      for (final i in topKIndices(probabilities, topK))
        IdentificationCandidate(
          scientificName: model.labels[i].label,
          score: probabilities[i],
          rank: model.labels[i].rank,
        ),
    ];
    return IdentificationResult(
      source: source,
      provider: provider,
      candidates: candidates,
      checklistMasked: false,
    );
  }
}
