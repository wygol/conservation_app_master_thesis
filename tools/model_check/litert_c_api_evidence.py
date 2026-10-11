#!/usr/bin/env python3
"""Evidence behind ADR 010: which LiteRT builds pass the model's allocation to InterpreterBuilder.

For each LiteRT AAR (Maven com.google.ai.edge.litert:litert:<version>) and for the native library inside
each APK given: SHA-256 of the container and of libtensorflowlite_jni.so (arm64-v8a), the zip date of that
entry, the runtime version string embedded in it, the instruction that sets x5 — the 6th argument, i.e.
`allocation` — before the InterpreterBuilder call in TfLiteInterpreterCreate (`mov x5, xzr` = nullptr),
the alignment of its LOAD segments, and whether it exports every C function tflite_flutter 0.12.1 calls.

Usage (from the repo root):
    python tools/model_check/litert_c_api_evidence.py <aar dir> [apk ...]
<aar dir> holds litert-<version>.aar; missing ones (1.4.0, 1.4.1, 1.4.2, 2.1.0) are downloaded from
https://dl.google.com/android/maven2/com/google/ai/edge/litert/litert/<v>/litert-<v>.aar
Needs llvm-objdump / llvm-readelf / llvm-nm from the Android NDK (%LOCALAPPDATA%\\Android\\Sdk\\ndk).
"""
import glob
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

sys.stdout.reconfigure(encoding="utf-8")
AAR_DIR, APKS = sys.argv[1], sys.argv[2:]
VERSIONS = ["1.4.0", "1.4.1", "1.4.2", "2.1.0"]
MAVEN = "https://dl.google.com/android/maven2/com/google/ai/edge/litert/litert/{v}/litert-{v}.aar"
NDK_BIN = sorted(glob.glob(os.path.join(os.environ.get("LOCALAPPDATA", ""), "Android", "Sdk", "ndk", "*",
                                        "toolchains", "llvm", "prebuilt", "*", "bin")))[-1]
PUB = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pub", "Cache", "hosted", "pub.dev", "tflite_flutter-0.12.1")


def tool(name, *args):
    exe = os.path.join(NDK_BIN, name + (".exe" if os.name == "nt" else ""))
    return subprocess.run([exe, *args], capture_output=True, text=True, errors="replace").stdout


def sha(data):
    return hashlib.sha256(data).hexdigest()


# The C functions tflite_flutter 0.12.1 reaches (its Dart sources), plus TfLiteVersion (read by the app).
used = {"TfLiteVersion"}
for f in glob.glob(os.path.join(PUB, "lib", "src", "**", "*.dart"), recursive=True):
    used |= set(re.findall(r"tfliteBinding\.(TfLite\w+)", open(f, encoding="utf-8").read()))
ios_only = {s for s in used if "CoreMl" in s}
android_used = sorted(used - ios_only)
print(f"NDK tools: {NDK_BIN}")
print(f"tflite_flutter 0.12.1 C functions: {len(used)} referenced, {len(ios_only)} iOS-only (CoreML), "
      f"{len(android_used)} on Android\n")

sources = []
for v in VERSIONS:
    path = os.path.join(AAR_DIR, f"litert-{v}.aar")
    if not os.path.exists(path):
        urllib.request.urlretrieve(MAVEN.format(v=v), path)
    sources.append((f"LiteRT {v} AAR", path, "jni/arm64-v8a/"))
sources += [(f"APK {os.path.basename(a)}", a, "lib/arm64-v8a/") for a in APKS]

with tempfile.TemporaryDirectory() as tmp:
    for label, path, prefix in sources:
        container = open(path, "rb").read()
        z = zipfile.ZipFile(path)
        libs = [i for i in z.infolist() if i.filename.startswith(prefix) and i.filename.endswith(".so")]
        print(f"== {label}: {os.path.basename(path)}  sha256 {sha(container)}")
        print(f"   native libraries ({prefix}): " + ", ".join(f"{os.path.basename(i.filename)} ({i.file_size:,} B)" for i in libs))
        entry = next((i for i in libs if i.filename.endswith("libtensorflowlite_jni.so")), None)
        if entry is None:
            print("   libtensorflowlite_jni.so: ABSENT — tflite_flutter 0.12.1 cannot load this runtime\n")
            continue
        lib = z.read(entry.filename)
        so = os.path.join(tmp, sha(lib)[:12] + ".so")
        open(so, "wb").write(lib)
        version = sorted(set(m.decode() for m in re.findall(rb"\d+\.\d+\.\d+-dev\d+\+selfbuilt", lib)))
        print(f"   libtensorflowlite_jni.so: {len(lib):,} B, sha256 {sha(lib)}, zip date {entry.date_time[:3]}, "
              f"version string {version}")
        dis = tool("llvm-objdump", "-d", "--no-show-raw-insn", "--disassemble-symbols=TfLiteInterpreterCreate", so)
        x5 = [ln.strip() for ln in dis.splitlines() if re.search(r"\b(mov|ldr)\s+x5,", ln)]
        print(f"   TfLiteInterpreterCreate, 6th argument (x5 = allocation): {x5} -> "
              + ("nullptr (allocation NOT passed)" if any("xzr" in x for x in x5) else "loaded from the model (allocation passed)"))
        align = sorted(set(re.findall(r"^\s+LOAD\s.*\s(0x[0-9a-f]+)\s*$", tool("llvm-readelf", "-lW", so), re.M)))
        print(f"   LOAD segment alignment: {align}")
        exports = {ln.split()[-1].split("@")[0] for ln in tool("llvm-nm", "-D", "--defined-only", so).splitlines() if ln.strip()}
        missing = [s for s in android_used if s not in exports]
        print(f"   tflite_flutter's {len(android_used)} Android C functions exported: "
              + ("all" if not missing else f"MISSING {missing}") + "\n")
