# 011 — Capture flow MVP: in-app camera with the model's frame, GPS-free photos, a raster web map, plant symbology
Date: 2026-10-11
Status: accepted for the MVP. Two parts are provisional until the thesis answers open questions 1 and 2
(`MasterThesis/app_agent_hints/2026-10-11_open_questions_for_the_app_mvp.md`): how a field photo is reduced
before the model, and calibration.
Thesis relevance: yes — the app now writes production `identifications` rows (P1, top-5 accuracy), decides
what leaves the device with a photo (sovereignty tier 2), and fixes the photo the model sees (train/serve).

## Context

René, 2026-10-11: one area for data input, one for visualisation, settings; Notes removed; a record with a
photo the model grades, a central frame while photographing, the schema's fields with good UI/UX; the most
likely species under the photo, the top 5 with their confidence one tap away; a simple web map with the
records' geometries and a symbology for families (and perhaps native vs neophyte).

State before: no capture flow; the record editor took typed coordinates and an optional checklist species;
the on-device model (ADR 009/010) ran only in the "Identify" tab, for the measurement round. Two thesis
questions bearing on the flow were open and still are: Q1 (reduction of a camera photo before `app_load`,
EXIF orientation) and Q2 (calibration file: temperature, thresholds, decision rule).

## Decision

1. **Navigation.** Records (capture and list) · Map · Settings. The model lab moves into Settings; the Notes
   screen is deleted (its table stays — dropping it is a migration nobody asked for).
2. **Camera.** An in-app camera (`camera` 0.12.1, CameraX on Android) at `ResolutionPreset.max`, with an
   overlay that dims everything but the centred square: exactly the crop of the reference preprocessing
   (`modelFieldOfView`, tested against the measured crop offset of `ref_01.jpg`). On the saved photo the
   frame is computed from the size the image decodes to, i.e. from what the model's decoder receives.
3. **Photos leave the camera without a position.** JPEG only. The EXIF GPS directory is blanked in place —
   entries, out-of-line values, count — so length, pixels and orientation are untouched
   (`JpegInfo.stripGps`; Pillow 12.3.0 confirms: GPS gone, orientation kept, pixels identical). If the GPS
   tags cannot be removed safely, the photo is refused. The model classifies these bytes, Storage receives
   them, `observation_media.sha256` is their hash, and `exif_stripped` is therefore always true.
4. **The model in the flow.** `OfflineModelIdentificationService` runs on the photo as taken (Q1 open: the
   measured 12 MP path). The top-5 is shown immediately; scores are labelled "not calibrated" (Q2 open). On
   save it becomes one `offline_model` row: `confidence_raw` = top-1 softmax at T = 1,
   `confidence_calibrated` null, `checklist_masked` false, `top_k` in the thesis' shape
   `{taxon_id, name, score}` plus `rank` and `class_id`, `identified_by` = the provider string,
   `date_identified` = the time the model answered on the device, `model_version_id` looked up by the
   file's SHA-256 (null when unregistered), `identification_remarks` naming the score type, the file hash,
   and the input's stored size and EXIF orientation. **Never accepted** on insert.
5. **A person's determination** stays restricted to the park checklist (the existing rule) and goes through
   `record_identification()`. A model candidate counts as "on the checklist" only through the join the
   schema designed: the GBIF key for a species class, the exact name for a genus class. No name matching.
6. **Location.** The best fix (smallest reported accuracy) while the record is open;
   `coordinate_uncertainty_m` = the device-reported accuracy, or null when the device gives none; the
   method in `georeference_protocol`. Fallback: set by hand on a map, with an optional uncertainty estimate.
   `country_code` is left to the park (the export already falls back to it).
7. **Save order and partial failure.** Observation → photo upload → media row → model suggestion → person's
   determination. The suggestion is stored only if its photo was; every failed step is named to the person.
8. **Map.** `flutter_map` 8.3.2 with raster tiles straight from their publishers: basemap.at grey (default),
   standard and orthophoto (CC BY 4.0, Austria), and OpenStreetMap. Markers from `observations_wide`
   centroids; polygon outlines when PostgREST returns GeoJSON.
9. **Symbology** behind a new core seam, `RecordSymbology` (same pattern as `IdentificationService`), with
   the plant implementation in the domain layer. Two colourings. *Family*: Asteraceae, Poaceae, Rosaceae in
   fixed palette slots (the three largest families of the label space), every other family a dark neutral,
   a record without a name hollow with "?". *Status*: confirmed / suggested by the model / awaiting, each
   with a glyph. Legend with counts; tapping an entry highlights it.
10. **Read side.** List and map read `identifications` themselves, because `observations_current` and
    `observations_wide` resolve names through `taxa` only and so show a model suggestion without a `taxa`
    row as "no name".

## Rationale

- The frame is a measurement fact, not decoration: nothing outside the centre square reaches the model.
  Showing it is the cheapest way to raise the share of usable photos, and it costs no model change.
- Stripping GPS on the device is what the schema already asked for ("strip it on the device, before
  upload") and what tier 2 requires — the bare image only — before the Pl@ntNet path exists. Blanking in
  place rather than re-encoding keeps the pixels bit-identical, so the bit-exact preprocessing of ADR 009
  still applies to what is stored.
- The app writes the full top-5 because top-5 accuracy cannot be recovered from the top-1 later, and it
  writes `class_id` because almost no candidate has a `taxa` row yet (below): without it a stored candidate
  could only be traced back to the label space by its display name.
- Raster tiles from the publisher need nothing to run. The constraint is "solo-maintainable, few moving
  parts" (CLAUDE.md §3, §5); a tile server is a moving part, and "where have we worked" needs no vector
  styling.
- Fixed family colours follow the entity, never its rank in the data (dataviz method), so adding a record
  can never repaint a family. Three hues is the most a map can carry: any two markers can be neighbours,
  so all pairs must separate, and the fourth palette slot would not.

## Alternatives rejected

- **The system camera via `image_picker`.** No overlay is possible, so the frame — the one guidance that
  matters to the model — could not be shown. (`image_picker` stays, for gallery photos.)
- **Martin + MapLibre GL (vector tiles).** Needs a tile server — another service to run and update — and a
  native map SDK binding; justified when styled vector layers are needed, not for points on a basemap. The
  basemap is one file (`widgets/basemaps.dart`); swapping later is cheap.
- **Google Maps.** An API key, a US service, and a usage contract — against the EU-sovereignty framing.
- **Storing a GPS-tagged photo with `exif_stripped = false`.** Legal by the schema, but the stored photo is
  what will later be sent to the online service: the coordinate would leave with it.
- **Re-encoding the JPEG to drop the EXIF block.** Changes the pixels; the model would no longer see what
  the reference preprocessing of the stored file sees.
- **Reducing photos (e.g. ≤ 800 px LANCZOS, JPEG q90, as the training images were stored) before the
  model.** Probably close to the thesis' answer to Q1, but it is the thesis' decision; until then the app
  uses the one path that was measured on the phone.
- **Applying the fitted temperature now** (T = 1.9123: `MasterThesis/ml-pipeline/arm2_scores.json` →
  `p3_shipped_int8.calibration.temperature`, checked by `tools/model_check/verify_report_numbers.py`). A
  value read from a scores file, without the decision rule, the thresholds and reference cases (Q2), cannot
  be verified on the phone. Temperature scaling would not change the order of the top-5 — only the scores.
- **Matching model labels to `taxa` by name.** "Leontopodium nivale subsp. alpinum (Cass.) Greuter" is not
  "Leontopodium nivale"; deciding otherwise is taxonomy, not app code.
- **Family colours ranked by frequency, or more than three coloured families.** Repaints on new data; and
  all-pairs separation fails beyond three hues.
- **A new migration (a view resolving verbatim names).** The schema was left unchanged in this step: the
  local Supabase was not running and a view could not be tested; a read-side join achieves the same.

## Consequences

- **Production data for the thesis.** Every record saved with a photo now carries a stored on-device
  answer with its top-5 and provenance. Its sibling, the online answer on the same photo, arrives when the
  Pl@ntNet adapter is written; the append-only log keeps both.
- **Provisional (Q1).** The model runs on the full-resolution photo: 0.41–0.46 s and a 473,089 kB peak on
  the S22 (measurement report §4) — above the 300 MB of O3b, and untested on smaller phones. Each stored
  answer records its input size and EXIF orientation, so the effect of the eventual reduction step can be
  assessed on these records.
- **Provisional (Q2).** Scores are shown and stored uncalibrated; `confidence_calibrated` stays null.
- **Data finding, not fixed here.** The seed's taxa do not share keys with the label space: `labels.csv`
  has Gentiana clusii as 7270031 where the seed has 5343979, and its edelweiss class is the subspecies
  *alpinum* (3140685) where the seed has the species (3111243). Of the seeded taxa only the genus class
  *Hieracium* joins. Until `taxa` and the park checklist are loaded from the label space (a tooling job),
  almost every suggestion is stored verbatim and cannot be taken over as a person's determination.
- **Schema observation, not changed (thesis-agent schema, for René).** `dwc_occurrence_export` drops a
  record whose accepted determination has no `taxa` row, but `dwc_export_readiness` does not list that as a
  blocker — such records would disappear from the export silently.
- **Not built.** Offline queue (the model works without a network; saving does not), the Pl@ntNet adapter,
  calibration, polygon capture, a photo for a record saved without one, native/neophyte symbology (no data:
  it needs e.g. `dwc:establishmentMeans` on the checklist — a schema decision), EXIF capture time for
  gallery photos.
- **Not verified on a device or against Supabase** at the time of writing: camera, GPS, upload and map
  were compiled, analysed and unit-tested, not run. Open device checks: EXIF orientation as decoded, preview
  vs capture aspect ratio, the geometry format PostgREST returns, upload to the placeholder bucket.
- OpenStreetMap's public tiles are for light use; production should default to basemap.at (Austria) or a
  contracted provider. The user agent is the Android application id, still `com.example.conservation_app`.
