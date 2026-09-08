/// The seam between the domain-agnostic core and the plant-specific part
/// (CLAUDE.md section 4). Swapping the use case later means writing a new
/// implementation of this interface, not touching the capture flow.
///
/// Nothing implements it against a real service yet. It exists as code rather
/// than as intent because the `identifications` table already distinguishes
/// `offline_model` from `online_service`, and the two paths have to be
/// separable from the first line of capture code — if the online answer is
/// allowed to overwrite the offline one, the thesis' central comparison is
/// destroyed at the moment it is taken.
library;

/// One candidate the identifier proposes.
class IdentificationCandidate {
  const IdentificationCandidate({
    required this.scientificName,
    required this.score,
    this.taxonId,
    this.rank = 'species',
  });

  final String scientificName;

  /// 0..1. Raw model output — calibration happens later and separately.
  final double score;

  /// Set when the candidate resolved to a row in `taxa`; null when the
  /// identifier answered with a name the checklist does not carry.
  final String? taxonId;

  /// The rank this candidate is stated at. A genus-level candidate is a valid
  /// answer, not a degraded one.
  final String rank;
}

/// What an identifier returns for one set of images.
class IdentificationResult {
  const IdentificationResult({
    required this.source,
    required this.provider,
    required this.candidates,
    this.checklistMasked = false,
    this.modelVersionId,
  });

  /// 'offline_model' or 'online_service'. Written straight into
  /// `identifications.source`, so the two paths stay distinguishable forever.
  final String source;

  /// 'thesis-offline', 'plantnet', … Written into `identifications.provider`.
  final String provider;

  /// Ranked best-first. The whole list is stored in `identifications.top_k`,
  /// because top-5 accuracy cannot be computed afterwards from the top-1 alone.
  final List<IdentificationCandidate> candidates;

  /// Whether the output space was restricted to the park's checklist. This
  /// single flag is what makes the checklist-prior measurement possible from
  /// ordinary production records.
  final bool checklistMasked;

  /// Which artefact produced this, for `identifications.model_version_id`.
  final String? modelVersionId;

  IdentificationCandidate? get best =>
      candidates.isEmpty ? null : candidates.first;
}

/// One photograph on its way to an identifier.
class IdentificationInput {
  const IdentificationInput({required this.bytes, this.organ});

  final List<int> bytes;

  /// 'leaf' | 'flower' | 'fruit' | 'bark' | 'habit'. Pl@ntNet accepts this as
  /// a parameter and identification quality depends on it.
  final String? organ;
}

abstract class IdentificationService {
  /// Never throws for "I don't know" — that is an empty candidate list.
  /// Throws only for transport or configuration failure, which the caller
  /// must be able to tell apart from an honest non-answer.
  Future<IdentificationResult> identify(List<IdentificationInput> images);

  /// Whether this identifier can run right now. The offline one answers true
  /// with no network; the online one needs connectivity.
  Future<bool> get isAvailable;

  String get source;
  String get provider;
}

/// Placeholder so the seam type-checks and the capture flow can be written
/// against it before either real identifier exists.
class UnconfiguredIdentificationService implements IdentificationService {
  const UnconfiguredIdentificationService();

  @override
  String get source => 'online_service';

  @override
  String get provider => 'none';

  @override
  Future<bool> get isAvailable async => false;

  @override
  Future<IdentificationResult> identify(List<IdentificationInput> images) async {
    throw UnimplementedError(
      'No identification service is configured yet. '
      'Implement IdentificationService for Pl@ntNet (online) and for the '
      'bundled TFLite model (offline).',
    );
  }
}
