import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/records.dart';
import '../services/org_context.dart';
import '../services/records_store.dart';
import '../widgets/record_marker.dart';
import '../widgets/record_tile.dart';

/// The active park's records, newest first — the "data input" tab.
///
/// Reads the shared [RecordsStore] (also behind the map), which reads the
/// determination log itself rather than `observations_current`: a record the
/// model has suggested a name for shows that name, marked as a suggestion,
/// even when the name has no `taxa` row yet (see models/records.dart).
///
/// As everywhere, there is no client-side `org_id` filter for SECURITY: RLS
/// injects it server-side. The store's `.eq('org_id', …)` only picks the
/// active park among the ones a person belongs to.
class ObservationsScreen extends StatefulWidget {
  const ObservationsScreen({
    super.key,
    required this.orgContext,
    required this.store,
    required this.symbology,
    required this.onOpenRecord,
    required this.onNewRecord,
  });

  final OrgContext orgContext;
  final RecordsStore store;
  final RecordSymbology symbology;
  final ValueChanged<String> onOpenRecord;
  final VoidCallback onNewRecord;

  @override
  State<ObservationsScreen> createState() => _ObservationsScreenState();
}

class _ObservationsScreenState extends State<ObservationsScreen> {
  /// null = all records.
  DeterminationState? _filter;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.orgContext, widget.store]),
      builder: (context, _) {
        final park = widget.orgContext.activePark;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Records'),
            // The active park is always on screen. A person recording for two
            // parks must never have to guess which one they are writing to.
            bottom: park == null
                ? null
                : PreferredSize(
                    preferredSize: const Size.fromHeight(28),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(park.name, style: Theme.of(context).textTheme.labelLarge),
                    ),
                  ),
          ),
          body: RefreshIndicator(
            onRefresh: widget.store.reload,
            child: _body(context),
          ),
          floatingActionButton: park == null
              ? null
              : FloatingActionButton.extended(
                  onPressed: widget.onNewRecord,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('New record'),
                ),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final store = widget.store;
    final oc = widget.orgContext;

    // Signed in, but no park came back. Two very different causes, and the
    // screen has to offer a way out of both rather than showing a blank list:
    // either nobody has invited this person yet, or the session outlived the
    // account (a `db reset` wipes auth.users while the device's JWT keeps
    // validating, so the app is authenticated as a user id that no longer
    // exists). Signing out and back in fixes the second.
    if (oc.bootstrapped && oc.activeOrgId == null) return _noPark(context);

    if (store.error != null && store.records.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 80),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Text('Could not load records:\n${store.error}', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: store.reload, child: const Text('Try again')),
          ]),
        ),
      ]);
    }
    if (store.records.isEmpty) {
      if (store.loading || !oc.bootstrapped) {
        return const Center(child: CircularProgressIndicator());
      }
      return ListView(children: [
        const SizedBox(height: 96),
        Icon(Icons.local_florist_outlined, size: 56, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        const Center(child: Text('No records in this park yet.')),
        const SizedBox(height: 4),
        const Center(child: Text('Tap "New record" to photograph a plant.')),
      ]);
    }

    final records = store.records;
    final counts = {
      for (final s in DeterminationState.values)
        s: records.where((r) => r.state == s).length,
    };
    final shown = _filter == null ? records : records.where((r) => r.state == _filter).toList();

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 96), // clear of the button
      itemCount: shown.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return _filters(context, records.length, counts, store.truncated);
        final r = shown[i - 1];
        return RecordTile(
          record: r,
          style: widget.symbology.styleOf(r, MapColouring.status),
          onTap: () => widget.onOpenRecord(r.id),
        );
      },
    );
  }

  Widget _filters(BuildContext context, int total, Map<DeterminationState, int> counts,
      bool truncated) {
    ChoiceChip chip(String label, DeterminationState? state, int n) => ChoiceChip(
          label: Text('$label $n'),
          selected: _filter == state,
          onSelected: (_) => setState(() => _filter = state),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 4, children: [
          chip('All', null, total),
          chip('Awaiting', DeterminationState.awaiting, counts[DeterminationState.awaiting]!),
          chip('Suggested', DeterminationState.suggested, counts[DeterminationState.suggested]!),
          chip('Confirmed', DeterminationState.confirmed, counts[DeterminationState.confirmed]!),
        ]),
        if (truncated)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Showing the newest ${RecordsStore.pageSize} records.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ]),
    );
  }

  Widget _noPark(BuildContext context) {
    final oc = widget.orgContext;
    return ListView(
      children: [
        const SizedBox(height: 64),
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Icon(Icons.park_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
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
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
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
}
