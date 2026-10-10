import 'dart:io';

import 'package:conservation_app/ml/inference_math.dart';
import 'package:conservation_app/ml/labels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCsv', () {
    test('quoted field with a comma and an escaped quote', () {
      final rows = parseCsv('a,b,c\n1,"x, y","say ""hi"""\n');
      expect(rows, [
        ['a', 'b', 'c'],
        ['1', 'x, y', 'say "hi"'],
      ]);
    });

    test('CRLF and a last line without newline', () {
      expect(parseCsv('a,b\r\n1,2'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
    });
  });

  group('the bundled labels.csv', () {
    late LabelTable labels;
    setUpAll(() {
      labels = LabelTable.parse(File('assets/model/labels.csv').readAsStringSync());
    });

    test('has one row per model output (1,004)', () => expect(labels.length, 1004));

    test('row order equals output order, spot-checked against phone_reference.json', () {
      expect(labels[0].label, 'Ophioglossum vulgatum L.');
      expect(labels[86].label, 'Orchis mascula (L.) L.');
      expect(labels[361].label, 'Carduus defloratus L.');
      expect(labels[974].label, 'Carduus');
      expect(labels[974].rank, 'genus');
      expect(labels[998].label, 'Sesleria');
    });

    test('the quoted aggregate label survives intact', () {
      expect(labels[1003].label, 'Bryophyta (aggregate) - moss, needs an expert');
      expect(labels[1003].rank, 'aggregate');
    });
  });

  group('inference math', () {
    test('softmax is normalised and order-preserving', () {
      final p = softmax([1.0, 3.0, 2.0]);
      expect(p.reduce((a, b) => a + b), closeTo(1.0, 1e-12));
      expect(topKIndices(p, 3), [1, 2, 0]);
    });

    test('p90 is nearest rank (rank 90 of 100), median averages the middle pair', () {
      final runs = List<int>.generate(100, (i) => i + 1); // 1..100
      final s = latencyStats(runs);
      expect(s['p90_us'], 90);
      expect(s['median_us'], 50.5);
      expect(latencyStats([5, 1, 3])['median_us'], 3.0);
    });
  });
}
