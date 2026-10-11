import 'package:conservation_app/models/records.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shapes as PostgREST returns them, modelled on supabase/seed.sql.
Map<String, dynamic> obs(String id, String date, {Object? geometry}) => {
      'id': id,
      'event_date': date,
      'latitude': 47.15,
      'longitude': 12.75,
      'geometry': geometry,
      'coordinate_uncertainty_m': 5.0,
      'sensitivity': 'open',
      'recorded_by': 'Park Ranger',
    };

IdentificationEntry ident(
  String observationId,
  String source,
  String at, {
  bool accepted = false,
  Map<String, dynamic>? taxa,
  String? verbatim,
  double? raw,
  double? calibrated,
  String? by,
}) =>
    IdentificationEntry.fromMap({
      'id': '$observationId-$source-$at',
      'observation_id': observationId,
      'source': source,
      'provider': source == 'human' ? null : 'p',
      'taxon_id': taxa == null ? null : 't',
      'verbatim_identification': verbatim,
      'taxon_rank_answered': 'species',
      'confidence_raw': raw,
      'confidence_calibrated': calibrated,
      'is_accepted': accepted,
      'identified_by': by,
      'date_identified': at,
      'verification_status': source == 'human' ? 'verified' : 'unverified',
      'taxa': taxa,
    });

void main() {
  const leo = {'scientific_name': 'Leontopodium nivale', 'family': 'Asteraceae', 'vernacular_name_de': 'Edelweiß'};
  const hie = {'scientific_name': 'Hieracium', 'family': 'Asteraceae', 'vernacular_name_de': null};

  final digests = buildRecordDigests(
    [
      obs('a', '2026-08-02T08:20:00Z'),
      obs('b', '2026-07-15T12:12:00Z'),
      obs('c', '2026-10-11T07:00:00Z'),
      obs('d', '2026-09-01T07:00:00Z'),
    ],
    [
      // a: the three paths; the person's answer is accepted.
      ident('a', 'offline_model', '2026-08-02T08:20:08Z', taxa: hie, raw: 0.58, calibrated: 0.44),
      ident('a', 'online_service', '2026-08-02T17:40:00Z', taxa: leo, raw: 0.91),
      ident('a', 'human', '2026-08-03T07:00:00Z', taxa: leo, accepted: true, by: 'admin@park.at'),
      // b: only the on-device answer, accepted (as in the seed).
      ident('b', 'offline_model', '2026-07-15T12:12:05Z', taxa: hie, raw: 0.55, calibrated: 0.41, accepted: true),
      // c: an app record — a suggestion with no taxa row, uncalibrated.
      ident('c', 'offline_model', '2026-10-11T07:00:02Z',
          verbatim: 'Carduus defloratus L.', raw: 0.62),
      // d: nothing yet.
    ],
    withPhoto: {'c'},
  );
  RecordDigest byId(String id) => digests.firstWhere((d) => d.id == id);

  test('newest first', () {
    expect(digests.map((d) => d.id).toList(), ['c', 'd', 'a', 'b']);
  });

  test('a person\'s accepted answer: confirmed, no machine score', () {
    final a = byId('a');
    expect(a.state, DeterminationState.confirmed);
    expect([a.name, a.family, a.vernacularName], ['Leontopodium nivale', 'Asteraceae', 'Edelweiß']);
    expect(a.nameSource, 'human');
    expect(a.identifiedBy, 'admin@park.at');
    expect(a.score, isNull);
  });

  test('a machine answer, even when accepted, is a suggestion; calibrated wins when present', () {
    final b = byId('b');
    expect(b.state, DeterminationState.suggested);
    expect(b.name, 'Hieracium');
    expect([b.score, b.scoreCalibrated], [0.41, true]);
  });

  test('a suggestion without a taxa row still shows the model\'s name, marked uncalibrated', () {
    final c = byId('c');
    expect(c.state, DeterminationState.suggested);
    expect(c.name, 'Carduus defloratus L.');
    expect(c.family, isNull); // the map resolves it from the label table
    expect([c.score, c.scoreCalibrated], [0.62, false]);
    expect(c.hasPhoto, isTrue);
  });

  test('no determination at all: awaiting, not an error', () {
    final d = byId('d');
    expect(d.state, DeterminationState.awaiting);
    expect(d.name, isNull);
    expect(d.point, isNotNull);
    expect(d.hasPhoto, isFalse);
  });

  group('geometry', () {
    test('Polygon and MultiPolygon outer rings; lat/lon order swapped from GeoJSON', () {
      final square = [
        [12.0, 47.0], [12.1, 47.0], [12.1, 47.1], [12.0, 47.1], [12.0, 47.0],
      ];
      final p = polygonRings({'type': 'Polygon', 'coordinates': [square]});
      expect(p.length, 1);
      expect([p.first.first.latitude, p.first.first.longitude], [47.0, 12.0]);
      expect(polygonRings({'type': 'MultiPolygon', 'coordinates': [[square], [square]]}).length, 2);
    });

    test('a point, a non-GeoJSON value or a malformed ring: nothing to draw', () {
      expect(polygonRings({'type': 'Point', 'coordinates': [12.0, 47.0]}), isEmpty);
      expect(polygonRings('0101000020E6100000'), isEmpty);
      expect(polygonRings({'type': 'Polygon', 'coordinates': [[[12.0, 47.0]]]}), isEmpty);
      expect(polygonRings(null), isEmpty);
    });
  });

  test('top_k as the seed wrote it (name and score only) is read', () {
    final e = TopKEntry.fromJson({'name': 'Hieracium', 'score': 0.61})!;
    expect([e.name, e.score, e.classId], ['Hieracium', 0.61, null]);
    expect(TopKEntry.fromJson({'name': 'x'}), isNull);
  });
}
