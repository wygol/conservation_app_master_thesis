#!/usr/bin/env python3
"""Checks every upstream source fact ADR 010 and the thesis hints rely on, against the raw files.

The facts were first read through a summarising web tool; this script fetches the raw files instead and
checks the exact text (present or, where the claim is an absence, absent), printing the line number and
the SHA-256 of what it read, so the check can be repeated and compared.

Usage: python tools/model_check/verify_upstream_sources.py
"""
import hashlib
import html
import json
import os
import re
import sys
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")
TF = "https://raw.githubusercontent.com/tensorflow/tensorflow/{tag}/{path}"
PUB = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Pub", "Cache", "hosted", "pub.dev", "tflite_flutter-0.12.1")
ok_all = []


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "conservation_app-evidence-check"})
    return urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "replace")


def check(source, text, needle, present=True, claim=""):
    lines = [i + 1 for i, ln in enumerate(text.splitlines()) if needle in ln]
    ok = bool(lines) == present
    ok_all.append(ok)
    where = f"line {lines[0]}" if lines else "absent"
    print(f"{'PASS' if ok else 'FAIL'}  {claim}\n      {source}: {needle!r} {'expected present' if present else 'expected ABSENT'} -> {where}")


def remote(url):
    text = fetch(url)
    print(f"\n{url}\n  sha256 {hashlib.sha256(text.encode('utf-8')).hexdigest()}, {len(text):,} characters")
    return text


t = remote(TF.format(tag="v2.20.0", path="tensorflow/lite/core/interpreter_builder.cc"))
check("TF v2.20.0 interpreter_builder.cc", t, "} else if (offset > 1 && allocation_) {",
      claim="an offset-stored buffer is resolved only when the builder has an allocation")
t = remote(TF.format(tag="v2.20.0", path="tensorflow/lite/core/interpreter_builder.h"))
check("TF v2.20.0 interpreter_builder.h", t, "const Allocation* allocation = nullptr",
      claim="the raw-Model* constructor defaults the allocation to nullptr")
t = remote(TF.format(tag="v2.20.0", path="tensorflow/lite/core/c/c_api.cc"))
check("TF v2.20.0 c_api.cc", t, "tflite::InterpreterBuilder builder(model->impl->GetModel(), *op_resolver,",
      claim="the C API builds the interpreter from the bare Model*")
check("TF v2.20.0 c_api.cc", t, "model->impl->allocation()", present=False,
      claim="... and passes no allocation")
t = remote(TF.format(tag="v2.20.0", path="tensorflow/lite/java/src/main/native/nativeinterpreterwrapper_jni.cc"))
check("TF v2.20.0 nativeinterpreterwrapper_jni.cc", t, "InterpreterBuilder interpreter_builder(*model, *resolver);",
      claim="the Java API builds from the FlatBufferModel, which carries the allocation")
t = remote(TF.format(tag="v2.12.0", path="tensorflow/lite/core/interpreter_builder.cc"))
check("TF v2.12.0 interpreter_builder.cc", t, "offset()", present=False,
      claim="TF 2.12 (tflite_flutter's iOS runtime) has no offset-stored buffer support")
t = remote("https://raw.githubusercontent.com/google-ai-edge/LiteRT/main/tflite/core/c/c_api.cc")
check("LiteRT main c_api.cc", t, "model->impl->allocation()", claim="LiteRT today passes the allocation")
c = json.loads(fetch("https://api.github.com/repos/google-ai-edge/LiteRT/commits/d17fd00"))
print(f"\nhttps://api.github.com/repos/google-ai-edge/LiteRT/commits/d17fd00\n  sha {c['sha']}")
msg, date = c["commit"]["message"], c["commit"]["author"]["date"]
ok = msg.startswith("Pass allocation info to `InterpreterBuilder` in `InterpreterCreateWithOpResolver`") and date.startswith("2025-11-05")
patch = "".join(f.get("patch", "") for f in c.get("files", []))
ok = ok and "model->impl->allocation()" in patch
ok_all.append(ok)
print(f"{'PASS' if ok else 'FAIL'}  commit d17fd00: message {msg.splitlines()[0]!r}, authored {date}, diff adds model->impl->allocation()")
t = remote("https://raw.githubusercontent.com/google-ai-edge/ai-edge-quantizer/main/ai_edge_quantizer/model_modifier.py")
check("ai-edge-quantizer main model_modifier.py", t, "packed_size < 256 * 1024",
      claim="the quantizer switches to offset-stored buffers from 256 KiB of packed data")
check("ai-edge-quantizer main model_modifier.py", t, "from ai_edge_litert.tools import flatbuffer_utils",
      claim="it serializes with ai_edge_litert.tools.flatbuffer_utils")
t = remote("https://raw.githubusercontent.com/google-ai-edge/ai-edge-quantizer/main/ai_edge_quantizer/quantizer.py")
check("ai-edge-quantizer main quantizer.py", t, "      enable_progress_report: bool = True,",
      claim="quantize() has no parameter for the buffer layout (its last parameter, then the return type)")
check("ai-edge-quantizer main quantizer.py", t, "  ) -> QuantizationResult:", claim="... signature closes here")
t = remote(TF.format(tag="v2.20.0", path="tensorflow/lite/python/interpreter_wrapper/interpreter_wrapper.cc"))
check("TF v2.20.0 python interpreter_wrapper.cc", t, "InterpreterBuilder builder(*model, resolver, &options);",
      claim="the Python interpreter also builds from the full model object")
t = remote("https://raw.githubusercontent.com/google-ai-edge/LiteRT/main/tflite/tools/flatbuffer_utils.py")
check("LiteRT main tflite/tools/flatbuffer_utils.py", t, "from tensorflow.python.platform import gfile",
      claim="read_model / write_model in the LiteRT source tree go through TF's gfile")
local_fu = os.path.join(sys.prefix, "Lib", "site-packages", "ai_edge_litert", "tools", "flatbuffer_utils.py")
if os.path.exists(local_fu):
    import importlib.metadata as md
    t = open(local_fu, encoding="utf-8").read()
    print(f"\n{local_fu} (ai-edge-litert {md.version('ai-edge-litert')} from PyPI, as installed)\n"
          f"  sha256 {hashlib.sha256(t.encode('utf-8')).hexdigest()}")
    check("ai-edge-litert flatbuffer_utils.py", t, "  _compact_buffers_array(model)",
          claim="read_model_from_bytearray also compacts empty buffers to buffer 0")
    check("ai-edge-litert flatbuffer_utils.py", t, "import os # import gfile", claim="... and replaces gfile with os")
else:
    print(f"\n(ai-edge-litert not installed in this interpreter - its two checks skipped; run with the venv that has it)")
t = remote("https://dl.google.com/android/maven2/com/google/ai/edge/litert/litert-gpu/1.4.0/litert-gpu-1.4.0.pom")
check("litert-gpu 1.4.0 POM", t, "<version>[1.4.0]</version>", claim="litert-gpu 1.4.0 pins its API artifacts to exactly 1.4.0")
page = remote("https://pub.dev/packages/flutter_litert/changelog")
text = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", page)))  # one line of visible text
check("pub.dev flutter_litert changelog (visible text)", text, "flutter_litert 3.9.3",
      claim="flutter_litert (ADR 009's fallback) is now at 3.9.x")
check("pub.dev flutter_litert changelog (visible text)", text, "updated from LiteRT Next 2.1.6 to 2.2.0",
      claim="... on LiteRT Next 2.2.0")
check("pub.dev flutter_litert changelog (visible text)", text, "The 2.2.0 AAR ships the same libLiteRt.so",
      claim="... whose AAR ships libLiteRt.so (the CompiledModel runtime), not libtensorflowlite_jni.so")

print(f"\nlocal: {PUB}")
for rel, needle, claim in [
        ("CHANGELOG.md", "## 0.12.1 (October 28, 2025)", "tflite_flutter 0.12.1 released 2025-10-28"),
        ("CHANGELOG.md", "Migrated from TensorFlow Lite 2.12.0 to Google AI Edge LiteRT 1.4.0", "... moving Android to LiteRT 1.4.0"),
        ("android/build.gradle", 'def litert_version = "1.4.0"', "the plugin declares LiteRT 1.4.0"),
        ("ios/tflite_flutter.podspec", "tflite_version = '2.12.0'", "iOS uses TensorFlowLiteSwift 2.12.0"),
        ("lib/src/bindings/bindings.dart", "DynamicLibrary.open('libtensorflowlite_jni.so')", "Android loads libtensorflowlite_jni.so by name")]:
    check(f"tflite_flutter-0.12.1/{rel}", open(os.path.join(PUB, rel), encoding="utf-8").read(), needle, claim=claim)

print(f"\n{sum(ok_all)}/{len(ok_all)} source facts confirmed")
sys.exit(0 if all(ok_all) else 1)
