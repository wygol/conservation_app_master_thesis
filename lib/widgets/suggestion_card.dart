import 'package:flutter/material.dart';

import '../models/models_extra.dart';

/// One candidate as the card shows it.
class SuggestionLine {
  const SuggestionLine({
    required this.name,
    required this.score,
    this.rank,
    this.detail,
    this.match,
  });

  final String name;
  final double score;

  /// 'species' | 'genus' | 'aggregate' — anything but species is labelled.
  final String? rank;

  /// A second line, e.g. the family.
  final String? detail;

  /// The park-checklist taxon this candidate is, when it is one. Only those
  /// can be taken over as a person's determination (see ObservationRepository
  /// .checklist for why).
  final ChecklistTaxon? match;
}

/// Scores as people read them: whole percent, "<1 %" for the long tail, one
/// decimal near 100 % so that 0.996 is not shown as a certainty.
String formatScore(double s) {
  if (s < 0.01) return '<1 %';
  if (s > 0.99) return '${(s * 100).toStringAsFixed(1)} %';
  return '${(s * 100).round()} %';
}

/// An identifier's answer: the most likely candidate, and — one tap — the
/// whole top-k with scores. Used for a fresh on-device answer while recording
/// and for stored answers when a record is opened again.
class SuggestionCard extends StatefulWidget {
  const SuggestionCard({
    super.key,
    required this.title,
    required this.icon,
    this.lines = const [],
    this.calibrated = false,
    this.busy = false,
    this.error,
    this.selectedTaxonId,
    this.onUse,
    this.when,
    this.initiallyExpanded = false,
  });

  final String title;
  final IconData icon;

  /// Best first.
  final List<SuggestionLine> lines;

  /// False until the thesis' temperature is applied (D-018). Uncalibrated
  /// scores rank the candidates correctly but are not probabilities, and the
  /// card says so.
  final bool calibrated;
  final bool busy;
  final String? error;

  /// The checklist taxon currently chosen as the person's determination.
  final String? selectedTaxonId;

  /// Null makes the card read-only.
  final ValueChanged<ChecklistTaxon>? onUse;

  /// When the answer was given, for stored answers.
  final String? when;
  final bool initiallyExpanded;

  @override
  State<SuggestionCard> createState() => _SuggestionCardState();
}

class _SuggestionCardState extends State<SuggestionCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = widget.lines;

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
            child: Row(
              children: [
                Icon(widget.icon, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [widget.title, ?widget.when].join(' · '),
                    style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary),
                  ),
                ),
                if (lines.isNotEmpty && !widget.calibrated)
                  Tooltip(
                    message: 'Raw model scores. They rank the candidates, but are '
                        'not probabilities until the model is calibrated.',
                    child: Chip(
                      label: const Text('not calibrated'),
                      labelStyle: theme.textTheme.labelSmall,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: EdgeInsets.zero,
                    ),
                  ),
              ],
            ),
          ),
          if (widget.busy)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Row(children: [
                SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 12),
                Expanded(child: Text('Identifying on this phone — nothing leaves it…')),
              ]),
            )
          else if (widget.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text(widget.error!, style: TextStyle(color: scheme.error)),
            )
          else if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Text('No answer.', style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          else ...[
            InkWell(
              onTap: lines.length > 1 ? () => setState(() => _expanded = !_expanded) : null,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
                child: _Line(
                  line: lines.first,
                  top: true,
                  selected: _isSelected(lines.first),
                  onUse: widget.onUse,
                  trailing: lines.length > 1
                      ? Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                          semanticLabel: _expanded ? 'Show fewer' : 'Show top ${lines.length}')
                      : null,
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: !_expanded
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Divider(height: 1),
                        for (final l in lines.skip(1))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                            child: _Line(
                              line: l,
                              selected: _isSelected(l),
                              onUse: widget.onUse,
                            ),
                          ),
                      ],
                    ),
            ),
            if (lines.length > 1 && !_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text('Tap to see the top ${lines.length}',
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
          ],
        ],
      ),
    );
  }

  bool _isSelected(SuggestionLine l) =>
      l.match != null && l.match!.taxonId == widget.selectedTaxonId;
}

class _Line extends StatelessWidget {
  const _Line({
    required this.line,
    required this.selected,
    required this.onUse,
    this.top = false,
    this.trailing,
  });

  final SuggestionLine line;
  final bool selected;
  final bool top;
  final ValueChanged<ChecklistTaxon>? onUse;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rankNote = (line.rank == null || line.rank == 'species') ? null : line.rank;
    final match = line.match;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                line.name,
                style: (top ? theme.textTheme.titleMedium : theme.textTheme.bodyLarge)
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),
              if (line.detail != null || rankNote != null)
                Text(
                  [?line.detail, if (rankNote != null) '$rankNote level'].join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: _ScoreBar(value: line.score, strong: top)),
                const SizedBox(width: 10),
                SizedBox(
                  width: 52,
                  child: Text(formatScore(line.score),
                      textAlign: TextAlign.end,
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ),
              ]),
              if (onUse != null && match == null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Not on this park\'s checklist',
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
                ),
            ],
          ),
        ),
        if (onUse != null && match != null)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: selected
                ? Icon(Icons.check_circle, color: scheme.primary, semanticLabel: 'Chosen')
                : TextButton(onPressed: () => onUse!(match), child: const Text('Use')),
          ),
        ?trailing,
      ],
    );
  }
}

class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.value, required this.strong});

  final double value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: strong ? 8 : 6,
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: scheme.surfaceContainerHighest),
          FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value.clamp(0.0, 1.0),
            child: ColoredBox(color: strong ? scheme.primary : scheme.primary.withValues(alpha: 0.6)),
          ),
        ]),
      ),
    );
  }
}
