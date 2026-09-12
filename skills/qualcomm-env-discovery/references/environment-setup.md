# Environment setup order (build host)

Shared by `qnn-model-export`, `qualcomm-cross-compile` and `qnn-context-binary`.
Getting this wrong is the leading cause of commands that **exit 0 and produce
nothing**.

## The order

```sh
unset LD_LIBRARY_PATH                       # 1
source <eSDK>/environment-setup-<arch>      # 2  cross toolchain
source "$QNN_SDK_ROOT/bin/envsetup.sh"      # 3  QAIRT tools
```

### 1. `unset LD_LIBRARY_PATH` first

The Yocto/QIRP `environment-setup` script refuses to configure correctly when
`LD_LIBRARY_PATH` is already set — it warns and continues, leaving a
half-configured environment. Downstream commands then link against host
libraries and either fail cryptically or silently produce host-arch output.

A previously-sourced `envsetup.sh` is itself a common source of a set
`LD_LIBRARY_PATH`, so **re-sourcing in the wrong order in the same shell
reproduces the bug**. Start a fresh shell when in doubt.

### 2. eSDK before QAIRT

Both scripts rewrite `PATH`. The eSDK's rewrite is more aggressive and will
push the QAIRT `bin/x86_64-linux-clang` directory out of reach. Sourcing QAIRT
last keeps the converters on `PATH`.

Symptom of the wrong order: `qnn-onnx-converter: command not found` in a shell
where you just sourced `envsetup.sh`.

### 3. `bash`, never `sh`

Both setup scripts use bashisms. Under `sh` (dash on Debian/Ubuntu) they fail
partway with a non-obvious parse error, and a `set -e`-less caller continues
with a broken environment.

In a Jupyter cell this means `%%bash`, not `%%sh`.

## Other silent-exit-0 modes on this toolchain

These are reported by teams running colcon/CMake builds against the eSDK. Each
exits 0 while producing nothing:

| Cause | Why it is silent |
|---|---|
| `LD_LIBRARY_PATH` set when sourcing the eSDK | Warning only, not an error |
| Relative output/base path | **Sourcing the eSDK changes the working directory.** A relative path resolves somewhere else |
| Missing `ROS_VERSION` / `ROS_DISTRO` / `AMENT_PREFIX_PATH` | ROS tooling skips packages rather than failing |
| Run under `sh` instead of `bash` | See above |

**The relative-path one deserves emphasis.** Always pass absolute paths to
`--output_path`, `-o`, and `--base-paths`. Capture the directory *before*
sourcing:

```sh
WORK="$(pwd)"                       # capture first
unset LD_LIBRARY_PATH
source <eSDK>/environment-setup-<arch>
source "$QNN_SDK_ROOT/bin/envsetup.sh"
cd "$WORK"                          # sourcing may have moved you
```

## A verification block worth pasting

```sh
echo "PWD           : $(pwd)"
echo "QNN_SDK_ROOT  : ${QNN_SDK_ROOT:-UNSET}"
echo "converter     : $(command -v qnn-onnx-converter || echo MISSING)"
echo "qairt-conv    : $(command -v qairt-converter || echo MISSING)"
echo "ctx-bin-gen   : $(command -v qnn-context-binary-generator || echo MISSING)"
echo "cross gcc     : $(command -v "${CC%% *}" || echo MISSING)"
echo "LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-unset}"
```

If `converter` is MISSING but `QNN_SDK_ROOT` is set, you sourced in the wrong
order. Start a new shell and redo it.

## PYTHONPATH leaking between environments

AIMET and the QAIRT converter want **different, incompatible numpy versions**.
Teams commonly satisfy both with two virtualenvs on one host — and then get
bitten by `PYTHONPATH`, which `activate` does **not** clear.

If the AIMET step exports a `PYTHONPATH` (to reach a user-site install, say) and
you then activate the converter venv in the same shell, that `PYTHONPATH`
**shadows the venv's own packages**. The converter picks up the wrong numpy and
fails inside shape inference with an error that looks like a corrupt model
`[measured]`:

```text
/encoder_embed/Unsqueeze ... 3120 != -138557648
```

A nonsensical negative dimension in a shape-inference error is the signature.
The model is fine.

**Run each stage with the environment it needs, explicitly:**

```sh
# AIMET stage - may need a PYTHONPATH
PYTHONPATH=/path/to/aimet/site-packages python step_quantize.py

# Converter stage - must NOT inherit it
env -u PYTHONPATH bash step_convert.sh
```

`env -u PYTHONPATH` is more reliable than remembering to unset it, and it
survives being run from a shell where someone else already exported it.

The same applies to `LD_LIBRARY_PATH` (above): **activation does not isolate
you from variables the parent shell exported.**

## On the board

Different problem — the board has no SDK, only the runtime:

```sh
export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH
```

Needed before ONNX Runtime or `qnn-net-run` in a fresh board shell. Here you
*set* it rather than unsetting; the rule above is about the build host only.
