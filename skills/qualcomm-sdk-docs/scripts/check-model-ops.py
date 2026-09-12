#!/usr/bin/env python3
"""
check-model-ops.py - list an ONNX model's operators and, where the SDK docs
could be parsed, flag the ones a backend may not support.

Answers "will this run on the NPU" cheaply, before a conversion run.

    python3 check-model-ops.py model.onnx
    python3 check-model-ops.py model.onnx --backend htp --docs .qualcomm-docs/2.37.1.250807

Requires `onnx`. The op list comes from extract-sdk-docs.py; without it this
still prints the model's op inventory and tells you where to check by hand,
which is most of the value.

IMPORTANT: a clean report here is not a guarantee. The authority is the
converter:

    qnn-onnx-converter --input_network model.onnx --input_dim <n> <dims> \\
        --output_path /tmp/probe.cpp --dry_run

Use this to find problems early, and --dry_run to confirm.
"""

import argparse
import glob
import json
import os
import sys
from collections import Counter

# Patterns that are a problem on fixed-function NPUs regardless of the op
# table: control flow cannot be scheduled, and data-dependent output shapes
# cannot be made static.
STRUCTURAL = {
    "If": "control flow - cannot be scheduled on a fixed-function NPU",
    "Loop": "control flow - unroll at export time",
    "Scan": "control flow - unroll at export time",
    "NonZero": "data-dependent output shape - cannot be made static",
    "NonMaxSuppression": "keep NMS outside the graph; run it on CPU",
    "TopK": "data-dependent; often fine, but check the op table",
    "RoiAlign": "frequently unsupported on NPU backends",
    "GridSample": "frequently unsupported on NPU backends",
}


def find_docs(explicit):
    if explicit:
        return explicit if os.path.isdir(explicit) else None
    cands = sorted(glob.glob(os.path.join(".qualcomm-docs", "*")))
    cands = [c for c in cands if os.path.isdir(c)]
    return cands[-1] if cands else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("model")
    ap.add_argument("--backend", default="htp")
    ap.add_argument("--docs", default=None,
                    help="extract-sdk-docs.py output dir (default: newest under .qualcomm-docs/)")
    args = ap.parse_args()

    try:
        import onnx
    except ImportError:
        sys.exit("ERROR: onnx is required: pip install onnx")

    if not os.path.isfile(args.model):
        sys.exit(f"ERROR: no such model: {args.model}")

    model = onnx.load(args.model)
    ops = Counter(n.op_type for n in model.graph.node)
    opset = {i.domain or "ai.onnx": i.version for i in model.opset_import}

    print(f"model  : {args.model}")
    print(f"opset  : {opset}")
    print(f"nodes  : {sum(ops.values())}  ({len(ops)} distinct operators)\n")

    # --- dynamic shapes: blocks conversion regardless of op support ---
    dynamic = []
    for t in list(model.graph.input) + list(model.graph.output):
        dims = t.type.tensor_type.shape.dim
        syms = [d.dim_param for d in dims if d.dim_param]
        if syms:
            dynamic.append((t.name, syms))
    if dynamic:
        print("DYNAMIC SHAPES - these must be pinned before conversion:")
        for name, syms in dynamic:
            print(f"  {name:35s} symbolic: {', '.join(syms)}")
        print("  -> see the qnn-model-export skill, stage 1\n")

    # --- structural blockers ---
    hits = [(op, STRUCTURAL[op], ops[op]) for op in ops if op in STRUCTURAL]
    if hits:
        print("STRUCTURAL CONCERNS:")
        for op, why, n in sorted(hits):
            print(f"  {op:22s} x{n:<5d} {why}")
        print()

    # --- op table comparison, when available ---
    docs = find_docs(args.docs)
    table = None
    if docs:
        p = os.path.join(docs, "ops", f"{args.backend}.json")
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                table = set(json.load(f).get("ops", []))

    if table:
        unknown = sorted(op for op in ops if op not in table)
        print(f"Checked against {len(table)} operators documented for "
              f"backend '{args.backend}' ({docs})")
        if unknown:
            print(f"\nNOT FOUND in the {args.backend} op table ({len(unknown)}):")
            for op in unknown:
                print(f"  {op:25s} x{ops[op]}")
            print("\n  An absent operator may still be supported - the table is")
            print("  parsed from HTML and can be incomplete. Confirm with --dry_run.")
        else:
            print("\nAll operators appear in the op table.")
            print("  Not a guarantee: quantization support is a separate question")
            print("  from op support. Confirm with --dry_run.")
    else:
        print("No parsed op table available"
              + (f" for backend '{args.backend}' under {docs}" if docs else "")
              + ".")
        print("  Run extract-sdk-docs.py first, or check the SDK op-support page")
        print("  by hand. The model's full operator inventory:\n")
        for op, n in sorted(ops.items(), key=lambda kv: (-kv[1], kv[0])):
            print(f"  {op:25s} x{n}")

    print("\nAuthoritative check:")
    print("  qnn-onnx-converter --input_network <model> --input_dim <name> <dims> \\")
    print("      --output_path /tmp/probe.cpp --dry_run")


if __name__ == "__main__":
    main()
