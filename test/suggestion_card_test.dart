import 'package:conservation_app/models/models_extra.dart';
import 'package:conservation_app/widgets/suggestion_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const hieracium = ChecklistTaxon(taxonId: 't-hie', scientificName: 'Hieracium', rank: 'genus');
  const lines = [
    SuggestionLine(name: 'Carduus defloratus L.', score: 0.62, rank: 'species', detail: 'Asteraceae'),
    SuggestionLine(name: 'Hieracium', score: 0.21, rank: 'genus', match: hieracium),
    SuggestionLine(name: 'Cirsium spinosissimum (L.) Scop.', score: 0.09),
    SuggestionLine(name: 'Carlina acaulis L.', score: 0.05),
    SuggestionLine(name: 'Bryophyta (aggregate) - moss, needs an expert', score: 0.004, rank: 'aggregate'),
  ];

  Future<List<ChecklistTaxon>> pump(WidgetTester tester, {bool readOnly = false}) async {
    final used = <ChecklistTaxon>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SuggestionCard(
            title: 'On-device model',
            icon: Icons.smartphone,
            lines: lines,
            onUse: readOnly ? null : used.add,
          ),
        ),
      ),
    ));
    return used;
  }

  testWidgets('collapsed: only the most likely answer, with its score and the uncalibrated label',
      (tester) async {
    await pump(tester);
    expect(find.text('Carduus defloratus L.'), findsOneWidget);
    expect(find.text('62 %'), findsOneWidget);
    expect(find.text('not calibrated'), findsOneWidget);
    expect(find.text('Hieracium'), findsNothing);
    expect(find.text('Tap to see the top 5'), findsOneWidget);
  });

  testWidgets('one tap shows the top 5 with their scores', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Carduus defloratus L.'));
    await tester.pumpAndSettle();
    for (final l in lines) {
      expect(find.text(l.name), findsOneWidget);
    }
    expect(find.text('21 %'), findsOneWidget);
    expect(find.text('<1 %'), findsOneWidget);
    expect(find.text('genus level'), findsOneWidget);
  });

  testWidgets('only a candidate on the park checklist can be taken over', (tester) async {
    final used = await pump(tester);
    await tester.tap(find.text('Carduus defloratus L.'));
    await tester.pumpAndSettle();
    expect(find.text('Use'), findsOneWidget);
    expect(find.text('Not on this park\'s checklist'), findsNWidgets(4));
    await tester.tap(find.text('Use'));
    expect(used.single.taxonId, 't-hie');
  });

  testWidgets('read-only for stored answers: no Use, no checklist notes', (tester) async {
    await pump(tester, readOnly: true);
    await tester.tap(find.text('Carduus defloratus L.'));
    await tester.pumpAndSettle();
    expect(find.text('Use'), findsNothing);
    expect(find.textContaining('checklist'), findsNothing);
  });

  test('score formatting', () {
    expect(formatScore(0.004), '<1 %');
    expect(formatScore(0.62), '62 %');
    expect(formatScore(0.996), '99.6 %');
  });
}
