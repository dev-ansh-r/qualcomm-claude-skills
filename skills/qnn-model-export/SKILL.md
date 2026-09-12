---
name: qnn-model-export
description: Convert an ONNX model to a QNN model library for Qualcomm HTP using the classic flow - static-shape preparation, calibration input_list generation, qnn-onnx-converter with W8A16 quantization, then qnn-model-lib-generator to produce an aarch64 .so, validated with qnn-net-run. Accepts AIMET .encodings via --quantization_overrides alongside --input_list. Use for Qualcomm/Hexagon HTP model conversion, whether a model will run on the NPU, FP16 or float_fallback errors, or any qnn-onnx-converter, model-lib-generator, input_list, bias_bw or W8A16 question. The DLC alternative is qnn-context-binary.
---

# QNN model export (classic flow)

ONNX → `qnn-onnx-converter` → `qnn-model-lib-generator` → `libmodel.so` on the
board.

**This route ships production models.** It is not a bring-up-only path: it
accepts AIMET `.encodings` via `--quantization_overrides` exactly as the DLC
route does, and the `.so` it produces becomes a context binary compiled **on the
board**.

Its practical advantage is inspectability — the generated `.cpp` records the
converter's full resolved argument namespace, which settles most "did my
settings take effect?" questions in seconds.

The alternative is `qnn-context-binary` (qairt-converter → DLC → host-side
context binary). See the repo README for how the two differ.

Verified against **QAIRT 2.37.x**, target **QCS6490 / HTP v68**. Confirm flags
with `qnn-onnx-converter --help` before trusting anything below — flags move
between majors.

## Before you start

```sh
WORK="$(pwd)"                                  # capture BEFORE sourcing
unset LD_LIBRARY_PATH
source "$QNN_SDK_ROOT/bin/envsetup.sh"
cd "$WORK"
```

Use `bash`, never `sh`. In Jupyter that means `%%bash`. Full rationale in
`qualcomm-env-discovery/references/environment-setup.md`.

## Stage 1 — static shapes

**QNN does not support dynamic shapes.** Every dynamic dimension must become a
concrete integer before conversion. A model with `batch_size` or `text_length`
as symbolic dims will fail to convert, or convert into something that cannot be
fed.

```python
import onnx
from onnx import shape_inference

g = onnx.load("model.onnx")

for inp in g.graph.input:
    if inp.name == "text_ids":
        inp.type.tensor_type.shape.dim[0].dim_value = 1      # batch
        inp.type.tensor_type.shape.dim[1].dim_value = 128    # sequence
for out in g.graph.output:
    if out.name == "text_emb":
        out.type.tensor_type.shape.dim[0].dim_value = 1
        out.type.tensor_type.shape.dim[2].dim_value = 128

g = shape_inference.infer_shapes(g)      # propagate, do not just pin the edges
g.opset_import[0].version = 17           # opset 17 for QAIRT 2.37.x
onnx.save(g, "model_static.onnx")
```

Two things people skip:

- **`shape_inference.infer_shapes`** — pinning inputs and outputs without
  propagating leaves interior tensors dynamic, and the converter fails on an
  internal node with a confusing name.
- **Choosing the static length is a product decision.** You are fixing the
  maximum sequence/latent length for the life of the binary. Padding and
  masking to that length becomes the application's job.

Details and the sizing trade-off: `references/static-shapes.md`.

## Stage 2 — calibration data

Quantization ranges come from data. In this flow the converter derives them
itself from an `--input_list`.

**The single highest-impact rule: calibration data must come from real
inference, not synthetic tensors.**

Random or hand-built inputs give ranges that do not match deployment, and the
model degrades in ways that look like a conversion bug. For a multi-stage
pipeline this means running the *actual* preceding stage in ONNX Runtime and
capturing its real output as the next stage's calibration input.

```text
qnn_calibration/
  text_encoder/
    input_list.txt
    text_ids_0.raw  style_ttl_0.raw  text_mask_0.raw
    text_ids_1.raw  ...
```

`input_list.txt` — one line per sample, space-separated `name:=path` entries,
**absolute paths**, matching the graph input names exactly:

```text
text_ids:=/abs/path/text_ids_0.raw style_ttl:=/abs/path/style_ttl_0.raw text_mask:=/abs/path/text_mask_0.raw
text_ids:=/abs/path/text_ids_1.raw style_ttl:=/abs/path/style_ttl_1.raw text_mask:=/abs/path/text_mask_1.raw
```

`.raw` files are **raw little-endian tensor dumps with no header** —
`arr.astype(np.float32).tofile(path)`. dtype must match the graph input
(int64 inputs stay int64; writing them as int32 produces silent garbage).

~100 samples spanning the real input distribution is a reasonable default
`[convention]`. Generator: `scripts/make_calibration.py`. Full guidance:
`references/calibration.md`.

## Stage 3 — convert

```sh
qnn-onnx-converter \
    --input_network  "$WORK/model_static.onnx" \
    --input_dim      text_ids   1,128 \
    --input_dim      style_ttl  1,50,256 \
    --input_dim      text_mask  1,1,128 \
    --output_path    "$WORK/QNN_Models/model.cpp" \
    --input_list     "$WORK/qnn_calibration/model/input_list.txt" \
    --act_bitwidth     16 \
    --weights_bitwidth 8
```

Produces `model.cpp`, `model.bin` and `model_net.json`.

**Check the output filename.** Depending on how `--output_path` is spelled, the
converter may write the source file **without a `.cpp` extension**, which then
breaks `qnn-model-lib-generator -c`. Production scripts defend against it:

```sh
CPP=${OUT}/model.cpp
[ -f "${OUT}/model" ] && [ ! -f "$CPP" ] && cp "${OUT}/model" "$CPP"
```

### Audit for FP16 immediately after converting

On an architecture without FP16 (v68), this must be zero or the context binary
will not build:

```sh
grep -ci "FLOAT_16\|float16\|QNN_DATATYPE_FLOAT_16" QNN_Models/model.cpp
```

Shipped pipelines run this as a **gate** on every convert, not as a diagnostic
after something breaks `[measured]`.

### Bitwidth flags have two spellings, and both work

`--act_bitwidth` / `--weights_bitwidth` and `--act_bw` / `--weight_bw` are
**aliases**. One shipped pipeline uses **both spellings in adjacent scripts** —
`--act_bw 16 --weight_bw 8 --bias_bw 32` to convert its encoder and
`--act_bitwidth 16 --weights_bitwidth 8 --bias_bitwidth 32` for its decoder and
joiner, same SDK build, both working `[measured]`. The converter's own resolved
namespace carries alias pairs side by side (`float_bitwidth=32; float_bw=32`).

Also set **`--bias_bw`** (namespace: `bias_bitwidth`, default 8). One production
W8A16 recipe uses `--act_bw 16 --weight_bw 8 --bias_bw 32` `[measured]` — bias
at 32-bit costs almost nothing and removes a quantization error source that
accumulates across a deep graph.

### Verify what the converter actually received

You do not have to trust that a flag was accepted. **The converter records its
full resolved argument namespace in the generated `.cpp`, `.onnx` and
`_net.json`** — every option, with the value it ended up with:

```sh
head -5 QNN_Models/model.cpp | tr ';' '\n' | grep -E 'bitwidth|_bw|quantization_overrides|float_fallback|input_list'
```

```text
act_bitwidth=16
weights_bitwidth=8
bias_bitwidth=32
float_fallback=False
input_list=./qnn_calibration/model/input_list.txt
quantization_overrides=/path/to/model.encodings
```

This is the authoritative answer to "did my quantization settings actually take
effect?" — better than reading the command you typed, because it shows what the
tool resolved. **Check it after every conversion.** A model you believe is
W8A16 but which shows `act_bitwidth=8`, or an empty `quantization_overrides=`
when you passed encodings, is caught here in seconds.

### Flags that matter

| Flag | Effect |
|---|---|
| `--act_bitwidth 16 --weights_bitwidth 8` | W8A16. The default for quality-sensitive models |
| `--act_bitwidth 8 --weights_bitwidth 8` | W8A8. Faster and smaller; try only after W8A16 works |
| `--input_encoding <name> other` | Keeps an input **unquantized** — required for int64 token ids |
| `--param_quantizer tf` / `--act_quantizer tf` | TensorFlow-style symmetric. `tf_enhanced` trades outlier robustness |
| `--act_quantizer_calibration mse` | Calibrate by minimising MSE rather than `min-max` (the default). A large win on sensitive graphs `[measured]` |
| `--percentile_calibration_value 99.99` | With percentile calibration, where to clip |
| `--use_per_channel_quantization` | Per-channel weights. Usually a clear accuracy win on conv |
| `--float_bw 32` | Keep float-fallback ops at FP32, avoiding FP16 on unsupported ops |
| `--float_fallback` | Allow unquantized ops to run in float. **Dangerous on v68 — see below** |
| `--quantization_overrides <file>` | **Apply AIMET `.encodings`.** Combine with `--input_list` |
| `--bias_bw 32` | Bias bitwidth (namespace `bias_bitwidth`, default 8) |
| `--dry_run` | **Parse and report without converting.** Use first, always |

### Using AIMET encodings with this converter

`qnn-onnx-converter` accepts `--quantization_overrides <model.encodings>`
`[measured]`. AIMET is **not** limited to the QAIRT/DLC route — this is the
classic flow consuming AIMET output directly.

The proven pattern passes **both**, and they do different jobs:

```sh
qnn-onnx-converter     --input_network model_adapted.onnx     --quantization_overrides model_w8a16.encodings \   # AIMET's ranges
    --input_list  real_vectors/input_list.txt \         # real activations
    --act_bw 16 --weight_bw 8 --bias_bw 32     -d <input_name> <dims>
```

- `--quantization_overrides` supplies the per-tensor scale/offset AIMET
  computed, including any AdaRound work.
- `--input_list` still supplies real data for the tensors the encodings do not
  cover.

They are complementary, not alternatives. Confirm both landed by grepping the
generated `.cpp` namespace (above) for a non-empty `quantization_overrides=`.

`-d` is shorthand for `--input_dim`.

### You do not have to quantize every sub-model the same way

In a multi-model pipeline, match the effort to each graph's sensitivity. One
shipped configuration `[measured]`:

| Sub-model | Strategy |
|---|---|
| Encoder (large, sensitive) | AIMET encodings + `--input_list` |
| Decoder / joiner (small) | Plain PTQ — `--input_list` only, no AIMET |

AIMET on the sensitive graph, converter-internal quantization on the small ones.
Running AIMET over everything costs time without buying accuracy where the graph
was never the problem.

**But "small" does not mean "insensitive to calibration".** In that same
pipeline the small joiner was the graph most sensitive to *calibration data
quality* — synthetic vectors cost ~15 accuracy points, real trace vectors
recovered all but ~1.3 `[measured]`. Skip AIMET on the small graphs if you like;
do not skip real calibration data. See `references/calibration.md`.

### Use `--dry_run` first, every time

```sh
qnn-onnx-converter --input_network model_static.onnx \
    --input_dim text_ids 1,128 --output_path /tmp/probe.cpp --dry_run
```

Seconds instead of minutes, and it surfaces unsupported ops and shape problems
before you have waited out a full quantization pass.

### Why W8A16 rather than W8A8

INT8 activations collapse small-magnitude and thin-structure signal first. On
generative audio that is audible distortion; on detection it is small or thin
classes disappearing. W8A16 keeps activations at 16-bit fixed point for a
modest speed cost and is the right default on HTP `[convention]`.

Note A16 is **INT16 fixed point, not FP16**. Do not reach for `--float_bw 16`
expecting the same thing.

### `--float_fallback` can make the model unloadable — check your HTP first

On **Hexagon v68 there is no FP16** `[vendor-claimed]`. An op left "float" by
`--float_fallback` becomes an FP16 op the hardware cannot execute, and
`qnn-context-binary-generator` then **aborts with exit 134** `[measured]`.

So on v68 the working recipe is the opposite of the intuitive one: **convert
all-quantized, with no `--float_fallback`**, and make the graph quantizable
rather than letting ops escape into float.

Audit the generated `.cpp` — this must be zero on v68:

```sh
grep -ci "FLOAT_16\|float16\|QNN_DATATYPE_FLOAT_16" QNN_Models/model.cpp
```

Newer HTP architectures do support FP16, which is why `--float_fallback` is
sound advice elsewhere. **Check your target's architecture before taking either
default** — `qualcomm-env-discovery` step 4.

### When quantization keeps failing, suspect the graph

If a model quantizes badly no matter what you try, the problem may be upstream
of quantization. One documented case `[measured]`: four strategies on a stock
ONNX export all failed — per-channel PTQ produced zero output tokens, AIMET
overrides reached cosine 0.27, and `--float_fallback` crashed ctx-gen at exit
134. What fixed it was **rewriting the graph into HTP-native ops before export**
— folding training-time scale factors into weights, replacing ops the HTP
handles poorly (Conv1d→Conv2d, Concat→Pad+Add), and precomputing constants.

The generalizable points:

- **Framework exports are tuned for training, not for an NPU.** Ops that are
  free on a GPU (a scaling `Mul`, a wide `Concat`) can be the exact thing that
  leaves FP16 behind or quantizes badly.
- **A graph rewrite is verifiable.** If it is numerically equivalent, cosine
  against the original should be ~1.000000. Gate on that before quantizing —
  anything less means the rewrite changed behaviour.
- **It often requires the original checkpoint**, not just the exported ONNX,
  because the surgery happens in the framework. Budget for that: an ONNX-only
  delivery can be a blocker.

## Stage 4 — model library

```sh
unset LD_LIBRARY_PATH
source "$ESDK_ENV"                             # e.g. environment-setup-armv8-2a-qcom-linux
source "$QNN_SDK_ROOT/bin/envsetup.sh"         # QAIRT second - order is load-bearing

qnn-model-lib-generator \
    -c "$WORK/QNN_Models/model.cpp" \
    -b "$WORK/QNN_Models/model.bin" \
    -o "$WORK/QNN_Model_lib/" \
    -t aarch64-oe-linux-gcc11.2
```

Output: `QNN_Model_lib/aarch64-oe-linux-gcc11.2/libmodel.so`.

- **The `-t` triple must match the board toolchain.** Read it from
  `.qualcomm-env` (`QC_TARGET_TRIPLE`); do not copy it from an example.
  A mismatch links against the wrong libc and fails at load with an unhelpful
  error.
- **This stage needs the eSDK**, unlike stage 3. This is where the ordering bug
  bites: sourcing QAIRT before the eSDK removes `qnn-model-lib-generator` from
  `PATH`.
- **Absolute paths only.** Sourcing the eSDK can change the working directory.

## Stage 5 — validate on the board

```sh
# on the board
export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH

qnn-net-run \
    --model      ./libmodel.so \
    --backend    /usr/lib/libQnnHtp.so \
    --input_list ./inputs.txt \
    --output_dir ./output \
    --log_level  warn
```

Backends, in order of what you learn:

| Backend | Use |
|---|---|
| `libQnnCpu.so` | Reference correctness. If this is wrong, the conversion is wrong |
| `libQnnHtp.so` | The real target |
| `libQnnGpu.so` | Adreno; rarely the right answer for a quantized model |

**Always compare HTP output against CPU output on identical input** before
believing a latency number. A fast wrong answer is the failure mode this flow
produces most often.

### Where to write output

Write to `/tmp` (tmpfs) on boards with an eMMC root. A burst write to the
eMMC-backed filesystem can trigger a firmware watchdog reset with no log entry
`[measured]` — it presents as the board vanishing mid-run.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `unrecognized arguments: --act_bw` | Wrong flag. Use `--act_bitwidth` |
| Unsupported op at convert time | Op has no HTP implementation. Check the SDK-local op-support doc for **your HTP arch**, then replace the op or add `--float_fallback` |
| Converts, garbage output | Calibration data unrepresentative, or an int64 input got quantized — add `--input_encoding <name> other` |
| `command not found` after sourcing | eSDK sourced after QAIRT. Fresh shell, correct order |
| Exits 0, no output file | Relative path plus the eSDK changed your cwd. Use absolute paths |
| `.so` will not load on board | `-t` triple mismatch, or built against a different eSDK than the image |
| Transformer/ViT fails to convert | Attention `Split`/`Chunk` patterns are unsupported on HTP v68 `[vendor-claimed]` — a CNN encoder is the usual answer, not a flag |

## Model-specific notes

`references/op-support.md` covers the architecture families that convert
cleanly, the ones that need surgery, and the ViT-on-HTP constraint in detail.
