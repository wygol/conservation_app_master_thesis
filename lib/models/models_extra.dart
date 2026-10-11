// Models added 2026-09-07 with the record editor and member management.

/// One row of `observations_wide` — an observation with the three
/// determination paths side by side. This is what the record editor loads.
class ObservationDetail {
  const ObservationDetail({
    required this.id,
    required this.orgId,
    required this.eventDate,
    required this.latitude,
    required this.longitude,
    this.coordinateUncertaintyM,
    this.individualCount,
    this.habitat,
    this.remarks,
    this.lifeStage,
    this.sensitivity = 'open',
    this.occurrenceStatus = 'present',
    this.recordedBy,
    this.offlineGuess,
    this.offlineRank,
    this.offlineConfidence,
    this.onlineGuess,
    this.onlineRank,
    this.onlineConfidence,
    this.expertGuess,
    this.expertRank,
    this.expertBy,
    this.acceptedName,
    this.acceptedSource,
    this.acceptedRank,
    this.acceptedStatus,
  });

  final String id;
  final String orgId;
  final DateTime eventDate;
  final double latitude;
  final double longitude;
  final double? coordinateUncertaintyM;
  final int? individualCount;
  final String? habitat;
  final String? remarks;
  final String? lifeStage;
  final String sensitivity;
  final String occurrenceStatus;
  final String? recordedBy;

  // The three paths, as columns. They are rows in `identifications`; this is a
  // flattened read of the most recent answer from each. None of them can
  // overwrite another.
  final String? offlineGuess;
  final String? offlineRank;
  final double? offlineConfidence;
  final String? onlineGuess;
  final String? onlineRank;
  final double? onlineConfidence;
  final String? expertGuess;
  final String? expertRank;
  final String? expertBy;

  final String? acceptedName;
  final String? acceptedSource;
  final String? acceptedRank;
  final String? acceptedStatus;

  static double? _d(dynamic v) => (v as num?)?.toDouble();

  factory ObservationDetail.fromMap(Map<String, dynamic> m) => ObservationDetail(
        id: m['id'] as String,
        orgId: m['org_id'] as String,
        eventDate: DateTime.parse(m['event_date'] as String).toLocal(),
        latitude: _d(m['latitude']) ?? 0,
        longitude: _d(m['longitude']) ?? 0,
        coordinateUncertaintyM: _d(m['coordinate_uncertainty_m']),
        individualCount: m['individual_count'] as int?,
        habitat: m['habitat'] as String?,
        remarks: m['occurrence_remarks'] as String?,
        lifeStage: m['life_stage'] as String?,
        sensitivity: (m['sensitivity'] as String?) ?? 'open',
        occurrenceStatus: (m['occurrence_status'] as String?) ?? 'present',
        recordedBy: m['recorded_by'] as String?,
        offlineGuess: m['offline_guess'] as String?,
        offlineRank: m['offline_rank'] as String?,
        offlineConfidence: _d(m['offline_confidence']),
        onlineGuess: m['online_guess'] as String?,
        onlineRank: m['online_rank'] as String?,
        onlineConfidence: _d(m['online_confidence']),
        expertGuess: m['expert_guess'] as String?,
        expertRank: m['expert_rank'] as String?,
        expertBy: m['expert_by'] as String?,
        acceptedName: m['accepted_name'] as String?,
        acceptedSource: m['accepted_source'] as String?,
        acceptedRank: m['accepted_rank'] as String?,
        acceptedStatus: m['accepted_status'] as String?,
      );
}

/// A taxon from the active park's checklist — what the identification picker
/// offers. Mixed rank on purpose: a genus is a legitimate answer.
class ChecklistTaxon {
  const ChecklistTaxon({
    required this.taxonId,
    required this.scientificName,
    required this.rank,
    this.vernacularName,
    this.tier,
    this.family,
    this.gbifTaxonKey,
  });

  /// What the record screen selects through `checklist_entries`.
  static const select =
      'tier, taxa!inner(id, scientific_name, taxon_rank, vernacular_name_de, family, gbif_taxon_key)';

  final String taxonId;
  final String scientificName;
  final String rank;
  final String? vernacularName;
  final String? tier;
  final String? family;
  final int? gbifTaxonKey;

  String get label => vernacularName == null
      ? scientificName
      : '$scientificName — $vernacularName';

  factory ChecklistTaxon.fromMap(Map<String, dynamic> m) {
    final t = (m['taxa'] as Map<String, dynamic>?) ?? m;
    return ChecklistTaxon(
      taxonId: t['id'] as String,
      scientificName: t['scientific_name'] as String,
      rank: (t['taxon_rank'] as String?) ?? 'species',
      vernacularName: t['vernacular_name_de'] as String?,
      tier: m['tier'] as String?,
      family: t['family'] as String?,
      gbifTaxonKey: (t['gbif_taxon_key'] as num?)?.toInt(),
    );
  }
}

/// One row of `park_members()`.
class ParkMember {
  const ParkMember({
    required this.userId,
    required this.email,
    required this.role,
    required this.joinedAt,
    required this.observationCount,
    required this.isSelf,
  });

  final String userId;
  final String email;
  final String role;
  final DateTime joinedAt;
  final int observationCount;
  final bool isSelf;

  bool get isAdmin => role == 'admin';

  factory ParkMember.fromMap(Map<String, dynamic> m) => ParkMember(
        userId: m['user_id'] as String,
        email: m['email'] as String,
        role: m['role'] as String,
        joinedAt: DateTime.parse(m['joined_at'] as String).toLocal(),
        observationCount: (m['observation_count'] as num?)?.toInt() ?? 0,
        isSelf: (m['is_self'] as bool?) ?? false,
      );
}
