import 'dart:ui';

import 'package:conservation_app/widgets/capture_frame.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portrait 3:4 preview: the full width, centred vertically', () {
    expect(modelFieldOfView(const Size(300, 400)), const Rect.fromLTWH(0, 50, 300, 300));
  });

  test('landscape 4:3: the full height, centred horizontally', () {
    expect(modelFieldOfView(const Size(4000, 3000)), const Rect.fromLTWH(500, 0, 3000, 3000));
  });

  test('a square image is seen whole', () {
    expect(modelFieldOfView(const Size(224, 224)), const Rect.fromLTWH(0, 0, 224, 224));
  });

  test('the same scene region whichever way the pixels are stored', () {
    // A 4000 x 3000 sensor image stored sideways (displayed 3000 x 4000):
    // the square keeps its size and its centre, i.e. the same scene points.
    final stored = modelFieldOfView(const Size(4000, 3000));
    final shown = modelFieldOfView(const Size(3000, 4000));
    expect(stored.width, shown.width);
    expect(stored.center, const Offset(2000, 1500));
    expect(shown.center, const Offset(1500, 2000));
  });

  test('matches the reference crop of the measured photographs', () {
    // ref_01.jpg is 600 x 800; the reference resizes it to 224 x 299 and crops
    // rows 37..260 (crop offset 37 — measurement report run 122950). In the
    // original's coordinates the square is rows 100..700 of 800.
    final r = modelFieldOfView(const Size(600, 800));
    expect(r, const Rect.fromLTWH(0, 100, 600, 600));
    expect((r.top / 800 * 299).floor(), 37);
  });
}
