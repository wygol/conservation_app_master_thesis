import 'package:flutter/material.dart';

import '../models/models_extra.dart';

/// Lets a person choose a determination from the park checklist. Taxa the
/// model proposed come first, so confirming a good suggestion is one tap.
///
/// Returns the chosen taxon, or null when dismissed.
Future<ChecklistTaxon?> showSpeciesPicker(
  BuildContext context, {
  required List<ChecklistTaxon> checklist,
  List<ChecklistTaxon> suggested = const [],
  String? parkName,
}) {
  return showModalBottomSheet<ChecklistTaxon>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _SpeciesPicker(
      checklist: checklist,
      suggested: suggested,
      parkName: parkName,
    ),
  );
}

class _SpeciesPicker extends StatefulWidget {
  const _SpeciesPicker({required this.checklist, required this.suggested, this.parkName});

  final List<ChecklistTaxon> checklist;
  final List<ChecklistTaxon> suggested;
  final String? parkName;

  @override
  State<_SpeciesPicker> createState() => _SpeciesPickerState();
}

class _SpeciesPickerState extends State<_SpeciesPicker> {
  String _query = '';

  bool _matches(ChecklistTaxon t) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return t.scientificName.toLowerCase().contains(q) ||
        (t.vernacularName?.toLowerCase().contains(q) ?? false) ||
        (t.family?.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestedIds = {for (final s in widget.suggested) s.taxonId};
    final suggested = widget.suggested.where(_matches).toList();
    final rest = widget.checklist
        .where((t) => !suggestedIds.contains(t.taxonId) && _matches(t))
        .toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Determine', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '${widget.checklist.length} taxa on the checklist of '
                  '${widget.parkName ?? 'this park'}. A genus is a valid answer.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  autofocus: false,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search by name or family',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scroll,
              children: [
                if (suggested.isNotEmpty) ...[
                  _Header('Suggested by the model'),
                  for (final t in suggested) _TaxonTile(taxon: t, suggested: true),
                ],
                if (rest.isNotEmpty) ...[
                  _Header(suggested.isEmpty ? 'Checklist' : 'Rest of the checklist'),
                  for (final t in rest) _TaxonTile(taxon: t),
                ],
                if (suggested.isEmpty && rest.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('Nothing on the checklist matches.')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary, letterSpacing: 1.2)),
      );
}

class _TaxonTile extends StatelessWidget {
  const _TaxonTile({required this.taxon, this.suggested = false});

  final ChecklistTaxon taxon;
  final bool suggested;

  @override
  Widget build(BuildContext context) {
    final t = taxon;
    return ListTile(
      leading: Icon(suggested ? Icons.auto_awesome : Icons.eco_outlined),
      title: Text(t.scientificName, style: const TextStyle(fontStyle: FontStyle.italic)),
      subtitle: Text([
        ?t.vernacularName,
        ?t.family,
        if (t.rank != 'species') '${t.rank} level',
      ].join(' · ')),
      onTap: () => Navigator.of(context).pop(t),
    );
  }
}
