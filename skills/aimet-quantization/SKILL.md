---
name: aimet-quantization
description: Quantize an ONNX model for Qualcomm HTP with AIMET - QuantizationSimModel (quantsim) calibration, AdaRound adaptive weight rounding, cross-layer equalization, bias correction and automatic mixed precision - exporting a .encodings file for qairt-converter. Use for post-training quantization (PTQ), W8A16/W8A8 accuracy recovery, per-layer quantization sensitivity analysis, or when a converted model runs but its accuracy dropped. Runs on the AIMET host, not the board.
---

# AIMET quantization

Produces a `.encodings` file: per-tensor quantization parameters that
`qairt-converter --quantization_overrides` consumes on the QAIRT/DLC path.

## Where this sits

```text
ONNX (static shapes)
   |
   |  [ this skill, on the AIMET host ]
   |  quantsim -> calibrate -> AdaRound -> evaluate -> export
   v
model.encodings  +  model.onnx
   |
   |  [ qnn-context-binary skill, on the build host ]
   v
qairt-converter --quantization_overrides model.encodings
```

**AIMET only feeds the QAIRT/DLC path.** There is no supported way to hand a
`.encodings` file to `qnn-onnx-converter` — that tool derives quantization from
its own calibration `--input_list`. The two are alternative quantization
sources, not sequential stages. Repo README has the full fork.

**Run this on the AIMET host.** AIMET pins specific torch/onnx/onnxruntime
versions that frequently conflict with the QAIRT SDK's Python environment, and
it is often a GPU box. Keep it in its own environment — if `.qualcomm-env` names
a separate `QC_AIMET_HOST`, that separation is deliberate; do not try to
consolidate it onto the build host.

## Flavours

| Package | Input | Use |
|---|---|---|
| `aimet-onnx` | ONNX graph | **Preferred here.** Quantizes the graph you will actually convert |
| `aimet-torch` | `torch.nn.Module` | Use when you need QAT, or the ONNX export itself is the problem |

`aimet-onnx` is the better default: quantizing the exact artifact that goes to
`qairt-converter` avoids a class of export-time drift.

Install and version compatibility are genuinely fiddly — follow
`quic.github.io/aimet-pages` for the release matrix rather than `pip install
aimet-onnx` and hoping. Confirm with:

```python
import aimet_onnx, onnx, onnxruntime, numpy
print(aimet_onnx.__version__, onnx.__version__, onnxruntime.__version__)
```

### Treat the snippets below as shape, not signature

**AIMET's API surface moves between releases** — argument names, module paths
and return values have all changed across versions, more than is typical. The
code here shows the correct *sequence and intent*; check the exact signature for
your installed version before running it:

```python
from aimet_onnx.quantsim import QuantizationSimModel
help(QuantizationSimModel.__init__)
```

and cross-check against the API reference for your release at
`quic.github.io/aimet-pages`. If a keyword below is rejected, the sequence is
still right — find the current name rather than abandoning the step.

## Stage 1 — quantsim

`QuantizationSimModel` inserts simulated quantization ops so you can measure
the quantized model in floating point before committing to a conversion.

```python
from aimet_onnx.quantsim import QuantizationSimModel
from aimet_common.defs import QuantScheme

sim = QuantizationSimModel(
    model=onnx_model,                          # static-shape ONNX
    quant_scheme=QuantScheme.post_training_tf_enhanced,
    default_param_bw=8,                        # weights  -> W8
    default_activation_bw=16,                  # acts     -> A16
    use_cuda=True,
)
```

### Choosing the quant scheme

| Scheme | Range from | When |
|---|---|---|
| `post_training_tf` | Absolute min/max seen | Clean, bounded activations |
| `post_training_tf_enhanced` | Search minimising MSE | **Default.** Robust to outliers |
| `post_training_percentile` | Clipped percentile | Heavy-tailed activations |

`tf_enhanced` is the right starting point. A single outlier activation drags a
plain min/max range wide enough to waste most of the available levels.

### W8A16 vs W8A8

Start at W8A16 (`default_param_bw=8`, `default_activation_bw=16`). A16 is
**INT16 fixed point, not FP16**. Drop to A8 only after W8A16 works and you have
measured that you need the speed.

## Stage 2 — calibration

```python
def forward_pass(session, _):
    for batch in calibration_batches:          # REAL data
        session.run(None, batch)

sim.compute_encodings(forward_pass, None)
```

**Calibration data must come from the real input distribution.** This is the
same rule as the classic flow and the same failure if broken: ranges that do
not match deployment, presenting as an inexplicable accuracy drop.

For a multi-stage pipeline, generate each stage's calibration inputs by running
the *real* preceding stage in ONNX Runtime. Do not feed a later stage random
tensors shaped like its input — the distribution is what matters, not the shape.

~100 samples spanning the real distribution is a working default `[convention]`;
more helps mainly when the input is genuinely multi-modal.

## Stage 3 — PTQ techniques, in the order to apply them

Apply in this order and **measure after each**. Stopping as soon as accuracy is
acceptable saves hours — AdaRound is expensive.

### 1. Cross-layer equalization (CLE) — free, do it first

```python
from aimet_onnx.cross_layer_equalization import equalize_model
equalize_model(onnx_model)
```

Rescales weights between consecutive conv layers so per-channel ranges are more
uniform. Costs seconds, needs no data, and often recovers most of the loss on
depthwise-separable architectures (MobileNet-family especially).

### 2. Bias correction — cheap

Corrects the systematic activation shift quantization introduces. Small but
usually positive; needs a little data.

### 3. AdaRound — expensive, the big lever

```python
from aimet_onnx.adaround.adaround_weight import Adaround, AdaroundParameters

params = AdaroundParameters(
    data_loader=calibration_loader,
    num_batches=len(calibration_batches),
    default_num_iterations=10000,
)

adarounded = Adaround.apply_adaround(
    model=onnx_model,
    params=params,
    path="./adaround_out",
    filename_prefix="model",
    default_param_bw=8,
    default_quant_scheme=QuantScheme.post_training_tf_enhanced,
)
```

Learns, per weight, whether rounding **up or down** loses less — instead of
rounding to nearest. Typically the single largest PTQ gain, and it is the
technique that most often closes the gap to QAT without retraining.

- `default_num_iterations=10000` is the usual starting point; it is a real
  optimization loop, so budget GPU minutes to hours by model size.
- AdaRound **writes its own `.encodings` for the weights it touched.** Pass
  that file to the subsequent quantsim via `set_and_freeze_param_encodings`
  before `compute_encodings`, or you will silently discard the work.

### A note on naming

You may see **AdaQuant** referenced. That is a separate technique from the
literature; it is not an AIMET API. Within AIMET the adaptive-rounding lever is
**AdaRound**, complemented by Sequential MSE in recent releases. If you need
AdaQuant specifically, it is not available here — say so rather than
substituting silently.

### 4. Automatic mixed precision (AMP) — when one block dominates

```python
from aimet_onnx.mixed_precision import choose_mixed_precision
```

Greedily raises the precision of the layers contributing most error, subject to
a bit-ops budget. Use when a sensitivity sweep shows one or two blocks causing
nearly all the loss. Availability varies by release — guard the import:

```python
try:
    from aimet_onnx.mixed_precision import choose_mixed_precision
except ImportError:
    MIXED_PRECISION_AVAILABLE = False
```

### 5. QAT — last resort

Needs `aimet-torch`, the training pipeline, and labelled data. Only worth it
when PTQ has genuinely plateaued short of requirement.

## Stage 4 — evaluate

Evaluate the sim model **on your task metric**, against the FP32 baseline.

```python
baseline = evaluate(fp32_session)
quantized = evaluate(sim.session)
print(f"FP32 {baseline:.4f} -> quantized {quantized:.4f}")
```

**Tensor similarity is not accuracy.** Cosine similarity above 0.99 routinely
accompanies a detector that has dropped an entire class or a vocoder with
audible artefacts. Use mAP, WER, MOS, IoU — whatever the product is judged on.

### Per-layer sensitivity

When accuracy is short, find out *where* before reaching for a bigger hammer.
AIMET's QuantAnalyzer produces per-layer sensitivity; the manual equivalent is
raising one layer to 16-bit at a time and re-measuring. Either way you usually
find a small number of layers responsible for most of the loss — which is
exactly the situation mixed precision solves cheaply.

## Stage 5 — export

```python
sim.export(path="./exported", filename_prefix="model")
```

Produces:

| File | Role |
|---|---|
| `model.encodings` | **The deliverable.** Per-tensor scale/offset, feeds `qairt-converter` |
| `model.onnx` | The graph the encodings refer to |

### The encodings and the ONNX must stay a matched pair

`.encodings` refers to tensors **by name**. Re-exporting the ONNX, renaming a
node, or running a graph optimizer afterwards invalidates the mapping — and
`qairt-converter` will accept the mismatched pair and quietly skip the
overrides it cannot resolve. You get a model that converted "successfully" with
some tensors unquantized or default-quantized.

Keep the pair together, and treat the ONNX as frozen from export onward.

Sanity check before handing off:

```python
import json
enc = json.load(open("exported/model.encodings"))
print("activation tensors:", len(enc.get("activation_encodings", {})))
print("param tensors     :", len(enc.get("param_encodings", {})))
```

Zero activation encodings means `compute_encodings` never ran, or ran with an
empty forward pass.

## Handing off

Copy `model.onnx` and `model.encodings` to the build host, then use the
`qnn-context-binary` skill. Record alongside them:

- quant scheme, param/activation bitwidths
- which PTQ techniques were applied, in order
- FP32 vs quantized score on the real metric
- calibration data provenance

That last one matters most six months later, when the model is re-exported and
nobody remembers what it was calibrated on.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `import aimet_onnx` fails | Version matrix. Check the release page against your torch/onnx/ort |
| Accuracy fine in sim, bad on device | Sim is not bit-exact with HTP. Validate on hardware; check op fallbacks |
| AdaRound gains nothing | Encodings not frozen — call `set_and_freeze_param_encodings` before `compute_encodings` |
| `compute_encodings` extremely slow | Calibration set too large. ~100 samples is enough |
| Encodings ignored by qairt-converter | ONNX and encodings drifted apart. Re-export as a pair |
| Everything degrades uniformly | Calibration data unrepresentative — the most common root cause |
