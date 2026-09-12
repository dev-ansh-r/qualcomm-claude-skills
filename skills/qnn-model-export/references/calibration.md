# Calibration data

Quantization maps a float range onto a fixed number of integer levels. The range
comes from data. **If the calibration data does not match deployment, the range
is wrong, and every inference pays for it.**

This is the most common root cause of "the model converted but accuracy
collapsed" — far more common than an unsupported op or a bad flag.

## The rule

**Calibration inputs must come from real inference on representative data.**

Not `np.random`. Not zeros. Not "correctly shaped tensors". The *distribution*
is the entire point; the shape is incidental.

## Format

```text
qnn_calibration/
  text_encoder/
    input_list.txt
    text_ids_0.raw
    style_ttl_0.raw
    text_mask_0.raw
    text_ids_1.raw
    ...
```

### `input_list.txt`

One line per sample. Space-separated `name:=path`. Absolute paths. Input names
matching the ONNX graph **exactly**.

```text
text_ids:=/abs/qnn_calibration/text_encoder/text_ids_0.raw style_ttl:=/abs/.../style_ttl_0.raw
text_ids:=/abs/qnn_calibration/text_encoder/text_ids_1.raw style_ttl:=/abs/.../style_ttl_1.raw
```

Single-input models may use a bare path per line, but the `name:=` form is
unambiguous and works everywhere. Use it.

### `.raw` files

Headerless, little-endian, C-contiguous dumps. No shape metadata — the
converter takes shape from `--input_dim`.

```python
arr = np.ascontiguousarray(arr)
arr.tofile("text_ids_0.raw")        # that is the whole format
```

**dtype must match the graph input.** An int64 token-id tensor written as int32
produces a file half the expected size; the converter reads it as int64 anyway
and gets garbage — with no error. This is a silent, total failure.

```python
assert arr.dtype == np.int64, arr.dtype    # cheap, catches a nasty bug
```

## Calibration quality outranks the quantization algorithm

Measured on a small downstream sub-model (a joiner) in an ASR pipeline
`[measured]`:

| Calibration set | Accuracy gap vs float |
|---|---|
| ~10 synthetic/random vectors | **~15 points** |
| ~60 real trace vectors, plus `--use_per_channel_quantization --act_quantizer_calibration mse` | **~1.3 points** |

Same model, same bitwidths. **This was a larger lever than the encoder's
quantization scheme** — an order of magnitude more than any algorithm choice.

The reason is that the calibration set defines the range, and a range derived
from data that never occurs at run time is wrong no matter how good the
rounding is. Spend your effort here first.

### Include the awkward frames

Real traces must cover the states the model actually meets, including the ones
that feel like noise:

- Frames where the model emits **blank**, padding, or an "unknown" token
- Leading silence and trailing tails
- Whatever your pipeline treats as a degenerate case

A calibration set built only from confident, mid-utterance frames teaches the
quantizer that the awkward cases do not exist — and those are exactly where a
quantized model falls apart.

### Sampling from a chained pipeline

For a sub-model fed by another model's output, sample real
`upstream_out`/`downstream_out` pairs across actual decode traces rather than
generating plausible tensors.

If a graph rewrite upstream is numerically equivalent (cosine ~1.0 against the
original), you can generate these vectors from **either** version — a useful
shortcut when the rewritten graph is harder to run locally.

## How many samples

~100 spanning the real input distribution is the working default `[convention]`.

- Fewer than ~30 and ranges get noisy; one unusual sample dominates.
- Beyond a few hundred, returns diminish sharply and `compute_encodings` gets
  slow for no gain.
- **Coverage beats count.** 50 samples spanning the real variation beat 500 near
  duplicates.

## Multi-stage pipelines — where this usually goes wrong

For a chained model, each stage's calibration input must be the **real output of
the previous stage**, produced by running that stage in ONNX Runtime.

```text
                      real text
                          |
                 [ run text_encoder in ORT ]
                          |
                  real text_emb  ----> calibration input for vector_estimator
                          |
              [ run vector_estimator in ORT ]
                          |
                real denoised_latent ---> calibration input for vocoder
```

Feeding a downstream stage synthetic tensors is the highest-frequency mistake in
this whole workflow. A vocoder calibrated on random latents sees nothing like a
real latent: wrong ranges, and audible artefacts that get misattributed to the
vocoder architecture or to HTP.

`scripts/make_calibration.py --capture-outputs` does this capture for you.

## Every input needs real values, including the boring ones

Style embeddings, masks, step counters, conditioning vectors — all of them.

- **Masks** must reflect the real distribution of valid lengths. A calibration
  set where every mask is all-ones teaches the quantizer that padding never
  occurs.
- **Scalar step counters** (diffusion step index, and similar) should span their
  real range. One value gives a degenerate range.
- **Style/speaker embeddings** should come from the real embedding file, not
  random normal draws with a plausible standard deviation.

## Domain match

Calibration data must come from the deployment domain:

| Deploying on | Calibrate on |
|---|---|
| Head-worn camera footage | Your own head-worn footage — not COCO |
| Indian-accented speech | That speech — not LibriSpeech |
| Indoor low light | Real low-light captures, not synthetically darkened frames |

A public dataset that "looks similar" has different sensor noise, different
exposure behaviour and different framing. Those differences are exactly what
quantization ranges are sensitive to.

## Verifying before you convert

Cheap checks that catch most problems:

```python
for name, arr in sample.items():
    print(f"{name:20s} {arr.dtype} {arr.shape} "
          f"min={arr.min():.4f} max={arr.max():.4f} mean={arr.mean():.4f}")
```

Look for:

| Signal | Meaning |
|---|---|
| `min == max` | Constant input — contributes no range information |
| Range vastly wider than expected | An outlier will dominate; consider percentile scheme |
| All-zero tensor | An input was never populated |
| Suspiciously round bounds (exactly ±1.0) | Possibly synthetic data that slipped in |

And confirm the list itself is well-formed:

```sh
wc -l qnn_calibration/model/input_list.txt          # sample count
head -1 qnn_calibration/model/input_list.txt        # names and absolute paths
awk '{for(i=1;i<=NF;i++){split($i,a,":=");
      if(system("test -r "a[2])) print "MISSING: "a[2]}}' \
    qnn_calibration/model/input_list.txt            # every file readable
```

A missing `.raw` referenced from the list is a common and confusingly-reported
failure.

## Relative paths

Use absolute paths in `input_list.txt`. The converter resolves them from its own
working directory, and sourcing the eSDK **changes the working directory** — so a
relative path that worked interactively breaks inside a build script, in the
silent exit-0 way.

## Classic flow vs AIMET

Both need the same data, consumed differently:

| | Classic | AIMET |
|---|---|---|
| Mechanism | `--input_list` of `.raw` files | `compute_encodings` forward pass |
| Format | Files on disk | Python arrays in a loop |
| Control | Converter picks the scheme | Full choice of scheme and technique |

The **data** is identical. If you have built a good calibration set for one, it
transfers directly to the other — which is worth knowing when moving a model
from bring-up to production.
