# Static shapes

QNN does not support dynamic shapes. Every symbolic dimension must become a
concrete integer before conversion. This applies to **both** flows — classic and
QAIRT/DLC.

## Finding what is dynamic

```python
import onnx

g = onnx.load("model.onnx")
for io, label in ((g.graph.input, "IN "), (g.graph.output, "OUT")):
    for t in io:
        dims = [
            d.dim_value if d.HasField("dim_value") else (d.dim_param or "?")
            for d in t.type.tensor_type.shape.dim
        ]
        dyn = any(isinstance(d, str) for d in dims)
        print(f"{label} {t.name:35s} {dims} {'<-- DYNAMIC' if dyn else ''}")
```

Anything printing a name (`batch_size`, `text_length`, `Muloutput_dim_0`) rather
than a number must be pinned.

## Pinning

```python
import onnx
from onnx import shape_inference

g = onnx.load("model.onnx")

SHAPES = {                       # graph input name -> full static shape
    "text_ids":  (1, 128),
    "style_ttl": (1, 50, 256),
    "text_mask": (1, 1, 128),
}

for inp in g.graph.input:
    if inp.name in SHAPES:
        for i, v in enumerate(SHAPES[inp.name]):
            inp.type.tensor_type.shape.dim[i].dim_value = v

for out in g.graph.output:                       # outputs too
    for d in out.type.tensor_type.shape.dim:
        if not d.HasField("dim_value"):
            ...                                  # set from known output shape

g = shape_inference.infer_shapes(g)              # propagate through the graph
g.opset_import[0].version = 17
onnx.save(g, "model_static.onnx")
```

### Always run `infer_shapes`

Pinning inputs and outputs alone leaves interior tensors symbolic. The converter
then fails on an internal node with a generated name like
`/encoder/layers.3/Reshape_output_0`, which tells you nothing about which input
was wrong. `infer_shapes` propagates the constraint and surfaces conflicts at
the point where they actually arise.

If `infer_shapes` raises, the shapes you chose are **inconsistent with the
graph** — that is real information, not an obstacle. A reshape somewhere expects
a product your chosen dimensions do not produce.

### Verify the pinned model still runs

Before converting, confirm the static ONNX produces correct output in ONNX
Runtime. A silently wrong reshape is much easier to find here than after
quantization.

```python
import onnxruntime as ort, numpy as np
s = ort.InferenceSession("model_static.onnx", providers=["CPUExecutionProvider"])
print([(i.name, i.shape) for i in s.get_inputs()])
```

Any remaining string in a shape means the pinning did not take.

## Choosing the values — a product decision, not a detail

The static length is frozen for the life of the binary. Getting it wrong is
expensive to discover later.

| Dimension | Typical choice | Consequence of choosing badly |
|---|---|---|
| Batch | Almost always 1 | Larger batch costs memory and latency for little gain on a single-stream device |
| Sequence / text length | Cover the p99 real input | Too short truncates real inputs; too long wastes compute on every call |
| Latent / frame count | Longest utterance or window you support | Sets the hard ceiling on output duration |
| Image H/W | Native model resolution | Resizing at runtime is cheap; re-exporting is not |

### The padding contract moves to the application

Once the length is fixed, the app must pad every input to it and supply a mask
marking the valid region. Two failure modes follow directly:

- **Padding without masking.** The model attends to padding as if it were real
  input. Output degrades in a way that looks like a quantization problem.
- **Mask convention mismatch.** 1-means-valid versus 1-means-masked is
  inconsistent across model families. Check against the FP32 model before
  blaming the conversion.

### Cost is paid on every inference

A graph pinned to 256 frames computes 256 frames whether the utterance needs 12
or 250. There is no early exit. If your real distribution is mostly short with
a long tail, **two binaries** — a short one and a long one, selected at
runtime — often beat one long binary, at the cost of a second context resident
on the device.

## Multi-stage pipelines

When one model's output feeds another, the static shapes must agree **exactly**:

```text
text_encoder   text_emb  (1, 256, 128)
                            |
vector_estimator  text_emb (1, 256, 128)   <- must match
```

A mismatch here converts cleanly and fails at runtime, or worse, silently
misaligns. Write the shapes down once and generate both models from that table
rather than pinning each by hand.

## Things that block pinning

| Pattern | Fix |
|---|---|
| `Shape` → `Reshape` computed at runtime | Constant-fold before export |
| `NonZero`, `Where` with data-dependent output size | Restructure; genuinely unsupported |
| `Loop` / `Scan` with dynamic trip count | Unroll at export |
| Dynamic upsample from an input tensor | Replace with a fixed `scales` attribute |

`onnxsim` (ONNX Simplifier) resolves many of these by constant-folding, and is
worth running before hand-editing the graph. Re-verify numerics afterwards — a
simplifier is a graph rewrite, and it can change behaviour.
