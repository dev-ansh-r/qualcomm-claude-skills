#!/usr/bin/env python3
"""
make_calibration.py - build a QNN calibration set from REAL inference.

The point of this script is the thing people get wrong: calibration tensors
must come from running the actual model on representative inputs, not from
np.random. Quantization ranges derived from synthetic data do not match
deployment, and the resulting accuracy loss looks like a conversion bug.

Produces, per model:
    <out>/<model>/input_list.txt
    <out>/<model>/<input_name>_<i>.raw     (headerless little-endian dump)

Usage as a library (the normal case - you supply real inputs):

    from make_calibration import CalibrationWriter

    w = CalibrationWriter("qnn_calibration", "text_encoder")
    for sample in my_real_inputs():            # dict[str, np.ndarray]
        w.add(sample)
    w.close()

Usage as a CLI, to capture a stage's real outputs as the next stage's inputs:

    python make_calibration.py \
        --onnx assets/onnx/text_encoder.onnx \
        --inputs-npz real_inputs.npz \
        --out qnn_calibration \
        --name text_encoder \
        --capture-outputs qnn_calibration/vector_estimator_feed
"""

import argparse
import os
import sys

import numpy as np


class CalibrationWriter:
    """Writes .raw tensors and the input_list.txt QNN expects."""

    def __init__(self, out_dir, model_name):
        self.dir = os.path.abspath(os.path.join(out_dir, model_name))
        os.makedirs(self.dir, exist_ok=True)
        self.list_path = os.path.join(self.dir, "input_list.txt")
        self._lines = []
        self._n = 0
        self._dtypes = {}

    def add(self, sample):
        """sample: dict of input_name -> np.ndarray, already the static shape."""
        entries = []
        for name, arr in sample.items():
            arr = np.ascontiguousarray(arr)

            # dtype must match the ONNX graph input. Silently widening or
            # narrowing here produces garbage the converter cannot detect.
            prev = self._dtypes.setdefault(name, arr.dtype)
            if prev != arr.dtype:
                raise ValueError(
                    f"dtype drift for input '{name}': {prev} then {arr.dtype}. "
                    "Every calibration sample must use the same dtype as the graph."
                )

            # A safe filename for names like '/encoder/Add_output_0'
            safe = name.replace("/", "_").replace(":", "_").lstrip("_")
            path = os.path.join(self.dir, f"{safe}_{self._n}.raw")
            arr.tofile(path)                      # headerless, little-endian
            entries.append(f"{name}:={path}")     # absolute path, exact graph name

        self._lines.append(" ".join(entries))
        self._n += 1

    def close(self):
        if not self._lines:
            raise RuntimeError("no calibration samples were added")
        with open(self.list_path, "w") as f:
            f.write("\n".join(self._lines) + "\n")
        print(f"  {self._n} samples -> {self.list_path}")
        for name, dt in self._dtypes.items():
            print(f"    {name:30s} {dt}")
        if self._n < 50:
            print(
                f"  NOTE: {self._n} samples is thin. ~100 spanning the real input "
                "distribution is the working default.",
                file=sys.stderr,
            )
        return self.list_path


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--onnx", required=True, help="static-shape ONNX model")
    ap.add_argument("--inputs-npz", required=True,
                    help="npz of REAL inputs; arrays keyed by graph input name, "
                         "stacked on axis 0 (one entry per sample)")
    ap.add_argument("--out", default="qnn_calibration")
    ap.add_argument("--name", required=True, help="model name / subdirectory")
    ap.add_argument("--capture-outputs", default=None,
                    help="also write this model's real outputs here, as "
                         "calibration input for the NEXT pipeline stage")
    ap.add_argument("--limit", type=int, default=100)
    args = ap.parse_args()

    try:
        import onnxruntime as ort
    except ImportError:
        sys.exit("onnxruntime is required: pip install onnxruntime")

    sess = ort.InferenceSession(args.onnx, providers=["CPUExecutionProvider"])
    in_names = [i.name for i in sess.get_inputs()]
    out_names = [o.name for o in sess.get_outputs()]
    print(f"model  : {args.onnx}")
    print(f"inputs : {in_names}")
    print(f"outputs: {out_names}")

    data = np.load(args.inputs_npz)
    missing = [n for n in in_names if n not in data]
    if missing:
        sys.exit(f"npz is missing required graph inputs: {missing}")

    n = min(len(data[in_names[0]]), args.limit)
    print(f"writing {n} calibration samples")

    w = CalibrationWriter(args.out, args.name)
    cap = CalibrationWriter(args.capture_outputs, "stage_outputs") if args.capture_outputs else None

    for i in range(n):
        sample = {name: data[name][i] for name in in_names}
        w.add(sample)
        if cap is not None:
            # Run the real model so the next stage calibrates on real activations
            outs = sess.run(None, {k: v for k, v in sample.items()})
            cap.add(dict(zip(out_names, outs)))

    w.close()
    if cap is not None:
        cap.close()
        print("\nThose captured outputs are the correct calibration input for the "
              "next stage. Do not substitute random tensors.")


if __name__ == "__main__":
    main()
