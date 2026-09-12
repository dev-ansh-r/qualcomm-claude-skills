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

## On the board

Different problem — the board has no SDK, only the runtime:

```sh
export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH
```

Needed before ONNX Runtime or `qnn-net-run` in a fresh board shell. Here you
*set* it rather than unsetting; the rule above is about the build host only.
