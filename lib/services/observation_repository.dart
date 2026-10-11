import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models_extra.dart';
import '../models/records.dart';
import 'identification_service.dart';
import 'observation_payloads.dart';
import 'prepared_photo.dart';

/// Everything the record screen collects before it saves a NEW record.
class RecordDraft {
  RecordDraft({
    required this.orgId,
    required this.eventDate,
    required this.latitude,
    required this.longitude,
    required this.uncertaintyM,
    required this.georeferenceProtocol,
    required this.sensitivity,
    this.individualCount,
    this.lifeStage,
    this.habitat,
    this.remarks,
    this.photo,
    this.organ,
    this.suggestion,
    this.suggestedAt,
    this.suggestionRemarks,
    this.modelVersionId,
    this.determination,
  });

  final String orgId;
  final DateTime eventDate;
  final double latitude;
  final double longitude;
  final double? uncertaintyM;
  final String georeferenceProtocol;
  final String sensitivity;
  final int? individualCount;
  final String? lifeStage;
  final String? habitat;
  final String? remarks;

  final PreparedPhoto? photo;
  final String? organ;

  /// The on-device model's answer for [photo], with taxa already attached.
  final IdentificationResult? suggestion;
  final DateTime? suggestedAt;
  final String? suggestionRemarks;
  final String? modelVersionId;

  /// A person's determination, from the park checklist.
  final ChecklistTaxon? determination;
}

/// What a save achieved. A record is written in up to four steps (record,
/// photo, model suggestion, person's determination) that cannot share one
/// transaction — the photo goes to Storage, not to Postgres. So a save can
/// half-succeed, and the person is told exactly which half: an earlier version
/// reported a blanket error for a record that had in fact been created.
class SaveOutcome {
  SaveOutcome(this.observationId);

  final String observationId;
  bool photoStored = false;
  bool suggestionStored = false;
  bool determinationStored = false;
  final problems = <String>[];

  bool get complete => problems.isEmpty;
}

/// The primary photo of a stored record.
class StoredPhoto {
  const StoredPhoto({
    required this.storagePath,
    this.organ,
    this.widthPx,
    this.heightPx,
    this.url,
    this.exifStripped = true,
  });

  final String storagePath;
  final String? organ;
  final int? widthPx;
  final int? heightPx;

  /// A signed URL valid for an hour; null when the object could not be signed
  /// (e.g. the seed's media rows, which point at files that were never uploaded).
  final String? url;
  final bool exifStripped;
}

/// One stored record, with its whole determination history.
class RecordDetail {
  const RecordDetail({
    required this.observation,
    required this.identifications,
    this.georeferenceProtocol,
    this.photo,
  });

  final ObservationDetail observation;
  final String? georeferenceProtocol;

  /// Oldest first — the order in which they were made.
  final List<IdentificationEntry> identifications;
  final StoredPhoto? photo;

  IdentificationEntry? latest(String source) {
    for (final i in identifications.reversed) {
      if (i.source == source) return i;
    }
    return null;
  }

  IdentificationEntry? get accepted {
    for (final i in identifications) {
      if (i.isAccepted) return i;
    }
    return null;
  }
}

/// Reads and writes records. Only this class and [RecordsStore] talk to the
/// database about observations; screens talk to them.
class ObservationRepository {
  ObservationRepository([SupabaseClient? db]) : _db = db ?? Supabase.instance.client;

  final SupabaseClient _db;

  static const bucket = 'observation-photos';

  /// The park's checklist — what a person can determine a record as. Joining
  /// through `checklist_entries` rather than reading `taxa` wholesale is the
  /// point: a determination is reachable only if the park expects the taxon.
  Future<List<ChecklistTaxon>> checklist(String orgId) async {
    final rows = await _db
        .from('checklist_entries')
        .select(ChecklistTaxon.select)
        .eq('org_id', orgId);
    return rows.map(ChecklistTaxon.fromMap).toList()
      ..sort((a, b) => a.scientificName.compareTo(b.scientificName));
  }

  /// Attaches `taxa` ids to an identifier's candidates (see [attachTaxa]).
  /// Never throws: without a connection the candidates are stored verbatim,
  /// which the schema allows.
  Future<List<IdentificationCandidate>> resolveTaxa(
      List<IdentificationCandidate> candidates) async {
    final keys = taxonLookupKeys(candidates);
    final filters = [
      if (keys.gbifKeys.isNotEmpty) 'gbif_taxon_key.in.(${keys.gbifKeys.join(',')})',
      if (keys.genusNames.isNotEmpty)
        'and(taxon_rank.eq.genus,scientific_name.in.('
            '${keys.genusNames.map((g) => '"${g.replaceAll('"', '')}"').join(',')}))',
    ];
    if (filters.isEmpty) return candidates;
    try {
      final rows = await _db
          .from('taxa')
          .select('id, scientific_name, taxon_rank, gbif_taxon_key')
          .or(filters.join(','));
      return attachTaxa(candidates, rows);
    } catch (_) {
      return candidates;
    }
  }

  /// The `model_versions` row of an artefact, by its file hash; null when the
  /// artefact is not registered (rows are loaded by tooling, not the app).
  Future<String?> modelVersionId(String artifactSha256) async {
    try {
      final row = await _db
          .from('model_versions')
          .select('id')
          .eq('artifact_sha256', artifactSha256)
          .limit(1)
          .maybeSingle();
      return row?['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<SaveOutcome> create(RecordDraft d) async {
    final user = _db.auth.currentUser!;
    final inserted = await _db
        .from('observations')
        .insert({
          'org_id': d.orgId,
          ...observationFields(
            eventDate: d.eventDate,
            latitude: d.latitude,
            longitude: d.longitude,
            uncertaintyM: d.uncertaintyM,
            georeferenceProtocol: d.georeferenceProtocol,
            sensitivity: d.sensitivity,
            individualCount: d.individualCount,
            lifeStage: d.lifeStage,
            habitat: d.habitat,
            remarks: d.remarks,
          ),
          'recorded_by_user_id': user.id,
          // dwc:recordedBy is a text snapshot taken at capture, so the record
          // keeps its attribution even if the account is later removed.
          'recorded_by': user.email ?? 'unknown',
          'client_created_at': DateTime.now().toUtc().toIso8601String(),
        })
        .select('id')
        .single();
    final out = SaveOutcome(inserted['id'] as String);

    final photo = d.photo;
    if (photo != null) {
      final path = photoStoragePath(
          orgId: d.orgId, observationId: out.observationId, sha256: photo.sha256);
      var uploaded = false;
      try {
        await _db.storage.from(bucket).uploadBinary(path, photo.bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'));
        uploaded = true;
        await _db.from('observation_media').insert(primaryMediaRow(
              observationId: out.observationId,
              orgId: d.orgId,
              storagePath: path,
              info: photo.info,
              byteCount: photo.bytes.length,
              sha256: photo.sha256,
              exifStripped: true, // PreparedPhoto refuses anything it could not strip
              organ: d.organ,
              capturedAt: photo.capturedAt,
            ));
        out.photoStored = true;
      } catch (e) {
        out.problems.add(uploaded
            ? 'The photo was uploaded but could not be linked to the record ($e).'
            : 'The photo could not be uploaded ($e).');
      }
    }

    // The suggestion belongs to the photo: without a stored photo it would be
    // an answer to a question nobody can look at again.
    final suggestion = d.suggestion;
    if (suggestion != null && suggestion.best != null) {
      if (!out.photoStored) {
        out.problems.add('The model\'s suggestion was not stored, because the photo it '
            'belongs to was not.');
      } else {
        try {
          await _db.from('identifications').insert(machineIdentificationRow(
                observationId: out.observationId,
                orgId: d.orgId,
                result: suggestion,
                identifiedAt: d.suggestedAt ?? DateTime.now(),
                modelVersionId: d.modelVersionId,
                remarks: d.suggestionRemarks,
              ));
          out.suggestionStored = true;
        } catch (e) {
          out.problems.add('The model\'s suggestion could not be stored ($e).');
        }
      }
    }

    final determination = d.determination;
    if (determination != null) {
      try {
        await addDetermination(out.observationId, determination);
        out.determinationStored = true;
      } catch (e) {
        out.problems.add('Your determination could not be stored ($e). The record has '
            'none yet, which is a valid state — add it from the record later.');
      }
    }
    return out;
  }

  /// Updates the observation's own columns. Determinations are never touched
  /// here: they are an append-only log (no UPDATE grant on `identifications`).
  Future<void> update(String observationId, Map<String, Object?> fields) => _db
      .from('observations')
      .update({...fields, 'updated_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', observationId);

  /// Appends a person's determination and makes it the accepted one. Never
  /// overwrites what the models said — those are rows of their own.
  Future<void> addDetermination(String observationId, ChecklistTaxon t) =>
      _db.rpc('record_identification', params: {
        'p_observation_id': observationId,
        'p_source': 'human',
        'p_taxon_id': t.taxonId,
        'p_scientific_name': t.scientificName,
        'p_rank': t.rank,
        'p_accept': true,
      });

  Future<RecordDetail> loadDetail(String observationId) async {
    final row =
        await _db.from('observations_wide').select().eq('id', observationId).single();
    // Not in observations_wide; read from the table itself.
    final protocol = await _db
        .from('observations')
        .select('georeference_protocol')
        .eq('id', observationId)
        .maybeSingle();
    final identifications = await _db
        .from('identifications')
        .select(IdentificationEntry.detailColumns)
        .eq('observation_id', observationId)
        .order('date_identified');
    final media = await _db
        .from('observation_media')
        .select('storage_path, organ, width_px, height_px, exif_stripped')
        .eq('observation_id', observationId)
        .eq('is_primary', true)
        .maybeSingle();

    StoredPhoto? photo;
    if (media != null) {
      final path = media['storage_path'] as String;
      String? url;
      try {
        url = await _db.storage.from(bucket).createSignedUrl(path, 3600);
      } catch (_) {
        url = null;
      }
      photo = StoredPhoto(
        storagePath: path,
        organ: media['organ'] as String?,
        widthPx: media['width_px'] as int?,
        heightPx: media['height_px'] as int?,
        url: url,
        exifStripped: (media['exif_stripped'] as bool?) ?? true,
      );
    }

    return RecordDetail(
      observation: ObservationDetail.fromMap(row),
      georeferenceProtocol: protocol?['georeference_protocol'] as String?,
      identifications: identifications.map(IdentificationEntry.fromMap).toList(),
      photo: photo,
    );
  }
}
