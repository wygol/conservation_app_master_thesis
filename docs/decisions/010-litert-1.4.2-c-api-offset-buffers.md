# 010 — LiteRT 1.4.2 under tflite_flutter: the 1.4.0 C API loaded offset-stored weights as empty tensors
Date: 2026-10-10
Status: accepted (amends ADR 009, decision 1: the runtime version)
Thesis relevance: yes (the runtime the O3b/O3c figures are measured on; why the shipped model file stays
byte-identical to the file the thesis scored)

## Context

The second run of the measurement round (`tools/measure_model.ps1`, raw files in
`docs/measurements/2026-10-10_arm2_phone/raw/2026-10-10_105927/`) built, installed and created the
interpreter (C1, 13.7 ms), then failed at the **first `invoke()`** of the correctness check. The app saw
only `Bad state: failed precondition` (tflite_flutter's check on the status of `TfLiteInterpreterInvoke`);
logcat had the runtime's reason: **`E tflite : Input tensor 87 lacks data`**. Nothing after it was measured.

**What tensor 87 is** (`tools/model_check/inspect_buffers.py`, which reads the FlatBuffer directly):
the INT8 weights `[64, 1, 1, 16]` of a pointwise convolution, input of `DEQUANTIZE` (operator 13). Its
buffer has no inline data; it points to `offset 2,562,976, size 1,024` — bytes stored *after* the
FlatBuffer in the same file. **78 of the file's 149 buffers are stored this way** (59 INT8, 18 FLOAT32,
1 INT32). Tensor 87 is the first of them in execution order; the 11 inline constants before it loaded fine.

**Where the layout comes from.** ai-edge-quantizer serializes with external buffers whenever the packed
buffer data is ≥ 256 KB (`model_modifier.py`); there is no option to turn it off. Every INT8 file the
thesis pipeline produced (spike and Arm 2) has the layout; the FP32 files (litert-torch) have none. The
file still declares `min_runtime_version 1.15.0`.

**Why the runtime dropped them.** `InterpreterBuilder` resolves an offset-stored buffer only
`if (offset > 1 && allocation_)` (`interpreter_builder.cc`, TF v2.20.0). Without the model's allocation it
returns "no data" without an error; the tensor becomes a read-write tensor no operator produces, is never
allocated, and `Invoke()` refuses it. The C API's `InterpreterCreateWithOpResolver` (`c_api.cc`, TF v2.20.0;
LiteRT 1.4.0 reports `2.20.0-dev0+selfbuilt`) constructs the builder from the bare `Model*` and passes **no
allocation**. The Java API (JNI) and Python construct it from the `FlatBufferModel`, which carries the
allocation — which is why the desk study (Python, ai-edge-litert 2.3.0) passed on the same file, and why the
LiteRT Java API (C3) is not affected. `Interpreter.fromFile` would not help: same C-API builder.

**Upstream fix:** LiteRT commit `d17fd00` (2025-11-05), *"Pass allocation info to `InterpreterBuilder` in
`InterpreterCreateWithOpResolver`"* — one week after tflite_flutter 0.12.1 (2025-10-28) moved to LiteRT 1.4.0.

**Which builds contain it — checked in the machine code**, not inferred from dates. `llvm-objdump` (NDK
28.2) on `TfLiteInterpreterCreate` (arm64), the constructor call's 6th register `x5` = `allocation`:

| `libtensorflowlite_jni.so` | built | runtime | `x5` before the `InterpreterBuilder` call |
|---|---|---|---|
| in the app's APK of run 105927 | — | 2.20.0-dev0 | `mov x5, xzr` → nullptr |
| LiteRT 1.4.0 AAR | 2025-06-30 | 2.20.0-dev0 | `mov x5, xzr` → nullptr |
| LiteRT 1.4.1 AAR | 2025-11-05 | 2.20.0-dev0 | `mov x5, xzr` → nullptr |
| **LiteRT 1.4.2 AAR** | 2026-03-12 | 2.22.0-dev0 | **`ldr x5, [x8, #0x10]`** → `model->impl->allocation()` |

No released LiteRT 2.x AAR (2.0.2 to 2.3.0, all ten checked) contains `libtensorflowlite_jni.so`, the
library tflite_flutter 0.12.1 opens by name: they ship `libLiteRt.so` (2.1.0 onward) or `liblitert_jni.so`
and `libLiteRtRuntimeCApi.so` (2.0.x). *[Corrected 2026-10-11: this said "LiteRT 2.x AARs ship
`libLiteRt.so`", from a check of 2.1.0 alone.]*

**Stored evidence** (`docs/measurements/2026-10-10_litert_c_api_check/`): `litert_c_api_evidence_output.txt`
(every AAR's SHA-256, the library's build date, version string, the `x5` instruction, exported C functions,
segment alignment; the 2.x listing), `upstream_sources_output.txt` (each source line this ADR quotes, checked
against the raw file), `gradle_litert_resolution.txt`, `thesis_tflite_buffer_layout.txt` — produced by the
scripts of the same names in `tools/model_check/`.

## Decision

1. **The model file stays unchanged** — `large075_plain_int8_weight_only.tflite`, SHA-256 `e0e182a8…`, the
   file the thesis exported and scored.
2. **The runtime under both bindings becomes LiteRT 1.4.2:** `com.google.ai.edge.litert:litert` and
   `litert-gpu` 1.4.2 declared in `android/app/build.gradle.kts`. Gradle resolves the plugin's 1.4.0
   declarations to 1.4.2. tflite_flutter stays pinned at 0.12.1.
3. The report names the artifact (`kLiteRtArtifact`) and, independently, the version the runtime reports
   itself. `tools/measure_model.ps1` 1.1 prints and records the runtime's own error lines (tag `tflite`,
   level E/F, the app's process), so a failure like this one shows its reason on screen.

## Rationale

- **The defect is in the instrument, not in the measured object.** Fixing the runtime keeps the file on the
  phone byte-identical to the file whose test results the thesis reports (`verify_numbers.py` block ARM2S
  asserts "the scored INT8 file is the exported weight-only file"; the handover asks the app to "confirm it
  is what the app ships"). Phone figures and test figures then refer to one SHA-256 — no equivalence
  argument is needed.
- **Verified, not assumed:** the fix is present in 1.4.2's machine code; 1.4.2 exports every one of the 30
  C functions tflite_flutter reaches on Android (the same set as 1.4.0, plus `TfLiteKernelInitFailed`);
  same library name; LOAD segments 16 KB-aligned; `litert-api`, `litert-gpu` and `litert-gpu-api` are all
  pinned to exactly 1.4.2 by its POMs.
- **Smallest change:** two Gradle lines, no Dart API change.

## Alternatives rejected

- **Re-serialize the model with inline weights** (TF `flatbuffer_utils`: `read_model` inlines offsets,
  `write_model` writes inline). Lossless in principle, and the result would also load on old runtimes and on
  iOS. Rejected for the measurement round: the app would ship a hash the thesis never scored, and under the
  thesis' invariant 14 (Arm 2 scored on test once; no model change afterwards) the copy needs a proof of
  computational identity on the pinned training-pool photographs against the checkpoint — both exist only on
  the VPS — plus thesis-side edits. René decided after a check against the thesis. The step is recommended to
  the pipeline for **future** exports instead (`MasterThesis/app_agent_hints/`, 2026-10-10).
- **LiteRT 1.4.1** — still `mov x5, xzr`.
- **LiteRT 2.x** — no `libtensorflowlite_jni.so`; would need a patched binding.
- **flutter_litert** (ADR 009's fallback) — now 3.9.x on LiteRT Next 2.2.0 (`libLiteRt.so`, CompiledModel
  API); no longer the source-compatible fork ADR 009 described.
- **`Interpreter.fromFile` instead of `fromBuffer`** — the same C-API builder, the same defect.
- **The LiteRT Java API as the app's binding** — unaffected, but rejected in ADR 009 (inference behind a
  platform channel for the whole app).
- **Rewriting the model bytes in Dart before `TfLiteModelCreate`** — the runtime would execute something
  other than the shipped file; hidden complexity.

## Consequences

- The O3b/O3c figures are measured on **LiteRT 1.4.2** (a TF 2.22.0-dev0 snapshot), not 1.4.0, and are
  reported with that version. ADR 009, decision 1, is amended accordingly.
- Two Gradle lines must stay aligned with tflite_flutter. Remove them once tflite_flutter bundles a fixed
  runtime itself.
- **iOS (end-of-project check, D-010):** tflite_flutter 0.12.1 uses TensorFlowLiteSwift 2.12.0 on iOS. Its
  `InterpreterBuilder` has no offset support at all, so the current file cannot load there. The remedy lies in
  the export (inline weights) or in an iOS runtime upgrade — handed to the thesis pipeline; not solved here.
- Any future model from the same toolchain has the same layout; with 1.4.2, Android loads it.
- **Verified on René's machine (2026-10-10, before any phone run):** `flutter analyze` 0 errors / 0 warnings;
  `flutter test test/ml` 28/28; release build passes (R8, Kotlin bench against `litert-api` 1.4.2);
  `gradlew :app:dependencies` shows `litert:1.4.0 -> 1.4.2` and `litert-gpu:1.4.0 -> 1.4.2` for the plugin;
  the new APK's `libtensorflowlite_jni.so` reports `2.22.0-dev0+selfbuilt` and its `TfLiteInterpreterCreate`
  passes the allocation (`ldr x5, [x8, #0x10]`); the model entry is unchanged (`e0e182a8…`, 4,425,408 bytes,
  stored uncompressed). **Not yet verified:** the phone run — the correctness check against
  `phone_reference.json` is the test of the whole chain.
