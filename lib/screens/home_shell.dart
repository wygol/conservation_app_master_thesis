import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/plants/plant_families.dart';
import '../domain/plants/plant_symbology.dart';
import '../services/org_context.dart';
import '../services/records_store.dart';
import 'map_screen.dart';
import 'observations_screen.dart';
import 'record_editor_screen.dart';
import 'settings_screen.dart';

/// The signed-in shell: Records (capture and the list), Map, Settings.
///
/// This is also where the concrete domain is plugged into the core: the map
/// and the list draw records through a `RecordSymbology`, and the plant one is
/// chosen here — the same seam as `IdentificationService` (CLAUDE.md §4).
///
/// History: the Notes placeholder left the bar on 2026-10-09 and its code on
/// 2026-10-11; the "Identify" tab (the model lab of the measurement round)
/// moved into Settings on 2026-10-11 (ADR 011).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.orgContext});

  final OrgContext orgContext;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late final RecordsStore _store = RecordsStore(Supabase.instance.client, widget.orgContext);
  PlantFamilies? _families;
  int _index = 0;

  /// Tabs are built on first visit, then kept alive — so the map loads no
  /// tiles until someone opens it, and keeps its view afterwards.
  final _visited = <int>{0};

  @override
  void initState() {
    super.initState();
    PlantFamilies.load().then((f) {
      if (mounted) setState(() => _families = f);
    }).catchError((_) {
      // Without the label table only families stored in `taxa` are known;
      // the map still works.
    });
  }

  @override
  void dispose() {
    _store.dispose();
    super.dispose();
  }

  Future<void> _open(String? recordId) async {
    final park = widget.orgContext.activePark;
    if (park == null) return;
    await openRecordEditor(context, park: park, store: _store, recordId: recordId);
  }

  @override
  Widget build(BuildContext context) {
    final symbology = PlantRecordSymbology(_families);
    final pages = [
      ObservationsScreen(
        orgContext: widget.orgContext,
        store: _store,
        symbology: symbology,
        onOpenRecord: _open,
        onNewRecord: () => _open(null),
      ),
      MapScreen(
        store: _store,
        orgContext: widget.orgContext,
        symbology: symbology,
        onOpenRecord: _open,
      ),
      SettingsScreen(orgContext: widget.orgContext),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          for (var i = 0; i < pages.length; i++)
            _visited.contains(i) ? pages[i] : const SizedBox.shrink(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() {
          _index = i;
          _visited.add(i);
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.eco_outlined),
            selectedIcon: Icon(Icons.eco),
            label: 'Records',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            selectedIcon: Icon(Icons.map),
            label: 'Map',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
