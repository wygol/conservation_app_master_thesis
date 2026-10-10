#!/usr/bin/env python3
"""Stage-by-stage expectations for the on-phone correctness check (DIAGNOSTIC ONLY).

The pass/fail criteria of the measurement round come from the thesis' own reference file,
assets/model_check/phone_reference.json (generated on the VPS by ml-pipeline/arm2_phone_reference.py).
That file only says WHETHER the app's pipeline matches. This script adds the information needed to say
WHERE it differs if it does not: exact checksums after every stage of the reference preprocessing
(the verbatim copy of ml-pipeline/export_arm2.app_load below), so the app can report
"decoder identical / resample identical / crop identical" instead of a bare FAIL.

It also writes the synthetic 12-megapixel JPEG used for the large-image memory reading (René's request,
2026-10-09): ref_01 rotated to landscape, upscaled to the Galaxy S22's default 4000 x 3000 photo size,
with deterministic grain so the file compresses like a real camera photograph. It is a memory stimulus,
not a plant photograph the model was evaluated on.

Usage (from an empty working directory):
    python3 tools/model_check/make_stage_expectations.py <assets/model_check dir> <model .tflite>

Requires numpy, Pillow and ai-edge-litert. Re-running with the same library versions reproduces the
same bytes; the versions used are recorded in the output.
"""
import datetime
import hashlib
import json
import os
import platform
import sys

import numpy as np
from PIL import Image, features

SIZE = 224


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_file(p):
    with open(p, "rb") as f:
        return sha256_bytes(f.read())


def stage(arr):
    """Checksums of an HxWx3 uint8 array, in row-major RGB order (what the app hashes too)."""
    a = np.ascontiguousarray(arr, dtype=np.uint8)
    return {"width": int(a.shape[1]), "height": int(a.shape[0]),
            "channel_sums_rgb": [int(a[:, :, c].sum(dtype=np.int64)) for c in range(3)],
            "sha256_rgb": sha256_bytes(a.tobytes())}


def reference_stages(path):
    """export_arm2.app_load, verbatim, with the intermediate images kept."""
    im = Image.open(path).convert("RGB")
    decoded = np.asarray(im)
    w, h = im.size
    s = SIZE / min(w, h)
    target = (max(SIZE, round(w * s)), max(SIZE, round(h * s)))
    im = im.resize(target, Image.BILINEAR)
    resized = np.asarray(im)
    w, h = im.size
    l, t = (w - SIZE) // 2, (h - SIZE) // 2
    im = im.crop((l, t, l + SIZE, t + SIZE))
    cropped = np.asarray(im)
    x = (np.asarray(im, dtype=np.float32) / 255.0)[None]
    return decoded, target, (l, t), resized, cropped, x


def make_synthetic_12mp(src_jpg, out_jpg):
    im = Image.open(src_jpg).convert("RGB").transpose(Image.Transpose.ROTATE_90)  # 600x800 -> 800x600
    im = im.resize((4000, 3000), Image.BICUBIC)
    a = np.asarray(im).astype(np.int16)
    rng = np.random.default_rng(20261009)
    a = np.clip(a + np.rint(rng.normal(0.0, 6.0, a.shape)).astype(np.int16), 0, 255).astype(np.uint8)
    # Baseline, 4:2:0, quality 92 — the common shape of a phone-camera JPEG. No EXIF, no ICC.
    Image.fromarray(a).save(out_jpg, format="JPEG", quality=92, subsampling=2, optimize=False,
                            progressive=False)


def main():
    check_dir, model = sys.argv[1], sys.argv[2]
    from ai_edge_litert.interpreter import Interpreter, OpResolverType
    import importlib.metadata as md

    synth = os.path.join(check_dir, "synthetic_12mp.jpg")
    make_synthetic_12mp(os.path.join(check_dir, "ref_01.jpg"), synth)

    runners = {}
    for name, resolver in [("auto", OpResolverType.AUTO),
                           ("builtin_without_default_delegates",
                            OpResolverType.BUILTIN_WITHOUT_DEFAULT_DELEGATES)]:
        it = Interpreter(model_path=model, num_threads=1, experimental_op_resolver_type=resolver)
        it.allocate_tensors()
        runners[name] = it

    def run(it, x):
        it.set_tensor(it.get_input_details()[0]["index"], x)
        it.invoke()
        return it.get_tensor(it.get_output_details()[0]["index"]).ravel()

    images = [f"ref_0{k}.jpg" for k in range(1, 6)] + ["synthetic_12mp.jpg"]
    cases = []
    for name in images:
        p = os.path.join(check_dir, name)
        decoded, target, offset, resized, cropped, x = reference_stages(p)
        outputs = {}
        for rname, it in runners.items():
            y = run(it, x)
            top = np.argsort(-y)[:5]
            outputs[rname] = [{"index": int(i), "logit": round(float(y[i]), 4)} for i in top]
        cases.append({
            "image": name,
            "file": {"sha256": sha256_file(p), "bytes": os.path.getsize(p)},
            "decoded": stage(decoded),
            "target_size": list(target),
            "crop_offset_left_top": list(offset),
            "resized": stage(resized),
            "cropped": stage(cropped),
            "input_channel_means_rgb": [float(x[0, :, :, c].astype(np.float64).mean()) for c in range(3)],
            "top5_by_resolver": outputs,
        })
        print(f"{name:<20} {decoded.shape[1]}x{decoded.shape[0]} -> {target[0]}x{target[1]}  "
              f"top-1 {outputs['auto'][0]['index']}")

    res = {
        "what": "DIAGNOSTIC stage checksums of the reference preprocessing (export_arm2.app_load). "
                "Pass/fail of the measurement round is decided against phone_reference.json, not this file.",
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "script": {"path": "tools/model_check/make_stage_expectations.py",
                   "sha256": sha256_file(os.path.abspath(__file__))},
        "model": {"sha256": sha256_file(model), "bytes": os.path.getsize(model)},
        "hash_convention": "sha256 over the HxWx3 uint8 RGB bytes in row-major order (no alpha, no padding)",
        "environment": {
            "python": platform.python_version(),
            "numpy": np.__version__,
            "pillow": Image.__version__,
            "libjpeg_turbo": features.version("libjpeg_turbo"),
            "ai_edge_litert": md.version("ai-edge-litert"),
            "platform": platform.platform(),
        },
        "synthetic_12mp": {
            "recipe": "ref_01.jpg -> ROTATE_90 (800x600) -> BICUBIC resize 4000x3000 -> + round(N(0,6)) grain "
                      "(numpy default_rng seed 20261009), clipped -> JPEG quality 92, 4:2:0, baseline, no EXIF/ICC",
            "purpose": "memory stimulus of camera-photo size for the large-image reading; not an evaluation image",
        },
        "cases": cases,
    }
    with open(os.path.join(check_dir, "stage_expectations.json"), "w") as f:
        json.dump(res, f, indent=1)
    print("wrote stage_expectations.json and synthetic_12mp.jpg")


if __name__ == "__main__":
    main()
