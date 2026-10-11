import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../domain/plants/plant_families.dart';
import '../ml/offline_model.dart';
import '../models/models.dart';
import '../models/models_extra.dart';
import '../models/records.dart';
import '../services/identification_service.dart';
import '../services/location_service.dart';
import '../services/observation_payloads.dart';
import '../services/observation_repository.dart';
import '../services/offline_model_identification_service.dart';
import '../services/prepared_photo.dart';
import '../services/records_store.dart';
import '../widgets/basemaps.dart';
import '../widgets/framed_photo.dart';
import '../widgets/record_tile.dart';
import '../widgets/species_picker.dart';
import '../widgets/suggestion_card.dart';
import 'capture_screen.dart';
import 'location_picker_screen.dart';

/// Opens the record screen and refreshes the shared records afterwards if
/// anything was saved.
Future<void> openRecordEditor(
  BuildContext context, {
  required Park park,
  required RecordsStore store,
  String? recordId,
}) async {
  final changed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(builder: (_) => RecordEditorScreen(park: park, existingId: recordId)),
  );
  if (changed == true) await store.reload();
}

/// One field record — the capture flow (ADR 011).
///
/// A NEW record starts with the camera: photograph → the on-device model
/// proposes (top-1, top-5 on tap) → a person may confirm, or leave it for
/// later → position, time and details → save. The position is followed from
/// the moment the screen opens, so the receiver has settled by the time the
/// photo is taken.
///
/// An EXISTING record shows its photo and every determination ever made for
/// it. The determinations are not editable: a person can ADD one, never change
/// what the model or a colleague said — the database refuses that anyway (no
/// UPDATE grant on `identifications`), because the offline-vs-online
/// comparison is measured from exactly those rows.
class RecordEditorScreen extends StatefulWidget {
  const RecordEditorScreen({super.key, required this.park, this.existingId});

  final Park park;

  /// null → a new record.
  final String? existingId;

  bool get isNew => existingId == null;

  @override
  State<RecordEditorScreen> createState() => _RecordEditorScreenState();
}

class _RecordEditorScreenState extends State<RecordEditorScreen> {
  final _repo = ObservationRepository();
  final _lifeStage = TextEditingController();
  final _habitat = TextEditingController();
  final _remarks = TextEditingController();
  final _manualUncertainty = TextEditingController();

  List<ChecklistTaxon> _checklist = const [];
  String? _checklistError;
  PlantFamilies? _families;

  // --- a new record ---------------------------------------------------------
  LocationTracker? _tracker;
  PreparedPhoto? _photo;
  String? _organ;
  IdentificationResult? _suggestion;
  bool _identifying = false;
  String? _identifyError;
  DateTime? _suggestedAt;
  String? _suggestionRemarks;
  bool _modelHashOk = true;
  ChecklistTaxon? _determination;

  // --- an existing record ---------------------------------------------------
  RecordDetail? _detail;
  bool _loading = false;
  String? _loadError;

  // --- both -------------------------------------------------------------------
  /// A position set by hand on the map (overrides GPS for a new record).
  LatLng? _manualPoint;
  DateTime _eventDate = DateTime.now();
  int? _count;
  String _sensitivity = 'open';
  bool _saving = false;

  /// Set just before the screen leaves itself (after a save), so the PopScope
  /// lets that pop through instead of asking whether to discard.
  bool _leaving = false;

  void _leave(bool result) {
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  @override
  void initState() {
    super.initState();
    _loadReferenceData();
    if (widget.isNew) {
      _tracker = LocationTracker()..addListener(_rebuild);
      WidgetsBinding.instance.addPostFrameCallback((_) => _beginNewRecord());
    } else {
      _loadExisting();
    }
  }

  /// Photograph first: the camera opens as soon as the screen exists — after
  /// the position has started, so the receiver settles while the photo is
  /// framed. The two are started one after the other because Android handles
  /// one permission request at a time and answers a second one, made while the
  /// first is on screen, as cancelled ("Can request only one set of
  /// permissions at a time"). On the very first record the person sees the
  /// location prompt, then the camera's.
  Future<void> _beginNewRecord() async {
    await _tracker!.start();
    if (mounted) await _takePhoto();
  }

  @override
  void dispose() {
    _tracker?.removeListener(_rebuild);
    _tracker?.dispose();
    _lifeStage.dispose();
    _habitat.dispose();
    _remarks.dispose();
    _manualUncertainty.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _loadReferenceData() async {
    PlantFamilies.load().then((f) {
      if (mounted) setState(() => _families = f);
    }).catchError((_) {});
    try {
      final list = await _repo.checklist(widget.park.orgId);
      if (mounted) setState(() => _checklist = list);
    } catch (e) {
      if (mounted) setState(() => _checklistError = 'The park checklist could not be loaded ($e).');
    }
  }

  Future<void> _loadExisting() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final d = await _repo.loadDetail(widget.existingId!);
      if (!mounted) return;
      final o = d.observation;
      setState(() {
        _detail = d;
        _eventDate = o.eventDate;
        _count = o.individualCount;
        _sensitivity = o.sensitivity;
        _lifeStage.text = o.lifeStage ?? '';
        _habitat.text = o.habitat ?? '';
        _remarks.text = o.remarks ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loading = false;
      });
    }
  }

  // ------------------------------------------------------------------ photo --

  Future<void> _takePhoto() async {
    final captured = await Navigator.of(context).push<CapturedPhoto>(
      MaterialPageRoute(builder: (_) => const CaptureScreen(), fullscreenDialog: true),
    );
    if (captured == null || !mounted) return;
    final PreparedPhoto prepared;
    try {
      prepared = PreparedPhoto.prepare(captured.bytes,
          origin: captured.origin, capturedAt: captured.capturedAt);
    } on PhotoRejected catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), duration: const Duration(seconds: 8)));
      return;
    }
    setState(() {
      _photo = prepared;
      _suggestion = null;
      _identifyError = null;
    });
    if (prepared.hadGps && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('This photo carried a GPS position. It was removed before '
            'anything else happened to the photo.'),
      ));
    }
    _identify(prepared);
  }

  Future<void> _identify(PreparedPhoto photo) async {
    setState(() {
      _identifying = true;
      _identifyError = null;
    });
    try {
      final model = await OfflineModel.shared();
      final result = await const OfflineModelIdentificationService()
          .identify([IdentificationInput(bytes: photo.bytes, organ: _organ)]);
      final at = DateTime.now();
      if (!mounted || !identical(photo, _photo)) return;
      setState(() {
        _suggestion = result;
        _suggestedAt = at;
        _suggestionRemarks = offlineRemarks(modelSha256: model.modelSha256, input: photo.info);
        _modelHashOk = model.modelHashMatches;
        _identifying = false;
      });
      // Taxa and provenance need the network; the answer is shown without
      // waiting for them, and stored verbatim if they never arrive.
      final resolved = await _repo.resolveTaxa(result.candidates);
      final versionId = await _repo.modelVersionId(model.modelSha256);
      if (!mounted || !identical(photo, _photo)) return;
      setState(() {
        _suggestion = IdentificationResult(
          source: result.source,
          provider: result.provider,
          candidates: resolved,
          checklistMasked: result.checklistMasked,
          modelVersionId: versionId,
        );
      });
    } catch (e) {
      if (!mounted || !identical(photo, _photo)) return;
      setState(() {
        _identifying = false;
        _identifyError = 'The on-device model could not run: $e';
      });
    }
  }

  ChecklistTaxon? _checklistMatch(String? taxonId) {
    if (taxonId == null) return null;
    for (final t in _checklist) {
      if (t.taxonId == taxonId) return t;
    }
    return null;
  }

  List<SuggestionLine> _linesFromCandidates(List<IdentificationCandidate> cs) => [
        for (final c in cs)
          SuggestionLine(
            name: c.scientificName,
            score: c.score,
            rank: c.rank,
            detail: _families?.familyOf(c.scientificName),
            match: _checklistMatch(c.taxonId),
          ),
      ];

  List<SuggestionLine> _linesFromStored(IdentificationEntry e) {
    if (e.topK.isNotEmpty) {
      return [
        for (final k in e.topK)
          SuggestionLine(
            name: k.name,
            score: k.score,
            rank: k.rank,
            detail: _families?.familyOf(k.name),
            match: _checklistMatch(k.taxonId),
          ),
      ];
    }
    final s = e.displayScore;
    if (e.name == null || s == null) return const [];
    return [
      SuggestionLine(
        name: e.name!,
        score: s.value,
        rank: e.rank,
        detail: e.family ?? _families?.familyOf(e.name),
        match: _checklistMatch(e.taxonId),
      ),
    ];
  }

  // --------------------------------------------------------------- position --

  ({double lat, double lon, double? uncertainty, String protocol})? get _position {
    final manual = _manualPoint;
    if (manual != null) {
      return (
        lat: manual.latitude,
        lon: manual.longitude,
        uncertainty: double.tryParse(_manualUncertainty.text.trim()),
        protocol: mapProtocol,
      );
    }
    final fix = _tracker?.best;
    if (fix == null) return null;
    return (lat: fix.latitude, lon: fix.longitude, uncertainty: fix.accuracyM, protocol: gpsProtocol);
  }

  Future<void> _setOnMap() async {
    final o = _detail?.observation;
    final fix = _tracker?.best;
    final start = _manualPoint ??
        (fix != null
            ? LatLng(fix.latitude, fix.longitude)
            : o != null
                ? LatLng(o.latitude, o.longitude)
                : const LatLng(47.6, 13.3));
    final picked = await Navigator.of(context).push<LatLng>(MaterialPageRoute(
      builder: (_) => LocationPickerScreen(
        initial: start,
        initialZoom: (fix != null || o != null || _manualPoint != null) ? 17 : 7,
      ),
    ));
    if (picked == null || !mounted) return;
    setState(() {
      _manualPoint = picked;
      _manualUncertainty.clear();
    });
    _tracker?.stop();
  }

  void _backToGps() {
    setState(() => _manualPoint = null);
    _tracker?.refresh();
  }

  // ------------------------------------------------------------------- time --

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _eventDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_eventDate));
    setState(() {
      _eventDate = DateTime(d.year, d.month, d.day, t?.hour ?? _eventDate.hour,
          t?.minute ?? _eventDate.minute);
    });
  }

  // ------------------------------------------------------------ determination --

  List<ChecklistTaxon> get _suggestedOnChecklist {
    final fromNew = _suggestion?.candidates.map((c) => c.taxonId);
    final fromStored = _detail?.latest('offline_model')?.topK.map((k) => k.taxonId);
    final out = <ChecklistTaxon>[];
    for (final id in [...?fromNew, ...?fromStored]) {
      final t = _checklistMatch(id);
      if (t != null && !out.contains(t)) out.add(t);
    }
    return out;
  }

  Future<ChecklistTaxon?> _pick() => showSpeciesPicker(
        context,
        checklist: _checklist,
        suggested: _suggestedOnChecklist,
        parkName: widget.park.name,
      );

  /// For an existing record a determination is its own act, written at once —
  /// not part of "Save changes", and never an edit of an earlier one.
  Future<void> _addDetermination(ChecklistTaxon t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add determination'),
        content: Text('Determine this record as ${t.scientificName}?\n\n'
            'This adds a new determination and makes it the accepted one. Every '
            'earlier determination — the model\'s included — is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _repo.addDetermination(widget.existingId!, t);
      _changed = true;
      await _loadExisting();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('The determination could not be added: $e')));
    }
  }

  /// Something was written while the screen was open (a determination), so
  /// the list behind it must refresh even without "Save changes".
  bool _changed = false;

  // ------------------------------------------------------------------- save --

  bool get _dirty =>
      widget.isNew && (_photo != null || _determination != null || _remarks.text.isNotEmpty);

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (widget.isNew) {
        final pos = _position!;
        final out = await _repo.create(RecordDraft(
          orgId: widget.park.orgId,
          eventDate: _eventDate,
          latitude: pos.lat,
          longitude: pos.lon,
          uncertaintyM: pos.uncertainty,
          georeferenceProtocol: pos.protocol,
          sensitivity: _sensitivity,
          individualCount: _count,
          lifeStage: _lifeStage.text,
          habitat: _habitat.text,
          remarks: _remarks.text,
          photo: _photo,
          organ: _organ,
          suggestion: _suggestion,
          suggestedAt: _suggestedAt,
          suggestionRemarks: _suggestionRemarks,
          modelVersionId: _suggestion?.modelVersionId,
          determination: _determination,
        ));
        if (!mounted) return;
        _leave(true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: Duration(seconds: out.complete ? 4 : 10),
          content: Text(out.complete
              ? 'Record saved.'
              : 'Record saved, but: ${out.problems.join(' ')}'),
        ));
      } else {
        final manual = _manualPoint;
        await _repo.update(widget.existingId!, {
          ...descriptiveFields(
            eventDate: _eventDate,
            sensitivity: _sensitivity,
            individualCount: _count,
            lifeStage: _lifeStage.text,
            habitat: _habitat.text,
            remarks: _remarks.text,
          ),
          if (manual != null)
            ...locationFields(
              latitude: manual.latitude,
              longitude: manual.longitude,
              uncertaintyM: double.tryParse(_manualUncertainty.text.trim()),
              georeferenceProtocol: mapProtocol,
            ),
        });
        if (!mounted) return;
        _leave(true);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Record updated.')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this record?'),
        content: const Text('The photo and everything entered so far will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------------------ build --

  @override
  Widget build(BuildContext context) {
    return PopScope<bool>(
      // Leaving is intercepted when there is unsaved work to confirm, and when
      // a determination was written, so the list behind refreshes whichever
      // way the screen is left (back button or system gesture).
      canPop: _leaving || (!_dirty && !_saving && !_changed),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _saving) return;
        if (_dirty && !await _confirmDiscard()) return;
        if (context.mounted) _leave(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: () => Navigator.maybePop(context, _changed)),
          title: Text(widget.isNew ? 'New record' : 'Record'),
        ),
        body: _body(context),
        bottomNavigationBar: _saveBar(context),
      ),
    );
  }

  Widget? _saveBar(BuildContext context) {
    if (!widget.isNew && _detail == null) return null;
    final canSave = !_saving && (!widget.isNew || _position != null);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.isNew && _position == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('Waiting for a position — or set it on the map.',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: canSave ? _save : null,
              icon: _saving
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(widget.isNew ? 'Save record' : 'Save changes'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Could not load the record:\n$_loadError', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _loadExisting, child: const Text('Try again')),
          ]),
        ),
      );
    }
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('Recording for ${widget.park.name}',
            style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        ..._photoSection(context),
        const SizedBox(height: 12),
        ..._identificationSection(context),
        _header(context, 'Where'),
        _locationCard(context),
        _header(context, 'When'),
        _whenTile(context),
        _header(context, 'How many'),
        _countRow(context),
        const SizedBox(height: 8),
        _detailsTile(context),
        _header(context, 'Sensitivity'),
        _sensitivityControl(context),
        if (!widget.isNew) ..._historySection(context),
      ],
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 10),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 1.2,
              ),
        ),
      );

  // --- photo -----------------------------------------------------------------

  List<Widget> _photoSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!widget.isNew) {
      final p = _detail?.photo;
      if (p == null) {
        return [
          _emptyPhoto(context, 'No photo with this record.', showButtons: false),
        ];
      }
      if (p.url == null) {
        return [
          _emptyPhoto(context, 'The photo file could not be found in Storage.', showButtons: false),
        ];
      }
      final image = ResizeImage(NetworkImage(p.url!), width: 1440);
      return [
        FramedPhoto(
          image: image,
          onTap: () => _viewPhoto(NetworkImage(p.url!)),
        ),
        if (p.organ != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Shows: ${_organLabels[p.organ] ?? p.organ}',
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
      ];
    }

    final photo = _photo;
    if (photo == null) return [_emptyPhoto(context, 'No photo yet.', showButtons: true)];
    return [
      Stack(children: [
        FramedPhoto(
          image: ResizeImage(MemoryImage(photo.bytes), width: 1440),
          onTap: () => _viewPhoto(MemoryImage(photo.bytes)),
        ),
        Positioned(
          right: 8,
          top: 8,
          child: FilledButton.tonalIcon(
            onPressed: _takePhoto,
            icon: const Icon(Icons.photo_camera_outlined, size: 18),
            label: const Text('Retake'),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Text(
        'The bright square is what the on-device model saw.'
        '${photo.origin == PhotoOrigin.gallery ? ' From the gallery.' : ''}',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 10),
      Text('What does the photo show?', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final e in _organLabels.entries)
            ChoiceChip(
              label: Text(e.value),
              selected: _organ == e.key,
              onSelected: (on) => setState(() => _organ = on ? e.key : null),
            ),
        ],
      ),
    ];
  }

  /// `observation_media.organ` values (its CHECK) and how they read.
  static const _organLabels = {
    'leaf': 'Leaf',
    'flower': 'Flower',
    'fruit': 'Fruit',
    'bark': 'Bark',
    'habit': 'Whole plant',
    'other': 'Other',
  };

  Widget _emptyPhoto(BuildContext context, String text, {required bool showButtons}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 200,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.local_florist_outlined, size: 40, color: scheme.outline),
          const SizedBox(height: 8),
          Text(text, style: TextStyle(color: scheme.onSurfaceVariant)),
          if (showButtons) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _takePhoto,
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Take photo'),
            ),
            const SizedBox(height: 4),
            Text('A record without a photo is fine too.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
      ),
    );
  }

  void _viewPhoto(ImageProvider image) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PhotoViewerScreen(image: image),
      ));

  // --- identification and determination ---------------------------------------

  List<Widget> _identificationSection(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!widget.isNew) {
      final d = _detail;
      if (d == null) return const [];
      final offline = d.latest('offline_model');
      final online = d.latest('online_service');
      final accepted = d.accepted;
      return [
        if (offline != null) ...[
          SuggestionCard(
            title: 'On-device model',
            icon: Icons.smartphone,
            when: formatDateTime(offline.dateIdentified),
            lines: _linesFromStored(offline),
            calibrated: offline.topK.isEmpty && offline.confidenceCalibrated != null,
          ),
          const SizedBox(height: 8),
        ],
        if (online != null) ...[
          SuggestionCard(
            title: 'Online service${online.provider == null ? '' : ' (${online.provider})'}',
            icon: Icons.cloud_outlined,
            when: formatDateTime(online.dateIdentified),
            lines: _linesFromStored(online),
            calibrated: online.topK.isEmpty && online.confidenceCalibrated != null,
          ),
          const SizedBox(height: 8),
        ],
        _header(context, 'Determination'),
        if (accepted != null)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(accepted.isMachine ? Icons.auto_awesome : Icons.verified_outlined,
                color: scheme.primary),
            title: Text(accepted.name ?? '—', style: const TextStyle(fontStyle: FontStyle.italic)),
            subtitle: Text([
              accepted.isMachine
                  ? 'Accepted machine suggestion'
                  : 'Confirmed${accepted.identifiedBy == null ? '' : ' by ${accepted.identifiedBy}'}',
              formatDateTime(accepted.dateIdentified),
            ].join(' · ')),
          )
        else
          Text('Not determined yet.', style: TextStyle(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _checklist.isEmpty
                ? null
                : () async {
                    final t = await _pick();
                    if (t != null) await _addDetermination(t);
                  },
            icon: const Icon(Icons.how_to_reg_outlined),
            label: Text(accepted == null ? 'Determine' : 'Change determination'),
          ),
        ),
        if (_checklistError != null) _note(context, _checklistError!),
      ];
    }

    final s = _suggestion;
    return [
      if (_photo != null) ...[
        SuggestionCard(
          title: 'On-device model',
          icon: Icons.smartphone,
          busy: _identifying,
          error: _identifyError,
          lines: s == null ? const [] : _linesFromCandidates(s.candidates),
          calibrated: false,
          selectedTaxonId: _determination?.taxonId,
          onUse: (t) => setState(() => _determination = t),
        ),
        if (!_modelHashOk)
          _note(context,
              'The bundled model file does not match the thesis artefact (SHA-256). '
              'Its suggestions are stored with the hash it actually has.'),
      ],
      _header(context, 'Your determination'),
      if (_determination != null)
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: scheme.primaryContainer,
          child: ListTile(
            leading: Icon(Icons.how_to_reg, color: scheme.onPrimaryContainer),
            title: Text(_determination!.scientificName,
                style: TextStyle(fontStyle: FontStyle.italic, color: scheme.onPrimaryContainer)),
            subtitle: Text('Saved as confirmed by you',
                style: TextStyle(color: scheme.onPrimaryContainer)),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: Icon(Icons.close, color: scheme.onPrimaryContainer),
              onPressed: () => setState(() => _determination = null),
            ),
          ),
        )
      else
        Text(
          'Not determined yet — that is fine. The model\'s suggestion is saved '
          'either way, and a person can determine the record later.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _checklist.isEmpty
              ? null
              : () async {
                  final t = await _pick();
                  if (t != null) setState(() => _determination = t);
                },
          icon: const Icon(Icons.list_alt),
          label: const Text('Choose from the park checklist'),
        ),
      ),
      if (_checklistError != null) _note(context, _checklistError!),
    ];
  }

  Widget _note(BuildContext context, String text, {IconData icon = Icons.info_outline}) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      ]),
    );
  }

  // --- where ------------------------------------------------------------------

  Widget _locationCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final manual = _manualPoint;
    final tracker = _tracker;
    final fix = tracker?.best;
    final o = _detail?.observation;

    final LatLng? point = manual ??
        (fix != null ? LatLng(fix.latitude, fix.longitude) : null) ??
        (o != null ? LatLng(o.latitude, o.longitude) : null);
    final double? radius = manual != null
        ? double.tryParse(_manualUncertainty.text.trim())
        : fix?.accuracyM ?? (manual == null && fix == null ? o?.coordinateUncertaintyM : null);

    final lines = <Widget>[];
    if (manual != null) {
      lines.addAll([
        Text('Set by hand on the map', style: theme.textTheme.titleMedium),
        Text(_coords(manual), style: _tabular(theme)),
        const SizedBox(height: 8),
        TextField(
          controller: _manualUncertainty,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Uncertainty in metres (optional)',
            helperText: 'Your estimate of how far off the point may be. '
                'Left empty, it is stored as unknown.',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ]);
    } else if (widget.isNew) {
      final problem = tracker?.problem;
      if (problem != null) {
        lines.addAll([
          Text(switch (problem) {
            LocationProblem.serviceDisabled => 'Location is switched off on this phone.',
            LocationProblem.denied => 'The app may not use your location.',
            LocationProblem.deniedForever => 'Location is blocked for this app.',
            LocationProblem.failed => 'Your position could not be determined.',
          }, style: theme.textTheme.titleMedium),
          if (tracker?.problemDetail != null)
            Text(tracker!.problemDetail!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            if (problem == LocationProblem.serviceDisabled)
              OutlinedButton(
                  onPressed: LocationTracker.openLocationSettings,
                  child: const Text('Location settings')),
            if (problem == LocationProblem.deniedForever)
              OutlinedButton(
                  onPressed: LocationTracker.openAppSettings, child: const Text('App settings')),
            OutlinedButton(onPressed: () => tracker?.start(), child: const Text('Try again')),
          ]),
        ]);
      } else if (fix == null) {
        lines.add(const Row(children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Finding your position…'),
        ]));
      } else {
        lines.addAll([
          Text(fix.accuracyM == null ? 'Accuracy unknown' : '±${fix.accuracyM!.round()} m',
              style: theme.textTheme.titleLarge?.copyWith(color: _accuracyColour(fix.accuracyM))),
          Text(_coords(LatLng(fix.latitude, fix.longitude)), style: _tabular(theme)),
          Text(
            tracker?.running == true
                ? 'Best fix so far — still improving while you stand here.'
                : 'Best fix.',
            style: theme.textTheme.bodySmall,
          ),
          if (fix.isMocked)
            _note(context, 'This position comes from a mock-location app.',
                icon: Icons.warning_amber),
        ]);
      }
      if (_photo?.origin == PhotoOrigin.gallery) {
        lines.add(_note(context,
            'The photo is from the gallery: the position is where you are NOW. '
            'If the photo was taken elsewhere, set the position on the map.',
            icon: Icons.warning_amber));
      }
    } else if (o != null) {
      lines.addAll([
        Text(
          o.coordinateUncertaintyM == null
              ? 'Uncertainty unknown'
              : '±${o.coordinateUncertaintyM!.round()} m',
          style: theme.textTheme.titleMedium,
        ),
        Text(_coords(LatLng(o.latitude, o.longitude)), style: _tabular(theme)),
        if (_detail?.georeferenceProtocol != null)
          Text(_detail!.georeferenceProtocol!, style: theme.textTheme.bodySmall),
      ]);
    }

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (point != null) _miniMap(point, radius),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Wrap(spacing: 4, children: [
            if (widget.isNew && manual == null && fix != null)
              TextButton.icon(
                onPressed: () => tracker?.refresh(),
                icon: const Icon(Icons.refresh),
                label: const Text('Locate again'),
              ),
            if (widget.isNew && manual != null)
              TextButton.icon(
                onPressed: _backToGps,
                icon: const Icon(Icons.gps_fixed),
                label: const Text('Use GPS'),
              ),
            TextButton.icon(
              onPressed: _setOnMap,
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: Text(widget.isNew ? 'Set on map' : 'Change on map'),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _miniMap(LatLng point, double? radius) => SizedBox(
        height: 140,
        child: IgnorePointer(
          child: FlutterMap(
            key: ValueKey(point),
            options: MapOptions(
              initialCenter: point,
              initialZoom: 17,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
            ),
            children: [
              Basemap.fallback.layer(),
              if (radius != null && radius > 0)
                CircleLayer(circles: [
                  CircleMarker(
                    point: point,
                    radius: radius,
                    useRadiusInMeter: true,
                    color: const Color(0x332A78D6),
                    borderColor: const Color(0x882A78D6),
                    borderStrokeWidth: 1,
                  ),
                ]),
              MarkerLayer(markers: [
                Marker(
                  point: point,
                  width: 18,
                  height: 18,
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF2A78D6),
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                  ),
                ),
              ]),
              Basemap.fallback.attributionWidget(),
            ],
          ),
        ),
      );

  /// Good / so-so / poor, by the usual field rule of thumb: within 10 m a
  /// record can be found again; beyond 30 m, hardly.
  Color? _accuracyColour(double? m) {
    if (m == null) return null;
    if (m <= 10) return const Color(0xFF0B8A0B);
    if (m <= 30) return const Color(0xFFB07A00);
    return Theme.of(context).colorScheme.error;
  }

  String _coords(LatLng p) =>
      '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}';

  TextStyle? _tabular(ThemeData theme) =>
      theme.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  // --- when, how many, details ----------------------------------------------------

  Widget _whenTile(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        child: ListTile(
          leading: const Icon(Icons.event),
          title: Text(formatDateTime(_eventDate)),
          subtitle: Text(_photo?.origin == PhotoOrigin.gallery
              ? 'Set this to when the photo was taken.'
              : 'When the plant was observed.'),
          trailing: const Icon(Icons.edit_calendar_outlined),
          onTap: _pickDate,
        ),
      );

  Widget _countRow(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      IconButton.outlined(
        tooltip: 'Fewer',
        onPressed: _count == null ? null : () => setState(() => _count = _count! <= 1 ? null : _count! - 1),
        icon: const Icon(Icons.remove),
      ),
      SizedBox(
        width: 120,
        child: Text(
          _count == null ? 'Not counted' : '$_count ${_count == 1 ? 'individual' : 'individuals'}',
          textAlign: TextAlign.center,
          style: _count == null
              ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)
              : theme.textTheme.titleMedium,
        ),
      ),
      IconButton.outlined(
        tooltip: 'More',
        onPressed: () => setState(() => _count = (_count ?? 0) + 1),
        icon: const Icon(Icons.add),
      ),
    ]);
  }

  Widget _detailsTile(BuildContext context) {
    final filled = [_lifeStage, _habitat, _remarks].where((c) => c.text.trim().isNotEmpty).length;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: filled > 0 && !widget.isNew,
        title: const Text('More details'),
        subtitle: Text(filled == 0 ? 'Life stage, habitat, remarks' : '$filled filled in'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          TextField(
            controller: _lifeStage,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Life stage',
              hintText: 'e.g. seedling, flowering adult',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _habitat,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Habitat',
              hintText: 'e.g. alpine grassland, scree',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _remarks,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Remarks',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  // --- sensitivity ----------------------------------------------------------------

  Widget _sensitivityControl(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'open', label: Text('Open'), icon: Icon(Icons.public)),
          ButtonSegment(value: 'generalised', label: Text('Generalised'), icon: Icon(Icons.blur_on)),
          ButtonSegment(value: 'withheld', label: Text('Withheld'), icon: Icon(Icons.lock_outline)),
        ],
        selected: {_sensitivity},
        onSelectionChanged: (s) => setState(() => _sensitivity = s.first),
      ),
      const SizedBox(height: 6),
      Text(
        switch (_sensitivity) {
          'generalised' => 'Exported with coordinates rounded to ~1 km. The park keeps '
              'the exact point.',
          'withheld' => 'Never exported. Only this park sees it.',
          _ => 'Publishable as recorded, if the park decides to publish.',
        },
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]);
  }

  // --- history ----------------------------------------------------------------------

  List<Widget> _historySection(BuildContext context) {
    final ids = _detail?.identifications ?? const [];
    if (ids.isEmpty) return const [];
    final scheme = Theme.of(context).colorScheme;
    return [
      _header(context, 'All determinations (${ids.length})'),
      for (final i in ids)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            switch (i.source) {
              'offline_model' => Icons.smartphone,
              'online_service' => Icons.cloud_outlined,
              _ => Icons.person_outline,
            },
            color: i.isAccepted ? scheme.primary : scheme.outline,
          ),
          title: Text(i.name ?? '—', style: const TextStyle(fontStyle: FontStyle.italic)),
          subtitle: Text([
            switch (i.source) {
              'offline_model' => 'on-device model',
              'online_service' => 'online service',
              _ => i.identifiedBy ?? 'a person',
            },
            if (i.rank != null && i.rank != 'species') '${i.rank} level',
            if (i.displayScore != null)
              '${formatScore(i.displayScore!.value)}${i.displayScore!.calibrated ? '' : ' (not calibrated)'}',
            formatDateTime(i.dateIdentified),
          ].join(' · ')),
          trailing: i.isAccepted
              ? Chip(
                  label: const Text('accepted'),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  labelStyle: Theme.of(context).textTheme.labelSmall,
                )
              : null,
        ),
      _note(context,
          'Determinations are only ever added. A new one becomes the accepted '
          'answer; none is overwritten — the comparison of the on-device and the '
          'online answer is measured from exactly these rows.'),
    ];
  }
}
