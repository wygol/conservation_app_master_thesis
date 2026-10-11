# Test fixtures

Tiny JPEGs with known EXIF content for `test/jpeg_metadata_test.dart`, generated with Pillow 12.3.0
(2026-10-11) by the snippet below; each was read back with Pillow to confirm its content.

| file | pixels as stored | EXIF orientation | GPS tags |
|---|---|---|---|
| `plain_32x16.jpg` | 32 × 16 | none | none |
| `rot6_32x16.jpg` | 32 × 16 | 6 (displayed 16 × 32) | none |
| `gps_rot6_32x16.jpg` | 32 × 16 | 6 | lat 47° 9′ N, lon 12° 45′ E |
| `gps_24x24.jpg` | 24 × 24 | none | lat 47° 9′ N, lon 12° 45′ E |

```python
from PIL import Image, ExifTags
def make(path, size, orientation=None, gps=False):
    im = Image.new("RGB", size, (40, 120, 60))
    ex = Image.Exif()
    if orientation: ex[ExifTags.Base.Orientation] = orientation
    if gps:
        ex.get_ifd(ExifTags.IFD.GPSInfo).update({
            ExifTags.GPS.GPSLatitudeRef: "N", ExifTags.GPS.GPSLatitude: (47.0, 9.0, 0.0),
            ExifTags.GPS.GPSLongitudeRef: "E", ExifTags.GPS.GPSLongitude: (12.0, 45.0, 0.0)})
    kw = {"exif": ex.tobytes()} if (orientation or gps) else {}
    im.save(path, "JPEG", quality=90, **kw)
```

Pillow writes little-endian EXIF; the big-endian case is built byte by byte inside the test.

## GPS stripping (2026-10-11)

`stripped_gps_rot6_32x16.jpg` and `stripped_gps_24x24.jpg` are the output of `JpegInfo.stripGps`
(`lib/services/jpeg_metadata.dart`) for the two GPS fixtures. `test/jpeg_metadata_test.dart` pins them
byte for byte; `tools/model_check/check_gps_stripping.py` reads originals and outputs with Pillow 12.3.0 and
checks: no GPS tags left, EXIF orientation unchanged, decoded pixels identical, same file length — all pass
(`docs/measurements/2026-10-11_gps_stripping/check_gps_stripping_output.txt`).
