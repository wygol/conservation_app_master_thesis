# Arm 2 on the phone — measurement report (2026-10-10)

*Written by the app agent from the raw files of run `2026-10-10_122950` (all figures below are from that run
unless stated otherwise). Every value carries how it was measured; nothing is estimated. A copy of this
report is in `MasterThesis/app_agent_hints/` for the thesis agent.*

## In short

| Objective (thesis definition) | Measured on a Galaxy S22 | Verdict |
|---|---|---|
| Correctness check of the handover (5 photographs + grey image) | 6/6 pass; logits within 0.00006 of the desktop reference (tolerance 0.1); preprocessing bit-identical to Pillow | **PASS** |
| **O3a** INT8 artefact ≤ 25 MB on disk | 4,425,408 bytes = **4.43 MB**, shipped unchanged in the APK | **met** |
| **O3b** peak runtime memory ≤ 300 MB on a physical phone | **257,693 kB** = 263.9 MB (dumpsys TOTAL PSS, peak while classifying) | **met** |
| **O3c** median ≤ 300 ms per image, one large core, 1 thread, batch 1, no delegate | **12.17 ms** on the Cortex-X2, **20.95 ms** on a Cortex-A710 | **met** |

Two findings beyond the handover: decoding a **12 MP photograph at full resolution** pushes memory to
**473,089 kB = 484.4 MB**, above the O3b budget (§4); and with the XNNPACK delegate the same model runs
about 30 % faster at identical correctness (§5).

## 1. Setup

- **Device:** Samsung Galaxy S22 (SM-S901U1), Snapdragon 8 Gen 1 (SM8450: 1 × Cortex-X2 at up to
  2.995 GHz = cpu 7, 3 × Cortex-A710 at up to 2.496 GHz = cpu 4–6, 4 × Cortex-A510 at up to 1.786 GHz),
  Android 16 (SDK 36), build `BP2A.250605.031.A3.S901U1UESAGZH3`. On USB power, battery 100 %. Thermal
  status 0 (no throttling) at start and end; SoC (AP) sensor 31.5 → 37.6 °C, skin 31.3 → 32.6 °C.
- **App:** release build (Flutter 3.44.1, Dart 3.12.1), started fresh by the script; it runs the protocol by
  itself (`MODEL_LAB_AUTORUN`), untouched. The model file and `labels.csv` (1,004 rows) are hash-checked on
  the device: SHA-256 `e0e182a8…` — the file the thesis exported and scored.
- **Runtime:** tflite_flutter 0.12.1 (dart:ffi → LiteRT C API) on **LiteRT 1.4.2** — its library reports
  `2.22.0-dev0+selfbuilt`. The plugin's own LiteRT 1.4.0 loads this file but cannot run it — it drops the
  weights stored at offsets (ADR 010; thesis hint `2026-10-10_arm2_phone_run_runtime_defect.md`). The model
  file is unchanged.
- **Configurations:**
  - **C1** — the app's own path: tflite_flutter, 1 thread, no delegate added. **Verified to receive no
    delegate by default**: C1 is the first interpreter in a fresh process, and the runtime's once-per-process
    line "Created TensorFlow Lite XNNPACK delegate for CPU." appears only when C2 adds XNNPACK explicitly.
    **C1 is Howard et al.'s "no delegate" condition.**
  - **C2** — as C1 plus the XNNPACK delegate, added explicitly with LiteRT's default options
    (single-threaded); XNNPACK took 208 of the 209 operators.
  - **C3** — the LiteRT Java API on the same runtime, `setUseXNNPACK(false)`: an independent second binding
    for the no-delegate figure.
- **Cores:** every configuration ran twice, pinned with `sched_setaffinity` to the X2 (cpu 7) and to an A710
  (cpu 4) — both readings of "one large core". Qualcomm core control parks the X2 while the phone idles, so
  the pin was refused at first (EINVAL) and held after a short spin had woken the core (110–120 ms; ADR 009,
  amendment 2026-10-10). The core is recorded after every timed run: **all 100 runs of all six
  configurations ran on the pinned core.**
- **Protocol:** 20 untimed warm-up runs, then 100 timed runs of `invoke()` alone (input already in the
  tensor), batch 1, input `ref_01.jpg` after the app's preprocessing. Median = mean of the two middle values;
  p90 = nearest rank (value at rank ⌈0.9 n⌉). Timers: Dart `Stopwatch` (monotonic) around `invoke()` for C1/C2;
  LiteRT's `getLastNativeInferenceDurationNanoseconds()` for C3.

## 2. Correctness — the handover's check

Criteria from the handover: per-channel input means within 0.01, identical top-1, at least 4 of 5 top-5
indices shared, logits within 0.1 at the reference top-5 — against `phone_reference.json`.

| case | max \|Δ channel mean\| | top-1 (app = ref) | top-5 overlap | max \|Δ logit\| | pass |
|---|---|---|---|---|---|
| ref_01.jpg | 0.000004 | 974 = 974 | 5/5 | 0.00005 | ✓ |
| ref_02.jpg | 0.000002 | 86 = 86 | 5/5 | 0.00005 | ✓ |
| ref_03.jpg | 0.000004 | 86 = 86 | 5/5 | 0.00003 | ✓ |
| ref_04.jpg | 0.000003 | 0 = 0 | 5/5 | 0.00006 | ✓ |
| ref_05.jpg | 0.000002 | 0 = 0 | 5/5 | 0.00005 | ✓ |
| grey (all 0.5) | 0 | 998 = 998 | 5/5 | 0.00005 | ✓ |

- The table is C1. **C2 and C3 pass the same check 6/6** (max |Δ logit| 0.00006 each).
- **Preprocessing is bit-identical to Pillow at every stage** — the decoded, resized and cropped pixels hash
  equal to Pillow's — for all five photographs and for a synthetic 4000 × 3000 JPEG.
- Conclusion: on this phone, the app computes what the thesis scored. The test-set figures of the shipped
  model describe what the phone computes, up to differences of 0.00006 in the logits.

## 3. O3a — model size: met

The model entry inside the release APK is **4,425,408 bytes (4.43 MB)**, SHA-256 equal to the scored file,
stored **uncompressed** (memory-mappable). Target ≤ 25 MB. (The APK as a whole is 87,632,079 bytes: a
universal build with the native libraries for every ABI and about 3.9 MB of measurement fixtures — not O3a.)

## 4. O3b — peak memory: met (with a 12 MP caveat)

- **Method** (ADR 009, decision 8): `adb shell dumpsys meminfo` — the app summary's TOTAL PSS — sampled
  back-to-back by the script while the app ran **100 classifications** (5 reference photographs × 20, full
  pipeline: decode → preprocessing → `invoke()`); 32 samples. dumpsys reports kB = 1,024 bytes.
- **Peak: 257,693 kB = 263.9 MB = 251.7 MiB.** Target ≤ 300 MB.
- **What the number contains:** the whole app process, including Flutter's GPU rendering. Before the model
  was loaded the idle app already used 167,382 kB (graphics 84,292 kB); after loading 201,999 kB; after the
  correctness check 236,822 kB.
- **Cross-checks inside the app:** `VmHWM` (peak resident set since process start, an upper bound for RSS)
  218,856 kB; `smaps_rollup` PSS sampled every 100 ms, maximum 140,091 kB (it does not count the graphics
  memory dumpsys adds).
- **Method caveat:** every dumpsys call triggers a garbage collection in the app; the Java heap is 2–9 MB
  here, so the effect on these figures is negligible.
- **12 MP photographs — beyond the handover, reported because the capture flow will meet them:** a synthetic
  4000 × 3000 JPEG (3.2 MB), decoded at full resolution as the reference pipeline does, through the same
  pipeline 3 times: **peak TOTAL PSS 473,089 kB = 484.4 MB** (14 samples), `VmHWM` 383,752 kB — **above
  300 MB**. Top-5 identical to the desktop reference. Per photograph: decode 288–336 ms, preprocessing
  104–121 ms, model run 11.7–12.1 ms (incl. tensor copies).

## 5. O3c — latency: met

`invoke()` only; 100 timed runs after 20 warm-up runs; 1 thread; batch 1.

| configuration | core | median | p90 | min | max |
|---|---|---|---|---|---|
| **C1** tflite_flutter, no delegate | **X2** | **12.17 ms** | 12.29 ms | 11.91 ms | 14.82 ms |
| **C1** tflite_flutter, no delegate | **A710** | **20.95 ms** | 21.71 ms | 20.72 ms | 23.70 ms |
| C2 + XNNPACK | X2 | 8.55 ms | 8.62 ms | 8.44 ms | 13.93 ms |
| C2 + XNNPACK | A710 | 15.77 ms | 15.84 ms | 15.63 ms | 18.49 ms |
| C3 Java API, no delegate | X2 | 12.29 ms | 12.37 ms | 11.94 ms | 17.27 ms |
| C3 Java API, no delegate | A710 | 18.45 ms | 21.16 ms | 17.63 ms | 25.22 ms |

- **Howard's condition is C1** (C3, the second binding, agrees on the X2 within about 1 %). Target ≤ 300 ms: met by a factor of
  about 25 (X2) and 14 (A710).
- **XNNPACK** (C2, reported separately as the handover asks) is about 30 % faster on the X2 and 25 % on the
  A710, with identical correctness.
- **Repeatability** — run `2026-10-10_120250`, same build and model, but with the pinning defect: on the A710,
  C1 20.81 ms and C2 15.65 ms (within 1 % of the table), C3 20.86 ms (13 % above). On the X2, C1 (unpinned,
  yet every run on cpu 7) had a median of 10.33 ms: its series fell from about 10.2 ms in the first runs to
  12.2 ms in the last, while run 122950 holds about 12.2 ms throughout. **The steady states agree; run
  120250 began in a faster transient state.** CPU frequency was not recorded, so its cause is not measured.
- **End to end per reference photograph** (decode + preprocessing + `invoke()`, C1, app thread not pinned):
  median 42.3 ms, p90 56.0 ms (n = 100). For 12 MP photographs see §4 (0.41–0.46 s each).
- Interpreter creation: C1 10.9 ms, C2 81.8 ms (XNNPACK rewrites the graph), C3 7.2 ms.

## 6. What this does not show

- **One device.** A 64-bit ARM flagship. Other phones are not measured; memory and latency are device
  figures, not "Android" figures.
- **Uncalibrated output:** softmax with T = 1; no temperature, no thresholds in the app yet.
- **No real camera photographs:** the 12 MP image is synthetic; EXIF orientation is not applied (the
  reference pipeline does not apply it either).
- **No endurance figures:** one short run of 55 s on USB power; battery drain and sustained thermal
  behaviour are TBD.
- Google's TFLite Benchmark Tool was not run — it was conditional on C1 receiving XNNPACK by default, which
  it did not.

## 7. Points for the thesis — the app agent's reading, not decisions

1. The handover's correctness check passes, and O3a, O3b and O3c are met on the S22 under the handover's
   conditions.
2. Both the X2 and the A710 are "one large core"; the thesis may quote both, or one with a reason.
3. **12 MP photographs:** full-resolution decoding exceeds the O3b budget. The capture flow needs a decision
   on how a camera photograph is reduced before `app_load`. The training and evaluation images were stored at
   ≤ 800 px long side (LANCZOS, JPEG q90, no rotation — `ml-pipeline/README.md`, invariants 11 and 13), so a
   reduction that mirrors that storage step would also bring a field photograph closer to the evaluated
   condition. That is a train/serve question for the thesis; the app implements what is decided.
4. **XNNPACK for the capture flow:** about 30 % faster at identical correctness; ADR 009 leaves the choice
   to these measurements.

## Provenance

- Raw files: `docs/measurements/2026-10-10_arm2_phone/raw/2026-10-10_122950/` — `measurement.json` (device,
  toolchain, APK/O3a, dumpsys samples, XNNPACK attribution), `report_app.json` (SHA-256 `9e34c964…`, verified
  by the script), `logcat_app.txt`, `dumpsys_snapshots.txt`, build and test logs.
- Script `tools/measure_model.ps1` version 1.2 (SHA-256 `8c940f3c…`); protocol `lib/ml/measurement_protocol.dart`;
  APK SHA-256 `ca0ba8f6…`; `flutter analyze` 0 errors / 0 warnings; unit tests `test/ml` passed.
- Earlier runs, kept as records: `103514` (build failed — Kotlin target), `105927` (first inference failed —
  runtime defect, ADR 010), `120250` (correctness passed; the script hung and the X2 pin failed — ADR 009
  amendment; used above for repeatability only).
