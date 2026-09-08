import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import '../services/org_context.dart';
import 'record_editor_screen.dart';

/// The active park's records, newest first.
///
/// Reads `observations_current`, not `observations`: the accepted
/// determination lives in a separate append-only table and is resolved by that
/// view. There is deliberately no `scientific_name` column on `observations`
/// to read instead — see Vault/30_Architecture/Observation_Data_Model.md.
///
/// As with `notes`, there is no client-side `org_id` filter for security: RLS
/// injects it server-side. The `.eq()` below is a *display* filter for the
/// active park, and a ranger who belongs to two parks would still be unable to
/// read a third park's rows if it were removed.
class ObservationsScreen extends StatefulWidget {
  const ObservationsScreen({super.key, required this.orgContext});

  final OrgContext orgContext;

  @override
  State<ObservationsScreen> createState() => _ObservationsScreenState();
}

class _ObservationsScreenState extends State<ObservationsScreen> {
  final supabase = Supabase.instance.client;
  bool _loading = true;
  String? _error;
  List<ObservationSummary> _rows = const [];
  String? _loadedForOrg;

  @override
  void initState() {
    super.initState();
    widget.orgContext.addListener(_onOrgChanged);
    _load();
  }

  @override
  void dispose() {
    widget.orgContext.removeListener(_onOrgChanged);
    super.dispose();
  }

  void _onOrgChanged() {
    if (widget.orgContext.activeOrgId != _loadedForOrg) _load();
  }

  Future<void> _load() async {
    final orgId = widget.orgContext.activeOrgId;
    if (orgId == null) {
      setState(() {
        _rows = const [];
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await supabase
          .from('observations_current')
          .select()
          .eq('org_id', orgId)
          .order('event_date', ascending: false)
          .limit(200);
      if (!mounted) return;
      setState(() {
        _rows = data.map((r) => ObservationSummary.fromMap(r)).toList();
        _loadedForOrg = orgId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Which of the three determination paths produced the name currently shown.
  /// Making this visible in the list is not decoration: a ranger has to be able
  /// to tell a phone's guess from a colleague's determination at a glance.
  ({IconData icon, String label, Color? color}) _sourceBadge(
      BuildContext context, ObservationSummary o) {
    final scheme = Theme.of(context).colorScheme;
    switch (o.identificationSource) {
      case 'human':
        return (icon: Icons.verified_outlined, label: 'expert', color: scheme.primary);
      case 'online_service':
        return (icon: Icons.cloud_outlined, label: 'online', color: scheme.secondary);
      case 'offline_model':
        return (icon: Icons.smartphone, label: 'on-device', color: scheme.tertiary);
      default:
        return (icon: Icons.pending_outlined, label: 'not determined yet', color: scheme.outline);
    }
  }

  Future<void> _openEditor(BuildContext context, Park park, String? id) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordEditorScreen(park: park, existingId: id),
      ),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.orgContext,
      builder: (context, _) {
        final park = widget.orgContext.activePark;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Observations'),
            // The active park is always on screen. A person recording for two
            // parks must never have to guess which one they are writing to.
            bottom: park == null
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(28),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        park.name,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                  ),
          ),
          body: RefreshIndicator(
            onRefresh: _load,
            child: _buildBody(context),
          ),
          // Any member of the park may add a record; any member may edit one.
          // Restricting editing to the record's own author is a rule we may
          // add later — the database is ready for it, the product is not.
          floatingActionButton: park == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _openEditor(context, park, null),
                  icon: const Icon(Icons.add),
                  label: const Text('Record'),
                ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Center(child: Text('Could not load records:\n$_error',
              textAlign: TextAlign.center)),
        ],
      );
    }

    // Signed in, but no park came back. Two very different causes, and the
    // screen has to offer a way out of both rather than showing a blank list:
    // either nobody has invited this person yet, or the session outlived the
    // account (a `db reset` wipes auth.users while the device's JWT keeps
    // validating, so the app is authenticated as a user id that no longer
    // exists). Signing out and back in fixes the second.
    if (widget.orgContext.activeOrgId == null) {
      final oc = widget.orgContext;
      return ListView(
        children: [
          const SizedBox(height: 64),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.park_outlined,
                    size: 48, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 16),
                const Text(
                  'You are signed in, but you do not belong to a park.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Either an administrator has not invited you yet, or this '
                  'sign-in is older than the database it points at. Signing out '
                  'and back in fixes the second one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13),
                ),
                if (oc.error != null) ...[
                  const SizedBox(height: 12),
                  Text(oc.error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => oc.retry(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                    FilledButton.icon(
                      onPressed: () async {
                        oc.clear();
                        await Supabase.instance.client.auth.signOut();
                      },
                      icon: const Icon(Icons.logout),
                      label: const Text('Sign out'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (_rows.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 80),
          Center(child: Text('No records in this park yet.')),
        ],
      );
    }

    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final o = _rows[i];
        final badge = _sourceBadge(context, o);
        final d = o.eventDate;
        final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        return ListTile(
          leading: Icon(badge.icon, color: badge.color),
          title: Text(
            // A record with no species yet is normal in the intended workflow
            // (photograph first, determine later), so it is worded as a state
            // rather than as a missing value.
            o.scientificName ?? 'Awaiting determination',
            style: TextStyle(
              fontStyle: o.isDetermined ? FontStyle.italic : FontStyle.normal,
              color: o.isDetermined
                  ? null
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          subtitle: Text([
            if (o.vernacularName != null) o.vernacularName!,
            date,
            badge.label,
            // A genus-level answer is labelled as such rather than dressed up
            // as a species determination.
            if (o.taxonRank != null && o.taxonRank != 'species')
              '${o.taxonRank} level',
            if (o.surveyEventId != null) 'survey',
          ].join(' · ')),
          trailing: o.confidence == null
              ? null
              : Text('${(o.confidence! * 100).round()}%'),
          onTap: () {
            final park = widget.orgContext.activePark;
            if (park != null) _openEditor(context, park, o.id);
          },
        );
      },
    );
  }
}
