"""Independent check of the app's GPS stripping (lib/services/jpeg_metadata.dart, JpegInfo.stripGps).

The app's output for two fixtures is pinned in test/fixtures/stripped_*.jpg (test/jpeg_metadata_test.dart
asserts the Dart code still produces exactly these bytes). This script reads original and stripped file
with Pillow - code that shares nothing with the app - and checks what stripping must guarantee:
no GPS tags left, EXIF orientation unchanged, decoded pixels identical, file length unchanged.

Run from the repo root:  python -I tools/model_check/check_gps_stripping.py
"""
import os
import sys

import PIL
from PIL import ExifTags, Image, ImageChops

PAIRS = [
    ("test/fixtures/gps_rot6_32x16.jpg", "test/fixtures/stripped_gps_rot6_32x16.jpg"),
    ("test/fixtures/gps_24x24.jpg", "test/fixtures/stripped_gps_24x24.jpg"),
]

print(f"Pillow {PIL.__version__}, Python {sys.version.split()[0]}")
failures = 0
for original, stripped in PAIRS:
    a, b = Image.open(original), Image.open(stripped)
    ea, eb = a.getexif(), b.getexif()
    gps_before = dict(ea.get_ifd(ExifTags.IFD.GPSInfo))
    gps_after = dict(eb.get_ifd(ExifTags.IFD.GPSInfo))
    a.load()
    b.load()
    checks = {
        "had GPS before": bool(gps_before),
        "no GPS after": not gps_after,
        "orientation unchanged": ea.get(ExifTags.Base.Orientation) == eb.get(ExifTags.Base.Orientation),
        "pixels identical": ImageChops.difference(a.convert("RGB"), b.convert("RGB")).getbbox() is None,
        "same file length": os.path.getsize(original) == os.path.getsize(stripped),
    }
    for name, ok in checks.items():
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}  {os.path.basename(original)}: {name}")
    print(f"      GPS before {gps_before}; after {gps_after}; "
          f"orientation {ea.get(ExifTags.Base.Orientation)} -> {eb.get(ExifTags.Base.Orientation)}")
print(f"{'ALL PASS' if failures == 0 else f'{failures} FAILED'}")
sys.exit(1 if failures else 0)
