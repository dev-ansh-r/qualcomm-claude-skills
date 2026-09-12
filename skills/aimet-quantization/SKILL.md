---
name: aimet-quantization
description: Quantize an ONNX model for Qualcomm HTP with AIMET - QuantizationSimModel (quantsim) calibration, AdaRound adaptive weight rounding, cross-layer equalization, bias correction and automatic mixed precision - exporting a .encodings file consumed by qnn-onnx-converter or qairt-converter via --quantization_overrides. Use for post-training quantization (PTQ), W8A16/W8A8 accuracy recovery, per-layer quantization sensitivity analysis, or when a converted model runs but its accuracy dropped. Runs on the AIMET host, not the board.
---

# AIMET quantization

Produces a `.encodings` file: per-tensor quantization parameters that
**either** converter consumes via `--quantization_overrides`.

## Where this sits

```text
ONNX (static shapes, HTP-native ops)
   |
   |  [ this skill, on the AIMET host ]
   |  quantsim -> calibrate -> (AdaRound) -> evaluate -> export
   v
model.encodings  +  model.onnx
   |
   |  --quantization_overrides   [ on the build host ]
   |
   +--> qnn-onnx-converter   (classic route)
   +--> qairt-converter      (QAIRT/DLC route)
```

**AIMET feeds both routes.** `--quantization_overrides` is accepted by
`qnn-onnx-converter` as well as `qairt-converter` `[measured]` — AIMET is not
tied to the DLC path.

**Pass `--input_list` alongside it.** The proven production recipe supplies
both: the encodings give the ranges AIMET computed, `--input_list` gives real
data for what they do not cover. They are complementary, not alternatives.

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

`aimet-onnx` is the better default: quantizing the exact artifact you will
convert avoids a class of export-time drift.

Install and version compatibility are genuinely fiddly — follow
`quic.github.io/aimet-pages` for the release matrix rather than `pip install
aimet-onnx` and hoping. Confirm with:

```python
import aimet_onnx, onnx, onnxruntime, numpy
print(aimet_onnx.__version__, onnx.__version__, onnxruntime.__version__)
```

### The API changed in AIMET 2.x — check which you have

**AIMET's surface moves between releases more than is typical.** The snippets
below are the **AIMET 2.23** form `[measured]`. On 1.x the same concepts use
different keywords (`default_param_bw`, `default_activation_bw`,
`QuantScheme.post_training_tf_enhanced`, and a callback-style
`compute_encodings`).

```python
import aimet_onnx; print(aimet_onnx.__version__)
from aimet_onnx.quantsim import QuantizationSimModel
help(QuantizationSimModel.__init__)
```

If a keyword is rejected, the *sequence* is still right — find the current name
rather than abandoning the step.

## Stage 1 — quantsim

`QuantizationSimModel` inserts simulated quantization ops so you can measure
the quantized model in floating point before committing to a conversion.

```python
import onnx
from aimet_onnx.quantsim import QuantizationSimModel
from aimet_onnx.common.defs import qtype, QuantScheme

# Per-HTP-architecture config shipped inside the aimet_onnx package.
# GLOB for it - do not hardcode an architecture:
#   ls <site-packages>/aimet_onnx/common/quantsim_config/htp_quantsim_config_*.json
HTP_CONFIG = ".../aimet_onnx/common/quantsim_config/htp_quantsim_config_v68.json"

sim = QuantizationSimModel(
    model=onnx.load(ENC),              # static-shape, HTP-native ONNX
    param_type=qtype.int(8),           # W8
    activation_type=qtype.int(16),     # A16  (INT16 fixed point, not FP16)
    quant_scheme=QuantScheme.min_max,
    config_file=HTP_CONFIG,            # targets a specific HTP architecture
)
```

**`config_file` is how AIMET targets your part.** The package ships one config
per Hexagon architecture; pick the one matching your target
(`qualcomm-env-discovery` step 4 determines it):

```python
import glob, os, aimet_onnx
d = os.path.join(os.path.dirname(aimet_onnx.__file__), "common", "quantsim_config")
print([os.path.basename(p) for p in glob.glob(os.path.join(d, "htp_quantsim_config_*.json"))])
```

Quantizing with the wrong architecture's config produces encodings whose
constraints do not match the hardware you deploy to.

### Choosing the quant scheme

Names differ by major version — check `QuantScheme` in your install.

| Concept | AIMET 2.x | AIMET 1.x | When |
|---|---|---|---|
| Absolute min/max | `QuantScheme.min_max` | `post_training_tf` | Clean, bounded activations. **Shipped a production W8A16 ASR encoder** `[measured]` |
| MSE-minimising search | *(see your release)* | `post_training_tf_enhanced` | Robust to outliers |
| Percentile clipping | *(see your release)* | `post_training_percentile` | Heavy-tailed activations |

An outlier-robust scheme is the safer general default `[convention]`, but
`min_max` is not a fallback — it carried a 70M-parameter streaming encoder to
15.88% WER on-device `[measured]`. Start with whichever, and let the **task
metric** decide.

### W8A16 vs W8A8

Start at W8A16 — `param_type=qtype.int(8)`, `activation_type=qtype.int(16)` on
2.x. A16 is **INT16 fixed point, not FP16**. Drop to A8 only after W8A16 works
and you have measured that you need the speed.

## Stage 2 — calibration

```python
# AIMET 2.23: compute_encodings takes an ITERATOR OF INPUT DICTS,
# not a forward-pass callback (that was the 1.x API).
sim.compute_encodings(iter(calibration_inputs))   # [{"x": arr, ...}, ...]
```

Each element is a dict mapping graph input name to a numpy array of the static
shape — the same data you would feed ONNX Runtime.

**Stateful / streaming models:** chain the states through the *float* model
while building the calibration set, so each chunk sees realistic incoming state.
Feeding zeroed state to every chunk calibrates the state tensors on a
distribution that never occurs at run time.

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

> **Unverified signature.** The quantsim and `compute_encodings` calls above are
> AIMET 2.23 as-run `[measured]`. The AdaRound snippet below is the **1.x** API
> and has not been re-verified on 2.x — the shipped production recipe this repo
> draws on reached its accuracy target with quantsim alone and never needed
> AdaRound. Check `help(Adaround.apply_adaround)` before running it.

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

**Cosine can also be misleading in the other direction, which is less expected.**
On one streaming ASR encoder, the quantized graph that **decoded correctly** sat
at chunk-0 cosine **~0.59**, while a different quantization of the same model at
cosine **0.60** produced **zero output tokens** `[measured]`. A higher cosine was
the worse model.

Two consequences:

- **Never gate a release on cosine.** It cannot distinguish error that the rest
  of the network absorbs from error that destroys the output.
- A low cosine on a deep or recurrent model is **not by itself** a reason to
  reject a quantization. Run the end-to-end task and look at the real metric.

### Per-layer sensitivity

When accuracy is short, find out *where* before reaching for a bigger hammer.
AIMET's QuantAnalyzer produces per-layer sensitivity; the manual equivalent is
raising one layer to 16-bit at a time and re-measuring. Either way you usually
find a small number of layers responsible for most of the loss — which is
exactly the situation mixed precision solves cheaply.

## Stage 5 — export

```python
sim.export(path=OUTDIR, filename_prefix="model")   # -> model.encodings + model.onnx
```

In AIMET 2.23 `activation_encodings` is a **list** of
`{name, scale:[s], offset:[o], bw}` records `[measured]` — not the 1.x dict
keyed by tensor name. Code that walks encodings must match the version.

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

## Gate the run, do not just eyeball it

Two cheap assertions catch most silent AIMET failures.

**1. Encoding counts.** Record how many activation and parameter encodings the
export produced, and assert the same numbers on re-runs:

```python
import json
enc = json.load(open("exported/model.encodings"))
print(len(enc["activation_encodings"]), "act /", len(enc["param_encodings"]), "param")
```

A shipped pipeline gates on an exact pair (e.g. `1501 act / 265 param`)
`[measured]`. If the count moves, something changed — the graph, the config, or
the AIMET version — and you want to know before converting, not after a WER
regression.

**2. Freeze the environment, and reuse it.** One team deliberately **reuses the
same AIMET virtualenv across model builds** rather than recreating it, so
results stay bit-identical `[measured]`. Recreating from the same
`requirements.txt` months later resolves different transitive dependencies and
can move your encodings.

If you must rebuild it, treat the first run as a **re-validation**: compare
encoding counts and the task metric against the last known-good build.

## When the output is garbage, suspect the layers around quantization

A quantized model producing nonsense is not always a quantization problem. Two
documented cases from the same pipeline `[measured]`:

- **The post-processing layer.** A decoder skipped two special token ids but the
  new model emitted a third on uncertain frames, so that token flooded the
  output and the real prediction never won. Nothing was wrong with the
  quantization. Suppressing the offending *logit* did not help either — the
  next-highest token simply won instead; the fix was in the decode loop.
- **The graph.** Four quantization strategies failed on a stock export until the
  graph was rewritten into HTP-native ops before quantization.

Before spending days on quantization tuning, check that the **float** model,
run through the **same** post-processing, still behaves. That one comparison
separates the three causes quickly.

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
