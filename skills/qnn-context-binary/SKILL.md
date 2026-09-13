---
name: qnn-context-binary
description: Build a pre-compiled QNN HTP context binary for Qualcomm QCS6490 using the QAIRT/DLC flow - qairt-converter with AIMET quantization_overrides, qairt-quantizer, then qnn-context-binary-generator - and deploy and validate it on the board. Use for production deployment, fastest model load time, applying AIMET .encodings, or any qairt-converter, qairt-quantizer, DLC or context binary question. The classic alternative is qnn-model-export, which reaches a context binary via a cross-compiled .so built on the board instead.
---

# QNN HTP context binary (QAIRT/DLC flow)

ONNX + `.encodings` → DLC → quantized DLC → **pre-compiled HTP context binary**.

The context binary is compiled for a specific HTP architecture ahead of time, so
the board does not build the graph at load — which makes cold start fast and
load cost predictable.

Both this route and the classic one (`qnn-model-export`) can end at a context
binary, and both accept AIMET encodings. What differs is the intermediate
artifact and **where** the binary is compiled — see the repo README.

Verified against **QAIRT 2.37.x**, target **QCS6490 / HTP v68**. Check
`qairt-converter --help` before trusting a flag.

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

## Prerequisites

- `.qualcomm-env` from `qualcomm-setup`. This skill needs **`QC_HTP_ARCH`**
  specifically — if it is empty because the board was not reachable at setup,
  say so and stop here rather than guessing an architecture: the binary would
  build and then fail to load
- A static-shape ONNX model
- Optionally `model.encodings` from `aimet-quantization` — **recommended for
  anything accuracy-critical**. (Available on the classic route too; it is not
  what distinguishes these two paths.)

```sh
WORK="$(pwd)"
unset LD_LIBRARY_PATH
source "$QNN_SDK_ROOT/bin/envsetup.sh"
cd "$WORK"
```

## The three stages

`scripts/build-context-binary.sh` runs all three with the checks below already
wired in — it verifies the HTP arch before building, greps both logs for
silently-dropped encodings and float fallbacks, and writes a provenance file
next to the binary. Use it rather than retyping the stages:

```sh
./scripts/build-context-binary.sh model.onnx model.encodings
```

The stages, for when you need to run them by hand:

```text
model.onnx  +  model.encodings
        |
        |  qairt-converter --quantization_overrides
        v
    model.dlc                        (graph, quantization params attached)
        |
        |  qairt-quantizer      (all-quantized; NO --float_fallback on v68)
        v
    model_quantized.dlc              (quantization applied)
        |
        |  qnn-context-binary-generator --backend libQnnHtp.so
        v
    model_htp.bin                    (compiled for one HTP arch)
```

### Stage 1 — convert to DLC

```sh
qairt-converter \
    --input_network          "$WORK/model.onnx" \
    --quantization_overrides "$WORK/model.encodings" \
    --output_path            "$WORK/context_binaries/model.dlc"
```

`--quantization_overrides` is how AIMET encodings reach the converter. Omit it
and the quantizer picks its own ranges, discarding the AIMET work entirely —
with no warning that it did.

The classic route's `qnn-onnx-converter` takes the same flag, so being on this
route is **not** what gives you AIMET. Pass `--input_list` here too when you
have real calibration vectors; the two are complementary.

Verify the overrides were actually read rather than assuming:

```sh
qairt-converter ... 2>&1 | tee convert.log
grep -iE 'override|encoding|skip|ignor' convert.log
```

Lines about skipped or unmatched tensors mean the ONNX and the `.encodings`
have drifted apart — tensor names in the encodings no longer match the graph.
Re-export the pair from AIMET rather than patching either side.

### Stage 2 — quantize the DLC

```sh
qairt-quantizer \
    --input_dlc  "$WORK/context_binaries/model.dlc" \
    --output_dlc "$WORK/context_binaries/model_quantized.dlc"
```

**Note what is absent: `--float_fallback`.**

It lets ops with no quantized implementation run in float instead of failing the
conversion, which sounds like a safe default and is not one:

- **On Hexagon v68 it breaks the model.** v68 has no FP16 `[vendor-claimed]`, so
  a float op becomes an FP16 op the HTP cannot execute, and
  `qnn-context-binary-generator` **aborts with exit 134** `[measured]`.
- **Even where FP16 exists**, every fallback op is a potential HTP-to-CPU round
  trip; a handful mid-graph can dominate latency.

So convert **all-quantized** and make the graph quantizable, rather than letting
ops escape into float. If an op genuinely cannot be quantized, changing the
model beats falling back — see the graph-adapt section in `qnn-model-export`.

`scripts/build-context-binary.sh` omits the flag by default; set
`FLOAT_FALLBACK=1` to opt in deliberately.

Check what fell back before accepting any result:

```sh
qairt-quantizer ... 2>&1 | tee quantize.log
grep -iE 'fallback|float|unsupported' quantize.log
```

### Stage 3 — generate the context binary

```sh
qnn-context-binary-generator \
    --model       libQnnModelDlc.so \
    --backend     libQnnHtp.so \
    --dlc_path    "$WORK/context_binaries/model_quantized.dlc" \
    --output_dir  "$WORK/context_binaries" \
    --binary_file model_htp
```

Produces `context_binaries/model_htp.bin`.

Two things that confuse people here:

- **`--model libQnnModelDlc.so` is not your model.** It is the SDK's generic
  DLC-loading shim. Your model arrives via `--dlc_path`. In the older
  model-lib flow `--model` *was* your compiled `.so` — same flag, different
  meaning between flows.
- **`--binary_file` takes a base name, not a filename.** `model_htp` produces
  `model_htp.bin`. Passing `model_htp.bin` gets you `model_htp.bin.bin`
  `[measured]`. Pass the base name — and if you inherit a script that deletes
  `*.bin.bin` before each run, that is what it is working around.

### The context binary is architecture-locked

The output is compiled for **one HTP architecture version**. A binary built
against v73 libraries does not run on a v68 part — it fails at load, with an
error that reads like file corruption rather than a mismatch.

Confirm before building:

```sh
ls -d "$QNN_SDK_ROOT"/lib/hexagon-v*/
```

Determine your part's architecture rather than assuming it — `qualcomm-env-discovery`
step 4 runs `qnn-platform-validator --coreVersion`, which has the backend report
its own. QCS6490 is **HTP v68** `[measured]`; other parts differ, and the
version does not track the part number in any extrapolable pattern.

**Encode the arch in the filename** (`model_w8a16_v68.bin`). It is the single
fact most likely to be lost when a binary is copied between machines, and its
absence is unrecoverable from the binary itself.

### Targeting a specific part

Beyond the architecture, some releases let you name the target SoC so the
compiler can apply part-specific settings — via `--soc_model`-style arguments
or the backend-extensions config referenced by `--config_file`. **The exact key
names vary by QAIRT version**, so read them from your install rather than
copying an example:

```sh
qnn-context-binary-generator --help
```

or extract the flag list with `qualcomm-sdk-docs`. A backend-extensions key that
your version does not recognise is typically **ignored without error** — you get
a binary built for a default target and no indication that your setting was
dropped. Verify the result rather than trusting the invocation.

## The other route: generate the context binary ON THE BOARD

The DLC route above compiles the context binary on the host. There is a second
route that compiles it **on the target**, from a cross-compiled `.so` produced
by the classic flow (`qnn-model-export` → `qualcomm-cross-compile`):

```sh
# on the board
export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH

qnn-context-binary-generator \
    --model       ./libmodel_w8a16.so \
    --backend     /usr/lib/libQnnHtp.so \
    --binary_file model_w8a16_ctx \
    --output_dir  .
```

Note `--model` here is **your** compiled `.so` — unlike the DLC route, where it
is the SDK's `libQnnModelDlc.so` shim. Same flag, different meaning between
routes; this trips people up.

**Why build on the board:** the compiler sees the actual HTP it is targeting, so
there is no architecture-mismatch class of failure. **Why not:** the board needs
the SDK's context-binary generator staged on it, and boards are slow and
thermally limited.

### Acceptance gates for context generation

Whichever route, the generation step has three pass conditions worth asserting
rather than eyeballing `[convention]`:

| Gate | Meaning if it fails |
|---|---|
| **RC = 0** | Generation failed. Exit **134** specifically means an op the HTP cannot run — on v68 almost always FP16 |
| **No FP16 error** | Ops were left in float. On v68 the binary will not run |
| **`spill_bytes = 0`** | The graph does not fit VTCM and is spilling to DDR. It will still run, much slower |

```sh
qnn-context-binary-generator ... 2>&1   | grep -iE 'error|fp16|spill|fail|saved' | tail -5
```

`spill_bytes = 0` is the one most often skipped, and it is the difference
between a model that meets its latency budget and one that quietly does not.

## Deploy and validate

### Copy to the board

```sh
scp context_binaries/model_htp.bin "$QC_BOARD_HOST":/tmp/
```

**Write to `/tmp` (tmpfs) first.** On boards with an eMMC root, a burst write
to the eMMC-backed filesystem can trigger a firmware watchdog reset with no log
entry `[measured]` — the board simply disappears mid-copy. Stage in `/tmp`,
then move deliberately to the install path.

### Run it

```sh
# on the board
export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH

qnn-net-run \
    --retrieve_context /tmp/model_htp.bin \
    --backend          /usr/lib/libQnnHtp.so \
    --input_list       /tmp/inputs.txt \
    --output_dir       /tmp/output \
    --log_level        warn
```

`--retrieve_context` is what distinguishes this from the model-lib flow — you
are loading a pre-compiled context, not building one from a `.so`.

### Validate numerically, not just "it ran"

1. Run the same inputs through the FP32 ONNX on the host.
2. Run them through the context binary on the board.
3. Compare on the **task metric**, not tensor distance.

A context binary that loads and produces plausibly-shaped output is the most
convincing way to ship a broken model. Cosine similarity above 0.99 is routinely
seen alongside a detector that lost a class.

## Versioning what you built

A `.bin` is opaque. Six months later nobody can tell what produced it, and a
diff tells you nothing. Record alongside each binary:

```text
model_htp_w8a16_v68.bin
  source onnx   : model.onnx        sha256 ...
  encodings     : model.encodings   sha256 ...
  QAIRT         : 2.37.1.250807
  HTP arch      : v68
  quantization  : W8A16, AIMET quantsim + AdaRound
  float fallback: 3 ops (list them)
  FP32 -> quant : 0.412 -> 0.398 mAP
  built         : <date> by <who>
```

**Keep model binaries out of git and pin them by hash in a manifest.** They are
megabytes of opaque data that change as a unit, they make every clone pay, and
a diff is meaningless. The question worth answering is "did the model under me
change?" — a `sha256` manifest answers that for free.

Version-critical revisions are real: a model rebuilt with a different SDK minor
can fail to load on the same board while the old one works. The manifest is how
you find that out in minutes instead of a day.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Binary fails to load on board | HTP arch mismatch. Verify `hexagon-v68` was present at build time |
| Encodings appear ignored | ONNX and `.encodings` drifted. Grep the convert log; re-export the pair |
| Much slower than expected | Float-fallback ops causing HTP→CPU round trips. Grep the quantize log |
| `libQnnModelDlc.so` not found | `envsetup.sh` not sourced, or the SDK lacks the DLC shim for this arch |
| Output file named `.bin.bin` | `--binary_file` takes a base name |
| Works on CPU backend, wrong on HTP | Genuine HTP op behaviour difference. Bisect by running sub-graphs |
| Board disappears during copy | eMMC burst-write watchdog reset. Stage via `/tmp` |

## Running several models at once

If multiple context binaries must be resident simultaneously, the binding
constraint on HTP is usually **VTCM**, not TOPS.

What is worth knowing before designing for concurrency:

- VTCM footprint is **per graph, not a constant** — it depends on the model. It
  must be measured per binary, not assumed from a datasheet figure.
- Loading a context is **not free**: context load is on the order of tens to
  hundreds of milliseconds `[vendor-claimed]`, so a load→run→unload pattern per frame
  will dominate your latency budget.
- Published per-context VTCM budgets and concurrency limits for a part are
  `[vendor-claimed]` until you measure them on your own graphs. Treat any
  specific number you were handed as a hypothesis to verify, not a constraint
  to design against.

The practical consequence: if several models must coexist, decide explicitly
which stay resident and which are loaded on demand, and measure the real
footprint of each before committing to the arrangement.
