// What the Records list, the map and the record screen read — added
// 2026-10-11 with the capture flow (ADR 011).
//
// Why these read `identifications` themselves instead of only the views:
// `observations_current` and `observations_wide` take a name from `taxa`
// alone. A model suggestion whose class has no `taxa` row yet — today that is
// almost every one of the 1,004 classes, because `taxa` holds the park
// checklist, not the label space — is stored with `verbatim_identification`
// only, and the views show it as "no name". Reading the log directly shows the
// name the model actually gave. Nothing is written differently because of
// this; it is a read-side choice.

import 'package:latlong2/latlong.dart';

/// Where a record stands in "photograph first, determine later".
enum DeterminationState {
  /// A person's determination is the accepted one.
  confirmed,

  /// Only a machine has proposed a name so far.
  suggested,

  /// Nothing has proposed a name yet — a normal state, not an error.
  awaiting,
}

/// What the colour of a map marker means.
enum MapColouring { family, status }

/// One candidate of a stored `top_k` list.
class TopKEntry {
  const TopKEntry({
    required this.name,
    required this.score,
    this.rank,
    this.taxonId,
    this.classId,
  });

  final String name;
  final double score;
  final String? rank;
  final String? taxonId;
  final String? classId;

  /// Tolerant on purpose: rows written by the seed carry only name and score.
  static TopKEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    final score = j['score'];
    if (name is! String || score is! num) return null;
    return TopKEntry(
      name: name,
      score: score.toDouble(),
      rank: j['rank'] as String?,
      taxonId: j['taxon_id'] as String?,
      classId: j['class_id']?.toString(),
    );
  }
}

/// One row of `identifications`, as the app reads it.
class IdentificationEntry {
  const IdentificationEntry({
    required this.id,
    required this.observationId,
    required this.source,
    required this.isAccepted,
    required this.dateIdentified,
    this.provider,
    this.name,
    this.taxonId,
    this.family,
    this.vernacularName,
    this.rank,
    this.confidenceRaw,
    this.confidenceCalibrated,
    this.identifiedBy,
    this.verificationStatus,
    this.remarks,
    this.topK = const [],
  });

  /// Columns for the list and the map (no top_k, no remarks).
  static const listColumns =
      'id, observation_id, source, provider, taxon_id, verbatim_identification, '
      'taxon_rank_answered, confidence_raw, confidence_calibrated, is_accepted, '
      'identified_by, date_identified, verification_status, '
      'taxa(scientific_name, family, vernacular_name_de)';

  /// Everything, for one record.
  static const detailColumns = '$listColumns, identification_remarks, top_k';

  final String id;
  final String observationId;

  /// 'offline_model' | 'online_service' | 'human'.
  final String source;
  final String? provider;

  /// The `taxa` name when the determination resolved to a taxon, otherwise
  /// the verbatim name the identifier gave.
  final String? name;
  final String? taxonId;
  final String? family;
  final String? vernacularName;
  final String? rank;
  final double? confidenceRaw;
  final double? confidenceCalibrated;
  final bool isAccepted;
  final String? identifiedBy;
  final DateTime dateIdentified;
  final String? verificationStatus;
  final String? remarks;
  final List<TopKEntry> topK;

  bool get isMachine => source != 'human';

  /// The score to show, and whether it is calibrated. Uncalibrated scores are
  /// labelled as such wherever they appear (D-018: calibration is a thesis
  /// output the app does not have yet).
  ({double value, bool calibrated})? get displayScore {
    if (confidenceCalibrated != null) return (value: confidenceCalibrated!, calibrated: true);
    if (confidenceRaw != null) return (value: confidenceRaw!, calibrated: false);
    return null;
  }

  static double? _d(Object? v) => (v as num?)?.toDouble();

  factory IdentificationEntry.fromMap(Map<String, dynamic> m) {
    final t = m['taxa'] as Map<String, dynamic>?;
    final rawTopK = m['top_k'];
    return IdentificationEntry(
      id: m['id'] as String,
      observationId: m['observation_id'] as String,
      source: m['source'] as String,
      provider: m['provider'] as String?,
      name: (t?['scientific_name'] as String?) ?? m['verbatim_identification'] as String?,
      taxonId: m['taxon_id'] as String?,
      family: t?['family'] as String?,
      vernacularName: t?['vernacular_name_de'] as String?,
      rank: m['taxon_rank_answered'] as String?,
      confidenceRaw: _d(m['confidence_raw']),
      confidenceCalibrated: _d(m['confidence_calibrated']),
      isAccepted: (m['is_accepted'] as bool?) ?? false,
      identifiedBy: m['identified_by'] as String?,
      dateIdentified: DateTime.parse(m['date_identified'] as String).toLocal(),
      verificationStatus: m['verification_status'] as String?,
      remarks: m['identification_remarks'] as String?,
      topK: rawTopK is List
          ? [for (final j in rawTopK) ?TopKEntry.fromJson(j)]
          : const [],
    );
  }
}

/// One record, reduced to what the list and the map show.
class RecordDigest {
  const RecordDigest({
    required this.id,
    required this.eventDate,
    required this.state,
    this.latitude,
    this.longitude,
    this.polygons = const [],
    this.uncertaintyM,
    this.sensitivity = 'open',
    this.recordedBy,
    this.habitat,
    this.name,
    this.vernacularName,
    this.family,
    this.rank,
    this.nameSource,
    this.identifiedBy,
    this.score,
    this.scoreCalibrated = false,
    this.hasPhoto = false,
  });

  final String id;
  final DateTime eventDate;

  /// Centroid of the geometry (from `observations_wide`); null if the view
  /// returned none, in which case the record is listed but not mapped.
  final double? latitude;
  final double? longitude;

  /// Outer rings, when the geometry is a polygon and came back as GeoJSON.
  final List<List<LatLng>> polygons;
  final double? uncertaintyM;
  final String sensitivity;
  final String? recordedBy;
  final String? habitat;

  /// The best name available: the accepted determination, else a person's,
  /// else the most recent machine suggestion.
  final String? name;
  final String? vernacularName;
  final String? family;
  final String? rank;

  /// Source of [name]: 'human' | 'offline_model' | 'online_service'.
  final String? nameSource;
  final String? identifiedBy;

  /// The machine score behind [name] (null for a person's determination).
  final double? score;
  final bool scoreCalibrated;
  final DeterminationState state;
  final bool hasPhoto;

  LatLng? get point =>
      latitude == null || longitude == null ? null : LatLng(latitude!, longitude!);
}

/// Joins observation rows, identification rows and the ids of records with a
/// photo into digests, newest first. Pure, so it is unit-tested.
List<RecordDigest> buildRecordDigests(
  List<Map<String, dynamic>> observations,
  List<IdentificationEntry> identifications, {
  Set<String> withPhoto = const {},
}) {
  final byObservation = <String, List<IdentificationEntry>>{};
  for (final i in identifications) {
    (byObservation[i.observationId] ??= []).add(i);
  }
  final digests = <RecordDigest>[];
  for (final o in observations) {
    final id = o['id'] as String;
    final ids = [...?byObservation[id]]
      ..sort((a, b) => b.dateIdentified.compareTo(a.dateIdentified));
    IdentificationEntry? first(bool Function(IdentificationEntry) test) {
      for (final i in ids) {
        if (test(i)) return i;
      }
      return null;
    }

    final shown = first((i) => i.isAccepted) ??
        first((i) => !i.isMachine) ??
        first((i) => i.isMachine);
    final state = shown == null
        ? DeterminationState.awaiting
        : shown.isMachine
            ? DeterminationState.suggested
            : DeterminationState.confirmed;
    final score = shown?.isMachine == true ? shown!.displayScore : null;

    digests.add(RecordDigest(
      id: id,
      eventDate: DateTime.parse(o['event_date'] as String).toLocal(),
      latitude: (o['latitude'] as num?)?.toDouble(),
      longitude: (o['longitude'] as num?)?.toDouble(),
      polygons: polygonRings(o['geometry']),
      uncertaintyM: (o['coordinate_uncertainty_m'] as num?)?.toDouble(),
      sensitivity: (o['sensitivity'] as String?) ?? 'open',
      recordedBy: o['recorded_by'] as String?,
      habitat: o['habitat'] as String?,
      name: shown?.name,
      vernacularName: shown?.vernacularName,
      family: shown?.family,
      rank: shown?.rank,
      nameSource: shown?.source,
      identifiedBy: shown?.identifiedBy,
      score: score?.value,
      scoreCalibrated: score?.calibrated ?? false,
      state: state,
      hasPhoto: withPhoto.contains(id),
    ));
  }
  digests.sort((a, b) => b.eventDate.compareTo(a.eventDate));
  return digests;
}

/// Outer rings of a GeoJSON Polygon or MultiPolygon; empty for anything else,
/// including a point or a geometry that did not come back as GeoJSON.
List<List<LatLng>> polygonRings(Object? geometry) {
  if (geometry is! Map) return const [];
  List<LatLng>? ring(Object? coords) {
    if (coords is! List || coords.length < 4) return null;
    final points = <LatLng>[];
    for (final c in coords) {
      if (c is! List || c.length < 2 || c[0] is! num || c[1] is! num) return null;
      points.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
    }
    return points;
  }

  final coordinates = geometry['coordinates'];
  if (coordinates is! List) return const [];
  switch (geometry['type']) {
    case 'Polygon':
      final r = coordinates.isEmpty ? null : ring(coordinates.first);
      return r == null ? const [] : [r];
    case 'MultiPolygon':
      return [
        for (final p in coordinates)
          if (p is List && p.isNotEmpty) ?ring(p.first),
      ];
    default:
      return const [];
  }
}
