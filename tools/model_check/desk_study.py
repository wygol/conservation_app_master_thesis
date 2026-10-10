#!/usr/bin/env python3
"""Desk study behind ADR 009 — why the app's preprocessing must be Pillow-exact.

Answers four questions on the desktop, with the shipped model file and the thesis'
phone_reference fixtures, BEFORE anything runs on a phone:

  A. Does the reference pipeline (export_arm2.app_load, verbatim) reproduce
     phone_reference.json in this environment?  (sanity: environment is comparable)
  B. Is a C-faithful re-implementation of Pillow's BILINEAR resample bit-exact?
     (the algorithm lib/ml/pillow_resize.dart ports)
  C. What happens with a naive (non-antialiased) bilinear resize — the common
     default in Dart image libraries?  (does the check catch it? which criterion?)
  D. How sensitive are the logits to decoder-sized pixel differences (+-1..2 levels)?
     (how strict is the +-0.1 logit tolerance in practice?)
  E. Does the runtime's default resolver apply XNNPACK, and how much does it change
     desktop latency?  (why "no delegate" must be verified, not assumed)

Usage (from an empty working directory; needs numpy, Pillow, ai-edge-litert):
    python3 tools/model_check/desk_study.py <assets/model_check dir> <model .tflite>

Desktop latencies printed here are NOT phone numbers and must never be reported as such.
"""
import importlib.metadata as md
import json
import math
import platform
import sys
import time

import numpy as np
from PIL import Image, features
from ai_edge_litert.interpreter import Interpreter, OpResolverType

CHECK_DIR, MODEL = sys.argv[1], sys.argv[2]
REF = json.load(open(f"{CHECK_DIR}/phone_reference.json"))
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


def target_size(w, h, size=SIZE):
    s = size / min(w, h)
    return max(size, round(w * s)), max(size, round(h * s))


def crop_scale(arr):
    h, w = arr.shape[:2]
    l, t = (w - SIZE) // 2, (h - SIZE) // 2
    return (arr[t:t + SIZE, l:l + SIZE].astype(np.float32) / 255.0)[None]


# --- Pillow libImaging/Resample.c, BILINEAR, 8 bits per channel -------------
PB = 32 - 8 - 2


def _coeffs(in_size, out_size):
    scale = float(in_size) / out_size
    fs = scale if scale >= 1.0 else 1.0
    support = 1.0 * fs
    bounds, kk = [], []
    for xx in range(out_size):
        center = (xx + 0.5) * scale
        xmin = max(int(center - support + 0.5), 0)
        xmax = min(int(center + support + 0.5), in_size) - xmin
        k = []
        for x in range(xmax):
            a = abs((x + xmin - center + 0.5) / fs)
            k.append(1.0 - a if a < 1.0 else 0.0)
        ww = sum(k)
        if ww != 0.0:
            k = [v / ww for v in k]
        bounds.append((xmin, xmax))
        kk.append(np.array([int(0.5 + v * (1 << PB)) for v in k], dtype=np.int64))
    return bounds, kk


def _clip8(a):
    return np.where(a >= (1 << PB << 8), 255, np.where(a <= 0, 0, a >> PB)).astype(np.uint8)


def pillow_bilinear(arr, out_w, out_h):
    h, w = arr.shape[:2]
    src = arr.astype(np.int64)
    if out_w != w:
        b, kk = _coeffs(w, out_w)
        tmp = np.empty((h, out_w, 3), dtype=np.int64)
        for xx, ((xmin, n), k) in enumerate(zip(b, kk)):
            tmp[:, xx, :] = (1 << (PB - 1)) + np.tensordot(src[:, xmin:xmin + n, :], k, axes=([1], [0]))
        src = _clip8(tmp).astype(np.int64)
    if out_h != h:
        b, kk = _coeffs(h, out_h)
        tmp = np.empty((out_h, src.shape[1], 3), dtype=np.int64)
        for yy, ((ymin, n), k) in enumerate(zip(b, kk)):
            tmp[yy] = (1 << (PB - 1)) + np.tensordot(src[ymin:ymin + n], k, axes=([0], [0]))
        src = _clip8(tmp).astype(np.int64)
    return src.astype(np.uint8)


def naive_bilinear(arr, out_w, out_h, half_pixel):
    h, w = arr.shape[:2]
    a = arr.astype(np.float64)

    def grid(n_out, n_in):
        sc = n_in / n_out
        i = np.arange(n_out, dtype=np.float64)
        s = np.clip((i + 0.5) * sc - 0.5 if half_pixel else i * sc, 0, n_in - 1)
        i0 = np.floor(s).astype(int)
        return i0, np.minimum(i0 + 1, n_in - 1), s - i0

    y0, y1, fy = grid(out_h, h)
    x0, x1, fx = grid(out_w, w)
    top = a[y0][:, x0] * (1 - fx)[None, :, None] + a[y0][:, x1] * fx[None, :, None]
    bot = a[y1][:, x0] * (1 - fx)[None, :, None] + a[y1][:, x1] * fx[None, :, None]
    return np.clip(np.floor(top * (1 - fy)[:, None, None] + bot * fy[:, None, None] + 0.5), 0, 255).astype(np.uint8)


def runner(resolver):
    it = Interpreter(model_path=MODEL, num_threads=1, experimental_op_resolver_type=resolver)
    it.allocate_tensors()
    i, o = it.get_input_details()[0]["index"], it.get_output_details()[0]["index"]

    def run(x):
        it.set_tensor(i, x)
        it.invoke()
        return it.get_tensor(o).ravel().copy()
    return run


RUN_AUTO = runner(OpResolverType.AUTO)
RUN_PLAIN = runner(OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)


def verdict(x, y, case):
    means = [float(x[0, :, :, c].mean()) for c in range(3)]
    dm = max(abs(a - b) for a, b in zip(means, case["preprocessed_channel_means_rgb"]))
    top = list(np.argsort(-y)[:5])
    ref = [t["index"] for t in case["top5"]]
    dl = max(abs(float(y[t["index"]]) - t["logit"]) for t in case["top5"])
    ok = dm <= 0.01 and top[0] == ref[0] and len(set(top) & set(ref)) >= 4 and dl <= 0.1
    return (f"dmean={dm:.5f} top1={'same' if top[0] == ref[0] else 'DIFF'} "
            f"top5_overlap={len(set(top) & set(ref))}/5 max|dlogit|={dl:.4f} -> {'PASS' if ok else 'FAIL'}")


print("environment:", {"python": platform.python_version(), "numpy": np.__version__,
                       "pillow": Image.__version__, "libjpeg_turbo": features.version("libjpeg_turbo"),
                       "ai_edge_litert": md.version("ai-edge-litert"), "platform": platform.platform()})

print("\nA. reference pipeline vs phone_reference.json (1 thread)")
for case in REF["cases"]:
    x = np.full((1, SIZE, SIZE, 3), 0.5, np.float32) if case["file"] is None \
        else app_load(f"{CHECK_DIR}/{case['image']}")
    print(f"  {case['image'][:12]:<12} default resolver:  {verdict(x, RUN_AUTO(x), case)}")
    print(f"  {'':<12} no default deleg.: {verdict(x, RUN_PLAIN(x), case)}")

photos = [c for c in REF["cases"] if c["file"] is not None]
print("\nB. C-faithful Pillow resample vs Pillow itself")
for case in photos:
    im = Image.open(f"{CHECK_DIR}/{case['image']}").convert("RGB")
    tw, th = target_size(*im.size)
    same = np.array_equal(np.asarray(im.resize((tw, th), Image.BILINEAR)), pillow_bilinear(np.asarray(im), tw, th))
    print(f"  {case['image']} {im.size[0]}x{im.size[1]} -> {tw}x{th}: bit-exact={same}")

print("\nC. naive (non-antialiased) bilinear instead of Pillow's")
for name, hp in [("half-pixel centres", True), ("top-left aligned", False)]:
    for case in photos:
        a = np.asarray(Image.open(f"{CHECK_DIR}/{case['image']}").convert("RGB"))
        tw, th = target_size(a.shape[1], a.shape[0])
        x = crop_scale(naive_bilinear(a, tw, th, hp))
        print(f"  {case['image']} {name:<18}: {verdict(x, RUN_AUTO(x), case)}")

print("\nD. decoder-sized pixel differences before the reference resize (seed 0)")
rng = np.random.default_rng(0)
for label, frac, amp in [("+-1 on 10% of pixels", .10, 1), ("+-1 on 50% of pixels", .50, 1),
                         ("+-2 on 20% of pixels", .20, 2)]:
    worst, same1, ov = 0.0, 0, []
    for case in photos:
        dec = np.asarray(Image.open(f"{CHECK_DIR}/{case['image']}").convert("RGB")).astype(int)
        mask = rng.random(dec.shape) < frac
        noisy = np.clip(dec + mask * rng.choice([-amp, amp], size=dec.shape), 0, 255).astype(np.uint8)
        im = Image.fromarray(noisy)
        tw, th = target_size(*im.size)
        x = crop_scale(np.asarray(im.resize((tw, th), Image.BILINEAR)))
        y = RUN_AUTO(x)
        ref = [t["index"] for t in case["top5"]]
        worst = max(worst, max(abs(float(y[t["index"]]) - t["logit"]) for t in case["top5"]))
        same1 += int(np.argmax(y) == ref[0])
        ov.append(len(set(np.argsort(-y)[:5]) & set(ref)))
    print(f"  {label:<22} worst max|dlogit| = {worst:.3f}; top-1 same {same1}/5; top-5 overlap {ov}")

print("\nE. desktop latency, 1 thread, 20 warm-up + 100 timed (x86 — NOT a phone number)")
x = app_load(f"{CHECK_DIR}/ref_01.jpg")
for name, fn in [("default resolver (applies XNNPACK)", RUN_AUTO), ("without default delegates", RUN_PLAIN)]:
    for _ in range(20):
        fn(x)
    t = []
    for _ in range(100):
        s = time.perf_counter()
        fn(x)
        t.append(1000 * (time.perf_counter() - s))
    t.sort()
    print(f"  {name:<36} median {(t[49] + t[50]) / 2:.2f} ms, p90 {t[89]:.2f} ms")
