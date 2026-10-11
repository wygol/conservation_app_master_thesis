# Map marker colours — validation (2026-10-11)

`validate_palette_output.txt` is the verbatim output of the dataviz skill's `validate_palette.js`
(node v24.14.1), run with `--mode light --pairs all`: on a map any two markers can sit side by side,
so every pair is checked, not only neighbours in a legend.

| Run | Palette | Result |
|---|---|---|
| 1 | the three family hues `#2A78D6 #EB6834 #1BAF7A` | separation passes: worst colour-blind pair ΔE 9.2 (target ≥ 8), worst normal-vision pair 24.0 (floor 15) |
| 2 | + the first "Other families" grey `#8A8A85` | **fails**: grey vs green ΔE 4.5 colour-blind, 14.2 normal vision |
| 3 | + `#5C5B57` instead (**shipped**) | separation passes: worst colour-blind 9.2, worst normal-vision 19.8 |
| 4 | status: `#0CA30C #FAB219 #8A8A85` | separation passes: worst colour-blind 10.9, normal 20.2 |

Expected, not defects:
- the grey's "chroma floor" failure (runs 2–4): "other" and "awaiting" are meant to read as grey;
- the yellow's lightness-band failure and the contrast warnings (green 2.74, yellow 1.79 against a
  near-white surface). The validator requires relief for these, and the map gives it three ways: every
  marker has a white ring and a shadow, every status marker carries a glyph (✓ / ✦ / ?), and the legend
  names each colour, with the Records list as the table view.

The first version of the code used `#8A8A85` for "Other families". It never reached a phone: the only
build that contained it was a compile check, and run 2 replaced it the same afternoon.
