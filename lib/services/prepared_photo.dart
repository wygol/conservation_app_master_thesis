/// A photograph made ready for a record: GPS removed, measured, hashed.
///
/// Every later step works on THESE bytes — the model classifies them, Storage
/// receives them, `observation_media.sha256` is their hash. So what was
/// classified is provably what was stored, and a position embedded in the
/// original never travels further than this file. (The original itself stays
/// where it was: the gallery, or the camera plugin's cache file.)
library;

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'jpeg_metadata.dart';

enum PhotoOrigin { camera, gallery }

/// Why a photo cannot be attached, in words for the person holding the phone.
class PhotoRejected implements Exception {
  const PhotoRejected(this.message);
  final String message;

  @override
  String toString() => message;
}

class PreparedPhoto {
  const PreparedPhoto._({
    required this.bytes,
    required this.info,
    required this.sha256,
    required this.hadGps,
    required this.origin,
    this.capturedAt,
  });

  /// The photo as stored and classified — without GPS tags.
  final Uint8List bytes;
  final JpegInfo info;
  final String sha256;

  /// Whether the original carried a position (now removed).
  final bool hadGps;
  final PhotoOrigin origin;

  /// When the shutter was pressed. Unknown for a gallery photo: its EXIF
  /// capture time is not read yet, and the file time of the picker's copy
  /// would be wrong.
  final DateTime? capturedAt;

  /// Throws [PhotoRejected] for anything that is not a JPEG — the only format
  /// whose GPS tags the app can verifiably remove — and for a JPEG whose GPS
  /// tags could not be removed safely. Refusing is the fail-safe default: a
  /// photo with a position in it must not reach Storage or, later, the online
  /// service (sovereignty tier 2: the bare image only).
  static PreparedPhoto prepare(
    Uint8List original, {
    required PhotoOrigin origin,
    DateTime? capturedAt,
  }) {
    if (JpegInfo.read(original) == null) {
      throw const PhotoRejected(
          'Only JPEG photos can be attached for now. Photos from this app\'s '
          'camera always are; for a gallery photo, check the camera\'s format '
          'setting (HEIF is not supported yet).');
    }
    final strip = JpegInfo.stripGps(original);
    if (!strip.stripped) {
      throw const PhotoRejected(
          'This photo carries a GPS position that could not be removed safely, '
          'so it is not attached. Take the photo with this app\'s camera instead.');
    }
    final info = JpegInfo.read(strip.bytes)!;
    return PreparedPhoto._(
      bytes: strip.bytes,
      info: info,
      sha256: crypto.sha256.convert(strip.bytes).toString(),
      hadGps: strip.hadGps,
      origin: origin,
      capturedAt: capturedAt,
    );
  }
}
