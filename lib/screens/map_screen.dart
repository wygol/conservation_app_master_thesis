import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/records.dart';
import '../services/location_service.dart';
import '../services/org_context.dart';
import '../services/records_store.dart';
import '../widgets/basemaps.dart';
import '../widgets/record_marker.dart';
import '../widgets/record_tile.dart';

/// Where the active park's records are — CORE (CLAUDE.md §4). The map knows
/// points, polygons and a [RecordSymbology]; that the categories are plant
/// families is the domain layer's business.
///
/// Positions come from `observations_wide` (centroid of the stored geometry),
/// so a polygon record has a marker too; its outline is drawn when PostgREST
/// returns the geometry as GeoJSON. A "generalised" record is shown at its
/// true position here: generalisation applies to export, never to the park's
/// own view of its own data.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.store,
    required this.orgContext,
    required this.symbology,
    required this.onOpenRecord,
  });

  final RecordsStore store;
  final OrgContext orgContext;
  final RecordSymbology symbology;
  final ValueChanged<String> onOpenRecord;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  Basemap _basemap = Basemap.fallback;
  MapColouring _colouring = MapColouring.family;
  String? _highlight;
  RecordDigest? _selected;
  bool _mapReady = false;
  String? _fittedFor;
  LocationTracker? _me;
  bool _followMe = false;

  /// Austria — shown until there is anything to fit to.
  static const _fallbackCentre = LatLng(47.6, 13.3);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onRecords);
  }

  /// The shell keeps this tab alive in an IndexedStack, which switches tickers
  /// off for hidden tabs. Following the position stops then: no GPS while
  /// nobody looks at the map. Tapping "Where am I" starts it again.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled) _me?.stop();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onRecords);
    _me?.dispose();
    _map.dispose();
    super.dispose();
  }

  void _onRecords() {
    if (!mounted) return;
    if (_selected != null && !widget.store.records.any((r) => r.id == _selected!.id)) {
      _selected = null;
    }
    setState(() {});
    _fitOnceForPark();
  }

  List<LatLng> get _points => [
        for (final r in widget.store.records) ?r.point,
      ];

  /// Fit the view to the records the first time they arrive for a park.
  void _fitOnceForPark() {
    final org = widget.store.orgId;
    if (!_mapReady || org == null || _fittedFor == org || widget.store.loading) return;
    _fittedFor = org;
    _fitToRecords();
  }

  void _fitToRecords() {
    final pts = _points;
    if (pts.isEmpty || !_mapReady) return;
    _map.fitCamera(CameraFit.coordinates(
      coordinates: pts,
      padding: const EdgeInsets.fromLTRB(48, 96, 48, 160),
      maxZoom: 17,
    ));
  }

  Future<void> _showMe() async {
    final me = _me ??= (LocationTracker(keepBest: false)..addListener(_onMe));
    _followMe = true;
    if (me.best != null && _mapReady) {
      _map.move(LatLng(me.best!.latitude, me.best!.longitude), _zoomForMe());
    }
    await me.start();
    if (!mounted) return;
    final problem = me.problem;
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(switch (problem) {
          LocationProblem.serviceDisabled => 'Location is switched off on this phone.',
          LocationProblem.denied => 'The app may not use your location.',
          LocationProblem.deniedForever =>
            'Location is blocked for this app. Allow it in the app\'s settings.',
          LocationProblem.failed => 'Your location could not be determined.',
        }),
      ));
    }
  }

  double _zoomForMe() => _map.camera.zoom < 15 ? 16 : _map.camera.zoom;

  void _onMe() {
    if (!mounted) return;
    final fix = _me?.best;
    if (fix != null && _followMe && _mapReady) {
      _followMe = false; // centre once; after that the person pans freely
      _map.move(LatLng(fix.latitude, fix.longitude), _zoomForMe());
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.orgContext,
      builder: (context, _) {
        final park = widget.orgContext.activePark;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Map'),
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
          body: _body(context),
        );
      },
    );
  }

  Widget _body(BuildContext context) {
    final store = widget.store;
    final records = store.records;
    final styles = {
      for (final r in records) r.id: widget.symbology.styleOf(r, _colouring),
    };
    final mapped = records.where((r) => r.point != null).toList();
    // The selected record is drawn last, i.e. on top.
    if (_selected != null) {
      mapped.sort((a, b) => (a.id == _selected!.id ? 1 : 0) - (b.id == _selected!.id ? 1 : 0));
    }
    final fix = _me?.best;

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _fallbackCentre,
            initialZoom: 7,
            maxZoom: 21,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onTap: (_, _) => setState(() => _selected = null),
            onMapReady: () {
              _mapReady = true;
              _fitOnceForPark();
            },
          ),
          children: [
            _basemap.layer(),
            PolygonLayer(polygons: [
              for (final r in records)
                for (final ring in r.polygons)
                  Polygon(
                    points: ring,
                    color: styles[r.id]!.fill.withValues(alpha: 0.2),
                    borderColor: styles[r.id]!.fill,
                    borderStrokeWidth: 2,
                  ),
            ]),
            if (fix != null) ...[
              if (fix.accuracyM != null)
                CircleLayer(circles: [
                  CircleMarker(
                    point: LatLng(fix.latitude, fix.longitude),
                    radius: fix.accuracyM!,
                    useRadiusInMeter: true,
                    color: const Color(0x332A78D6),
                    borderColor: const Color(0x882A78D6),
                    borderStrokeWidth: 1,
                  ),
                ]),
              MarkerLayer(markers: [
                Marker(
                  point: LatLng(fix.latitude, fix.longitude),
                  width: 20,
                  height: 20,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF2A78D6),
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 3)],
                    ),
                  ),
                ),
              ]),
            ],
            MarkerLayer(markers: [
              for (final r in mapped)
                Marker(
                  point: r.point!,
                  // The hit target is bigger than the mark (dataviz rule).
                  width: 44,
                  height: 44,
                  child: GestureDetector(
                    onTap: () => setState(() => _selected = r),
                    child: Center(
                      child: RecordMarker(
                        style: styles[r.id]!,
                        diameter: _selected?.id == r.id ? 30 : 22,
                        selected: _selected?.id == r.id,
                        dimmed: _highlight != null && styles[r.id]!.label != _highlight,
                      ),
                    ),
                  ),
                ),
            ]),
            _basemap.attributionWidget(),
          ],
        ),
        if (store.loading)
          const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator()),
        Positioned(
          top: 12,
          left: 12,
          right: 68,
          child: Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 2,
              borderRadius: BorderRadius.circular(24),
              color: Theme.of(context).colorScheme.surface,
              child: SegmentedButton<MapColouring>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: MapColouring.family, label: Text('Family')),
                  ButtonSegment(value: MapColouring.status, label: Text('Status')),
                ],
                selected: {_colouring},
                onSelectionChanged: (s) => setState(() {
                  _colouring = s.first;
                  _highlight = null;
                }),
              ),
            ),
          ),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: Column(children: [
            BasemapButton(value: _basemap, onChanged: (b) => setState(() => _basemap = b)),
            const SizedBox(height: 10),
            MapIconButton(
              icon: Icons.fit_screen_outlined,
              tooltip: 'Show all records',
              onPressed: mapped.isEmpty ? null : _fitToRecords,
            ),
            const SizedBox(height: 10),
            MapIconButton(
              icon: _me?.running == true ? Icons.my_location : Icons.location_searching,
              tooltip: 'Where am I',
              onPressed: _showMe,
            ),
          ]),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 28,
          child: _selected != null
              ? _SelectedCard(
                  record: _selected!,
                  style: styles[_selected!.id] ?? widget.symbology.styleOf(_selected!, _colouring),
                  onOpen: () => widget.onOpenRecord(_selected!.id),
                  onClose: () => setState(() => _selected = null),
                )
              : Align(
                  alignment: Alignment.bottomLeft,
                  child: _Legend(
                    entries: widget.symbology.legend(_colouring),
                    counts: _counts(records, styles),
                    highlight: _highlight,
                    unmapped: records.length - mapped.length,
                    truncated: store.truncated,
                    onTap: (label) =>
                        setState(() => _highlight = _highlight == label ? null : label),
                  ),
                ),
        ),
        if (!store.loading && records.isEmpty && store.error == null)
          const Center(
            child: Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No records in this park yet.'),
              ),
            ),
          ),
        if (store.error != null)
          Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('Could not load records:\n${store.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: store.reload, child: const Text('Try again')),
                ]),
              ),
            ),
          ),
      ],
    );
  }

  Map<String, int> _counts(List<RecordDigest> records, Map<String, MarkerStyle> styles) {
    final counts = <String, int>{};
    for (final r in records) {
      final label = styles[r.id]!.label;
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return counts;
  }
}

/// The legend: every category the current colouring can produce, in a fixed
/// order, with how many records fall into it. Tapping one highlights it.
class _Legend extends StatelessWidget {
  const _Legend({
    required this.entries,
    required this.counts,
    required this.highlight,
    required this.onTap,
    required this.unmapped,
    required this.truncated,
  });

  final List<MarkerStyle> entries;
  final Map<String, int> counts;
  final String? highlight;
  final ValueChanged<String> onTap;
  final int unmapped;
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in entries)
              InkWell(
                onTap: () => onTap(e.label),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    RecordMarker(
                      style: e,
                      diameter: 16,
                      dimmed: highlight != null && highlight != e.label,
                      selected: highlight == e.label,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      e.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: highlight == e.label ? FontWeight.bold : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${counts[e.label] ?? 0}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                  ]),
                ),
              ),
            if (unmapped > 0 || truncated)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
                child: Text(
                  [
                    if (unmapped > 0) '$unmapped without a position',
                    if (truncated) 'newest ${RecordsStore.pageSize} only',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SelectedCard extends StatelessWidget {
  const _SelectedCard({
    required this.record,
    required this.style,
    required this.onOpen,
    required this.onClose,
  });

  final RecordDigest record;
  final MarkerStyle style;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final r = record;
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          RecordTile(
            record: r,
            style: style,
            onTap: onOpen,
            trailing: IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close),
              onPressed: onClose,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Expanded(
                child: Text(
                  [
                    if (r.uncertaintyM != null) '±${r.uncertaintyM!.round()} m',
                    if (r.recordedBy != null) r.recordedBy!,
                    if (r.sensitivity != 'open') r.sensitivity,
                  ].join(' · '),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              FilledButton.tonal(onPressed: onOpen, child: const Text('Open record')),
            ]),
          ),
        ]),
      ),
    );
  }
}
