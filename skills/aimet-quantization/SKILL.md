---
name: aimet-quantization
description: Quantize an ONNX model for Qualcomm HTP with AIMET - QuantizationSimModel (quantsim) calibration, AdaRound adaptive weight rounding, cross-layer equalization, bias correction and automatic mixed precision - exporting a .encodings file consumed by qnn-onnx-converter or qairt-converter via --quantization_overrides. Use for post-training quantization (PTQ), W8A16/W8A8 accuracy recovery, per-layer quantization sensitivity analysis, or when a converted model runs but its accuracy dropped. Runs on the AIMET host, not the board.
---

# AIMET quantization

Produces a `.encodings` file: per-tensor quantization parameters that
**either** converter consumes via `--quantization_overrides`.

## First run

This skill reads `.qualcomm-env`. Check the **marker**, not the file — a config
can exist and be half-written:

```sh
grep -q '^QC_SETUP_VERSION=' .qualcomm-env 2>/dev/null && echo ready || echo "run setup"
```

If it says `run setup`, run the **`qualcomm-setup`** skill first. It probes your
machines, asks only what it cannot discover, and writes the config once so no
other skill has to ask again.

**If `qualcomm-setup` is not installed** — you copied this skill on its own —
do not stop. Ask the two questions it would have asked, then continue:

1. Which host runs the QAIRT SDK? (x86_64 Linux only; a Windows or macOS
   workstation must drive a remote one, and WSL2 counts as Linux)
2. How is the board reached — SSH, ADB, or not available yet?

An empty field is not a blocker by itself. Where this skill needs one it will
say which, and why.

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

**Pass `--input_list` alongside it.** Supply both: the encodings give the ranges
AIMET computed, `--input_list` gives real data for what they do not cover. They
are complementary, not alternatives.

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
print(sorted(os.path.basename(p) for p in glob.glob(os.path.join(d, "*.json"))))
```

AIMET **2.23.0** ships HTP configs for **v66, v68, v69, v73, v75, v79, v81**
`[measured]`, plus `_per_channel_linear` variants for v69 and newer, and
`backend_aware_*` and non-HTP targets (CPU, DSP, AIC100, LPAI).

Two things follow:

- **Glob the directory rather than trusting any list**, including this one. The
  set grows with each release, and your part may need one that did not exist
  when this was written.
- **Prefer the `_per_channel_linear` variant** where it exists for your
  architecture. Per-channel weight quantization is usually a clear accuracy win
  on convolutional graphs, and this is the config that enables it.

Quantizing with the wrong architecture's config produces encodings whose
constraints do not match the hardware you deploy to.

### Choosing the quant scheme

Names differ by major version — check `QuantScheme` in your install.

Verified present in **AIMET 2.23.0** `[measured]`:

| Scheme | Range from | When |
|---|---|---|
| `QuantScheme.min_max` | Absolute min/max observed | Clean, bounded activations. Sufficient for large models that hit their target |
| `QuantScheme.post_training_tf_enhanced` | Search minimising MSE | Robust to outliers |
| `QuantScheme.post_training_percentile` | Clipped percentile | Heavy-tailed activations |
| `QuantScheme.training_range_learning*` | Learned during training | QAT, not PTQ |

The `post_training_*` names survived into 2.x — they are **not** 1.x-only. List
yours rather than assuming:

```python
from aimet_onnx.common.defs import QuantScheme
print([m for m in dir(QuantScheme) if not m.startswith('_')])
```

An outlier-robust scheme is the safer general default `[convention]`, but
`min_max` is not a fallback — it is sufficient for large models that meet their
accuracy target `[measured]`. Start with either and let the **task metric**
decide; do not assume the more elaborate scheme wins.

### W8A16 vs W8A8

Start at W8A16 — `param_type=qtype.int(8)`, `activation_type=qtype.int(16)` on
2.x. A16 is **INT16 fixed point, not FP16**. Drop to A8 only after W8A16 works
and you have measured that you need the speed.

## Stage 2 — calibration

```python
# AIMET 2.23 OVERLOADS this. Both forms are valid [measured]:
sim.compute_encodings(iter(calibration_inputs))   # inputs:   [{"x": arr, ...}, ...]
sim.compute_encodings(forward_pass_callback)      # callback: you drive the passes
```

The signature reports `(*args, **kwargs)` because it dispatches, so
`inspect.signature` tells you nothing — read the docstring instead:

```python
help(sim.compute_encodings)
```

The **inputs** form is simpler when you already have calibration tensors in
memory: each element is a dict mapping graph input name to a numpy array of the
static shape, exactly what you would feed ONNX Runtime. The **callback** form
earns its keep when generating a sample is expensive or stateful and you want to
stream rather than materialise the set.

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
> and has not been re-verified on 2.x. Note that quantsim with good calibration
> is often enough to hit an accuracy target without AdaRound at all — try that
> first. Check `help(Adaround.apply_adaround)` before running this.

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
On one sequence model, the quantization that **produced correct output** sat at
cosine **~0.59**, while a different quantization of the same model at cosine
**0.60** produced **no usable output at all** `[measured]`. The higher cosine was
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

Gate on the exact pair `[convention]`. If the count moves, something changed —
the graph, the config, or the AIMET version — and you want to know before
converting, not after an accuracy regression you then have to bisect.

**2. Freeze the environment, and reuse it.** Keep one AIMET virtualenv and reuse
it across builds rather than recreating it, so results stay comparable
`[convention]`. Rebuilding from the same `requirements.txt` months later
resolves different transitive dependencies, and that can move your
encodings.

If you must rebuild it, treat the first run as a **re-validation**: compare
encoding counts and the task metric against the last known-good build.

## When the output is garbage, suspect the layers around quantization

A quantized model producing nonsense is not always a quantization problem. Two
causes that present identically `[measured]`:

- **The post-processing layer.** Decode logic carried over from a previous model
  can mishandle an output the new model produces — a special token the old one
  never emitted, say — so that output floods the result and the real prediction
  never wins. Nothing is wrong with the quantization. Suppressing the offending
  *logit* does not help either: the next-highest candidate simply wins instead.
  The fix belongs in the decode loop.
- **The graph.** Several quantization strategies can all fail on a framework
  export until the graph is rewritten into HTP-native ops beforehand.

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
