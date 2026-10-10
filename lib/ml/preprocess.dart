/// The app's image preprocessing — a faithful re-implementation of the thesis
/// reference `export_arm2.app_load`:
///
///   decode (no resize at decode time)
///   -> resize so the shorter side is 224, Pillow BILINEAR, Python rounding
///   -> centre crop 224 x 224, offsets `(w - 224) // 2`
///   -> RGB / 255 as float32, NHWC
///
/// ImageNet mean/std normalisation is INSIDE the model; it is deliberately not
/// applied here.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';

import 'pillow_resize.dart';

/// Edge length of the model input.
const int kModelInputSize = 224;

/// A decoded image as Flutter's engine delivers it: RGBA, 4 bytes per pixel.
class DecodedRgba {
  DecodedRgba(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;
}

/// Decodes [encoded] with Flutter's engine at full resolution.
///
/// For JPEG this goes through libjpeg-turbo — the same library Pillow uses —
/// which is the best available chance of bit-identical pixels. Whether it IS
/// bit-identical on a given phone is measured, not assumed: the correctness
/// check compares a hash of the decoded pixels with Pillow's
/// (assets/model_check/stage_expectations.json).
Future<DecodedRgba> decodeImage(Uint8List encoded) async {
  final codec = await ui.instantiateImageCodec(encoded);
  try {
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) throw StateError('Image readback returned no data');
      return DecodedRgba(
        image.width,
        image.height,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// Result of the reference preprocessing, with the intermediate stages kept
/// for the diagnostics of the correctness check.
class PreprocessedImage {
  PreprocessedImage({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.targetWidth,
    required this.targetHeight,
    required this.cropLeft,
    required this.cropTop,
    required this.resizedRgb,
    required this.croppedRgb,
    required this.input,
  });

  final int sourceWidth;
  final int sourceHeight;
  final int targetWidth;
  final int targetHeight;
  final int cropLeft;
  final int cropTop;

  /// Packed RGB, targetWidth x targetHeight.
  final Uint8List resizedRgb;

  /// Packed RGB, 224 x 224.
  final Uint8List croppedRgb;

  /// The model input: [1, 224, 224, 3] float32 in [0, 1], NHWC order.
  final Float32List input;

  /// Per-channel means of [input], the quantity the handover compares.
  List<double> get channelMeans => inputChannelMeans(input);
}

PreprocessedImage preprocessLikeReference(DecodedRgba decoded,
    {int size = kModelInputSize}) {
  final (tw, th) =
      referenceTargetSize(decoded.width, decoded.height, size: size);
  final resized = pillowResizeBilinear(
      decoded.rgba, decoded.width, decoded.height, tw, th,
      srcStride: 4);
  final left = (tw - size) ~/ 2;
  final top = (th - size) ~/ 2;
  final cropped = Uint8List(size * size * 3);
  final rowBytes = size * 3;
  for (var y = 0; y < size; y++) {
    cropped.setRange(
        y * rowBytes, (y + 1) * rowBytes, resized, ((top + y) * tw + left) * 3);
  }
  final input = Float32List(size * size * 3);
  for (var i = 0; i < cropped.length; i++) {
    // Double division, stored as float32: identical to numpy's float32
    // division for all 256 byte values (checked exhaustively).
    input[i] = cropped[i] / 255.0;
  }
  return PreprocessedImage(
    sourceWidth: decoded.width,
    sourceHeight: decoded.height,
    targetWidth: tw,
    targetHeight: th,
    cropLeft: left,
    cropTop: top,
    resizedRgb: resized,
    croppedRgb: cropped,
    input: input,
  );
}

/// The uniform grey input of the handover: every value 0.5, no file involved.
Float32List greyInput({int size = kModelInputSize}) =>
    Float32List(size * size * 3)..fillRange(0, size * size * 3, 0.5);

List<double> inputChannelMeans(Float32List input) {
  final sums = [0.0, 0.0, 0.0];
  for (var i = 0; i < input.length; i += 3) {
    sums[0] += input[i];
    sums[1] += input[i + 1];
    sums[2] += input[i + 2];
  }
  final n = input.length / 3;
  return [sums[0] / n, sums[1] / n, sums[2] / n];
}

/// Checksums of one pipeline stage, in the convention of
/// tools/model_check/make_stage_expectations.py: SHA-256 over the H x W x 3
/// RGB bytes in row-major order, plus integer channel sums.
class StageDigest {
  StageDigest(this.width, this.height, this.channelSums, this.sha256Hex);

  final int width;
  final int height;
  final List<int> channelSums;
  final String sha256Hex;

  Map<String, Object?> toJson() => {
        'width': width,
        'height': height,
        'channel_sums_rgb': channelSums,
        'sha256_rgb': sha256Hex,
      };

  /// Compares with an expectation entry from stage_expectations.json.
  bool matches(Map<String, dynamic> expected) =>
      expected['width'] == width &&
      expected['height'] == height &&
      expected['sha256_rgb'] == sha256Hex;
}

StageDigest digestRgb(Uint8List rgb, int width, int height) {
  var s0 = 0, s1 = 0, s2 = 0;
  for (var i = 0; i < width * height * 3; i += 3) {
    s0 += rgb[i];
    s1 += rgb[i + 1];
    s2 += rgb[i + 2];
  }
  final bytes = rgb.length == width * height * 3
      ? rgb
      : Uint8List.sublistView(rgb, 0, width * height * 3);
  return StageDigest(width, height, [s0, s1, s2], sha256.convert(bytes).toString());
}

/// Digest of the RGB part of an RGBA buffer, streamed row by row so that a
/// 12-megapixel image does not need a second full-size copy.
StageDigest digestRgbaAsRgb(Uint8List rgba, int width, int height) {
  final sink = _DigestSink();
  final conversion = sha256.startChunkedConversion(sink);
  final row = Uint8List(width * 3);
  var s0 = 0, s1 = 0, s2 = 0;
  for (var y = 0; y < height; y++) {
    var p = y * width * 4;
    for (var o = 0; o < width * 3; o += 3) {
      final r = rgba[p], g = rgba[p + 1], b = rgba[p + 2];
      row[o] = r;
      row[o + 1] = g;
      row[o + 2] = b;
      s0 += r;
      s1 += g;
      s2 += b;
      p += 4;
    }
    conversion.add(row); // the hash copies the bytes, so the buffer is reused
  }
  conversion.close();
  return StageDigest(width, height, [s0, s1, s2], sink.value.toString());
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
