import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/records.dart';
import 'org_context.dart';

/// The active park's records, loaded once and shared by the Records list and
/// the map, so the two can never disagree and a save refreshes both.
///
/// As everywhere in the app, RLS — not the `.eq('org_id', …)` below — is what
/// keeps another park's rows out. The filter only picks the ACTIVE park among
/// the parks a person belongs to (ADR 005).
class RecordsStore extends ChangeNotifier {
  RecordsStore(this._db, this._orgContext) {
    _orgContext.addListener(_onOrgChanged);
    _onOrgChanged();
  }

  final SupabaseClient _db;
  final OrgContext _orgContext;

  /// PostgREST's `max_rows` (supabase/config.toml) caps every response at
  /// 1,000 rows; identifications are paged past it, observations are not —
  /// the newest 1,000 records are shown and [truncated] says so.
  static const pageSize = 1000;

  List<RecordDigest> _records = const [];
  bool _loading = false;
  String? _error;
  String? _loadedFor;
  bool _truncated = false;
  int _generation = 0;

  List<RecordDigest> get records => _records;
  bool get loading => _loading;
  String? get error => _error;
  bool get truncated => _truncated;

  /// The park the current [records] belong to.
  String? get orgId => _loadedFor;

  /// The park a load was last started for. OrgContext notifies on every
  /// loading step, not only on a switch; comparing with this keeps those from
  /// starting a second load of the same park.
  String? _requestedFor;

  void _onOrgChanged() {
    final org = _orgContext.activeOrgId;
    if (org == _requestedFor) return;
    _requestedFor = org;
    _records = const [];
    _loadedFor = null;
    _error = null;
    if (org != null) {
      reload();
    } else {
      notifyListeners();
    }
  }

  Future<void> reload() async {
    final org = _orgContext.activeOrgId;
    if (org == null) return;
    final generation = ++_generation;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final observations = await _db
          .from('observations_wide')
          .select('id, event_date, latitude, longitude, geometry, '
              'coordinate_uncertainty_m, sensitivity, recorded_by, habitat')
          .eq('org_id', org)
          .order('event_date', ascending: false)
          .limit(pageSize);

      final identifications = <IdentificationEntry>[];
      for (var from = 0;; from += pageSize) {
        final page = await _db
            .from('identifications')
            .select(IdentificationEntry.listColumns)
            .eq('org_id', org)
            .order('date_identified', ascending: false)
            .range(from, from + pageSize - 1);
        identifications.addAll(page.map(IdentificationEntry.fromMap));
        if (page.length < pageSize) break;
      }

      final withPhoto = <String>{};
      for (var from = 0;; from += pageSize) {
        final page = await _db
            .from('observation_media')
            .select('observation_id')
            .eq('org_id', org)
            .eq('is_primary', true)
            .range(from, from + pageSize - 1);
        withPhoto.addAll(page.map((m) => m['observation_id'] as String));
        if (page.length < pageSize) break;
      }

      if (generation != _generation) return; // a newer load has started
      _records = buildRecordDigests(observations, identifications, withPhoto: withPhoto);
      _truncated = observations.length >= pageSize;
      _loadedFor = org;
    } catch (e) {
      if (generation != _generation) return;
      _error = e.toString();
    } finally {
      if (generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _orgContext.removeListener(_onOrgChanged);
    super.dispose();
  }
}
