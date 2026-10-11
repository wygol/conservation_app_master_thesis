import 'dart:io';
import 'dart:typed_data';

import 'package:conservation_app/services/jpeg_metadata.dart';
import 'package:conservation_app/services/prepared_photo.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

  test('a gallery photo with a position: stored and hashed without it', () {
    final p = PreparedPhoto.prepare(fixture('gps_rot6_32x16.jpg'), origin: PhotoOrigin.gallery);
    expect(p.hadGps, isTrue);
    expect(JpegInfo.read(p.bytes)!.hasGps, isFalse);
    expect(p.info.orientation, 6);
    expect(p.sha256, sha256.convert(p.bytes).toString());
    expect(p.capturedAt, isNull);
  });

  test('a photo without a position is taken as it is', () {
    final original = fixture('plain_32x16.jpg');
    final p = PreparedPhoto.prepare(original, origin: PhotoOrigin.camera, capturedAt: DateTime(2026));
    expect(p.hadGps, isFalse);
    expect(p.bytes, original);
    expect(p.sha256, sha256.convert(original).toString());
  });

  test('not a JPEG: refused with a reason', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(() => PreparedPhoto.prepare(png, origin: PhotoOrigin.gallery),
        throwsA(isA<PhotoRejected>()));
  });
}
