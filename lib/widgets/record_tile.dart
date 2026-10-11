import 'package:flutter/material.dart';

import '../models/records.dart';
import 'record_marker.dart';
import 'suggestion_card.dart';

/// 2026-10-11 09:30 — fixed, sortable, no locale package needed.
String formatDateTime(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

String _two(int v) => v.toString().padLeft(2, '0');

/// Where a record's determination stands, in one line.
String stateText(RecordDigest r) => switch (r.state) {
      DeterminationState.confirmed =>
        'Confirmed${r.identifiedBy == null ? '' : ' by ${r.identifiedBy}'}',
      DeterminationState.suggested => [
          r.nameSource == 'online_service' ? 'Online suggestion' : 'On-device suggestion',
          if (r.score != null)
            '${formatScore(r.score!)}${r.scoreCalibrated ? '' : ' (not calibrated)'}',
        ].join(' · '),
      DeterminationState.awaiting => 'Awaiting determination',
    };

/// One record in a list: what it is, where its determination stands, when.
class RecordTile extends StatelessWidget {
  const RecordTile({
    super.key,
    required this.record,
    required this.style,
    this.onTap,
    this.trailing,
  });

  final RecordDigest record;

  /// The marker style the record has on the map, so list and map match.
  final MarkerStyle style;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = record;
    final named = r.name != null;
    return ListTile(
      onTap: onTap,
      leading: SizedBox(width: 40, child: Center(child: RecordMarker(style: style, diameter: 26))),
      title: Text(
        // A record with no name yet is normal (photograph first, determine
        // later), so it is worded as a state rather than as a missing value.
        r.name ?? 'Awaiting determination',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontStyle: named ? FontStyle.italic : FontStyle.normal,
          color: named ? null : theme.colorScheme.onSurfaceVariant,
        ),
      ),
      subtitle: Text(
        [
          ?r.vernacularName,
          if (r.rank != null && r.rank != 'species') '${r.rank} level',
          stateText(r),
          formatDateTime(r.eventDate),
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing ??
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (r.hasPhoto)
              Icon(Icons.photo_camera_outlined, size: 18, color: theme.colorScheme.outline,
                  semanticLabel: 'Has a photo'),
            if (r.sensitivity != 'open') ...[
              const SizedBox(width: 6),
              Icon(r.sensitivity == 'withheld' ? Icons.lock_outline : Icons.blur_on,
                  size: 18,
                  color: theme.colorScheme.outline,
                  semanticLabel: r.sensitivity),
            ],
          ]),
    );
  }
}
