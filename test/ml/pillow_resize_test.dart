// Pins lib/ml/pillow_resize.dart to Pillow's output.
//
// The input is a deterministic pattern both languages can generate, so no
// image needs embedding:  v(x, y, c) = (7x + 13y + 101c + (x*y mod 17)) mod 256.
// Expected hashes/sums were produced with Pillow 12.3.0:
//   Image.fromarray(pattern).resize(target, Image.BILINEAR)
// with target = the reference rule (shorter side 224, Python round), and the
// crop = the reference centre crop (offsets (w-224)//2, (h-224)//2).

import 'dart:typed_data';

import 'package:conservation_app/ml/pillow_resize.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List pattern(int w, int h, {int stride = 3}) {
  final out = Uint8List(w * h * stride);
  var p = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < 3; c++) {
        out[p + c] = (x * 7 + y * 13 + c * 101 + (x * y) % 17) % 256;
      }
      if (stride == 4) out[p + 3] = 255;
      p += stride;
    }
  }
  return out;
}

Uint8List crop224(Uint8List rgb, int w, int h) {
  final left = (w - 224) ~/ 2, top = (h - 224) ~/ 2;
  final out = Uint8List(224 * 224 * 3);
  for (var y = 0; y < 224; y++) {
    out.setRange(y * 672, (y + 1) * 672, rgb, ((top + y) * w + left) * 3);
  }
  return out;
}

List<int> sums(Uint8List rgb) {
  final s = [0, 0, 0];
  for (var i = 0; i < rgb.length; i += 3) {
    s[0] += rgb[i];
    s[1] += rgb[i + 1];
    s[2] += rgb[i + 2];
  }
  return s;
}

class Case {
  const Case(this.w, this.h, this.tw, this.th, this.resizedSha, this.cropSha,
      this.resizedSums);
  final int w, h, tw, th;
  final String resizedSha, cropSha;
  final List<int> resizedSums;
}

const cases = [
  Case(300, 250, 269, 224,
      '54411c70d37b00264d52cfdfc626175eb79ee570d1b21b8f967b39d5d94fcb14',
      'e086f7c0796fbd99c4f0d320475d04d5bebc77b7ce22ed07c84980fb1452d35d',
      [7678871, 7683432, 7682933]),
  Case(1000, 700, 320, 224,
      'f2de9fee4574d81e8cc9ed56c44a703f35002d8fae2a6c9d20601e9132390cc0',
      'dc0c042758b480a8a9bc60f8cead97c82f4dd6fc3a4d5344de280d37755f1d01',
      [9138201, 9139059, 9138311]),
  Case(61, 45, 304, 224,
      '19e73bb29b97b84154f0dedd9dbb9769ed447a34120b1d29140e876c78d3b883',
      'fbb79330b89f9160b80118037c275fb3c944f5eafa2438d7e57a25b7083fcf91',
      [8654085, 8755519, 8603069]),
  Case(224, 400, 224, 400,
      '877f454c7d324011aee0bf56235abd7746930483b2720c2c6a0efd37f45bea09',
      '522c4ce23f17126955f5dc63138571ffb1a893f820b67f617b801755e186f31f',
      [11422876, 11422876, 11421340]),
  Case(600, 800, 224, 299,
      'dadbcb4b92928a833b7bc33926e5d9022a51bba37e1ffe01190a441569d211da',
      'ac2ff7d7d3d47d01b3bd35c98f4de00832f574785cc4013aa80e3dc3a5a93f48',
      [8539417, 8539659, 8538737]),
  Case(533, 800, 224, 336,
      '57cdc7b526166cdc20924886859eb4a40ad41b3efdd5fb5009a3c09a016d072a',
      'db5b6bdccd8d8f65d9c2c3b955948f76b4907874acf5cc3b9534809d85806e7b',
      [9597067, 9596445, 9596472]),
];

void main() {
  group('pythonRound matches Python 3 round()', () {
    final expected = <double, int>{
      0.5: 0,
      1.5: 2,
      2.5: 2,
      3.5: 4,
      298.5: 298,
      299.5: 300,
      2.4999999999999996: 2,
      298.66666666666663: 299,
    };
    expected.forEach((x, r) {
      test('$x -> $r', () => expect(pythonRound(x), r));
    });
  });

  test('reference target sizes of the handover photographs', () {
    expect(referenceTargetSize(600, 800), (224, 299));
    expect(referenceTargetSize(533, 800), (224, 336));
    expect(referenceTargetSize(800, 450), (398, 224));
    expect(referenceTargetSize(4000, 3000), (299, 224));
  });

  for (final c in cases) {
    test('${c.w}x${c.h} -> ${c.tw}x${c.th} is bit-exact with Pillow', () {
      expect(referenceTargetSize(c.w, c.h), (c.tw, c.th));
      final resized = pillowResizeBilinear(pattern(c.w, c.h), c.w, c.h, c.tw, c.th);
      expect(sums(resized), c.resizedSums);
      expect(sha256.convert(resized).toString(), c.resizedSha);
      expect(sha256.convert(crop224(resized, c.tw, c.th)).toString(), c.cropSha);
    });

    test('${c.w}x${c.h}: reading RGBA in place gives the same bytes', () {
      final viaRgba = pillowResizeBilinear(
          pattern(c.w, c.h, stride: 4), c.w, c.h, c.tw, c.th,
          srcStride: 4);
      expect(sha256.convert(viaRgba).toString(), c.resizedSha);
    });
  }
}
