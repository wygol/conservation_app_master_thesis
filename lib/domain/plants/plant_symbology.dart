/// How plant records are drawn on the map — DOMAIN layer (CLAUDE.md §4). The
/// core map draws circles with a fill, a ring and an optional glyph
/// (widgets/record_marker.dart); which categories exist and which colours they
/// get is decided here.
///
/// Colour rules (the dataviz method; palette validated 2026-10-11 with its
/// validator, see ADR 011):
///  * A map is an "all pairs" form — any two markers can sit side by side — so
///    only the first three slots of the validated categorical palette are used
///    (worst all-pairs ΔE: colour-blind 9.2, normal vision 24.0). Every other
///    family is "Other families"; any single family can still be highlighted
///    from the legend.
///  * Colour follows the family, never its rank in the current data: the three
///    coloured families are FIXED — the three largest of the label space
///    (Asteraceae 111, Poaceae 54, Rosaceae 51 classes) — so adding records can
///    never repaint a family.
///  * Status colours are reserved for status and always come with a glyph and
///    a label, never colour alone.
library;

import 'package:flutter/material.dart';

import '../../models/records.dart';
import '../../widgets/record_marker.dart';
import 'plant_families.dart';

class PlantSymbology {
  PlantSymbology._();

  /// The three coloured families, in the palette's slot order.
  static const colouredFamilies = ['Asteraceae', 'Poaceae', 'Rosaceae'];
  static const _slots = [Color(0xFF2A78D6), Color(0xFFEB6834), Color(0xFF1BAF7A)];

  static const otherFamiliesLabel = 'Other families';
  static const unknownFamilyLabel = 'No name yet';

  /// A dark neutral. The first choice, #8A8A85, failed the validator against
  /// the green slot (colour-blind ΔE 4.5, normal vision 14.2 — both below the
  /// floors); #5C5B57 passes against all three hues (worst normal-vision pair
  /// 19.8). Its "chroma floor" failure is intended: "other" is meant to read
  /// as grey. Validator output: docs/measurements/2026-10-11_map_palette/.
  static const _otherFill = Color(0xFF5C5B57);
  static const _ringOnly = Color(0xFF6B6A66);

  /// Status palette of the dataviz method: good, warning, and a neutral.
  static const confirmedColor = Color(0xFF0CA30C);
  static const suggestedColor = Color(0xFFFAB219);
  static const awaitingColor = Color(0xFF8A8A85);

  /// [name] is the record's best available name (the accepted one, else the
  /// model's suggestion); [family] is its family when known. A record with a
  /// name but no known family (a checklist taxon outside the model's label
  /// space) is "Other families" — it is not unnamed.
  static MarkerStyle forFamily({required String? name, required String? family}) {
    if (name == null) {
      return const MarkerStyle(
          fill: _ringOnly, label: unknownFamilyLabel, glyph: Icons.question_mark, hollow: true);
    }
    final slot = family == null ? -1 : colouredFamilies.indexOf(family);
    if (slot < 0) return const MarkerStyle(fill: _otherFill, label: otherFamiliesLabel);
    return MarkerStyle(fill: _slots[slot], label: family!);
  }

  static MarkerStyle forState(DeterminationState state) => switch (state) {
        DeterminationState.confirmed => const MarkerStyle(
            fill: confirmedColor, label: 'Confirmed by a person', glyph: Icons.check),
        DeterminationState.suggested => const MarkerStyle(
            fill: suggestedColor,
            label: 'Suggested by the model',
            glyph: Icons.auto_awesome,
            glyphColor: Color(0xFF1A1A19)),
        DeterminationState.awaiting => const MarkerStyle(
            fill: awaitingColor, label: 'Awaiting determination', glyph: Icons.question_mark),
      };

  /// The legend's entries, in a fixed order, for whichever colouring is on.
  static List<MarkerStyle> legend(MapColouring colouring) => switch (colouring) {
        MapColouring.family => [
            for (final f in colouredFamilies) forFamily(name: f, family: f),
            forFamily(name: 'any', family: null),
            forFamily(name: null, family: null),
          ],
        MapColouring.status => [for (final s in DeterminationState.values) forState(s)],
      };
}

/// The plant implementation of the core map's [RecordSymbology] seam.
class PlantRecordSymbology implements RecordSymbology {
  const PlantRecordSymbology(this.families);

  /// Genus → family from the model's label table; null until it has loaded,
  /// in which case only families stored in `taxa` are known.
  final PlantFamilies? families;

  @override
  MarkerStyle styleOf(RecordDigest record, MapColouring colouring) => switch (colouring) {
        MapColouring.family => PlantSymbology.forFamily(
            name: record.name,
            family: record.family ?? families?.familyOf(record.name)),
        MapColouring.status => PlantSymbology.forState(record.state),
      };

  @override
  List<MarkerStyle> legend(MapColouring colouring) => PlantSymbology.legend(colouring);
}
