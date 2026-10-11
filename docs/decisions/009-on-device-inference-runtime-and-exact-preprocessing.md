# 009 — On-device inference: tflite_flutter on LiteRT, Pillow-exact preprocessing, "no delegate" verified rather than assumed
Date: 2026-10-09
Status: accepted (for the measurement round; the capture-flow CPU configuration is decided after it);
decision 1 amended by 010 (2026-10-10): the runtime under tflite_flutter is LiteRT **1.4.2**, not 1.4.0 —
1.4.0's C API loaded the model's offset-stored weights as empty tensors; decision 6 amended below
(2026-10-10): pinning wakes a core that core control has paused
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

## Amendment 2026-10-10 — decision 6: pinning under core control

**Context.** In run `2026-10-10_120250` every pin to the X2 (cpu 7) failed with EINVAL, every pin to the
A710 (cpu 4) succeeded. Cause, read on the device (`/sys/devices/system/cpu/cpu{0,4,7}/core_ctl`):
Qualcomm **core control pauses big cores while the phone idles** — at idle the X2 had `active_cpus=0`, the
A710 cluster keeps `min_cpus=2` of its 3 cores, and a core is paused after `offline_delay_ms=100` without
load. A paused core is not "active": `sched_setaffinity` to it alone returns EINVAL, and
`sched_getaffinity` leaves it out (the run saw `[0..5]`). The protocol's 2 s settling pause before each
configuration is exactly such an idle period. A second defect made it worse: after each configuration the
timing thread's affinity was "restored" from `sched_getaffinity` — i.e. to `[0..5]`, locking the app's main
thread out of the X2 for the rest of the run. So C1 ran on cpu 7 only by the scheduler's choice (its mask
was still complete), C2's 100 "prime" runs all ran on cpu 4 (an A710), and C3 (a separate Java thread,
never restricted) ran on cpu 7. The per-run CPU record caught it, as decision 6 intended.

**Decision** (René chose this of three options).
- `CpuAffinity.pinWaking`: try the pin; on EINVAL the calling thread spins in 10 ms slices — the load
  wakes the core — and retries, for at most 3 s; timing starts immediately after the pin holds. For C3 the
  Dart thread spins while it pins the idle Java bench thread; the run starts within milliseconds, far
  inside `offline_delay_ms`.
- A configuration whose pin does not hold is **not measured**: it carries `error`, and the script prints
  it in red.
- After each configuration the affinity is reset to every possible CPU (`/sys/devices/system/cpu/possible`),
  never to the `sched_getaffinity` result.
- The report records `pin_first_errno`, `pin_attempts`, `pin_wait_ms` and `pin_method` per configuration.

**Evidence that the mechanism works** (adb shell on the S22, 2026-10-10, before any code change): at idle
`taskset` to cpu 7 is refused; a busy loop wakes the X2 within about 20 ms; pinning then succeeds both for
the busy process and for a sleeping one (the C3 case); 0.5 s after the load stops the X2 is paused again.

*Provenance (added 2026-10-11).* The core-control readings in the context above and this experiment are adb
output from the 2026-10-10 session; they were not stored as files. `tools/model_check/core_control_check.sh`
repeats both. Independently of them, the **stored** record of run `2026-10-10_122950` confirms the mechanism:
in all three X2 configurations the first pin returned EINVAL (`pin_first_errno` 22) and held after 110–120 ms
of waking, and every timed run executed on cpu 7.

**Alternatives rejected.** Reporting the A710 only — loses the fastest-core reading this ADR planned.
Keeping X2 figures labelled "unpinned" — where a run executes is then the scheduler's choice, not the
protocol's. Dropping the settling pause — it exists so that one configuration's heat and clock state does
not carry into the next. A second spinning thread during C3 — it could itself be scheduled onto the X2 and
compete with the measured thread.

**Consequence.** The measurement report uses the next complete run. Run `120250` stays as the record of
the failure; its A710 configurations were validly pinned and can serve as a repeatability check.
