// Plain data holders for the rows the app reads. Deliberately small and
// hand-written: no code generation, no freezed, nothing to regenerate when a
// column changes. Each model owns exactly one `fromMap`, and that is the only
// place a column name appears as a string.

/// A park instance the signed-in person belongs to. One row of `my_parks`.
class Park {
  const Park({
    required this.orgId,
    required this.name,
    required this.role,
    required this.isActive,
    this.slug,
    this.publishingStatus,
  });

  final String orgId;
  final String name;
  final String role; // 'admin' | 'member'
  final bool isActive;
  final String? slug;
  final String? publishingStatus;

  bool get isAdmin => role == 'admin';

  factory Park.fromMap(Map<String, dynamic> m) => Park(
        orgId: m['org_id'] as String,
        name: m['name'] as String,
        role: (m['role'] as String?) ?? 'member',
        isActive: (m['is_active'] as bool?) ?? false,
        slug: m['slug'] as String?,
        publishingStatus: m['publishing_status'] as String?,
      );
}

/// One row of `observations_current` — an occurrence together with whichever
/// identification is currently accepted for it.
class ObservationSummary {
  const ObservationSummary({
    required this.id,
    required this.orgId,
    required this.eventDate,
    this.scientificName,
    this.vernacularName,
    this.identificationSource,
    this.taxonRank,
    this.confidence,
    this.verificationStatus,
    this.recordedBy,
    this.habitat,
    this.surveyEventId,
  });

  final String id;
  final String orgId;
  final DateTime eventDate;
  final String? scientificName;
  final String? vernacularName;

  /// 'offline_model' | 'online_service' | 'human' — null when nothing has been
  /// determined yet, which is a normal state, not an error.
  final String? identificationSource;

  /// The rank actually answered. A genus-level answer is a real answer, not a
  /// failure: park records are routinely made at mixed rank.
  final String? taxonRank;
  final double? confidence;
  final String? verificationStatus;
  final String? recordedBy;
  final String? habitat;
  final String? surveyEventId;

  bool get isDetermined => scientificName != null;
  bool get isVerified => verificationStatus == 'verified';

  factory ObservationSummary.fromMap(Map<String, dynamic> m) => ObservationSummary(
        id: m['id'] as String,
        orgId: m['org_id'] as String,
        eventDate: DateTime.parse(m['event_date'] as String).toLocal(),
        scientificName: m['scientific_name'] as String?,
        vernacularName: m['vernacular_name_de'] as String?,
        identificationSource: m['identification_source'] as String?,
        taxonRank: m['taxon_rank_answered'] as String?,
        confidence: (m['confidence_calibrated'] as num?)?.toDouble(),
        verificationStatus: m['verification_status'] as String?,
        recordedBy: m['recorded_by'] as String?,
        habitat: m['habitat'] as String?,
        surveyEventId: m['survey_event_id'] as String?,
      );
}

/// A survey session — the Humboldt Extension layer. Nullable on an observation
/// by design: most records are opportunistic and belong to no survey.
class SurveyEvent {
  const SurveyEvent({
    required this.id,
    required this.orgId,
    required this.startedAt,
    this.endedAt,
    this.eventType,
    this.samplingProtocol,
    this.targetTaxonomicScope,
    this.isAbsenceReported = false,
    this.siteCount,
  });

  final String id;
  final String orgId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? eventType;
  final String? samplingProtocol;
  final String? targetTaxonomicScope;
  final bool isAbsenceReported;
  final int? siteCount;

  bool get isOpen => endedAt == null;

  Duration get elapsed => (endedAt ?? DateTime.now()).difference(startedAt);

  factory SurveyEvent.fromMap(Map<String, dynamic> m) => SurveyEvent(
        id: m['id'] as String,
        orgId: m['org_id'] as String,
        startedAt: DateTime.parse(m['event_started_at'] as String).toLocal(),
        endedAt: m['event_ended_at'] == null
            ? null
            : DateTime.parse(m['event_ended_at'] as String).toLocal(),
        eventType: m['event_type'] as String?,
        samplingProtocol: m['sampling_protocol'] as String?,
        targetTaxonomicScope: m['target_taxonomic_scope'] as String?,
        isAbsenceReported: (m['is_absence_reported'] as bool?) ?? false,
        siteCount: m['site_count'] as int?,
      );
}

/// A pending or historical invitation, as an admin sees it.
class Invitation {
  const Invitation({
    required this.id,
    required this.email,
    required this.role,
    required this.status,
    required this.expiresAt,
  });

  final String id;
  final String email;
  final String role;
  final String status; // pending | sent | accepted | revoked | expired
  final DateTime expiresAt;

  bool get isLive => status == 'pending' || status == 'sent';

  factory Invitation.fromMap(Map<String, dynamic> m) => Invitation(
        id: m['id'] as String,
        email: m['email'] as String,
        role: m['role'] as String,
        status: m['status'] as String,
        expiresAt: DateTime.parse(m['expires_at'] as String).toLocal(),
      );
}
