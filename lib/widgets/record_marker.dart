/// How one record is drawn on the map — CORE (CLAUDE.md §4). This file knows
/// circles, rings and glyphs; which categories exist and which colour each
/// gets is decided by a [RecordSymbology] from the domain layer.
library;

import 'package:flutter/material.dart';

import '../models/records.dart';

/// The look of one marker and its legend entry.
class MarkerStyle {
  const MarkerStyle({
    required this.fill,
    required this.label,
    this.glyph,
    this.glyphColor = Colors.white,
    this.hollow = false,
  });

  final Color fill;
  final String label;
  final IconData? glyph;
  final Color glyphColor;

  /// Drawn as a ring only (no fill) — used for "no name yet".
  final bool hollow;
}

/// The seam between the core map and the domain layer — the same pattern as
/// `IdentificationService`. Swapping the use case means a new implementation
/// of this class; the map screen does not change.
abstract class RecordSymbology {
  /// Must return one of the [legend] entries (matched by label), so that what
  /// is on the map is always explained by the legend.
  MarkerStyle styleOf(RecordDigest record, MapColouring colouring);

  /// The legend's entries, in a fixed order.
  List<MarkerStyle> legend(MapColouring colouring);
}

/// A record on the map: a filled circle with a 2 px light ring, so markers stay
/// readable where they overlap and on any basemap (dataviz rule: marker ≥ 8 px,
/// surface ring on overlapping marks). The hit target is the [Marker]'s box,
/// which the map makes larger than the circle.
class RecordMarker extends StatelessWidget {
  const RecordMarker({
    super.key,
    required this.style,
    this.diameter = 22,
    this.dimmed = false,
    this.selected = false,
  });

  final MarkerStyle style;
  final double diameter;

  /// Faded when the legend highlights another category.
  final bool dimmed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ring = selected ? scheme.onSurface : Colors.white;
    final circle = Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: style.hollow ? Colors.white.withValues(alpha: 0.85) : style.fill,
        border: Border.all(
          color: style.hollow ? style.fill : ring,
          width: selected ? 3 : (style.hollow ? 2.5 : 2),
        ),
        boxShadow: const [
          BoxShadow(color: Color(0x40000000), blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      alignment: Alignment.center,
      child: style.glyph == null
          ? null
          : Icon(style.glyph,
              size: diameter * 0.6,
              color: style.hollow ? style.fill : style.glyphColor),
    );
    return Opacity(opacity: dimmed ? 0.25 : 1, child: circle);
  }
}
