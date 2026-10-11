/// The rows the capture flow writes, built as plain maps by pure functions so
/// that every column can be unit-tested without a database (ADR 011).
///
/// Column semantics are the schema's, not invented here:
/// supabase/migrations/20260905120000_* and Vault/30_Architecture/
/// Observation_Data_Model.md (top_k shape, identified_by for machine rows).
library;

import '../services/identification_service.dart';
import 'jpeg_metadata.dart';

/// The ranks `identifications.taxon_rank_answered` accepts (its CHECK). The
/// model's moss class is an "aggregate", which is no Linnaean rank: stored as
/// null, with the name kept verbatim.
const databaseRanks = {'species', 'genus', 'family', 'order', 'class', 'phylum', 'kingdom'};

String? databaseRank(String? rank) => databaseRanks.contains(rank) ? rank : null;

/// How the coordinate was obtained (dwc:georeferenceProtocol).
const gpsProtocol =
    'smartphone location service; coordinateUncertaintyInMeters = the device-reported '
    'horizontal accuracy';
const mapProtocol = 'position set by hand on a map';

/// Storage key of a photo. The first folder must be the organisation: the
/// bucket policies read it as such (migration 20260907100000, §4).
String photoStoragePath({
  required String orgId,
  required String observationId,
  required String sha256,
}) =>
    '$orgId/$observationId/$sha256.jpg';

/// EWKT, which PostGIS accepts through PostgREST. Longitude first.
String pointEwkt(double latitude, double longitude) =>
    'SRID=4326;POINT($longitude $latitude)';

String? _text(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

/// Where: the location columns. Written on insert, and on update only when
/// the location was changed — an edit of the remarks must not rewrite how
/// the coordinate was obtained.
Map<String, Object?> locationFields({
  required double latitude,
  required double longitude,
  required double? uncertaintyM,
  required String georeferenceProtocol,
}) =>
    {
      'geometry': pointEwkt(latitude, longitude),
      'coordinate_uncertainty_m': uncertaintyM,
      'georeference_protocol': georeferenceProtocol,
    };

/// When, how many, what else.
Map<String, Object?> descriptiveFields({
  required DateTime eventDate,
  required String sensitivity,
  int? individualCount,
  String? lifeStage,
  String? habitat,
  String? remarks,
}) =>
    {
      'event_date': eventDate.toUtc().toIso8601String(),
      'sensitivity': sensitivity,
      'individual_count': individualCount,
      'life_stage': _text(lifeStage),
      'habitat': _text(habitat),
      'occurrence_remarks': _text(remarks),
      // country_code is left out on purpose: the export falls back to the
      // park's own (dwc_occurrence_export), so the app hard-codes no country.
    };

/// Both, as written on insert.
Map<String, Object?> observationFields({
  required DateTime eventDate,
  required double latitude,
  required double longitude,
  required double? uncertaintyM,
  required String georeferenceProtocol,
  required String sensitivity,
  int? individualCount,
  String? lifeStage,
  String? habitat,
  String? remarks,
}) =>
    {
      ...locationFields(
          latitude: latitude,
          longitude: longitude,
          uncertaintyM: uncertaintyM,
          georeferenceProtocol: georeferenceProtocol),
      ...descriptiveFields(
          eventDate: eventDate,
          sensitivity: sensitivity,
          individualCount: individualCount,
          lifeStage: lifeStage,
          habitat: habitat,
          remarks: remarks),
    };

/// The `observation_media` row of the primary photo — the image the model
/// classified. Width and height are as DISPLAYED (EXIF orientation applied),
/// i.e. as a person viewing the photo sees it.
Map<String, Object?> primaryMediaRow({
  required String observationId,
  required String orgId,
  required String storagePath,
  required JpegInfo info,
  required int byteCount,
  required String sha256,
  required bool exifStripped,
  String? organ,
  DateTime? capturedAt,
}) =>
    {
      'observation_id': observationId,
      'org_id': orgId,
      'storage_path': storagePath,
      'organ': organ,
      'is_primary': true,
      'captured_at': capturedAt?.toUtc().toIso8601String(),
      'width_px': info.displayWidth,
      'height_px': info.displayHeight,
      'bytes': byteCount,
      'sha256': sha256,
      'exif_stripped': exifStripped,
    };

/// `identifications.top_k`: the thesis' shape `{taxon_id, name, score}`
/// (Observation_Data_Model.md), plus `rank` and `class_id` so a candidate
/// without a `taxa` row stays traceable to the label space.
List<Map<String, Object?>> topKJson(List<IdentificationCandidate> candidates) => [
      for (final c in candidates)
        {
          'taxon_id': c.taxonId,
          'name': c.scientificName,
          'score': c.score,
          'rank': c.rank,
          'class_id': c.externalId,
        },
    ];

/// A machine determination, written directly rather than through
/// `record_identification()`, because that function stores neither `top_k`
/// nor `model_version_id`. Never accepted on insert: a machine suggests, a
/// person accepts. Requires at least one candidate.
Map<String, Object?> machineIdentificationRow({
  required String observationId,
  required String orgId,
  required IdentificationResult result,
  required DateTime identifiedAt,
  String? modelVersionId,
  String? remarks,
}) {
  final best = result.best;
  if (best == null) {
    throw ArgumentError('A machine identification needs at least one candidate.');
  }
  return {
    'observation_id': observationId,
    'org_id': orgId,
    'source': result.source,
    'provider': result.provider,
    'model_version_id': modelVersionId ?? result.modelVersionId,
    'taxon_id': best.taxonId,
    'verbatim_identification': best.scientificName,
    'taxon_rank_answered': databaseRank(best.rank),
    'confidence_raw': best.score,
    // Stays null until the thesis' calibration file is applied (D-018).
    'confidence_calibrated': null,
    'checklist_masked': result.checklistMasked,
    'top_k': topKJson(result.candidates),
    'is_accepted': false,
    // "For machine rows, the provider string" (Observation_Data_Model.md).
    'identified_by': result.provider,
    // When the model answered, on the device — not when the row arrived.
    'date_identified': identifiedAt.toUtc().toIso8601String(),
    'verification_status': 'unverified',
    'identification_remarks': remarks,
  };
}

/// Provenance of an on-device answer, in words: what the score is, which
/// file produced it, and what the model was given.
String offlineRemarks({required String modelSha256, JpegInfo? input}) => [
      'On-device model, uncalibrated softmax (T = 1), no decision threshold.',
      'Model file SHA-256 $modelSha256.',
      if (input != null)
        'Input: JPEG ${input.width} x ${input.height} px as stored, '
            'EXIF orientation ${input.orientation}.',
    ].join(' ');

/// What to look up in `taxa` for the candidates of an identifier: the GBIF
/// keys of species classes and the names of genus classes. The aggregate class
/// has neither and stays unresolved.
({Set<int> gbifKeys, Set<String> genusNames}) taxonLookupKeys(
    List<IdentificationCandidate> candidates) {
  final keys = <int>{};
  final genera = <String>{};
  for (final c in candidates) {
    if (c.rank == 'species') {
      final key = int.tryParse(c.externalId ?? '');
      if (key != null) keys.add(key);
    } else if (c.rank == 'genus') {
      genera.add(c.scientificName.trim());
    }
  }
  return (gbifKeys: keys, genusNames: genera);
}

/// Attaches `taxa` ids found for the candidates. The join is the one the
/// schema designed — the GBIF key ("the join to everything external") for a
/// species, the exact name at genus rank for a genus class, which has no key.
/// No name matching for species: a label such as "Leontopodium nivale subsp.
/// alpinum (Cass.) Greuter" is not the same taxon as "Leontopodium nivale",
/// and deciding otherwise is taxonomy, not app code.
List<IdentificationCandidate> attachTaxa(
  List<IdentificationCandidate> candidates,
  List<Map<String, dynamic>> taxaRows,
) {
  final byKey = <int, String>{};
  final byGenus = <String, String>{};
  for (final t in taxaRows) {
    final key = (t['gbif_taxon_key'] as num?)?.toInt();
    if (key != null) byKey[key] = t['id'] as String;
    if (t['taxon_rank'] == 'genus') byGenus[t['scientific_name'] as String] = t['id'] as String;
  }
  return [
    for (final c in candidates)
      c.withTaxonId(c.taxonId ??
          switch (c.rank) {
            'species' => byKey[int.tryParse(c.externalId ?? '')],
            'genus' => byGenus[c.scientificName.trim()],
            _ => null,
          }),
  ];
}
