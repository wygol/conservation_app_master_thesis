import 'dart:io';
import 'dart:ui';

import 'package:conservation_app/domain/plants/plant_families.dart';
import 'package:conservation_app/domain/plants/plant_symbology.dart';
import 'package:conservation_app/ml/labels.dart';
import 'package:conservation_app/models/records.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The real label table of the shipped model, read from disk.
  final families = PlantFamilies.fromLabels(
      LabelTable.parse(File('assets/model/labels.csv').readAsStringSync()).labels);

  group('PlantFamilies (labels.csv)', () {
    test('a species name resolves through its genus', () {
      expect(families.familyOf('Carduus defloratus L.'), 'Asteraceae');
      expect(families.familyOf('Ophioglossum vulgatum'), 'Ophioglossaceae');
      expect(families.familyOf('  Asplenium   ruta-muraria  '), 'Aspleniaceae');
    });

    test('a genus-level class resolves to its family', () {
      expect(families.familyOf('Agrostis'), 'Poaceae');
    });

    test('the moss aggregate is not given a family', () {
      expect(families.familyOf('Bryophyta (aggregate) - moss, needs an expert'), isNull);
    });

    test('unknown genus, empty or missing name: null', () {
      expect(families.familyOf('Notagenus inventus'), isNull);
      expect(families.familyOf(''), isNull);
      expect(families.familyOf(null), isNull);
    });

    test('all genera of the label space except the aggregate', () {
      expect(families.genusCount, 497); // 498 genus values in labels.csv, minus the aggregate
    });
  });

  group('PlantSymbology', () {
    test('the three coloured families have distinct fixed colours', () {
      final fills = {
        for (final f in PlantSymbology.colouredFamilies)
          PlantSymbology.forFamily(name: f, family: f).fill
      };
      expect(fills.length, 3);
      expect(PlantSymbology.forFamily(name: 'x', family: 'Asteraceae').fill,
          const Color(0xFF2A78D6));
    });

    test('a named record of any other family, or of an unknown one, is "Other families"', () {
      final other = PlantSymbology.forFamily(name: 'Ophioglossum vulgatum', family: 'Ophioglossaceae');
      final unknown = PlantSymbology.forFamily(name: 'Some checklist taxon', family: null);
      expect(other.label, PlantSymbology.otherFamiliesLabel);
      expect(unknown.label, PlantSymbology.otherFamiliesLabel);
      expect(unknown.hollow, isFalse);
    });

    test('a record without any name is drawn hollow with a question mark', () {
      final s = PlantSymbology.forFamily(name: null, family: null);
      expect(s.hollow, isTrue);
      expect(s.glyph, isNotNull);
    });

    test('status styles never rely on colour alone: each has a glyph and a label', () {
      for (final state in DeterminationState.values) {
        final s = PlantSymbology.forState(state);
        expect(s.glyph, isNotNull, reason: '$state');
        expect(s.label, isNotEmpty);
      }
    });

    test('status colours are not reused for families', () {
      final familyFills = PlantSymbology.legend(MapColouring.family).map((s) => s.fill).toSet();
      final statusFills = {PlantSymbology.confirmedColor, PlantSymbology.suggestedColor};
      expect(familyFills.intersection(statusFills), isEmpty);
    });

    test('legends: five family entries, three status entries, in a fixed order', () {
      expect(PlantSymbology.legend(MapColouring.family).map((s) => s.label).toList(), [
        'Asteraceae', 'Poaceae', 'Rosaceae',
        PlantSymbology.otherFamiliesLabel, PlantSymbology.unknownFamilyLabel,
      ]);
      expect(PlantSymbology.legend(MapColouring.status).length, 3);
    });
  });

  group('PlantRecordSymbology (the map seam)', () {
    RecordDigest digest({String? name, String? family, DeterminationState? state}) =>
        RecordDigest(
          id: 'x',
          eventDate: DateTime(2026, 10, 11),
          name: name,
          family: family,
          state: state ?? DeterminationState.suggested,
        );
    final symbology = PlantRecordSymbology(families);

    test('family from taxa wins; otherwise from the label table', () {
      expect(symbology.styleOf(digest(name: 'Leontopodium nivale', family: 'Asteraceae'),
              MapColouring.family).label,
          'Asteraceae');
      // A model suggestion without a taxa row: the genus decides.
      expect(symbology.styleOf(digest(name: 'Carduus defloratus L.'), MapColouring.family).label,
          'Asteraceae');
      expect(symbology.styleOf(digest(name: 'Agrostis'), MapColouring.family).label, 'Poaceae');
    });

    test('every style on the map is a legend entry', () {
      for (final c in MapColouring.values) {
        final labels = symbology.legend(c).map((s) => s.label).toSet();
        for (final d in [
          digest(name: 'Carduus defloratus L.'),
          digest(name: 'Ophioglossum vulgatum'),
          digest(name: 'Notagenus inventus'),
          digest(name: null, state: DeterminationState.awaiting),
          digest(name: 'Gentiana clusii', state: DeterminationState.confirmed),
        ]) {
          expect(labels, contains(symbology.styleOf(d, c).label), reason: '$c ${d.name}');
        }
      }
    });
  });
}
