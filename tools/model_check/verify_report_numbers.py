#!/usr/bin/env python3
"""Re-derives every figure in docs/measurements/2026-10-10_arm2_phone/report.md from the raw files.

The same idea as the thesis' ml-pipeline/verify_numbers.py: a number in the report that does not
reproduce from the stored measurement files is a FAIL. Each check names the exact text it looks for
in the report (whitespace and ** bold markers normalised), recomputes that text from the raw data,
and compares the two. Rounding is half-up on exact decimals (integer microseconds, kB as reported).

Also checks that the thesis copy in MasterThesis/app_agent_hints/ is the report plus its header note.

Usage (from the repo root; needs Pillow for the JPEG dimensions):
    python tools/model_check/verify_report_numbers.py [path to MasterThesis]
"""
import hashlib
import json
import math
import os
import re
import sys
from decimal import ROUND_HALF_UP, Decimal

from PIL import Image

sys.stdout.reconfigure(encoding="utf-8")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MEAS = os.path.join(ROOT, "docs", "measurements", "2026-10-10_arm2_phone")
RUN4, RUN3 = os.path.join(MEAS, "raw", "2026-10-10_122950"), os.path.join(MEAS, "raw", "2026-10-10_120250")
RUN2, RUN1 = os.path.join(MEAS, "raw", "2026-10-10_105927"), os.path.join(MEAS, "raw", "2026-10-10_103514")
THESIS = sys.argv[1] if len(sys.argv) > 1 else None

report_raw = open(os.path.join(MEAS, "report.md"), encoding="utf-8").read()
REPORT = re.sub(r"\s+", " ", report_raw.replace("**", ""))
m = json.load(open(os.path.join(RUN4, "measurement.json"), encoding="utf-8-sig"))
r = json.load(open(os.path.join(RUN4, "report_app.json"), encoding="utf-8"))
r3 = json.load(open(os.path.join(RUN3, "report_app.json"), encoding="utf-8"))

results = []


def check(label, claim, recomputed, note=""):
    """PASS when the claim is in the report AND equals the recomputed text."""
    in_report = claim in REPORT
    ok = in_report and claim == recomputed
    results.append(ok)
    status = "PASS" if ok else "FAIL"
    detail = "" if ok else (f"  -> recomputed: {recomputed!r}" + ("" if in_report else "  [claim text not found in report]"))
    print(f"{status}  {label}: {claim!r}{detail}{('  (' + note + ')') if note else ''}")


def fact(label, condition, note=""):
    results.append(bool(condition))
    print(f"{'PASS' if condition else 'FAIL'}  {label}{('  (' + note + ')') if note else ''}")


def q(x, places):
    d = x if isinstance(x, Decimal) else Decimal(repr(x)) if isinstance(x, float) else Decimal(x)
    return d.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def thousands(n):
    return f"{int(n):,}"


def mb(kib, places=1):  # dumpsys kB = 1,024 bytes -> decimal MB
    return q(Decimal(kib) * 1024 / Decimal(10**6), places)


def mib(kib, places=1):
    return q(Decimal(kib) / 1024, places)


def median_us(v):
    s = sorted(v)
    n = len(s)
    return Decimal(s[n // 2 - 1] + s[n // 2]) / 2 if n % 2 == 0 else Decimal(s[n // 2])


def p90_us(v):
    s = sorted(v)
    return Decimal(s[math.ceil(0.9 * len(s)) - 1])


def ms(us, places=2):
    return q(Decimal(us) / 1000, places)


cfg4 = {c["id"]: c for c in r["o3c_latency"]["configs"]}
cfg3 = {c["id"]: c for c in r3["o3c_latency"]["configs"]}
med = {k: median_us(c["runs_us"]) for k, c in cfg4.items()}
cases = r["correctness"]["cases"]
samples = m["dumpsys_meminfo"]["samples"]
snaps = {s["name"]: s for s in m["dumpsys_meminfo"]["snapshots"]}
o3b_pss = [s["total_pss_kb"] for s in samples if s["phase"] == "O3B_CLASSIFY" and s["total_pss_kb"] is not None]
big_pss = [s["total_pss_kb"] for s in samples if s["phase"] == "BIGIMG_CLASSIFY" and s["total_pss_kb"] is not None]
model_path = os.path.join(ROOT, "assets", "model", "large075_plain_int8_weight_only.tflite")
model_bytes = open(model_path, "rb").read()

print("== The run and its integrity")
fact("report_app.json SHA-256 equals the hash the script recorded",
     hashlib.sha256(open(os.path.join(RUN4, "report_app.json"), "rb").read()).hexdigest() == m["app_report_sha256"])
check("report_app.json hash prefix", "SHA-256 `9e34c964…`", f"SHA-256 `{m['app_report_sha256'][:8]}…`")
check("script version and hash", "version 1.2 (SHA-256 `8c940f3c…`)",
      f"version {m['script']['version'].split()[0]} (SHA-256 `{m['script']['sha256'][:8]}…`)")
fact("tools/measure_model.ps1 on disk is still the version that ran",
     hashlib.sha256(open(os.path.join(ROOT, "tools", "measure_model.ps1"), "rb").read()).hexdigest() == m["script"]["sha256"])
check("APK hash prefix", "APK SHA-256 `ca0ba8f6…`", f"APK SHA-256 `{m['o3a_apk']['apk_sha256'][:8]}…`")
check("analyze", "flutter analyze` 0 errors / 0 warnings",
      f"flutter analyze` {m['toolchain']['analyze']['errors']} errors / {m['toolchain']['analyze']['warnings']} warnings")
fact("unit tests passed", m["toolchain"]["unit_tests"] == "passed")
fact("no app error and no runtime error line", r.get("error") is None and m["runtime_errors_logcat"] == [])

print("\n== Summary table")
check("correctness count", "6/6 pass", f"{sum(c['pass'] for c in cases)}/{len(cases)} pass")
max_dlogit = max(Decimal(repr(c["max_abs_logit_diff"])) for c in cases)
check("max logit deviation", "largest logit difference 0.00006 (stored by the app rounded to 5 decimals; tolerance 0.1)",
      f"largest logit difference {q(max_dlogit, 5)} (stored by the app rounded to 5 decimals; tolerance 0.1)",
      "unrounded maximum therefore < 0.000065")
check("max logit deviation, §2", "the largest logit difference is 0.00006 (rounded to 5 decimals)",
      f"the largest logit difference is {q(max_dlogit, 5)} (rounded to 5 decimals)")
check("O3a", f"4,425,408 bytes = 4.43 MB", f"{thousands(m['o3a_apk']['model_entry']['uncompressed_bytes'])} bytes = "
      f"{q(Decimal(m['o3a_apk']['model_entry']['uncompressed_bytes']) / Decimal(10**6), 2)} MB")
check("O3b peak", "257,693 kB = 263.9 MB", f"{thousands(max(o3b_pss))} kB = {mb(max(o3b_pss))} MB")
fact("O3b peak equals the script's own peak_o3b", max(o3b_pss) == m["dumpsys_meminfo"]["peak_o3b"]["max_total_pss_kb"])
check("O3c C1 medians", "12.17 ms on the Cortex-X2, 20.95 ms on a Cortex-A710",
      f"{ms(med['C1_prime'])} ms on the Cortex-X2, {ms(med['C1_big'])} ms on a Cortex-A710")
check("12 MP peak", "473,089 kB = 484.4 MB", f"{thousands(max(big_pss))} kB = {mb(max(big_pss))} MB")
check("XNNPACK speed-up (X2)", "about 30 % faster at identical",
      f"about {q((1 - med['C2_prime'] / med['C1_prime']) * 100, 0)} % faster at identical")

print("\n== Setup")
gp, dev = m["device"]["getprop"], r["device_in_app"]
check("model", "Samsung Galaxy S22 (SM-S901U1)", f"Samsung Galaxy S22 ({gp['ro.product.model']})", "marketing name = device knowledge")
check("SoC", "Snapdragon 8 Gen 1 (SM8450", f"Snapdragon 8 Gen 1 ({gp['ro.soc.model']}", "SM8450 = Snapdragon 8 Gen 1 is device knowledge")
cores = {}
for c in dev["cpus"]:
    cores.setdefault(c["core_name"], []).append((c["cpu"], c["max_freq_khz"]))
x2, a710, a510 = cores["Cortex-X2"], cores["Cortex-A710"], cores["Cortex-A510"]
check("X2", "1 × Cortex-X2 at up to 2.995 GHz = cpu 7",
      f"{len(x2)} × Cortex-X2 at up to {q(Decimal(x2[0][1]) / 10**6, 3)} GHz = cpu {x2[0][0]}")
check("A710", "3 × Cortex-A710 at up to 2.496 GHz = cpu 4–6",
      f"{len(a710)} × Cortex-A710 at up to {q(Decimal(a710[0][1]) / 10**6, 3)} GHz = cpu {a710[0][0]}–{a710[-1][0]}")
check("A510", "4 × Cortex-A510 at up to 1.786 GHz",
      f"{len(a510)} × Cortex-A510 at up to {q(Decimal(a510[0][1]) / 10**6, 3)} GHz")
check("Android", "Android 16 (SDK 36), build `BP2A.250605.031.A3.S901U1UESAGZH3`",
      f"Android {gp['ro.build.version.release']} (SDK {gp['ro.build.version.sdk']}), build `{gp['ro.build.display.id']}`")


def field(text, key):
    return re.search(rf"^\s*{re.escape(key)}: (.*)$", text, re.M).group(1).strip()


bat = m["device"]["battery_at_start"]
check("power", "On USB power, battery 100 %",
      f"On {'USB' if field(bat, 'USB powered') == 'true' else 'NO USB'} power, battery {field(bat, 'level')} %")
ts, te = m["device"]["thermal_at_start"], m["device"]["thermal_at_end"]
status = lambda t: re.search(r"Thermal Status: (\d+)", t).group(1)
temp = lambda t, n: re.search(rf"mValue=([\d.]+), mType=\d+, mName={n},", t).group(1)
fact("thermal status 0 at start and end", status(ts) == "0" and status(te) == "0")
check("temperatures", "SoC (AP) sensor 31.5 → 37.6 °C, skin 31.3 → 32.6 °C",
      f"SoC (AP) sensor {temp(ts, 'AP')} → {temp(te, 'AP')} °C, skin {temp(ts, 'SKIN')} → {temp(te, 'SKIN')} °C")
fl = m["toolchain"]["flutter_version"]
check("toolchain", "Flutter 3.44.1, Dart 3.12.1",
      f"Flutter {re.search(r'Flutter (\S+)', fl).group(1)}, Dart {r['runtime']['dart'].split()[0]}")
check("labels", "`labels.csv` (1,004 rows)", f"`labels.csv` ({thousands(r['model']['labels_rows'])} rows)")
fact("model hash checked on device, in the APK and on disk (e0e182a8…)",
     r["model"]["sha256_matches"] and r["model"]["labels_sha256_matches"] and m["o3a_apk"]["model_sha256_matches"]
     and hashlib.sha256(model_bytes).hexdigest() == r["model"]["sha256_expected"]
     and r["model"]["sha256_expected"].startswith("e0e182a8"))
check("binding", "tflite_flutter 0.12.1 (dart:ffi → LiteRT C API) on LiteRT 1.4.2",
      f"tflite_flutter {r['runtime']['binding_version']} (dart:ffi → LiteRT C API) on LiteRT {r['runtime']['android_runtime_artifact'].rsplit(':', 1)[1]}")
check("runtime self-report", "`2.22.0-dev0+selfbuilt`", f"`{r['runtime']['runtime_version_reported_by_litert']}`")
xa = m["xnnpack_attribution"]
created = [x for x in xa["xnnpack_lines"] if "Created TensorFlow Lite XNNPACK delegate" in x["line"]]
fact("C1 first in a fresh process, no XNNPACK by default (verdict not_default, creation line after C2 started)",
     r["runtime"]["c1_created_in_this_run"] is True and r["runtime"]["explicit_xnnpack_interpreters_before_c1"] == 0
     and xa["verdict"] == "not_default" and created and created[0]["epoch"] >= xa["marker_epochs"]["C2_START"])
rep = re.search(r"Replacing (\d+) out of (\d+) node", " ".join(x["line"] for x in xa["xnnpack_lines"]))
check("XNNPACK partition", "XNNPACK took 208 of the 209 operators", f"XNNPACK took {rep.group(1)} of the {rep.group(2)} operators")
x2cfg = [cfg4[k] for k in ("C1_prime", "C2_prime", "C3_prime")]
fact("X2 pin refused at first (EINVAL = 22) in all three X2 configurations", all(c["pin_first_errno"] == 22 for c in x2cfg))
check("X2 pin wait", "(110–120 ms;", f"({min(c['pin_wait_ms'] for c in x2cfg)}–{max(c['pin_wait_ms'] for c in x2cfg)} ms;")
fact("all 100 runs of all six configurations on the pinned core",
     len(cfg4) == 6 and all(c["pin_errno"] == 0 and len(c["cpu_per_run"]) == 100
                            and all(x == c["pinned_cpu"] for x in c["cpu_per_run"]) for c in cfg4.values()))
check("protocol", "20 untimed warm-up runs, then 100 timed runs",
      f"{r['protocol']['warmup_runs']} untimed warm-up runs, then {r['protocol']['timed_runs']} timed runs")
fact("timing input ref_01.jpg", r["o3c_latency"]["timing_input"].startswith("ref_01.jpg"))

print("\n== Correctness table (values as stored by the app: |dmean| 6 decimals, |dlogit| 5 decimals)")
for c in cases:
    name = c["image"] if c["image"].endswith(".jpg") else "grey (all 0.5)"
    dmean = "0" if c["max_abs_mean_diff"] == 0 else f"{q(Decimal(repr(c['max_abs_mean_diff'])), 6)}"
    row = (f"| {name} | {dmean} | {c['top5_app'][0]['index']} = {c['top5_reference'][0]} | "
           f"{c['top5_overlap']}/5 | {q(Decimal(repr(c['max_abs_logit_diff'])), 5)} | {'✓' if c['pass'] else '✗'} |")
    claim = row if row in REPORT else f"| {name} |"
    check(f"row {name}", row if row in REPORT else claim, row)
for key in ("c2_correctness", "c3_correctness"):
    rows = r["o3c_latency"][key]
    fact(f"{key}: 6/6 pass, max |dlogit| 0.00006",
         sum(x["pass"] for x in rows) == 6 and q(max(Decimal(repr(x["max_abs_logit_diff"])) for x in rows), 5) == Decimal("0.00006"))
st_ok = all(c["stages"]["decoded_identical_to_pillow"] and c["stages"]["resized_identical_to_pillow"]
            and c["stages"]["cropped_identical_to_pillow"] for c in cases if c.get("stages"))
li = r["large_image"]
st12 = li["stages_vs_pillow"]
fact("decode/resize/crop bit-identical to Pillow for the 5 photos and the 12 MP image",
     st_ok and sum(1 for c in cases if c.get("stages")) == 5
     and st12["decoded_identical_to_pillow"] and st12["resized_identical_to_pillow"] and st12["cropped_identical_to_pillow"])
jpg = os.path.join(ROOT, "assets", "model_check", "synthetic_12mp.jpg")
w, h = Image.open(jpg).size
check("synthetic JPEG size", "4000 × 3000 JPEG (3.2 MB)", f"{w} × {h} JPEG ({q(Decimal(os.path.getsize(jpg)) / 10**6, 1)} MB)")

print("\n== O3a")
a = m["o3a_apk"]
check("model entry", "4,425,408 bytes (4.43 MB)",
      f"{thousands(a['model_entry']['uncompressed_bytes'])} bytes ({q(Decimal(a['model_entry']['uncompressed_bytes']) / 10**6, 2)} MB)")
fact("model entry stored uncompressed, SHA-256 = scored file",
     a["model_entry"]["stored_without_compression"] and a["model_sha256_matches"] and len(model_bytes) == a["model_entry"]["uncompressed_bytes"])
check("APK size", "87,632,079 bytes", f"{thousands(a['apk_bytes'])} bytes")
fix = sum(e["uncompressed_bytes"] for e in a["entries"] if e["name"].startswith("assets/flutter_assets/assets/model_check/"))
check("fixtures", "about 3.9 MB of measurement fixtures", f"about {q(Decimal(fix) / 10**6, 1)} MB of measurement fixtures",
      f"{thousands(fix)} bytes")

print("\n== O3b")
check("classifications", "100 classifications", f"{r['o3b_memory']['classifications']} classifications")
check("O3b samples", "32 samples", f"{len(o3b_pss)} samples")
check("O3b peak, three units", "Peak: 257,693 kB = 263.9 MB = 251.7 MiB",
      f"Peak: {thousands(max(o3b_pss))} kB = {mb(max(o3b_pss))} MB = {mib(max(o3b_pss))} MiB")
check("snapshots", "167,382 kB (graphics 84,292 kB); after loading 201,999 kB; after the correctness check 236,822 kB",
      f"{thousands(snaps['M0_idle_before_model_load']['total_pss_kb'])} kB (graphics {thousands(snaps['M0_idle_before_model_load']['graphics_kb'])} kB); "
      f"after loading {thousands(snaps['M1_after_model_load']['total_pss_kb'])} kB; after the correctness check "
      f"{thousands(snaps['M2_after_correctness']['total_pss_kb'])} kB")
check("VmHWM", "218,856 kB", f"{thousands(r['o3b_memory']['vm_hwm_kb_after_loop'])} kB")
ias = r["o3b_memory"]["in_app_sampler"]
check("smaps max", "every 100 ms, maximum 140,091 kB",
      f"every {re.search(r'every (\d+) ms', ias['method']).group(1)} ms, maximum {thousands(ias['max_pss_kb'])} kB")
java = [x["java_heap_kb"] for x in samples + list(snaps.values()) if x.get("java_heap_kb") is not None]
check("Java heap range", "the Java heap is 2,068–9,476 kB (2.1–9.7 MB) across all 51 dumpsys readings",
      f"the Java heap is {thousands(min(java))}–{thousands(max(java))} kB ({mb(min(java))}–{mb(max(java))} MB) "
      f"across all {len(java)} dumpsys readings")
check("12 MP rounds", "through the same pipeline 3 times", f"through the same pipeline {len(li['rounds'])} times")
check("12 MP peak", "peak TOTAL PSS 473,089 kB = 484.4 MB (14 samples)",
      f"peak TOTAL PSS {thousands(max(big_pss))} kB = {mb(max(big_pss))} MB ({len(big_pss)} samples)")
fact("12 MP peak equals the script's own peak_bigimg", max(big_pss) == m["dumpsys_meminfo"]["peak_bigimg"]["max_total_pss_kb"])
check("12 MP VmHWM", "`VmHWM` 383,752 kB", f"`VmHWM` {thousands(li['vm_hwm_kb_after'])} kB")
fact("12 MP top-5 identical to the desktop reference", li["top5_app"] == li["top5_desktop_reference"])
rd = li["rounds"]
rng = lambda k, p: f"{q(min(x[k] for x in rd), p)}–{q(max(x[k] for x in rd), p)}"
check("12 MP stage times", "decode 288–336 ms, preprocessing 104–121 ms, model run 11.7–12.1 ms",
      f"decode {rng('decode_ms', 0)} ms, preprocessing {rng('preprocess_ms', 0)} ms, model run {rng('run_ms_incl_tensor_copies', 1)} ms")

print("\n== O3c table (recomputed from the 100 raw values per configuration)")
names = {"C1_prime": "C1", "C1_big": "C1", "C2_prime": "C2", "C2_big": "C2", "C3_prime": "C3", "C3_big": "C3"}
for k, c in cfg4.items():
    v = c["runs_us"]
    cells = f"{ms(median_us(v))} ms | {ms(p90_us(v))} ms | {ms(min(v))} ms | {ms(max(v))} ms |"
    check(f"{k} median | p90 | min | max", cells, cells if cells in REPORT else cells)
    fact(f"{k}: recomputed median/p90 equal the app's own stats",
         median_us(v) == Decimal(repr(c["stats"]["median_us"])) and p90_us(v) == Decimal(c["stats"]["p90_us"]))
check("C3 vs C1 on the X2", "agrees on the X2 within about 1 %",
      f"agrees on the X2 within about {q(abs(med['C3_prime'] - med['C1_prime']) / med['C1_prime'] * 100, 0)} %")
check("O3c margin", "met by a factor of about 25 (X2) and 14 (A710)",
      f"met by a factor of about {q(300000 / med['C1_prime'], 0)} (X2) and {q(300000 / med['C1_big'], 0)} (A710)")
check("XNNPACK speed-up", "about 30 % faster on the X2 and 25 % on the A710",
      f"about {q((1 - med['C2_prime'] / med['C1_prime']) * 100, 0)} % faster on the X2 and "
      f"{q((1 - med['C2_big'] / med['C1_big']) * 100, 0)} % on the A710")
m3 = {k: median_us(c["runs_us"]) for k, c in cfg3.items()}
check("repeatability A710 (run 3)", "C1 20.81 ms and C2 15.65 ms (within 1 % of the table), C3 20.86 ms (13 % above)",
      f"C1 {ms(m3['C1_big'])} ms and C2 {ms(m3['C2_big'])} ms (within "
      f"{q(max(abs(m3[k] - med[k]) / med[k] * 100 for k in ('C1_big', 'C2_big')), 0)} % of the table), "
      f"C3 {ms(m3['C3_big'])} ms ({q((m3['C3_big'] - med['C3_big']) / med['C3_big'] * 100, 0)} % above)",
      "\"within 1 %\": largest deviation 0.81 % rounds to 1")
c3p = cfg3["C1_prime"]
fact("run 3 C1 on the X2 was unpinned (errno 22) yet every run on cpu 7",
     c3p["pin_errno"] == 22 and all(x == 7 for x in c3p["cpu_per_run"]))
check("run 3 X2 median", "had a median of 10.33 ms", f"had a median of {ms(m3['C1_prime'])} ms")
first = sum(Decimal(x) for x in c3p["runs_us"][:10]) / 10
last = sum(Decimal(x) for x in c3p["runs_us"][-10:]) / 10
check("run 3 X2 drift", "fell from about 10.2 ms in the first runs to 12.2 ms in the last",
      f"fell from about {ms(first, 1)} ms in the first runs to {ms(last, 1)} ms in the last", "means of the first and last 10 runs")
blocks = [sum(Decimal(x) for x in cfg4["C1_prime"]["runs_us"][i:i + 10]) / 10 / 1000 for i in range(0, 100, 10)]
check("run 4 X2 block means", "every block of 10 runs averages 12.1–12.4 ms",
      f"every block of 10 runs averages {q(min(blocks), 1)}–{q(max(blocks), 1)} ms",
      f"block means {min(blocks):.2f}–{max(blocks):.2f} ms")
e2e = r["o3b_memory"]["end_to_end_per_image"]
check("end to end", "median 42.3 ms, p90 56.0 ms (n = 100)",
      f"median {ms(Decimal(repr(e2e['median_us'])), 1)} ms, p90 {ms(e2e['p90_us'], 1)} ms (n = {e2e['n']})",
      "computed by the app from its per-image timings; the series itself is not stored")
tot = [Decimal(repr(x["decode_ms"])) + Decimal(repr(x["preprocess_ms"])) + Decimal(repr(x["run_ms_incl_tensor_copies"])) for x in rd]
check("12 MP per photo", "(0.41–0.46 s each)", f"({q(min(tot) / 1000, 2)}–{q(max(tot) / 1000, 2)} s each)")
check("creation times", "C1 10.9 ms, C2 81.8 ms", f"C1 {q(Decimal(repr(r['runtime']['c1_create_ms'])), 1)} ms, C2 "
      f"{q(Decimal(repr(cfg4['C2_prime']['create_ms'])), 1)} ms")
check("C3 creation", "C3 7.2 ms", f"C3 {q(Decimal(repr(r['o3c_latency']['c3_interpreter']['create_ms'])), 1)} ms")

print("\n== Limits and provenance")
check("run length", "one short run of 55 s", f"one short run of {q(Decimal(r['elapsed_ms']) / 1000, 0)} s")
fact("Benchmark Tool not run", m["benchmark_tool"]["ran"] is False)
raw1 = open(os.path.join(RUN1, "flutter_build.txt"), "rb").read()
log1 = raw1.decode("utf-16") if raw1[:2] == b"\xff\xfe" else raw1.decode("utf-8-sig")  # script 1.0 wrote UTF-16
fact("run 103514: the build failed on the Kotlin target",
     "Execution failed for task ':tflite_flutter:compileReleaseKotlin'" in log1 and "BUILD FAILED" in log1)
r2 = json.load(open(os.path.join(RUN2, "report_app.json"), encoding="utf-8"))
fact("run 105927: first inference failed ('Input tensor 87 lacks data')",
     "failed precondition" in r2["error"] and "Input tensor 87 lacks data" in open(os.path.join(RUN2, "logcat_app.txt"), encoding="utf-8-sig").read())
fact("run 120250: correctness passed, no measurement.json, X2 pin errno 22",
     r3["correctness"]["all_pass"] and not os.path.exists(os.path.join(RUN3, "measurement.json")) and c3p["pin_errno"] == 22)

print("\n== Numbers in the other documents (process log, ADR 010, CLAUDE.md) against stored evidence")


def norm(t):
    return re.sub(r"\s+", " ", t.replace("**", "").replace("*", ""))


def doc_claim(label, doc, claim, data_ok, note=""):
    in_doc = norm(claim) in doc
    fact(f"{label}: {claim!r} — in the text{'' if in_doc else ' [NOT FOUND]'} and backed by the data", in_doc and bool(data_ok), note)


EVID = os.path.join(ROOT, "docs", "measurements", "2026-10-10_litert_c_api_check")
evid = open(os.path.join(EVID, "litert_c_api_evidence_output.txt"), encoding="utf-8").read()
inspect = __import__("subprocess").run([sys.executable, "-I", os.path.join(ROOT, "tools", "model_check", "inspect_buffers.py"),
                                        model_path, "87"], capture_output=True, text=True, encoding="utf-8").stdout
feas = open(os.path.join(ROOT, "docs", "measurements", "2026-10-10_inline_feasibility", "inline_feasibility_output.txt"),
            encoding="utf-8").read()
probe = open(os.path.join(MEAS, "ps51_json_probe_output.txt"), encoding="utf-8-sig").read()
m2 = json.load(open(os.path.join(RUN2, "measurement.json"), encoding="utf-8-sig"))
log = norm(open(os.path.join(ROOT, "docs", "process_log.md"), encoding="utf-8").read())
adr10 = norm(open(os.path.join(ROOT, "docs", "decisions", "010-litert-1.4.2-c-api-offset-buffers.md"), encoding="utf-8").read())
claude = norm(open(os.path.join(ROOT, "CLAUDE.md"), encoding="utf-8").read())


def aar(v):  # one evidence block: (zip date, version string, x5 instruction)
    block = evid.split(f"== LiteRT {v} AAR")[1].split("==")[0].replace("\\t", " ").replace("\t", " ")
    date = re.search(r"zip date \((\d+), (\d+), (\d+)\)", block)
    return (f"{int(date[1]):04d}-{int(date[2]):02d}-{int(date[3]):02d}", re.search(r"(\d+\.\d+\.\d+-dev\d)\+selfbuilt", block)[1],
            "mov x5, xzr" if "mov x5, xzr" in block else "ldr x5, [x8, #0x10]" if "ldr x5, [x8, #0x10]" in block else "?")


for v in ("1.4.0", "1.4.1", "1.4.2"):
    date, ver, x5 = aar(v)
    doc_claim(f"ADR 010 table, LiteRT {v}", adr10, f"LiteRT {v} AAR | {date} | {ver} | `{x5}`", True)
doc_claim("ADR 010, 2.x", adr10, "all ten checked", evid.count("-> libtensorflowlite_jni.so absent") == 10)
doc_claim("ADR 010, offset buffers", adr10, "78 of the file's 149 buffers are stored this way (59 INT8, 18 FLOAT32, 1 INT32)",
          "stored at an offset after the FlatBuffer: 78" in inspect and "('INT8', 'offset'): 59" in inspect
          and "('FLOAT32', 'offset'): 18" in inspect and "('INT32', 'offset'): 1" in inspect)
doc_claim("ADR 010, tensor 87", adr10, "offset 2,562,976, size 1,024", "OFFSET 2562976, 1024 bytes" in inspect)
doc_claim("ADR 010, inline before", adr10, "the 11 inline constants before it loaded fine", "inline constants consumed before it: 11" in inspect)
doc_claim("ADR 010, run 2 interpreter", adr10, "created the interpreter (C1, 13.7 ms)",
          q(Decimal(repr(json.load(open(os.path.join(RUN2, "report_app.json"), encoding="utf-8"))["runtime"]["c1_create_ms"])), 1) == Decimal("13.7"))
doc_claim("ADR 010, C functions", adr10, "exports every one of the 30 C functions", "30 on Android" in evid)
doc_claim("process log, run 3 duration", log, "56 s — app start to DONE, `elapsed_ms` 55,807", r3["elapsed_ms"] == 55807)
doc_claim("process log, probe", log, "the 59-character probe line becomes 496, 1,776 and 32,527 characters of JSON",
          "probe line: 59 characters" in probe and ": 496 characters" in probe and ": 1776 characters" in probe and ": 32527 characters" in probe)
doc_claim("process log, fix on the real log", log, "8 lines, 2,983 characters of JSON", "8 XNNPACK lines -> 2983 characters" in probe)
doc_claim("process log, run 2 toolchain", log, "0 errors, 0 warnings, 5 pre-existing infos",
          m2["toolchain"]["analyze"] == {"errors": 0, "warnings": 0, "infos": 5})
doc_claim("CLAUDE.md status", claude, "O3b 257,693 kB peak, O3c 12.17 ms (X2) / 20.95 ms (A710)",
          max(o3b_pss) == 257693 and ms(med["C1_prime"]) == Decimal("12.17") and ms(med["C1_big"]) == Decimal("20.95"))
doc_claim("CLAUDE.md status, 12 MP", claude, "peaks at 473,089 kB", max(big_pss) == 473089)

if THESIS:
    print("\n== Thesis-side texts the report cites")
    readme = re.sub(r"\s+", " ", open(os.path.join(THESIS, "ml-pipeline", "README.md"), encoding="utf-8").read())
    fact("invariant 11: corpus downscaled to <= 800 px, JPEG q90", "downscales to ≤ 800 px and re-encodes as JPEG q90" in readme)
    fact("invariant 13: <= 800 px long side, LANCZOS, JPEG q90, no rotation", "≤ 800 px long side, LANCZOS, JPEG q90, no rotation" in readme)
    so = open(os.path.join(THESIS, "Vault", "20_Requirements", "Solution_Objectives.md"), encoding="utf-8").read()
    fact("O3a/O3b/O3c targets as quoted", "INT8 artefact **≤ 25 MB** on disk" in so and "**≤ 300 MB** on device" in so
         and "median **≤ 300 ms** per image" in so)
    hints = os.path.join(THESIS, "app_agent_hints")
    copy = open(os.path.join(hints, "2026-10-10_arm2_phone_measurement_report.md"), encoding="utf-8").read()
    note = re.search(r"\n\*Copy of .*?\*\n", copy, re.S)
    # (text in the copy, corrected text) - the corrections listed in the corrigendum of 2026-10-11
    CORRECTIONS = [
        ("6/6 pass; logits within 0.00006 of the desktop reference (tolerance 0.1); preprocessing",
         "6/6 pass; largest logit difference 0.00006 (stored by the app rounded to 5 decimals; tolerance 0.1); preprocessing"),
        ("model describe what the phone computes, up to differences of 0.00006 in the logits.",
         "model describe what the phone computes; the largest logit difference is 0.00006 (rounded to 5 decimals)."),
        ("the Java heap is 2–9 MB\n  here, so the effect on these figures is negligible.",
         "the Java heap is\n  2,068–9,476 kB (2.1–9.7 MB) across all 51 dumpsys readings, so the effect on these figures is negligible."),
        ("while run 122950 holds about 12.2 ms throughout.", "while in run 122950 every block of 10 runs averages 12.1–12.4 ms."),
        ("- Earlier runs, kept as records:",
         "- **Verification:** every figure in this report is re-derived from the raw files by\n"
         "  `tools/model_check/verify_report_numbers.py` (output: `verify_report_numbers_output.txt` beside this report).\n"
         "- Earlier runs, kept as records:"),
    ]
    body = copy.replace(note.group(0), "", 1) if note else copy
    each_once = all(body.count(old) == 1 for old, _ in CORRECTIONS)
    for old, new in CORRECTIONS:
        body = body.replace(old, new, 1)
    fact("thesis copy + its header note + the corrigendum's corrections = the corrected report",
         note is not None and each_once and body == report_raw)
    corr = norm(open(os.path.join(hints, "2026-10-11_corrigendum_arm2_phone_measurement_report.md"), encoding="utf-8").read())
    fact("the corrigendum lists all four corrected statements",
         all(s in corr for s in ("logits within 0.00006", "up to differences of 0.00006", "2–9 MB", "12.2 ms throughout")))

    print("\n== Numbers in the hint notes against stored evidence")
    h1 = norm(open(os.path.join(hints, "2026-10-10_arm2_phone_run_runtime_defect.md"), encoding="utf-8").read())
    doc_claim("runtime-defect note, tensor 87", h1, "INT8 weight tensor `[64, 1, 1, 16]` that feeds `DEQUANTIZE` (operator 13)",
              "INT8 [64, 1, 1, 16]" in inspect and "operator 13 (DEQUANTIZE v1)" in inspect)
    doc_claim("runtime-defect note, offset", h1, "`offset 2,562,976, size 1,024`", "OFFSET 2562976, 1024 bytes" in inspect)
    doc_claim("runtime-defect note, buffers", h1, "78 of the file's 149 buffers", "buffers: 149, of which stored at an offset after the FlatBuffer: 78" in inspect)
    layout = open(os.path.join(EVID, "thesis_tflite_buffer_layout.txt"), encoding="utf-8").read()
    entries = re.findall(r"^(\S+\.tflite)\n.*\n.*min_runtime_version = '([\d.]+)';buffers: (\d+), of which stored at an offset after the FlatBuffer: (\d+);",
                         layout, re.M)
    int8_ok = all(int(n) > 0 for f, _, _, n in entries if "int8" in f) and all(int(n) == 0 for f, _, _, n in entries if "fp32" in f)
    doc_claim("runtime-defect note, all INT8 exports", h1, "Every INT8 file in `ml-pipeline/arm2_export/` and `ml-pipeline/export_spike/out*/` has it; the FP32 files (litert-torch) have none",
              len(entries) == 14 and int8_ok, f"{len(entries)} files in the stored scan")
    doc_claim("runtime-defect note, min_runtime", h1, "The Arm 2 files declare `min_runtime_version 1.15.0`",
              all(v == "1.15.0" for f, v, _, _ in entries if f.startswith("arm2_export")))
    doc_claim("runtime-defect note, versions", h1, "and 1.4.1 pass nullptr; 1.4.2 passes the allocation",
              aar("1.4.0")[2] == aar("1.4.1")[2] == "mov x5, xzr" and aar("1.4.2")[2].startswith("ldr"))
    doc_claim("runtime-defect note, feasibility", h1, "offset-stored buffers 78 → 0; file 4,425,408 → 4,424,504 bytes",
              "offset-stored buffers: source 78, inline 0" in feas and "source    4425408 bytes" in feas and "inline    4424504 bytes" in feas)
    doc_claim("runtime-defect note, feasibility structure", h1, "all 356 tensors (name, type, shape, quantization, 4,039,532 constant bytes) and all 209 operators identical",
              "tensors 356 vs 356; differing (name/type/shape/quantization/constant bytes): none" in feas
              and "constant bytes compared: 4039532 vs 4039532" in feas and "operators 209 vs 209" in feas)
    doc_claim("runtime-defect note, feasibility behaviour", h1, "logits bit-identical (`np.array_equal`) on 72 inputs",
              feas.count("bit-identical logits: 72/72") == 2 and "6/6 cases pass" in feas)
    ops = re.search(r"operators used: (.*)", inspect)[1].split(", ")
    doc_claim("runtime-defect note, operators", h1, "All 13 operator types in the file (ADD, CONV_2D, DEPTHWISE_CONV_2D, DEQUANTIZE, FULLY_CONNECTED, GATHER_ND, HARD_SWISH, MUL, PAD, RESHAPE, SUB, SUM, TRANSPOSE) are built-ins at version 1",
              len(ops) == 13 and all(o.endswith(" v1") for o in ops)
              and sorted(o[:-3] for o in ops) == sorted("ADD CONV_2D DEPTHWISE_CONV_2D DEQUANTIZE FULLY_CONNECTED GATHER_ND HARD_SWISH MUL PAD RESHAPE SUB SUM TRANSPOSE".split()))
    up = open(os.path.join(EVID, "upstream_sources_output.txt"), encoding="utf-8").read()
    fact("every upstream source fact confirmed against the raw files (stored output)",
         re.search(r"(\d+)/(\d+) source facts confirmed", up) is not None
         and len(set(re.search(r"(\d+)/(\d+) source facts confirmed", up).groups())) == 1)
    h2 = norm(open(os.path.join(hints, "2026-10-11_open_questions_for_the_app_mvp.md"), encoding="utf-8").read())
    scores = json.load(open(os.path.join(THESIS, "ml-pipeline", "arm2_scores.json"), encoding="utf-8"))["p3_shipped_int8"]
    doc_claim("open-questions note, calibration", h2, "temperature 1.9123, `global_threshold` 0.6383",
              scores["calibration"]["temperature"] == 1.9123 and scores["global_threshold"] == 0.6383)
    doc_claim("open-questions note, 12 MP", h2, "peaks at 473,089 kB", max(big_pss) == 473089)

print(f"\n{sum(results)}/{len(results)} checks pass" + ("" if all(results) else " - FAILURES above"))
sys.exit(0 if all(results) else 1)
