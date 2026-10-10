#!/usr/bin/env python3
"""Where does a .tflite file keep its constant data? — the evidence behind ADR 010.

A LiteRT FlatBuffer can store a constant tensor's bytes in two ways: inline (`Buffer.data`)
or after the FlatBuffer in the same file (`Buffer.offset` / `Buffer.size`). ai-edge-quantizer
uses the second way for every model whose packed weights exceed 256 KB. LiteRT 1.4.0's C API
(what tflite_flutter binds) cannot resolve such buffers: the tensors load empty and the first
invoke fails with "Input tensor N lacks data" (phone run of 2026-10-10).

This script reads the file directly — no TensorFlow / LiteRT needed — and prints:
  - metadata (e.g. the min_runtime_version the converter declared),
  - how many buffers are inline and how many are offset-stored, by tensor type,
  - the FIRST offset-stored constant in execution order (= the tensor a runtime that cannot
    resolve offsets fails on), and
  - details for any tensor indices given on the command line (type, shape, storage, which
    operator consumes or produces it).

Usage:
    python tools/model_check/inspect_buffers.py <model .tflite> [tensor_index ...]

Field indices follow tensorflow/compiler/mlir/lite/schema/schema.fbs (TF v2.20.0).
"""
import struct
import sys

TENSOR_TYPES = {0: "FLOAT32", 1: "FLOAT16", 2: "INT32", 3: "UINT8", 4: "INT64", 5: "STRING",
                6: "BOOL", 7: "INT16", 8: "COMPLEX64", 9: "INT8", 10: "FLOAT64", 11: "COMPLEX128",
                12: "UINT64", 13: "RESOURCE", 14: "VARIANT", 15: "UINT32", 16: "UINT16",
                17: "INT4", 18: "BFLOAT16"}
# Only the BuiltinOperator values checked against schema.fbs; others print as "op#N".
OPS = {0: "ADD", 1: "AVERAGE_POOL_2D", 2: "CONCATENATION", 3: "CONV_2D", 4: "DEPTHWISE_CONV_2D",
       6: "DEQUANTIZE", 9: "FULLY_CONNECTED", 14: "LOGISTIC", 18: "MUL", 19: "RELU", 21: "RELU6",
       22: "RESHAPE", 25: "SOFTMAX", 32: "CUSTOM", 34: "PAD", 36: "GATHER", 39: "TRANSPOSE",
       40: "MEAN", 41: "SUB", 42: "DIV", 43: "SQUEEZE", 45: "STRIDED_SLICE", 74: "SUM",
       107: "GATHER_ND", 114: "QUANTIZE", 117: "HARD_SWISH"}


class FlatBuffer:
    """Just enough of the FlatBuffers wire format to walk tables, vectors and strings."""

    def __init__(self, data):
        self.b = data

    def u32(self, p):
        return struct.unpack_from("<I", self.b, p)[0]

    def field(self, table, idx):
        vtable = table - struct.unpack_from("<i", self.b, table)[0]
        slot = 4 + 2 * idx
        if slot >= struct.unpack_from("<H", self.b, vtable)[0]:
            return None
        off = struct.unpack_from("<H", self.b, vtable + slot)[0]
        return table + off if off else None

    def deref(self, p):
        return p + self.u32(p)

    def scalar(self, table, idx, fmt, default=0):
        p = self.field(table, idx)
        return default if p is None else struct.unpack_from("<" + fmt, self.b, p)[0]

    def vector(self, table, idx):
        p = self.field(table, idx)
        if p is None:
            return None, 0
        v = self.deref(p)
        return v + 4, self.u32(v)

    def ints(self, table, idx):
        start, n = self.vector(table, idx)
        return [] if start is None else [struct.unpack_from("<i", self.b, start + 4 * i)[0] for i in range(n)]

    def tables(self, table, idx):
        start, n = self.vector(table, idx)
        return [] if start is None else [self.deref(start + 4 * i) for i in range(n)]

    def string(self, table, idx):
        p = self.field(table, idx)
        if p is None:
            return None
        s = self.deref(p)
        return self.b[s + 4:s + 4 + self.u32(s)].decode("utf-8", "replace")


def main():
    path, wanted = sys.argv[1], [int(a) for a in sys.argv[2:]]
    fb = FlatBuffer(open(path, "rb").read())
    model = fb.u32(0)
    buffers = fb.tables(model, 4)                      # Model.buffers
    subgraph = fb.tables(model, 2)[0]                  # Model.subgraphs[0]
    tensors, operators = fb.tables(subgraph, 0), fb.tables(subgraph, 3)
    opcodes = []
    for oc in fb.tables(model, 1):                     # OperatorCode: max(deprecated, builtin_code)
        code = max(fb.scalar(oc, 0, "b"), fb.scalar(oc, 3, "i"))
        opcodes.append("%s v%d" % (OPS.get(code, "op#%d" % code), fb.scalar(oc, 2, "i", 1)))

    def storage(tensor_index):
        b = fb.scalar(tensors[tensor_index], 2, "I")   # Tensor.buffer; 0 = no constant data
        if b == 0:
            return "none", 0, 0
        start, n = fb.vector(buffers[b], 0)            # Buffer.data
        if start is not None and n:
            return "inline", n, 0
        offset, size = fb.scalar(buffers[b], 1, "Q"), fb.scalar(buffers[b], 2, "Q")
        return ("offset", size, offset) if offset > 1 else ("empty", 0, 0)

    def describe(ti):
        t = tensors[ti]
        kind, size, offset = storage(ti)
        where = {"inline": "inline, %d bytes" % size, "offset": "OFFSET %d, %d bytes" % (offset, size),
                 "none": "no constant data", "empty": "empty buffer"}[kind]
        return "tensor %d: %s %s, %s, name %r" % (
            ti, TENSOR_TYPES.get(fb.scalar(t, 1, "b"), "?"), fb.ints(t, 0), where, fb.string(t, 3))

    print("file: %s (%d bytes), %d tensors, %d operators" % (path, len(fb.b), len(tensors), len(operators)))
    for md in fb.tables(model, 6):                     # Model.metadata
        start, n = fb.vector(buffers[fb.scalar(md, 1, "I")], 0)
        value = b"" if start is None else bytes(fb.b[start:start + n]).rstrip(b"\0")
        print("metadata %s = %r" % (fb.string(md, 0), value.decode("latin1")))
    print("operators used:", ", ".join(sorted(set(opcodes))))

    counts = {}
    for ti in range(len(tensors)):
        kind = storage(ti)[0]
        if kind in ("inline", "offset"):
            key = (TENSOR_TYPES.get(fb.scalar(tensors[ti], 1, "b"), "?"), kind)
            counts[key] = counts.get(key, 0) + 1
    n_offset = sum(1 for b in buffers if fb.scalar(b, 1, "Q") > 1)
    print("buffers: %d, of which stored at an offset after the FlatBuffer: %d" % (len(buffers), n_offset))
    print("constant tensors by (type, storage):", dict(sorted(counts.items())))

    inline_before = 0
    for oi, op in enumerate(operators):                # execution order = operator order
        for x in fb.ints(op, 1):
            if x < 0:
                continue
            kind = storage(x)[0]
            if kind == "offset":
                print("first offset-stored constant in execution order: operator %d (%s), %s"
                      % (oi, opcodes[fb.scalar(op, 0, "I")], describe(x)))
                print("inline constants consumed before it: %d" % inline_before)
                break
            inline_before += kind == "inline"
        else:
            continue
        break
    else:
        print("no offset-stored constants: every runtime can read this file's weights")

    for ti in wanted:
        print("\n" + describe(ti))
        for oi, op in enumerate(operators):
            ins, outs = fb.ints(op, 1), fb.ints(op, 2)
            if ti in ins or ti in outs:
                print("  %s operator %d (%s): inputs %s, outputs %s" % (
                    "consumed by" if ti in ins else "produced by", oi, opcodes[fb.scalar(op, 0, "I")], ins, outs))


if __name__ == "__main__":
    main()
