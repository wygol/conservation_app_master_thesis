#!/usr/bin/env python3
"""Feasibility test behind the 2026-10-10 hint to the thesis pipeline (ADR 010) — NOT a thesis result.

Question: can a quantizer output whose weights sit at offsets after the FlatBuffer be re-written with
every weight inline — so that any LiteRT/TFLite runtime can load it (incl. tflite_flutter's iOS runtime,
TF 2.12) — without changing the model?

  1. Re-serialize with ai-edge-litert's own flatbuffer_utils (the module ai-edge-quantizer imports):
     read_model_from_bytearray (copies offset-stored buffers into Buffer.data; in ai-edge-litert 2.3.0 it
     also points tensors with EMPTY buffers at buffer 0) -> convert_object_to_bytearray (all inline).
  2. Structure, two independent readers (this repo's raw reader and the official object API): every
     tensor's name, type, shape, quantization and constant BYTES (resolved through whatever buffer index it
     has), every operator (code, version, inputs, outputs, options), signature defs and metadata — equal.
  3. Behaviour: both files in the same LiteRT interpreter, both resolver types, on the phone reference
     photographs (export_arm2.app_load, verbatim), the grey image and seeded random inputs:
     logits must be bit-identical (np.array_equal), not merely close.
  4. Sanity: both files reproduce phone_reference.json (the handover's criteria).

The thesis-grade proof needs the 218 + 100 pinned training-pool photographs and the checkpoint, which
exist only on the VPS; this script uses what the app repo has.

Usage (from an empty working directory; needs ai-edge-litert, numpy, Pillow):
    python tools/model_check/inline_feasibility.py <model .tflite> <assets/model_check dir> <out .tflite>
"""
import hashlib
import importlib.metadata as md
import json
import os
import platform
import sys

import numpy as np
from PIL import Image
from ai_edge_litert.interpreter import Interpreter, OpResolverType
from ai_edge_litert.tools import flatbuffer_utils as fu

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inspect_buffers import FlatBuffer  # noqa: E402  (this repo's dependency-free reader)

SRC, CHECK_DIR, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
SIZE = 224


def app_load(path, size=SIZE):  # verbatim from ml-pipeline/export_arm2.py
    im = Image.open(path).convert("RGB")
    w, h = im.size
    s = size / min(w, h)
    im = im.resize((max(size, round(w * s)), max(size, round(h * s))), Image.BILINEAR)
    w, h = im.size
    l, t = (w - size) // 2, (h - size) // 2
    im = im.crop((l, t, l + size, t + size))
    return (np.asarray(im, dtype=np.float32) / 255.0)[None]


def sha(data):
    return hashlib.sha256(data).hexdigest()


# ------------------------------------------------------------------ 1. re-serialize
src_bytes = open(SRC, "rb").read()
model = fu.read_model_from_bytearray(bytearray(src_bytes))
out_bytes = bytes(fu.convert_object_to_bytearray(model))
open(OUT, "wb").write(out_bytes)
print("environment:", {"python": platform.python_version(), "ai_edge_litert": md.version("ai-edge-litert"),
                       "flatbuffers": md.version("flatbuffers"), "numpy": np.__version__,
                       "pillow": Image.__version__, "platform": platform.platform()})
print(f"\n1. re-serialized\n  source  {len(src_bytes):>9} bytes  sha256 {sha(src_bytes)}"
      f"\n  inline  {len(out_bytes):>9} bytes  sha256 {sha(out_bytes)}")


# ------------------------------------------------------- 2a. structure, raw reader
def raw_view(data):
    """Per tensor (name, type, shape, signature, raw quantization fields, constant bytes) and per
    operator (opcode string, inputs, outputs), with constants resolved inline OR via offset."""
    fb = FlatBuffer(data)
    root = fb.u32(0)
    buffers = fb.tables(root, 4)
    sg = fb.tables(root, 2)[0]
    codes = []
    for oc in fb.tables(root, 1):
        codes.append((max(fb.scalar(oc, 0, "b"), fb.scalar(oc, 3, "i")), fb.scalar(oc, 2, "i", 1)))

    def const_bytes(b):
        if b == 0:
            return b""
        start, n = fb.vector(buffers[b], 0)
        if start is not None:
            return bytes(fb.b[start:start + n])
        off, size = fb.scalar(buffers[b], 1, "Q"), fb.scalar(buffers[b], 2, "Q")
        return bytes(fb.b[off:off + size]) if off > 1 else b""

    def quant(t):
        p = fb.field(t, 4)
        if p is None:
            return None
        q = fb.deref(p)
        out = []
        for idx in (0, 1, 2, 3):  # min, max (float), scale (float), zero_point (long)
            start, n = fb.vector(q, idx)
            width = 8 if idx == 3 else 4
            out.append(None if start is None else bytes(fb.b[start:start + n * width]))
        out.append(fb.scalar(q, 6, "i"))  # quantized_dimension
        return tuple(out)

    tensors = []
    for t in fb.tables(sg, 0):
        tensors.append((fb.string(t, 3), fb.scalar(t, 1, "b"), tuple(fb.ints(t, 0)), tuple(fb.ints(t, 7)),
                        quant(t), const_bytes(fb.scalar(t, 2, "I")), bool(fb.scalar(t, 5, "B"))))
    ops = [(codes[fb.scalar(op, 0, "I")], tuple(fb.ints(op, 1)), tuple(fb.ints(op, 2)))
           for op in fb.tables(sg, 3)]
    n_offset = sum(1 for b in buffers if fb.scalar(b, 1, "Q") > 1)
    return tensors, ops, tuple(fb.ints(sg, 1)), tuple(fb.ints(sg, 2)), n_offset


ts, os_, is_, outs_, off_s = raw_view(src_bytes)
ti, oi, ii, outi, off_i = raw_view(out_bytes)
diff_t = [k for k, (a, b) in enumerate(zip(ts, ti)) if a != b]
print("\n2a. structure, this repo's raw reader")
print(f"  offset-stored buffers: source {off_s}, inline {off_i}")
print(f"  tensors {len(ts)} vs {len(ti)}; differing (name/type/shape/quantization/constant bytes): {diff_t or 'none'}")
print(f"  constant bytes compared: {sum(len(t[5]) for t in ts)} vs {sum(len(t[5]) for t in ti)}")
print(f"  operators {len(os_)} vs {len(oi)}; differing (code, version, inputs, outputs): "
      f"{[k for k, (a, b) in enumerate(zip(os_, oi)) if a != b] or 'none'}")
print(f"  graph inputs/outputs equal: {is_ == ii and outs_ == outi}")
raw_ok = (off_i == 0 and not diff_t and len(ts) == len(ti) and os_ == oi and is_ == ii and outs_ == outi)


# --------------------------------------------- 2b. structure, the official object API
def as_bytes(x):
    return bytes(np.asarray(x, dtype=np.uint8).tobytes()) if not isinstance(x, (bytes, bytearray)) else bytes(x)


def deep_diff(a, b, path, skip, out):
    if len(out) > 20:
        return
    if isinstance(a, np.ndarray) or isinstance(b, np.ndarray):
        if not np.array_equal(np.asarray(a), np.asarray(b)):
            out.append(path)
    elif isinstance(a, (list, tuple)) or isinstance(b, (list, tuple)):
        if a is None or b is None or len(a) != len(b):
            out.append(path)
        else:
            for k, (x, y) in enumerate(zip(a, b)):
                deep_diff(x, y, f"{path}[{k}]", skip, out)
    elif hasattr(a, "__dict__") and hasattr(b, "__dict__"):
        if type(a) is not type(b):
            out.append(path)
            return
        for k in vars(a):
            if f"{type(a).__name__}.{k}" not in skip:
                deep_diff(getattr(a, k), getattr(b, k), f"{path}.{k}", skip, out)
    elif a != b:
        out.append(path)


src_obj = fu.convert_bytearray_to_object(bytearray(src_bytes))   # raw: offsets NOT resolved
out_obj = fu.convert_bytearray_to_object(bytearray(out_bytes))
diffs = []
deep_diff(src_obj, out_obj, "model", {"ModelT.buffers", "TensorT.buffer", "MetadataT.buffer"}, diffs)


def resolved(obj, data, idx):
    b = obj.buffers[idx]
    if b.data is not None and len(b.data):
        return as_bytes(b.data)
    return bytes(data[b.offset:b.offset + b.size]) if b.offset and b.offset > 1 else b""


const_diff = [k for k, (a, b) in enumerate(zip(src_obj.subgraphs[0].tensors, out_obj.subgraphs[0].tensors))
              if resolved(src_obj, src_bytes, a.buffer) != resolved(out_obj, out_bytes, b.buffer)]
meta_diff = [m.name for m, n in zip(src_obj.metadata or [], out_obj.metadata or [])
             if resolved(src_obj, src_bytes, m.buffer) != resolved(out_obj, out_bytes, n.buffer)]
print("\n2b. structure, official object API (all fields; buffer indices compared through their content)")
print(f"  differing fields: {diffs or 'none'}")
print(f"  tensors whose constant bytes differ: {const_diff or 'none'}; metadata differing: {meta_diff or 'none'}")
print(f"  deprecated Model.metadata_buffer: source {src_obj.metadataBuffer}, inline {out_obj.metadataBuffer}")
api_ok = not diffs and not const_diff and not meta_diff


# ------------------------------------------------------------------ 3. behaviour
ref = json.load(open(os.path.join(CHECK_DIR, "phone_reference.json")))
inputs = []
for case in ref["cases"]:
    if case["file"] is None:
        inputs.append((case["image"], np.full((1, SIZE, SIZE, 3), 0.5, np.float32)))
    else:
        inputs.append((case["image"], app_load(os.path.join(CHECK_DIR, case["image"]))))
rng = np.random.default_rng(20261010)
inputs += [(f"random_{k:02d}", rng.random((1, SIZE, SIZE, 3), dtype=np.float32)) for k in range(64)]
inputs += [("zeros", np.zeros((1, SIZE, SIZE, 3), np.float32)), ("ones", np.ones((1, SIZE, SIZE, 3), np.float32))]


def runner(path, resolver):
    it = Interpreter(model_path=path, num_threads=1, experimental_op_resolver_type=resolver)
    it.allocate_tensors()
    i, o = it.get_input_details()[0]["index"], it.get_output_details()[0]["index"]

    def run(x):
        it.set_tensor(i, x)
        it.invoke()
        return it.get_tensor(o).ravel().copy()
    return run


print(f"\n3. behaviour: {len(inputs)} inputs (6 phone-reference cases, 64 seeded random, zeros, ones)")
outputs = {}
beh_ok = True
for rname, rtype in [("default resolver", OpResolverType.AUTO),
                     ("no default delegates", OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)]:
    a, b = runner(SRC, rtype), runner(OUT, rtype)
    same = 0
    worst = 0.0
    for name, x in inputs:
        ya, yb = a(x), b(x)
        same += int(np.array_equal(ya, yb))
        worst = max(worst, float(np.abs(ya - yb).max()))
        outputs[(rname, name)] = ya
    beh_ok &= same == len(inputs)
    print(f"  {rname:<21} bit-identical logits: {same}/{len(inputs)}   max |difference| {worst}")


# ------------------------------------------------------------------ 4. sanity
def verdict(x, y, case):
    means = [float(x[0, :, :, c].mean()) for c in range(3)]
    dm = max(abs(p - q) for p, q in zip(means, case["preprocessed_channel_means_rgb"]))
    top = list(np.argsort(-y)[:5])
    ref_top = [t["index"] for t in case["top5"]]
    dl = max(abs(float(y[t["index"]]) - t["logit"]) for t in case["top5"])
    return dm <= 0.01 and top[0] == ref_top[0] and len(set(top) & set(ref_top)) >= 4 and dl <= 0.1


passes = sum(verdict(x, outputs[("no default delegates", name)], case)
             for (name, x), case in zip(inputs, ref["cases"]))
print(f"\n4. phone_reference.json reproduced (no-default-delegate runs; inline = source by 3.): "
      f"{passes}/{len(ref['cases'])} cases pass")

print(f"\nRESULT: structure (raw reader) {'IDENTICAL' if raw_ok else 'DIFFERS'}; "
      f"structure (object API) {'IDENTICAL' if api_ok else 'DIFFERS'}; "
      f"behaviour {'BIT-IDENTICAL' if beh_ok else 'DIFFERS'}; offset-stored buffers left: {off_i}")
