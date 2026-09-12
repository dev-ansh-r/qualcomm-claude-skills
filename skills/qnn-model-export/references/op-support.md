# What converts cleanly on HTP, and what does not

Op support is **per Hexagon architecture version** — a model that converts for
v73 may not for v68, and vice versa. Nothing in this file is a substitute for
the table that matches your target.

**The authoritative source is the op-support page in your SDK-local docs**
(`$QNN_SDK_ROOT/docs/`). Extract it for your architecture with the
**`qualcomm-sdk-docs`** skill, then check a model against it:

```sh
python3 check-model-ops.py model.onnx --backend htp
```

This file records the patterns that cost teams time, across parts. Examples
were seen on **QCS6490 / HTP v68, QAIRT 2.37.x**.

## The check that answers it in seconds

```sh
qnn-onnx-converter --input_network model.onnx \
    --input_dim <name> <dims> --output_path /tmp/probe.cpp --dry_run
```

Do this before any calibration work. An unsupported op found after a 20-minute
quantization pass is 20 minutes wasted.

## Architecture families

### Convert cleanly

| Family | Notes |
|---|---|
| CNN classifiers (ResNet, MobileNet, EfficientNet-lite) | The best-supported case |
| YOLO detection (v5/v8/11 backbones) | Convert the backbone; keep NMS outside the graph |
| Conv-based segmentation (DeepLabv3, U-Net, FCN) | Well supported |
| Conv/GRU audio models, vocoders | 1-D conv paths are fine |

### Need surgery

| Family | Problem | Usual fix |
|---|---|---|
| **ViT / transformer encoders** | `Split`/`Chunk` in multi-head attention unsupported on HTP v68 `[vendor-claimed]` | Use a CNN or hybrid encoder. See below |
| Detection heads with NMS in-graph | NMS is a control-flow op | Export without NMS, run it on CPU |
| Dynamic-shape anything | Not supported at all | Pin shapes first (skill stage 1) |
| Models with `If` / `Loop` / `Scan` | Control flow | Unroll at export, or split the graph |
| Custom ops | No HTP kernel | Rewrite in supported ops, or write an HTP op package |

## The ViT constraint

**ViT-style attention does not accelerate on HTP v68** — the `Split`/`Chunk`
pattern used to break QKV into heads has no HTP implementation
`[vendor-claimed]`.

Consequences worth knowing before you plan a model:

- It is **not a flag problem.** `--float_fallback` will let it convert, but the
  attention blocks then run in float on CPU/GPU, which is usually slower than
  not using the NPU at all — and you have paid the conversion complexity for
  nothing.
- **Choosing a vision encoder is therefore an architecture decision made early,
  not a deployment detail.** Teams deploying VLMs on this class of part
  commonly move from a ViT encoder to a CNN or hybrid encoder (FastViT-style)
  specifically to keep the encoder on the NPU, leaving the decoder to run
  elsewhere (llama.cpp on Adreno via OpenCL is one route).
- **Verify against your own SDK before committing.** This is vendor-claimed and
  arch-specific. Newer HTP versions have better transformer coverage, and the
  op-support doc in your install is the thing that settles it. Run the
  `--dry_run` above on the actual encoder.

## Quantization sensitivity, by structure

Not all layers degrade equally at INT8. What collapses first:

| Structure | Why it suffers |
|---|---|
| Thin/small objects in detection | Small activations quantize into the same bucket as noise |
| Depth or disparity discontinuities | Error concentrates exactly at edges — the safety-critical pixels |
| Generative audio (vocoders, diffusion) | Quantization noise is directly audible |
| Attention softmax | Large dynamic range across the tensor |
| Final regression heads | No downstream layer to absorb the error |

Two practical consequences:

- **W8A16 is the right default** on anything quality-sensitive. Move to W8A8
  only after W8A16 works and you have measured that you need the speed.
- **Report accuracy on your own task metric, not a proxy.** "The tensors look
  close" is not evidence; cosine similarity above 0.99 routinely accompanies a
  detector that has lost a whole class.

## Mixed precision

When one block dominates the error, keeping *that block* at higher precision is
cheaper than raising the whole graph. In the classic flow your lever is
`--float_fallback` plus `--float_bw 32`, which is coarse. For genuine per-op
control, use the AIMET path (`aimet-quantization` → `qnn-context-binary`) —
that is the main reason to prefer it for production.

## Benchmark honestly

Two rules that prevent most bad deployment decisions:

- **Paper FPS is desktop FPS.** A latency from a paper or a model card was
  almost certainly measured on a desktop GPU. It does not transfer to this
  class of part by any simple ratio.
- **Report sustained, thermally-loaded wall-clock, not batch-1 burst.** Boards
  in this class throttle under continuous load `[measured]`. A first-run
  number is not what your application will see, and the gap is often large
  enough to invalidate a design.
