# 009 — On-device inference: tflite_flutter on LiteRT, Pillow-exact preprocessing, "no delegate" verified rather than assumed
Date: 2026-10-09
Status: accepted (for the measurement round; the capture-flow CPU configuration is decided after it);
decision 1 amended by 010 (2026-10-10): the runtime under tflite_flutter is LiteRT **1.4.2**, not 1.4.0 —
1.4.0's C API loaded the model's offset-stored weights as empty tensors
Thesis relevance: yes (O3a–O3c measurement method; train/serve consistency of the offline model)

## Context

The thesis' offline model (Arm 2: MobileNetV3-Large 0.75, 1,004 classes, weight-only INT8, 4.43 MB,
`assets/model/`) arrived with a contract (`ml-pipeline/arm2_export/README_for_app_agent.md`): input
`[1,224,224,3]` float32 RGB in [0,1]; shorter side to 224 with **Pillow `BILINEAR`**, centre crop;
ImageNet normalisation inside the model; 1,004 logits out, softmax in the app, labels by row of
`labels.csv`. Before measuring size, memory and latency (O3a–O3c), the app must reproduce the
desktop reference (`phone_reference.json`) within ±0.01 channel means, identical top-1, ≥4/5 top-5
and **±0.1 logits**. O3c follows Howard et al.: one large core, one thread, batch 1, **no delegate**.

Three facts, established before writing app code (desk study: `tools/model_check/desk_study.py`,
output with environment in `docs/measurements/2026-10-09_desk_study/desk_study_output.txt`;
Pillow 12.3.0, libjpeg-turbo 3.1.4.1, ai-edge-litert 2.3.0, x86 Linux — no phone involved):

1. **Pillow's `BILINEAR` is not classic bilinear.** On a downscale it widens the triangle filter by
   the scale factor (antialiasing) and rounds to 8 bits between its two passes. A classic
   (non-antialiased) bilinear resize — the default of common Dart image libraries — **passes the
   channel-mean criterion by a factor of 20–1000 (Δ ≤ 0.0005) but misses the logit criterion by
   10–64× (max |Δlogit| 1.05–6.39) and drops top-5 overlap to 3/5, below the ≥4 criterion, on one
   of the five photographs in each of the two naive variants tested.** Top-1 stays
   correct on these confident training-pool images, so the error would be invisible in casual
   testing — and it would silently shift every logit the thesis later calibrates (temperature,
   per-species thresholds are fitted on the reference pipeline's logits).
2. **The ±0.1 logit tolerance effectively requires a bit-exact JPEG decode too.** Perturbing the
   decoded pixels by ±1 grey level on 10 % of pixels already moves the worst logit by 0.127 (±1 on
   50 %: 0.343; ±2 on 20 %: 0.264), while top-1 and top-5 stay intact.
3. **A runtime's default can silently be XNNPACK.** On the desktop, LiteRT's default resolver
   applies XNNPACK (it logs "Created TensorFlow Lite XNNPACK delegate for CPU."), and plain
   kernels are ~3× slower there. `tflite_flutter` 0.12.1 offers **no switch to remove** a default
   delegate (`InterpreterOptions`: threads, NNAPI, Metal, addDelegate only), and nothing documents
   whether its LiteRT build (`libtensorflowlite_jni.so` from `com.google.ai.edge.litert:litert:1.4.0`)
   applies XNNPACK by default through the C API it binds to.

## Decision

1. **Runtime:** `tflite_flutter` **0.12.1, pinned exactly** (official publisher tensorflow.org;
   LiteRT 1.4.0 on Android; FFI-only plugin, no platform code). The interpreter is created once per
   process (`OfflineModel.shared()`) and kept alive; 1 thread; no explicit delegate.
2. **Preprocessing: a bit-exact Dart port of Pillow's resample** (`lib/ml/pillow_resize.dart`,
   from `libImaging/Resample.c`), Python's round-half-even for the target size, the reference's
   floor-division crop, float32 /255. It reads Flutter's RGBA buffer in place (no full-size copy).
3. **Decode with Flutter's engine** (`instantiateImageCodec`, Skia → libjpeg-turbo, the library
   Pillow also uses), at full resolution, no decode-time scaling.
4. **Correctness check with stage diagnostics:** besides the four handover criteria, the app hashes
   the decoded, resized and cropped pixels and compares them with Pillow's
   (`assets/model_check/stage_expectations.json`, generator in `tools/model_check/`), so a failure
   names its stage instead of being a bare FAIL.
5. **"No delegate" is established empirically, three ways, in one run:**
   (a) logcat — LiteRT logs XNNPACK creation once per process, and the no-delegate interpreter (C1)
   is created first, between markers; (b) a second binding — the LiteRT **Java API with
   `setUseXNNPACK(false)`** (`LiteRtJavaBench.kt`, C3), guaranteed no delegate, same native runtime;
   (c) if logcat shows XNNPACK was applied by default, the script additionally runs Google's
   **TFLite Benchmark Tool** with `--use_xnnpack=false` under `taskset` (Howard's literal tool).
   XNNPACK itself is measured as a separate configuration (C2), as the handover asks.
6. **Core pinning:** `sched_setaffinity` via dart:ffi on the timing thread (and on the Java bench
   thread by its kernel tid), to the single fastest core and to one core of the next cluster
   (on a Snapdragon 8 Gen 1: Cortex-X2 and a Cortex-A710 — both readings of "one large core"). The
   executing CPU is recorded after every timed run.
7. **Timing:** 20 warm-up + 100 timed runs (satisfies the Oct "≥10 + ≥50" and the Sept "20 + 100"
   protocols) of `invoke()` only — Dart `Stopwatch` (monotonic) for tflite_flutter, LiteRT's
   `getLastNativeInferenceDurationNanoseconds()` for the Java path. Median = mean of the two middle
   values; p90 = nearest rank; all raw runs kept.
8. **Memory (O3b):** `dumpsys meminfo` TOTAL PSS sampled by the script while the app classifies
   (never during latency runs), plus in-app `VmHWM` (peak RSS since process start, an upper bound)
   and `smaps_rollup` sampling from a separate isolate. Method stated with every number.
9. **No calibration, no threshold:** scores are an explicitly uncalibrated softmax (T = 1); no
   accept/decline decision anywhere in the app until the thesis supplies it.

## Rationale

Exactness is cheaper than arguing about tolerance: once the pipeline is bit-identical to Pillow,
any residual logit difference can only come from the decoder or the kernels, and the stage hashes
say which. Measuring the delegate question three ways turns an undocumented runtime default into
evidence, at the cost of one extra code path that also cross-validates the latency numbers. Pinning
plus per-run CPU records makes "one large core" a verifiable fact instead of a hope about the
scheduler. Everything runs in one fresh process from one command, so the round is repeatable.

## Alternatives rejected

- **`image` package (or any naive bilinear) for resizing** — fails the logit criterion by up to 64×
  while passing the means criterion (fact 1): a silent train/serve skew.
- **Decoding at reduced size** (`instantiateImageCodec(targetWidth: …)`, libjpeg DCT scaling) — saves
  memory on 12 MP photos but is a different filter than the reference's full decode + resize; kept
  as an option for the capture flow only if its logit impact is measured first.
- **Normalising (ImageNet mean/std) in the app** — the model already contains it; doing it twice is
  the classic failure the handover warns about.
- **`flutter_litert` (maintained community fork, LiteRT 1.4.2)** — source-compatible and the
  fallback if `tflite_flutter`'s AGP-8-era Gradle file fails under the app's AGP 9.0.1; not first
  choice because it is a third-party publisher and bundles additional runtimes (CompiledModel, GPU
  accelerator) by default — more moving parts and APK size for no gain in this round.
- **Java/Kotlin API as the app's main binding** — would give the XNNPACK switch, but moves inference
  out of Dart behind a platform channel for the whole app; kept as the measurement reference only.
- **Benchmark Tool only** — Howard's literal tool, but it reports mean/std, not median/p90, and it
  measures a different process than the app; used as a cross-check, not as the primary number.
- **Trusting the plugin's `lastNativeInferenceDurationMicroSeconds`** — measured with the wall clock
  (`DateTime.now()`), which can jump; replaced by a monotonic `Stopwatch`.
- **Measuring in a debug build** — JIT and debug services distort memory and Dart-side timing; the
  round uses the release build that also gives O3a.

## Consequences

- The app's preprocessing is now a contract with the thesis pipeline: if `ml-pipeline` ever changes
  `app_load` (resize filter, crop, scaling), `pillow_resize.dart`, its unit test vectors and
  `stage_expectations.json` must change with it.
- The bundled fixtures (`assets/model_check/`, ~3.9 MB incl. the synthetic 12 MP JPEG) are
  measurement-only; they inflate the APK but not the model file (O3a). Remove or keep as a
  self-test before release.
- tflite_flutter 0.12.1 does not build unmodified under this app's AGP 9 + `builtInKotlin=false`
  setup: its Kotlin target falls back to the build JDK (21) while its Java target is 11. A scoped
  alignment in `android/build.gradle.kts` is required (2026-10-10, process log session 8) — remove it
  once the plugin sets its Kotlin target itself, or when moving to built-in Kotlin.
- Two native bindings ship in this round (tflite_flutter FFI + LiteRT Java API, one shared runtime
  library). After the measurements, the capture flow keeps one CPU configuration — decided from the
  measured C1/C2 numbers, not assumed.
- Open for the capture flow (not decided here): EXIF orientation of camera photos (the reference
  `app_load` does not apply it; the Sept-27 handover suggests applying it "as the user sees the
  photo"), and how a 12 MP photo is decoded within the memory budget.
