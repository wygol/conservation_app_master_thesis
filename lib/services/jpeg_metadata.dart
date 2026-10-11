/// A minimal JPEG header reader — pixel size, EXIF orientation, whether the
/// file carries GPS tags — and the one write the app needs: removing those GPS
/// tags. Neither decodes image data, so both are cheap even for a 12 MP
/// photograph (the full decode of one costs ~470 MB on the S22 — measurement
/// report 2026-10-10, §4).
///
/// Why the app needs it:
///  * `observation_media` stores width, height and `exif_stripped`. The schema
///    asks for GPS to be stripped on the device before upload ("a second copy
///    of the coordinate that no export policy governs"), and sovereignty tier 2
///    sends the bare image — never a coordinate — to the online service. A
///    photo from the in-app camera normally has no GPS tags; one from the
///    gallery usually does.
///  * The display aspect ratio depends on the EXIF orientation: cameras often
///    store the pixels sideways and set orientation 6 instead of rotating them.
library;

import 'dart:typed_data';

class JpegInfo {
  const JpegInfo({
    required this.width,
    required this.height,
    this.orientation = 1,
    this.hasGps = false,
  });

  /// Pixel size as stored, before any EXIF rotation.
  final int width;
  final int height;

  /// EXIF orientation 1–8; 1 = display as stored.
  final int orientation;

  /// True when the EXIF block contains a non-empty GPS directory.
  final bool hasGps;

  /// Orientations 5–8 turn the image by 90°: width and height swap on screen.
  bool get swapsAxes => orientation >= 5 && orientation <= 8;
  int get displayWidth => swapsAxes ? height : width;
  int get displayHeight => swapsAxes ? width : height;

  /// Reads the header of [bytes]; null when it is not a JPEG with a frame header.
  static JpegInfo? read(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
    int? width;
    int? height;
    var orientation = 1;
    var hasGps = false;
    var pos = 2;
    while (pos + 4 <= bytes.length) {
      if (bytes[pos] != 0xFF) break; // not at a marker: malformed, stop reading
      final marker = bytes[pos + 1];
      if (marker == 0xFF) {
        pos++; // fill byte
        continue;
      }
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        pos += 2; // markers without a length field
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) break; // end of image / start of scan
      final length = (bytes[pos + 2] << 8) | bytes[pos + 3];
      final start = pos + 4;
      final end = pos + 2 + length;
      if (length < 2 || end > bytes.length) break;

      if (marker == 0xE1 && _isExif(bytes, start, end)) {
        final exif = _readExif(bytes, start + 6, end);
        orientation = exif.orientation;
        hasGps = hasGps || exif.hasGps;
      } else if (_isFrameHeader(marker) && start + 5 <= end) {
        height = (bytes[start + 1] << 8) | bytes[start + 2];
        width = (bytes[start + 3] << 8) | bytes[start + 4];
      }
      pos = end;
    }
    if (width == null || height == null) return null;
    return JpegInfo(
      width: width,
      height: height,
      orientation: (orientation >= 1 && orientation <= 8) ? orientation : 1,
      hasGps: hasGps,
    );
  }

  /// SOF0–SOF15, except DHT (C4), JPG (C8) and DAC (CC), which share the range.
  static bool _isFrameHeader(int m) =>
      m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC;

  static bool _isExif(Uint8List b, int start, int end) =>
      end - start >= 14 &&
      b[start] == 0x45 && b[start + 1] == 0x78 && b[start + 2] == 0x69 && // "Exi"
      b[start + 3] == 0x66 && b[start + 4] == 0 && b[start + 5] == 0; // "f\0\0"

  /// Walks IFD0 of the TIFF structure that starts at [tiff] (offsets in TIFF
  /// are relative to it) and stops at [end], the end of the APP1 segment.
  static ({int orientation, bool hasGps}) _readExif(Uint8List b, int tiff, int end) {
    const none = (orientation: 1, hasGps: false);
    if (tiff + 8 > end) return none;
    final little = b[tiff] == 0x49 && b[tiff + 1] == 0x49; // "II"
    final big = b[tiff] == 0x4D && b[tiff + 1] == 0x4D; // "MM"
    if (!little && !big) return none;
    int u16(int at) => little ? b[at] | (b[at + 1] << 8) : (b[at] << 8) | b[at + 1];
    int u32(int at) => little
        ? b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)
        : (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    if (u16(tiff + 2) != 42) return none;

    final ifd0 = tiff + u32(tiff + 4);
    if (ifd0 + 2 > end) return none;
    final count = u16(ifd0);
    var orientation = 1;
    var hasGps = false;
    for (var i = 0; i < count; i++) {
      final entry = ifd0 + 2 + 12 * i;
      if (entry + 12 > end) break;
      final tag = u16(entry);
      if (tag == 0x0112) {
        orientation = u16(entry + 8); // SHORT, stored in the value field
      } else if (tag == 0x8825) {
        final gpsIfd = tiff + u32(entry + 8); // pointer to the GPS directory
        hasGps = gpsIfd + 2 <= end && u16(gpsIfd) > 0;
      }
    }
    return (orientation: orientation, hasGps: hasGps);
  }

  /// A copy of [bytes] without GPS tags, plus what was done.
  ///
  /// Every entry of the EXIF GPS directory, and every value an entry points
  /// to, is overwritten with zeros, and the directory's entry count is set to
  /// 0. The file keeps its length and every other byte — orientation, pixels,
  /// the rest of the EXIF — so the photo shows, and is classified, exactly as
  /// before. Re-encoding the JPEG would change the pixels the model sees.
  ///
  /// When GPS tags are present but cannot be removed safely (offsets outside
  /// the segment, an unknown value type), the ORIGINAL bytes come back with
  /// `stripped: false` — never a half-stripped file that looks clean. The
  /// caller records that as `exif_stripped = false`.
  ///
  /// Not covered: a position in an XMP packet. Cameras write it to EXIF.
  static GpsStripResult stripGps(Uint8List bytes) {
    final out = Uint8List.fromList(bytes);
    var hadGps = false;
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
      return GpsStripResult(bytes, hadGps: false, stripped: true);
    }
    var pos = 2;
    while (pos + 4 <= out.length) {
      if (out[pos] != 0xFF) break;
      final marker = out[pos + 1];
      if (marker == 0xFF) {
        pos++;
        continue;
      }
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        pos += 2;
        continue;
      }
      if (marker == 0xD9 || marker == 0xDA) break;
      final length = (out[pos + 2] << 8) | out[pos + 3];
      final start = pos + 4;
      final end = pos + 2 + length;
      if (length < 2 || end > out.length) break;
      if (marker == 0xE1 && _isExif(out, start, end)) {
        final r = _blankGpsDirectory(out, start + 6, end);
        hadGps = hadGps || r.found;
        if (r.found && !r.blanked) {
          return GpsStripResult(bytes, hadGps: true, stripped: false);
        }
      }
      pos = end;
    }
    return GpsStripResult(hadGps ? out : bytes, hadGps: hadGps, stripped: true);
  }

  /// Bytes per value of each TIFF field type (TIFF 6.0 §2, plus FLOAT/DOUBLE).
  static const _typeSize = {
    1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8,
  };

  static ({bool found, bool blanked}) _blankGpsDirectory(Uint8List b, int tiff, int end) {
    const nothing = (found: false, blanked: true);
    if (tiff + 8 > end) return nothing;
    final little = b[tiff] == 0x49 && b[tiff + 1] == 0x49;
    final big = b[tiff] == 0x4D && b[tiff + 1] == 0x4D;
    if (!little && !big) return nothing;
    int u16(int at) => little ? b[at] | (b[at + 1] << 8) : (b[at] << 8) | b[at + 1];
    int u32(int at) => little
        ? b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)
        : (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    if (u16(tiff + 2) != 42) return nothing;
    final ifd0 = tiff + u32(tiff + 4);
    if (ifd0 + 2 > end) return nothing;

    for (var i = 0; i < u16(ifd0); i++) {
      final entry = ifd0 + 2 + 12 * i;
      if (entry + 12 > end) break;
      if (u16(entry) != 0x8825) continue;

      final gps = tiff + u32(entry + 8);
      if (gps + 2 > end) return (found: true, blanked: false);
      final count = u16(gps);
      if (count == 0) return nothing; // already empty
      final entriesEnd = gps + 2 + 12 * count;
      if (entriesEnd + 4 > end) return (found: true, blanked: false);

      // Check every entry before touching anything.
      final ranges = <(int, int)>[];
      for (var k = 0; k < count; k++) {
        final e = gps + 2 + 12 * k;
        final size = _typeSize[u16(e + 2)];
        if (size == null) return (found: true, blanked: false);
        final bytes = size * u32(e + 4);
        if (bytes > 4) {
          final at = tiff + u32(e + 8);
          if (at < tiff || at + bytes > end) return (found: true, blanked: false);
          ranges.add((at, at + bytes));
        }
      }
      for (final (from, to) in ranges) {
        b.fillRange(from, to, 0);
      }
      b.fillRange(gps, entriesEnd + 4, 0); // count, entries, next-IFD pointer
      return (found: true, blanked: true);
    }
    return nothing;
  }
}

/// What [JpegInfo.stripGps] did.
class GpsStripResult {
  const GpsStripResult(this.bytes, {required this.hadGps, required this.stripped});

  /// The photo to store and to classify.
  final Uint8List bytes;

  /// Whether the input carried a non-empty GPS directory.
  final bool hadGps;

  /// True when [bytes] carries no GPS tags — also when there were none.
  final bool stripped;
}
