/// Bit-exact port of Pillow's `Image.resize(..., Image.BILINEAR)` for 8-bit RGB.
///
/// Why this exists: the thesis model was trained, evaluated and will be
/// calibrated on images resized by Pillow (`app_load` in
/// ml-pipeline/export_arm2.py). On a downscale, Pillow's "bilinear" is NOT the
/// classic 2x2 interpolation: it widens the triangle filter by the downscale
/// factor, i.e. it antialiases. A desk study (docs/decisions/009) showed that a
/// classic bilinear resize passes the per-channel-mean check of the phone
/// handover but moves the logits by up to 6.4 — so the app reproduces Pillow
/// exactly, including its 22-bit fixed-point rounding between the two passes.
///
/// Source of truth: Pillow `src/libImaging/Resample.c` — `precompute_coeffs`,
/// `normalize_coeffs_8bpc`, `ImagingResampleHorizontal_8bpc`,
/// `ImagingResampleVertical_8bpc`, `ImagingResampleInner`. The same algorithm,
/// mirrored in Python, was verified bit-exact against Pillow 12.3.0 on the five
/// reference photographs, a 4000x3000 image and odd/edge sizes;
/// test/ml/pillow_resize_test.dart pins this Dart version to Pillow's output.
library;

import 'dart:math' as math;
import 'dart:typed_data';

const int _precisionBits = 32 - 8 - 2; // PRECISION_BITS in Resample.c
const int _half = 1 << (_precisionBits - 1); // rounding offset ("ss = 1 << 21")
const int _clipLimit = (1 << _precisionBits) << 8; // "1 << PRECISION_BITS << 8"

/// Python 3 `round(x)` for a float: nearest integer, ties to even.
///
/// The reference computes its target size with Python's `round`, and Dart's
/// `round()` rounds ties away from zero, so the two disagree on exact .5 cases.
int pythonRound(double x) {
  final double f = x.floorToDouble();
  final double diff = x - f; // exact for the magnitudes used here
  final int fi = f.toInt();
  if (diff > 0.5) return fi + 1;
  if (diff < 0.5) return fi;
  return fi.isEven ? fi : fi + 1;
}

/// The reference target size: shorter side scaled to [size], other side by the
/// same factor, rounded like Python, never below [size].
(int, int) referenceTargetSize(int width, int height, {int size = 224}) {
  final double s = size / math.min(width, height);
  return (
    math.max(size, pythonRound(width * s)),
    math.max(size, pythonRound(height * s)),
  );
}

class _Coefficients {
  _Coefficients(this.ksize, this.bounds, this.weights);

  /// Allocated taps per output sample ("ksize").
  final int ksize;

  /// Pairs per output sample: first source index, number of taps used.
  final Int32List bounds;

  /// `outSize * ksize` fixed-point weights (at most 2^22, fits in 32 bits).
  final Int32List weights;
}

double _triangle(double x) {
  final double a = x < 0.0 ? -x : x;
  return a < 1.0 ? 1.0 - a : 0.0;
}

/// `precompute_coeffs` + `normalize_coeffs_8bpc` for box (0, inSize).
_Coefficients _precompute(int inSize, int outSize) {
  final double scale = inSize / outSize;
  final double filterscale = scale < 1.0 ? 1.0 : scale;
  final double support = 1.0 * filterscale; // bilinear support = 1.0
  final int ksize = support.ceil() * 2 + 1;
  final double ss = 1.0 / filterscale;

  final bounds = Int32List(outSize * 2);
  final weights = Int32List(outSize * ksize);
  final pre = Float64List(ksize);

  for (var xx = 0; xx < outSize; xx++) {
    final double center = (xx + 0.5) * scale;
    // C's (int) cast truncates toward zero; so does Dart's truncate().
    var xmin = (center - support + 0.5).truncate();
    if (xmin < 0) xmin = 0;
    var xmax = (center + support + 0.5).truncate();
    if (xmax > inSize) xmax = inSize;
    xmax -= xmin;

    var ww = 0.0;
    for (var x = 0; x < xmax; x++) {
      final double w = _triangle((x + xmin - center + 0.5) * ss);
      pre[x] = w;
      ww += w;
    }
    final int base = xx * ksize;
    for (var x = 0; x < xmax; x++) {
      final double k = ww != 0.0 ? pre[x] / ww : pre[x];
      weights[base + x] = k < 0
          ? (-0.5 + k * (1 << _precisionBits)).truncate()
          : (0.5 + k * (1 << _precisionBits)).truncate();
    }
    bounds[xx * 2] = xmin;
    bounds[xx * 2 + 1] = xmax;
  }
  return _Coefficients(ksize, bounds, weights);
}

int _clip8(int v) {
  if (v >= _clipLimit) return 255;
  if (v <= 0) return 0;
  return v >> _precisionBits;
}

/// Horizontal pass. [src] has [srcStride] bytes per pixel (3 = RGB, 4 = RGBA
/// with alpha ignored); the result is packed RGB, `outWidth x height`.
Uint8List _horizontal(
    Uint8List src, int width, int height, int srcStride, int outWidth) {
  final c = _precompute(width, outWidth);
  final out = Uint8List(outWidth * height * 3);
  final int rowBytes = width * srcStride;
  var o = 0;
  for (var y = 0; y < height; y++) {
    final int rowBase = y * rowBytes;
    for (var xx = 0; xx < outWidth; xx++) {
      final int xmin = c.bounds[xx * 2];
      final int n = c.bounds[xx * 2 + 1];
      final int kBase = xx * c.ksize;
      var s0 = _half, s1 = _half, s2 = _half;
      var p = rowBase + xmin * srcStride;
      for (var x = 0; x < n; x++) {
        final int k = c.weights[kBase + x];
        s0 += src[p] * k;
        s1 += src[p + 1] * k;
        s2 += src[p + 2] * k;
        p += srcStride;
      }
      out[o] = _clip8(s0);
      out[o + 1] = _clip8(s1);
      out[o + 2] = _clip8(s2);
      o += 3;
    }
  }
  return out;
}

/// Vertical pass. [src] has [srcStride] bytes per pixel; result is packed RGB,
/// `width x outHeight`.
Uint8List _vertical(
    Uint8List src, int width, int height, int srcStride, int outHeight) {
  final c = _precompute(height, outHeight);
  final out = Uint8List(width * outHeight * 3);
  final int rowBytes = width * srcStride;
  var o = 0;
  for (var yy = 0; yy < outHeight; yy++) {
    final int ymin = c.bounds[yy * 2];
    final int n = c.bounds[yy * 2 + 1];
    final int kBase = yy * c.ksize;
    for (var xx = 0; xx < width; xx++) {
      var s0 = _half, s1 = _half, s2 = _half;
      var p = ymin * rowBytes + xx * srcStride;
      for (var y = 0; y < n; y++) {
        final int k = c.weights[kBase + y];
        s0 += src[p] * k;
        s1 += src[p + 1] * k;
        s2 += src[p + 2] * k;
        p += rowBytes;
      }
      out[o] = _clip8(s0);
      out[o + 1] = _clip8(s1);
      out[o + 2] = _clip8(s2);
      o += 3;
    }
  }
  return out;
}

/// Copies an RGB or RGBA buffer into packed RGB (alpha dropped).
Uint8List packRgb(Uint8List src, int width, int height, int srcStride) {
  final out = Uint8List(width * height * 3);
  if (srcStride == 3) {
    out.setRange(0, out.length, src);
    return out;
  }
  final int n = width * height;
  for (var i = 0, p = 0, o = 0; i < n; i++, p += srcStride, o += 3) {
    out[o] = src[p];
    out[o + 1] = src[p + 1];
    out[o + 2] = src[p + 2];
  }
  return out;
}

/// Pillow `Image.resize((outWidth, outHeight), Image.BILINEAR)` on an 8-bit
/// image whose pixels are [srcStride] bytes apart (3 = RGB, 4 = RGBA — Flutter's
/// decoder delivers RGBA, and reading it in place avoids a full-size copy).
/// Returns packed RGB. Bit-exact with Pillow, including pass order (horizontal
/// first) and the identity shortcut when the size does not change.
Uint8List pillowResizeBilinear(
  Uint8List src,
  int width,
  int height,
  int outWidth,
  int outHeight, {
  int srcStride = 3,
}) {
  if (srcStride != 3 && srcStride != 4) {
    throw ArgumentError.value(srcStride, 'srcStride', 'must be 3 or 4');
  }
  if (src.length < width * height * srcStride) {
    throw ArgumentError('Buffer too small for ${width}x$height x $srcStride');
  }
  final bool needHorizontal = outWidth != width;
  final bool needVertical = outHeight != height;
  if (!needHorizontal && !needVertical) {
    return packRgb(src, width, height, srcStride); // Pillow returns a copy
  }
  var current = src;
  var stride = srcStride;
  var currentWidth = width;
  if (needHorizontal) {
    current = _horizontal(current, width, height, stride, outWidth);
    stride = 3;
    currentWidth = outWidth;
  }
  if (needVertical) {
    current = _vertical(current, currentWidth, height, stride, outHeight);
  }
  return current;
}
