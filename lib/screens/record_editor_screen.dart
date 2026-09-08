import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';
import '../models/models_extra.dart';

/// Create or edit one field record.
///
/// Two things about this screen are deliberate rather than provisional:
///
/// **Coordinates are typed in.** There is no `geolocator` in `pubspec.yaml`,
/// and adding a plugin is a separate decision with a separate permission story.
/// Typing them means the whole write path can be tested today. The GPS button
/// replaces the two fields when the capture flow lands; nothing else changes.
///
/// **The three determinations are shown separately and are not editable as a
/// unit.** A person can add *their own* determination; they cannot rewrite what
/// the on-device model or the online service said. That is the whole point —
/// those two rows are the thesis' measurement, and the database refuses an
/// update to them anyway (no UPDATE grant on `identifications`).
class RecordEditorScreen extends StatefulWidget {
  const RecordEditorScreen({super.key, required this.park, this.existingId});

  final Park park;

  /// null → creating a new record.
  final String? existingId;

  bool get isNew => existingId == null;

  @override
  State<RecordEditorScreen> createState() => _RecordEditorScreenState();
}

class _RecordEditorScreenState extends State<RecordEditorScreen> {
  final supabase = Supabase.instance.client;

  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _uncertainty = TextEditingController(text: '10');
  final _count = TextEditingController();
  final _habitat = TextEditingController();
  final _remarks = TextEditingController();

  DateTime _eventDate = DateTime.now();
  String _sensitivity = 'open';
  String _occurrenceStatus = 'present';

  List<ChecklistTaxon> _checklist = const [];
  ChecklistTaxon? _pickedTaxon;

  ObservationDetail? _existing;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _lat.dispose();
    _lon.dispose();
    _uncertainty.dispose();
    _count.dispose();
    _habitat.dispose();
    _remarks.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // The park's checklist is what the identification picker offers. Joining
      // through checklist_entries rather than reading `taxa` wholesale is the
      // point: an identification should be reachable only if the park expects
      // that taxon to occur.
      final rows = await supabase
          .from('checklist_entries')
          .select('tier, taxa!inner(id, scientific_name, taxon_rank, vernacular_name_de)')
          .eq('org_id', widget.park.orgId);
      final list = rows.map((r) => ChecklistTaxon.fromMap(r)).toList()
        ..sort((a, b) => a.scientificName.compareTo(b.scientificName));

      ObservationDetail? existing;
      if (!widget.isNew) {
        final one = await supabase
            .from('observations_wide')
            .select()
            .eq('id', widget.existingId!)
            .maybeSingle();
        if (one != null) existing = ObservationDetail.fromMap(one);
      }

      if (!mounted) return;
      setState(() {
        _checklist = list;
        _existing = existing;
        if (existing != null) {
          _lat.text = existing.latitude.toStringAsFixed(6);
          _lon.text = existing.longitude.toStringAsFixed(6);
          _uncertainty.text =
              (existing.coordinateUncertaintyM ?? 10).toStringAsFixed(0);
          _count.text = existing.individualCount?.toString() ?? '';
          _habitat.text = existing.habitat ?? '';
          _remarks.text = existing.remarks ?? '';
          _eventDate = existing.eventDate;
          _sensitivity = existing.sensitivity;
          _occurrenceStatus = existing.occurrenceStatus;
        }
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

  String? _validate() {
    final lat = double.tryParse(_lat.text.trim());
    final lon = double.tryParse(_lon.text.trim());
    if (lat == null || lat < -90 || lat > 90) {
      return 'Latitude must be a number between -90 and 90.';
    }
    if (lon == null || lon < -180 || lon > 180) {
      return 'Longitude must be a number between -180 and 180.';
    }
    if (double.tryParse(_uncertainty.text.trim()) == null) {
      return 'Coordinate uncertainty must be a number, in metres.';
    }
    // A determination is deliberately OPTIONAL. The intended workflow is
    // photograph first: capture the plant, let the on-device model and then the
    // online service propose names, and have a person confirm one later. A
    // record with no species yet is a normal state, not an incomplete one.
    return null;
  }

  Future<void> _save() async {
    final problem = _validate();
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    setState(() => _saving = true);
    try {
      final lat = double.parse(_lat.text.trim());
      final lon = double.parse(_lon.text.trim());
      final payload = <String, dynamic>{
        'org_id': widget.park.orgId,
        'event_date': _eventDate.toUtc().toIso8601String(),
        // PostGIS accepts EWKT on insert through PostgREST.
        'geometry': 'SRID=4326;POINT($lon $lat)',
        'coordinate_uncertainty_m': double.parse(_uncertainty.text.trim()),
        'georeference_protocol': 'entered by hand',
        'individual_count': int.tryParse(_count.text.trim()),
        'habitat': _habitat.text.trim().isEmpty ? null : _habitat.text.trim(),
        'occurrence_remarks':
            _remarks.text.trim().isEmpty ? null : _remarks.text.trim(),
        'sensitivity': _sensitivity,
        'occurrence_status': _occurrenceStatus,
        'country_code': 'AT',
      };

      if (widget.isNew) {
        payload['recorded_by_user_id'] = supabase.auth.currentUser!.id;
        // dwc:recordedBy is a text snapshot taken at capture, so the record
        // keeps its attribution even if the account is later removed.
        payload['recorded_by'] =
            supabase.auth.currentUser?.email ?? 'unknown';
        payload['client_created_at'] = DateTime.now().toUtc().toIso8601String();

        final inserted =
            await supabase.from('observations').insert(payload).select('id').single();
        final newId = inserted['id'] as String;

        // The determination is a separate, append-only fact — never a column on
        // the observation — so it is a second call. If it fails the record is
        // still saved and simply has no species yet, which is a valid state.
        // Say exactly that rather than reporting a blanket failure: an earlier
        // version showed an error while the record had in fact been created,
        // which is how you end up not trusting your own app.
        if (_pickedTaxon != null) {
          try {
            await _recordDetermination(newId, _pickedTaxon!);
          } catch (e) {
            if (!mounted) return;
            Navigator.of(context).pop(true);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              duration: const Duration(seconds: 6),
              content: Text('Record saved, but the species could not be '
                  'attached: $e'),
            ));
            return;
          }
        }
      } else {
        payload['updated_at'] = DateTime.now().toUtc().toIso8601String();
        await supabase
            .from('observations')
            .update(payload)
            .eq('id', widget.existingId!);

        // Editing the record does not touch its determinations. Choosing a
        // name adds a new one; it never overwrites what the models said.
        if (_pickedTaxon != null) {
          await _recordDetermination(widget.existingId!, _pickedTaxon!);
        }
      }

      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.isNew ? 'Record saved.' : 'Record updated.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Append a person's determination. Never overwrites the on-device or online
  /// answer — those are rows of their own in `identifications`, and the
  /// database has no UPDATE grant on that table for any client.
  Future<void> _recordDetermination(String observationId, ChecklistTaxon t) {
    return supabase.rpc('record_identification', params: {
      'p_observation_id': observationId,
      'p_source': 'human',
      'p_taxon_id': t.taxonId,
      'p_scientific_name': t.scientificName,
      'p_rank': t.rank,
      'p_accept': true,
    });
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _eventDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null) return;
    if (!mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_eventDate),
    );
    setState(() {
      _eventDate = DateTime(d.year, d.month, d.day, t?.hour ?? _eventDate.hour,
          t?.minute ?? _eventDate.minute);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'New record' : 'Edit record'),
        actions: [
          TextButton(
            onPressed: _saving || _loading ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Could not load: $_error'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('Recording for ${widget.park.name}',
                        style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 16),

                    // ---------------------------------------- what -------
                    _header(context, 'What did you see?'),
                    // TODO(capture-flow): this is where the PHOTOGRAPH goes.
                    // The intended workflow is photograph first -> on-device
                    // model proposes -> online service proposes -> a person
                    // confirms. This dropdown is the stand-in until the camera
                    // and the IdentificationService implementations exist, and
                    // it stays afterwards as the manual fallback for a record
                    // made without a usable photo.
                    Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        leading: const Icon(Icons.photo_camera_outlined),
                        title: const Text('Photograph'),
                        subtitle: const Text(
                            'Not built yet. When it is, the models propose a '
                            'name from the photo and a person confirms it.'),
                        enabled: false,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<ChecklistTaxon>(
                      initialValue: _pickedTaxon,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Species or genus (optional)',
                        border: OutlineInputBorder(),
                        helperText: 'Optional. Leave empty to record now and '
                            'determine later. A genus is a valid answer.',
                      ),
                      items: _checklist
                          .map((t) => DropdownMenuItem(
                                value: t,
                                child: Text(
                                  '${t.label}${t.rank == 'genus' ? '  (genus)' : ''}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => _pickedTaxon = v),
                    ),
                    if (!widget.isNew)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Leave empty to keep the current determination. '
                          'Choosing one adds a new determination — it does not '
                          'overwrite the old one.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 12),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'present', label: Text('Present')),
                        ButtonSegment(value: 'absent', label: Text('Absent')),
                      ],
                      selected: {_occurrenceStatus},
                      onSelectionChanged: (s) =>
                          setState(() => _occurrenceStatus = s.first),
                    ),
                    if (_occurrenceStatus == 'absent')
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'An absence only means something inside a survey — '
                          '"I looked here, for this long, and did not find it". '
                          'Survey capture is not built yet, so the database will '
                          'reject this.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),

                    // ---------------------------------------- where ------
                    _header(context, 'Where and when'),
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: _lat,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true, signed: true),
                          decoration: const InputDecoration(
                            labelText: 'Latitude',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _lon,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true, signed: true),
                          decoration: const InputDecoration(
                            labelText: 'Longitude',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    const Text(
                      'Typed in for now — there is no GPS plugin yet. '
                      'testPark_A sits around 47.15 N, 12.75 E.',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _uncertainty,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Coordinate uncertainty (m)',
                        border: OutlineInputBorder(),
                        helperText: 'dwc:coordinateUncertaintyInMeters. '
                            'GBIF asks for it; record what the device reports, '
                            'never a constant.',
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event),
                      title: const Text('Observed at'),
                      subtitle: Text(_eventDate.toString().substring(0, 16)),
                      trailing: const Icon(Icons.edit_calendar),
                      onTap: _pickDate,
                    ),

                    // ---------------------------------------- detail -----
                    _header(context, 'Detail'),
                    TextField(
                      controller: _count,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Individual count',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _habitat,
                      decoration: const InputDecoration(
                        labelText: 'Habitat',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _remarks,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        labelText: 'Remarks',
                        border: OutlineInputBorder(),
                      ),
                    ),

                    // ---------------------------------------- publish ----
                    _header(context, 'Publication'),
                    DropdownButtonFormField<String>(
                      initialValue: _sensitivity,
                      decoration: const InputDecoration(
                        labelText: 'Sensitivity',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'open', child: Text('Open — publishable as recorded')),
                        DropdownMenuItem(
                            value: 'generalised',
                            child: Text('Generalised — blur on export')),
                        DropdownMenuItem(
                            value: 'withheld',
                            child: Text('Withheld — never leaves the park')),
                      ],
                      onChanged: (v) => setState(() => _sensitivity = v ?? 'open'),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'The stored coordinate always keeps full precision. '
                      'Generalisation happens only when data is exported.',
                      style: TextStyle(fontSize: 12),
                    ),

                    // ------------------------------- the three guesses ---
                    if (_existing != null) ...[
                      _header(context, 'Determinations'),
                      _guessTile(context, 'On-device model',
                          _existing!.offlineGuess, _existing!.offlineRank,
                          _existing!.offlineConfidence, Icons.smartphone),
                      _guessTile(context, 'Online service',
                          _existing!.onlineGuess, _existing!.onlineRank,
                          _existing!.onlineConfidence, Icons.cloud_outlined),
                      _guessTile(context, 'Person',
                          _existing!.expertGuess, _existing!.expertRank,
                          null, Icons.verified_outlined,
                          by: _existing!.expertBy),
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'All determinations are kept. A new one supersedes the '
                          'old as the accepted answer; none is ever overwritten.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                  ],
                ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 12),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 1.2,
              ),
        ),
      );

  Widget _guessTile(BuildContext context, String label, String? name,
      String? rank, double? confidence, IconData icon,
      {String? by}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(icon,
          color: name == null
              ? Theme.of(context).colorScheme.outline
              : Theme.of(context).colorScheme.primary),
      title: Text(name ?? '— not yet',
          style: TextStyle(
              fontStyle: name == null ? FontStyle.normal : FontStyle.italic)),
      subtitle: Text([
        label,
        if (rank != null && rank != 'species') '$rank level',
        if (by != null) by,
      ].join(' · ')),
      trailing: confidence == null
          ? null
          : Text('${(confidence * 100).round()}%'),
    );
  }
}
