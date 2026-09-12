---
name: qualcomm-sdk-preflight
description: Verify a QAIRT/QNN SDK install is complete and usable before converting a model, and locate the documentation that matches the installed version. Checks SDK dependency scripts, HTP backend libraries, Python bindings, ONNX/ONNXRuntime versions and cross-toolchain presence, then finds the version-correct docs (SDK-local HTML first, vendor site second). Use before a first conversion on a new machine, after an SDK upgrade, or when a converter fails with import or library errors.
---

# QAIRT / QNN SDK preflight

Confirms the SDK on this machine can actually convert a model, and points at
docs for **the version installed** rather than the newest published.

Assumes `qualcomm-env-discovery` has run and `.qualcomm-env` exists. If not, run
that first — this skill needs `QC_QNN_SDK_ROOT`.

## Part 1 — dependency check

### Run the vendor's own checker first

QAIRT ships a dependency script. It is authoritative for the platform packages;
run it before diagnosing anything by hand.

```sh
source "$QNN_SDK_ROOT/bin/envsetup.sh"
bash "$QNN_SDK_ROOT/bin/check-python-dependency"
sudo bash "$QNN_SDK_ROOT/bin/check-linux-dependency.sh"
```

Both exist across the 2.2x–2.3x line. If either is missing, note the exact
path that failed and continue with the manual checks — a missing checker is
usually a partial extraction of the SDK tarball.

### What a complete install has

| Check | Command | Failure meaning |
|---|---|---|
| x86 tool dir | `ls $QNN_SDK_ROOT/bin/x86_64-linux-clang/` | Tarball extracted partially |
| HTP arch libs | `ls -d $QNN_SDK_ROOT/lib/hexagon-v*/` | **Blocks HTP entirely** — see below |
| x86 backend libs | `ls $QNN_SDK_ROOT/lib/x86_64-linux-clang/libQnn*.so` | No host-side simulation/validation |
| aarch64 runtime | `ls $QNN_SDK_ROOT/lib/aarch64-oe-linux-gcc*/` | Nothing to deploy to the board |
| Python bindings | `python3 -c "import qti.aisw"` | Converters are Python; this is fatal |
| ONNX | `pip show onnx onnxruntime` | Converter parses via onnx |

### The HTP architecture check is the one that bites

```sh
ls -d "$QNN_SDK_ROOT"/lib/hexagon-v*/ 2>/dev/null
```

The `v68` / `v73` / `v75` in those directory names is the **Hexagon HTP
architecture version**. This tells you what the SDK can *build for*; which one
your part *needs* is a separate question — determine it with
`qualcomm-env-discovery` (SoC id) and `qualcomm-sdk-docs` (the mapping, from
your SDK's own documentation).

**Do not infer the architecture from the part number.** Hexagon versions do not
track SoC model numbers in any extrapolable pattern.

If your target architecture is absent, a context binary still builds on the host
and then **fails to load on the board**, with a backend error that reads like a
corrupt file. This costs hours if you do not check it up front. Fix by
installing the matching Hexagon / HTP support package, not by rebuilding the
model.

### Python version compatibility

The converters pin a narrow Python range per QAIRT release, and it is often
*older* than the system Python. Symptom is an import error deep inside
`qti.aisw`, not a clean "unsupported version" message.

If `import qti.aisw` fails on a system Python, check the SDK's own bundled
Python or its documented version before debugging the traceback.

### numpy and onnx versions can break the converter

**numpy 2.x breaks QAIRT 2.37's shape inference** `[measured]`. A working pin is
**numpy 1.26.4 / onnx 1.12.0** in a dedicated converter virtualenv.

This is worth isolating deliberately: AIMET wants a recent torch/numpy, the
converter wants an old numpy, and one environment cannot satisfy both. Two
virtualenvs on the same host is the normal arrangement —

```sh
source ~/venvs/aimet/bin/activate      # torch 2.5.x, aimet_onnx 2.x
source ~/venvs/convenv/bin/activate    # numpy 1.26.4, onnx 1.12.0  <- converter
```

A converter failing deep inside shape inference, on a model that is fine, is the
signature of this.

### ONNX opset

Export models at **opset 17** for QAIRT 2.37.x `[measured]` — the pipeline in
this repo's reference material was set explicitly with
`g.opset_import[0].version = 17`. Higher opsets may parse and then lower badly.

## Part 2 — finding the right documentation

**Order matters. The SDK-local docs match your install; the website does not.**

> For anything beyond a quick look, use the **`qualcomm-sdk-docs`** skill — it
> extracts tool flags, operator tables and architecture identifiers out of your
> installed SDK into a greppable local cache, and checks a model's operators
> against it. The rest of this section is the manual equivalent.

### 1. SDK-local docs — always first

```sh
ls "$QNN_SDK_ROOT/docs/"
find "$QNN_SDK_ROOT/docs" -name 'index.html' | head
```

QAIRT ships a full HTML doc tree. It is version-exact — flags, supported ops
and backend notes are for the bits on disk. Open it locally rather than
searching the web.

The two pages worth knowing:

- **Operator support / backend op definitions** — which ONNX ops each backend
  (HTP, GPU, CPU) implements. This is what answers "will my model run on the
  NPU", and it is *per HTP arch version*.
- **Tool reference** — the real flag list for `qnn-onnx-converter`,
  `qairt-converter`, `qnn-context-binary-generator` for this version.

### 2. Per-tool help — second

```sh
qnn-onnx-converter --help
qairt-converter --help
qnn-context-binary-generator --help
```

Authoritative and instant. Prefer this over any example in any skill, including
the ones in this repo, when the two disagree.

### 3. Vendor site — last

Qualcomm's public docs sit behind a developer account and default to the
**latest** release. When you use them, pin the version explicitly and confirm
against `--help` before trusting a flag.

Useful public sources that are not auth-walled:
- AIMET docs and API reference (`quic.github.io/aimet-pages`) — open source
- The `quic/aimet` GitHub repo — the actual API surface
- Qualcomm AI Hub model zoo — working export configs for common architectures

**Do not start this skill with a web fetch.** If the SDK is installed, the
answer is on disk.

## Part 3 — report

Produce a go/no-go, not a log dump:

```text
QAIRT            2.37.1.250807       OK
HTP archs        hexagon-v68,v73     OK  (v68 present - QCS6490 target)
Python bindings  qti.aisw importable OK
onnx / ort       1.16.0 / 1.17.1     OK
aarch64 runtime  gcc11.2             OK
eSDK             found               OK
AIMET            not installed       -> QAIRT/DLC path unavailable on this host
Docs             $QNN_SDK_ROOT/docs/index.html

VERDICT: ready for the classic flow (qnn-model-export).
         For context binaries, AIMET must run on a separate host.
```

State the verdict in terms of **which flow is open**, since that is the decision
the user is about to make. See the repo README for the fork.
