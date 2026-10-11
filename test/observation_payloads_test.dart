import 'dart:convert';

import 'package:conservation_app/models/records.dart';
import 'package:conservation_app/services/identification_service.dart';
import 'package:conservation_app/services/jpeg_metadata.dart';
import 'package:conservation_app/services/observation_payloads.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Real rows of labels.csv (model_index 382, 757, 985, 1003).
  const edelweiss = IdentificationCandidate(
      scientificName: 'Leontopodium nivale subsp. alpinum (Cass.) Greuter',
      score: 0.61,
      rank: 'species',
      externalId: '3140685');
  const gentian = IdentificationCandidate(
      scientificName: 'Gentiana clusii E.P.Perrier & Songeon',
      score: 0.2,
      rank: 'species',
      externalId: '7270031');
  const hawkweeds = IdentificationCandidate(
      scientificName: 'Hieracium', score: 0.1, rank: 'genus', externalId: 'genus_Hieracium');
  const moss = IdentificationCandidate(
      scientificName: 'Bryophyta (aggregate) - moss, needs an expert',
      score: 0.05,
      rank: 'aggregate',
      externalId: 'bryophyta');
  const all = [edelweiss, gentian, hawkweeds, moss];

  group('ranks', () {
    test('Linnaean ranks pass; the aggregate and unknowns become null', () {
      expect(databaseRank('species'), 'species');
      expect(databaseRank('genus'), 'genus');
      expect(databaseRank('aggregate'), isNull);
      expect(databaseRank(null), isNull);
    });
  });

  group('taxon resolution', () {
    test('lookup keys: GBIF keys of species, names of genus classes, nothing for the aggregate', () {
      final k = taxonLookupKeys(all);
      expect(k.gbifKeys, {3140685, 7270031});
      expect(k.genusNames, {'Hieracium'});
    });

    test('joins by GBIF key and by genus name — never by species name', () {
      // The seed's taxa, verbatim: its Gentiana clusii carries key 5343979, the
      // model's class 7270031, so they do NOT join. That is a data finding
      // (ADR 011), not something to paper over with name matching.
      final seedTaxa = [
        {'id': 't-leo', 'scientific_name': 'Leontopodium nivale', 'taxon_rank': 'species', 'gbif_taxon_key': 3111243},
        {'id': 't-gen', 'scientific_name': 'Gentiana clusii', 'taxon_rank': 'species', 'gbif_taxon_key': 5343979},
        {'id': 't-hie', 'scientific_name': 'Hieracium', 'taxon_rank': 'genus', 'gbif_taxon_key': null},
      ];
      final r = attachTaxa(all, seedTaxa);
      expect(r.map((c) => c.taxonId).toList(), [null, null, 't-hie', null]);

      final withRightKey = attachTaxa(all, [
        {'id': 't-gen2', 'scientific_name': 'Gentiana clusii', 'taxon_rank': 'species', 'gbif_taxon_key': 7270031},
      ]);
      expect(withRightKey[1].taxonId, 't-gen2');
      // Everything else about a candidate is kept.
      expect(withRightKey[1].score, 0.2);
      expect(withRightKey[1].externalId, '7270031');
    });
  });

  group('machine identification row', () {
    final result = IdentificationResult(
      source: 'offline_model',
      provider: 'thesis-offline',
      candidates: attachTaxa(all, [
        {'id': 't-hie', 'scientific_name': 'Hieracium', 'taxon_rank': 'genus', 'gbif_taxon_key': null},
      ]),
    );
    final at = DateTime.utc(2026, 10, 11, 9, 30);
    final row = machineIdentificationRow(
      observationId: 'obs-1',
      orgId: 'org-1',
      result: result,
      identifiedAt: at,
      remarks: 'r',
    );

    test('satisfies the schema constraints of a machine row', () {
      expect(row['source'], 'offline_model');
      expect(row['provider'], isNotNull); // identifications_machine_has_score
      expect(row['confidence_raw'], 0.61);
      expect(row['checklist_masked'], isFalse); // only the offline model may set it; it does not yet
      expect(row['is_accepted'], isFalse); // a machine suggests; a person accepts
      expect(row['verification_status'], 'unverified');
      expect(row['identified_by'], 'thesis-offline');
    });

    test('top-1 is stored verbatim; calibrated stays empty', () {
      expect(row['verbatim_identification'], edelweiss.scientificName);
      expect(row['taxon_id'], isNull);
      expect(row['taxon_rank_answered'], 'species');
      expect(row.containsKey('confidence_calibrated'), isTrue);
      expect(row['confidence_calibrated'], isNull);
      expect(row['date_identified'], '2026-10-11T09:30:00.000Z');
    });

    test('top_k keeps every candidate, in order, in the thesis shape plus rank and class_id', () {
      final topK = row['top_k'] as List;
      expect(topK.length, 4);
      expect(topK.first, {
        'taxon_id': null,
        'name': edelweiss.scientificName,
        'score': 0.61,
        'rank': 'species',
        'class_id': '3140685',
      });
      expect((topK[2] as Map)['taxon_id'], 't-hie');
      expect((topK[3] as Map)['rank'], 'aggregate'); // kept as given inside top_k
      // It survives JSON as the app reads it back.
      final back = [for (final j in jsonDecode(jsonEncode(topK)) as List) TopKEntry.fromJson(j)!];
      expect(back.map((e) => e.name).toList(), all.map((c) => c.scientificName).toList());
      expect(back.first.classId, '3140685');
    });

    test('an aggregate top-1 is stored without a rank, never with an invalid one', () {
      final r = machineIdentificationRow(
        observationId: 'o',
        orgId: 'g',
        result: const IdentificationResult(
            source: 'offline_model', provider: 'thesis-offline', candidates: [moss]),
        identifiedAt: at,
      );
      expect(r['taxon_rank_answered'], isNull);
      expect(r['verbatim_identification'], moss.scientificName);
    });

    test('no candidates: refused, not written as an empty determination', () {
      expect(
        () => machineIdentificationRow(
          observationId: 'o',
          orgId: 'g',
          result: const IdentificationResult(
              source: 'offline_model', provider: 'thesis-offline', candidates: []),
          identifiedAt: at,
        ),
        throwsArgumentError,
      );
    });
  });

  group('observation and media rows', () {
    test('point as EWKT, longitude first; blank text becomes null; no country', () {
      final row = observationFields(
        eventDate: DateTime.utc(2026, 10, 11, 8),
        latitude: 47.15,
        longitude: 12.75,
        uncertaintyM: 4.2,
        georeferenceProtocol: gpsProtocol,
        sensitivity: 'open',
        habitat: '  ',
        remarks: ' near the path ',
      );
      expect(row['geometry'], 'SRID=4326;POINT(12.75 47.15)');
      expect(row['coordinate_uncertainty_m'], 4.2);
      expect(row['habitat'], isNull);
      expect(row['occurrence_remarks'], 'near the path');
      expect(row.containsKey('country_code'), isFalse);
    });

    test('photo path starts with the organisation, as the bucket policies require', () {
      expect(photoStoragePath(orgId: 'org', observationId: 'obs', sha256: 'abc'), 'org/obs/abc.jpg');
    });

    test('media row: displayed size, honest stripping flag, primary', () {
      final row = primaryMediaRow(
        observationId: 'obs',
        orgId: 'org',
        storagePath: 'org/obs/abc.jpg',
        info: const JpegInfo(width: 4000, height: 3000, orientation: 6),
        byteCount: 123,
        sha256: 'abc',
        exifStripped: true,
        organ: 'flower',
      );
      expect([row['width_px'], row['height_px']], [3000, 4000]);
      expect(row['is_primary'], isTrue);
      expect(row['exif_stripped'], isTrue);
      expect(row['captured_at'], isNull);
    });

    test('remarks name the score, the file and the input', () {
      final s = offlineRemarks(
          modelSha256: 'e0e1', input: const JpegInfo(width: 4000, height: 3000, orientation: 6));
      expect(s, contains('uncalibrated softmax (T = 1)'));
      expect(s, contains('SHA-256 e0e1'));
      expect(s, contains('4000 x 3000 px as stored, EXIF orientation 6'));
    });
  });
}
