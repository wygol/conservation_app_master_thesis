import 'dart:io';
import 'dart:typed_data';

import 'package:conservation_app/services/jpeg_metadata.dart';
import 'package:flutter_test/flutter_test.dart';

/// Expected values were read with Pillow 12.3.0, independently of this code
/// (test/fixtures/README.md).
void main() {
  JpegInfo read(String path) => JpegInfo.read(File(path).readAsBytesSync())!;

  test('plain JPEG: size, no orientation, no GPS', () {
    final i = read('test/fixtures/plain_32x16.jpg');
    expect([i.width, i.height, i.orientation, i.hasGps], [32, 16, 1, false]);
    expect([i.displayWidth, i.displayHeight], [32, 16]);
  });

  test('orientation 6 swaps the displayed axes', () {
    final i = read('test/fixtures/rot6_32x16.jpg');
    expect([i.width, i.height, i.orientation, i.hasGps], [32, 16, 6, false]);
    expect(i.swapsAxes, isTrue);
    expect([i.displayWidth, i.displayHeight], [16, 32]);
  });

  test('GPS tags are detected, with and without an orientation tag', () {
    expect(read('test/fixtures/gps_rot6_32x16.jpg').hasGps, isTrue);
    expect(read('test/fixtures/gps_rot6_32x16.jpg').orientation, 6);
    expect(read('test/fixtures/gps_24x24.jpg').hasGps, isTrue);
  });

  test('real photographs of the measurement round', () {
    final ref = read('assets/model_check/ref_01.jpg');
    expect([ref.width, ref.height, ref.orientation, ref.hasGps], [600, 800, 1, false]);
    final big = read('assets/model_check/synthetic_12mp.jpg');
    expect([big.width, big.height], [4000, 3000]);
  });

  test('big-endian ("MM") EXIF, as written by some cameras', () {
    // SOI, APP1 Exif (TIFF "MM": orientation 3 + a GPS directory with one
    // entry), SOF0 20 x 10, EOI — built by hand, since Pillow writes "II".
    final bytes = Uint8List.fromList([
      0xFF, 0xD8, //
      0xFF, 0xE1, 0x00, 0x40, // APP1, length 64
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // "Exif\0\0"
      0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // TIFF header, IFD0 at 8
      0x00, 0x02, // IFD0: 2 entries
      0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, // orientation 3
      0x88, 0x25, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x26, // GPS IFD at 38
      0x00, 0x00, 0x00, 0x00, // no next IFD
      0x00, 0x01, // GPS IFD: 1 entry
      0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x4E, 0x00, 0x00, 0x00, // LatitudeRef "N"
      0x00, 0x00, 0x00, 0x00, //
      0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x0A, 0x00, 0x14, 0x03, // SOF0: height 10, width 20
      0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, //
      0xFF, 0xD9,
    ]);
    final i = JpegInfo.read(bytes)!;
    expect([i.width, i.height, i.orientation, i.hasGps], [20, 10, 3, true]);
    expect(i.swapsAxes, isFalse);
  });

  test('not a JPEG, or truncated before the frame header: null', () {
    expect(JpegInfo.read(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isNull);
    expect(JpegInfo.read(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x00])), isNull);
    final plain = File('test/fixtures/plain_32x16.jpg').readAsBytesSync();
    expect(JpegInfo.read(Uint8List.sublistView(plain, 0, 20)), isNull);
  });

  group('stripGps', () {
    /// Index of the first occurrence of [needle] in [hay], or -1.
    int indexOf(Uint8List hay, List<int> needle) {
      outer:
      for (var i = 0; i + needle.length <= hay.length; i++) {
        for (var j = 0; j < needle.length; j++) {
          if (hay[i + j] != needle[j]) continue outer;
        }
        return i;
      }
      return -1;
    }

    test('removes the position, keeps orientation, size and every other byte', () {
      final original = File('test/fixtures/gps_rot6_32x16.jpg').readAsBytesSync();
      final r = JpegInfo.stripGps(original);
      expect([r.hadGps, r.stripped], [true, true]);
      expect(r.bytes.length, original.length);

      final after = JpegInfo.read(r.bytes)!;
      expect([after.width, after.height, after.orientation, after.hasGps], [32, 16, 6, false]);

      // Pillow stores 47° as the RATIONAL 47/1, little-endian. It is there
      // before and gone after.
      const lat47 = [47, 0, 0, 0, 1, 0, 0, 0];
      expect(indexOf(original, lat47), greaterThan(0));
      expect(indexOf(r.bytes, lat47), -1);

      // Only the EXIF segment changed: before it and after it, every byte of
      // the two files is identical. (Pillow writes APP0 "JFIF" first.)
      var pos = 2, app1Start = -1, app1End = -1;
      while (app1End < 0) {
        final len = (original[pos + 2] << 8) | original[pos + 3];
        if (original[pos + 1] == 0xE1) (app1Start, app1End) = (pos, pos + 2 + len);
        pos += 2 + len;
      }
      expect(r.bytes.sublist(0, app1Start), original.sublist(0, app1Start));
      expect(r.bytes.sublist(app1End), original.sublist(app1End));
      // The input is never modified.
      expect(JpegInfo.read(original)!.hasGps, isTrue);
    });

    test('output pinned: exactly the bytes Pillow verified', () {
      // tools/model_check/check_gps_stripping.py reads these pinned files with
      // Pillow (no GPS left, orientation kept, pixels identical); this test
      // keeps the Dart code producing exactly them.
      for (final name in ['gps_rot6_32x16.jpg', 'gps_24x24.jpg']) {
        final r = JpegInfo.stripGps(File('test/fixtures/$name').readAsBytesSync());
        expect(r.bytes, File('test/fixtures/stripped_$name').readAsBytesSync(), reason: name);
      }
    });

    test('GPS without an orientation tag', () {
      final r = JpegInfo.stripGps(File('test/fixtures/gps_24x24.jpg').readAsBytesSync());
      expect([r.hadGps, r.stripped], [true, true]);
      expect(JpegInfo.read(r.bytes)!.hasGps, isFalse);
    });

    test('nothing to strip: the same bytes back, marked clean', () {
      for (final f in ['plain_32x16.jpg', 'rot6_32x16.jpg']) {
        final original = File('test/fixtures/$f').readAsBytesSync();
        final r = JpegInfo.stripGps(original);
        expect([r.hadGps, r.stripped], [false, true], reason: f);
        expect(r.bytes, original, reason: f);
      }
    });

    Uint8List bigEndianWithGpsAt(int gpsOffset) => Uint8List.fromList([
          0xFF, 0xD8, //
          0xFF, 0xE1, 0x00, 0x40, //
          0x45, 0x78, 0x69, 0x66, 0x00, 0x00, //
          0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, //
          0x00, 0x02, //
          0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, //
          0x88, 0x25, 0x00, 0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, gpsOffset, //
          0x00, 0x00, 0x00, 0x00, //
          0x00, 0x01, //
          0x00, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x4E, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, //
          0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x0A, 0x00, 0x14, 0x03, //
          0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, //
          0xFF, 0xD9,
        ]);

    test('big-endian EXIF: the inline "N" goes, orientation 3 stays', () {
      final original = bigEndianWithGpsAt(0x26);
      final r = JpegInfo.stripGps(original);
      expect([r.hadGps, r.stripped], [true, true]);
      expect(indexOf(r.bytes, [0x4E, 0x00, 0x00, 0x00]), -1);
      final after = JpegInfo.read(r.bytes)!;
      expect([after.width, after.height, after.orientation, after.hasGps], [20, 10, 3, false]);
    });

    test('a GPS pointer outside the segment: original bytes back, NOT marked clean', () {
      final original = bigEndianWithGpsAt(0x7F);
      final r = JpegInfo.stripGps(original);
      expect([r.hadGps, r.stripped], [true, false]);
      expect(r.bytes, original);
    });
  });
}
