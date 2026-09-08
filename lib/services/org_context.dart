import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';

/// Holds which park the person is currently recording under.
///
/// Why this exists at all: `memberships` is many-to-many, so a ranger can work
/// for two parks at once. An observation, however, belongs to exactly one.
/// Rather than guess from the coordinates — which breaks the moment someone
/// records from a car park outside the boundary — the person chooses, and the
/// choice is explicit and visible (ADR 005).
///
/// The choice is stored server-side in `user_settings.active_org_id`, not only
/// on the device, so it follows the person to a second phone.
class OrgContext extends ChangeNotifier {
  OrgContext(this._supabase);

  final SupabaseClient _supabase;

  List<Park> _parks = const [];
  String? _activeOrgId;
  bool _loading = true;
  bool _bootstrapped = false;
  String? _error;

  List<Park> get parks => _parks;
  bool get loading => _loading;
  String? get error => _error;
  String? get activeOrgId => _activeOrgId;
  bool get hasMultipleParks => _parks.length > 1;

  /// True once bootstrap() has finished, successfully or not. Without this the
  /// UI cannot tell "still loading" from "loaded, and you really do belong to
  /// no park".
  bool get bootstrapped => _bootstrapped;

  /// Signed in, bootstrap finished, and no park came back.
  ///
  /// This is a real state and it has a real cause worth knowing about: a
  /// session can outlive the account it belongs to. `supabase db reset` wipes
  /// `auth.users`, but the JWT on the device is still signed with the same
  /// secret, so it keeps validating while `auth.uid()` now points at a user id
  /// that no longer exists. The app is authenticated as nobody. Signing out and
  /// back in fixes it, which is why that button is offered rather than leaving
  /// a blank screen.
  bool get isOrphanedSession => _bootstrapped && !_loading && _parks.isEmpty;

  Park? get activePark {
    for (final p in _parks) {
      if (p.orgId == _activeOrgId) return p;
    }
    return null;
  }

  /// Called once after sign-in.
  ///
  /// Order matters. Any invitation addressed to this e-mail is claimed first,
  /// because a person invited five minutes ago has no membership yet and would
  /// otherwise see an empty app and conclude it is broken.
  Future<void> bootstrap() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      // Idempotent: returns 0 when there is nothing to claim. Its own failure
      // must not stop the park list from loading -- a person who belongs to a
      // park already does not need an invitation claimed to see it.
      try {
        await _supabase.rpc('accept_pending_invitations');
      } catch (e) {
        _error = 'Could not check for invitations: $e';
      }
      await _reload();
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      _bootstrapped = true;
      notifyListeners();
    }
  }

  /// Run the whole bootstrap again. What the Retry button calls.
  Future<void> retry() => bootstrap();

  Future<void> _reload() async {
    final rows = await _supabase.from('my_parks').select().order('name');
    _parks = rows.map((r) => Park.fromMap(r)).toList();

    // Whichever park the server says is active. If none is set yet — a person
    // whose settings row was never written — fall back to the first park and
    // persist that, so the state on the server and in the app agree.
    String? active;
    for (final p in _parks) {
      if (p.isActive) active = p.orgId;
    }
    if (active == null && _parks.isNotEmpty) {
      active = _parks.first.orgId;
      await _supabase.rpc('set_active_org', params: {'p_org_id': active});
    }
    _activeOrgId = active;
  }

  /// Switch park. The database refuses an org the caller is not a member of,
  /// so this cannot be used to reach another park's data even if the UI is
  /// wrong.
  Future<void> switchTo(String orgId) async {
    if (orgId == _activeOrgId) return;
    await _supabase.rpc('set_active_org', params: {'p_org_id': orgId});
    await _reload();
    notifyListeners();
  }

  Future<void> refresh() async {
    try {
      await _reload();
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  void clear() {
    _parks = const [];
    _activeOrgId = null;
    _loading = true;
    _bootstrapped = false;
    _error = null;
    notifyListeners();
  }
}
