---
name: qualcomm-cross-compile
description: Cross-compile a C/C++ or ROS2 application for a Qualcomm QCS6490 aarch64 board using the Yocto/QIRP eSDK - environment setup order, CMake and colcon invocation, linking the QNN runtime, and the silent-failure modes that exit 0 while producing nothing. Use when the target board has an immutable or OSTree image with no on-device compiler, when a build succeeds but produces no binary, or for toolchain, sysroot, eSDK or aarch64 linking questions.
---

# Cross-compiling for QCS6490

Boards in this class typically ship an **immutable OSTree image**: no gcc, no
cmake, no git on-device. Building on the target is not slow, it is impossible.
Everything is cross-compiled on an x86_64 host against the eSDK and deployed.

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

## The asymmetric loop

```text
edit (workstation)  ->  sync  ->  build (x86_64 Linux host)  ->  deploy (board)
```

Accept it rather than fighting it. If your workstation is Windows or macOS it
cannot run colcon, the eSDK **or the QAIRT converters** — those are x86_64 Linux
binaries. Propose the build-host command rather than attempting anything
locally.

**WSL2 counts as a Linux host** and is the usual answer for a Windows
workstation that wants to build locally. Git Bash, MSYS and Cygwin do not —
they provide a POSIX shell, not a Linux userland the SDK can run in.

Check which case you are in:

```sh
ssh "$QC_BOARD_HOST" 'command -v gcc cmake || echo "NO TOOLCHAIN - cross-compile required"'
ssh "$QC_BOARD_HOST" 'ostree admin status 2>/dev/null | head -3'
```

## Environment setup — the order is load-bearing

```sh
WORK="$(pwd)"                                       # capture BEFORE sourcing
unset LD_LIBRARY_PATH                               # 1
source "$QC_ESDK_ENV"                               # 2  eSDK
source "$QNN_SDK_ROOT/bin/envsetup.sh"              # 3  QAIRT, if you need it
cd "$WORK"                                          # sourcing may have moved you
```

Each step is there because of a specific silent failure. Full rationale:
`qualcomm-env-discovery/references/environment-setup.md`.

Verify before building:

```sh
echo "CC      : ${CC:-UNSET}"
echo "SYSROOT : ${SDKTARGETSYSROOT:-UNSET}"
echo "PWD     : $(pwd)"
"${CC%% *}" -dumpmachine        # expect aarch64-...
```

If `CC` is unset, the eSDK did not configure. Start a fresh shell.

## The five silent-exit-0 failure modes

Every one of these exits 0 and produces nothing. They are the reason a wrapper
script is worth having.

| # | Cause | Why silent |
|---|---|---|
| 1 | `LD_LIBRARY_PATH` set when sourcing the eSDK | Warning only, not an error |
| 2 | **Relative output path** — sourcing the eSDK **changes the cwd** | Output lands somewhere else entirely |
| 3 | Missing `ROS_VERSION` / `ROS_DISTRO` / `AMENT_PREFIX_PATH` | colcon skips packages rather than failing |
| 4 | Run under `sh` instead of `bash` | Setup scripts use bashisms; caller continues broken |
| 5 | Stale `build/` from a host-arch build | Cached x86 objects link into an "aarch64" build |

**#2 deserves emphasis.** Always pass absolute paths to `--base-paths`,
`--install-base`, `-o`, `--output_path`. Capture `$(pwd)` before sourcing.

## CMake

```sh
cmake -S "$WORK/src" -B "$WORK/build" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$WORK/install"
cmake --build "$WORK/build" -j"$(nproc)"
```

The eSDK exports `CC`, `CXX`, `CMAKE_TOOLCHAIN_FILE` and `SDKTARGETSYSROOT`;
CMake picks them up without a separate toolchain file. **Verify the output
rather than trusting the exit code:**

```sh
file "$WORK/build/your_binary"
# want: ELF 64-bit LSB ..., ARM aarch64
```

Getting `x86-64` here means the environment was not active. This single check
catches most of the five failure modes.

### Host packages leaking into a cross build

The classic version: a `find_package` resolves against `/usr/include` on the
host, and the build fails deep in a header (`gnu/stubs-32.h` is a common
tell). Fix by isolating the search:

```cmake
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
```

or disable the offending lookup outright
(`-DCMAKE_DISABLE_FIND_PACKAGE_CURL=ON`) and supply a vendored header. Library
code that `#include`s a dependency **unconditionally** while making it optional
in CMake is a recurring cause `[measured]`.

## colcon / ROS2

```sh
colcon build \
    --base-paths  "$WORK/src" \
    --build-base  "$WORK/build" \
    --install-base "$WORK/install" \
    --merge-install \
    --cmake-args -DCMAKE_BUILD_TYPE=Release
```

- **Absolute `--base-paths`** — failure mode #2 hits colcon hardest.
- Confirm `ROS_DISTRO`, `ROS_VERSION` and `AMENT_PREFIX_PATH` are set. Missing,
  colcon silently builds nothing and reports success.
- `--merge-install` produces a flatter tree that is easier to deploy.
- If a rebuild behaves oddly, wipe `build/ install/ log/`. Stale objects from a
  host-arch attempt are failure mode #5.

Wrap it. A `build.sh` that asserts the environment, uses absolute paths and
checks `file` on an output binary converts five silent failures into one loud
one.

## Linking the QNN runtime

To call QNN from your application:

```cmake
target_include_directories(app PRIVATE "$ENV{QNN_SDK_ROOT}/include/QNN")
target_link_libraries(app PRIVATE dl pthread)
```

**Do not link `libQnnHtp.so` at build time.** The QNN backends are loaded with
`dlopen` at runtime, selected by path. Linking them directly couples your
binary to one backend and to the SDK's library layout on the build host.

At runtime on the board the backends live alongside the system libraries:

```sh
export LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH
```

Match the aarch64 runtime libraries in
`$QNN_SDK_ROOT/lib/aarch64-oe-linux-gcc*/` against what the image actually
ships. A newer SDK's runtime against an older image is a real source of load
failures.

## When there is no eSDK

A plain GNU aarch64 toolchain works if you are not using Yocto-provided
libraries:

```sh
# e.g. arm-gnu-toolchain-*-x86_64-aarch64-none-linux-gnu
```

**Match glibc versions.** Build against a glibc **older than or equal to** the
board's and the binary runs (forward compatibility); build against a newer one
and it fails at load with a `GLIBC_2.xx not found` error. Check the board with
`ldd --version`.

For ARM-only sources, mind the ISA baseline. `-march` flags that assume a newer
revision than the part produce SIGILL at runtime, not a build error. Check
`/proc/cpuinfo` on the board for the features actually present — a core may
have `asimddp` but not `i8mm`, and a `-march` string requesting the latter
builds happily and crashes on device `[measured]`.

Link statically where practical to avoid depending on the image's C++ runtime:

```sh
-static-libstdc++ -static-libgcc
```

Then verify what you actually depend on:

```sh
aarch64-none-linux-gnu-readelf -d app | grep NEEDED
```

Every `NEEDED` entry must exist on the board. Checking this on the host takes
seconds; discovering it on the board takes a deploy cycle.

## Deploy

```sh
scp -r install/* "$QC_BOARD_HOST":/tmp/staging/
ssh "$QC_BOARD_HOST" 'mv /tmp/staging/* /opt/myapp/'
```

**Stage through `/tmp` (tmpfs).** On an eMMC-rooted board, a burst write to the
eMMC-backed filesystem can trigger a firmware watchdog reset with no log entry
`[measured]`. Copy to tmpfs, then move deliberately.

On an OSTree image, `/usr` is read-only. Install under `/opt` or another
writable path; check with `ostree admin status` if a write is refused.

## Long builds on a shared host

Build hosts under load fall over, and from your workstation that appears only
as `Connection timed out during banner exchange` — indistinguishable from a
failed build, a finished build, or a running one.

If builds take more than a few minutes, log them durably:

- Write logs **inside the checkout, not `/tmp`** — many hosts clear `/tmp` on
  boot, which deletes the evidence at exactly the moment a reboot made it
  interesting.
- Record the kernel boot id (`/proc/sys/kernel/random/boot_id`) at start. If it
  changed and no exit code was written, the host rebooted — that is a different
  problem from a failed build, and exact string equality tells you which.
- Track liveness by **pid file plus process start time**, never `pgrep -f`:
  `pgrep -f build.sh` matches the polling command's own command line and
  cheerfully reports processes that do not exist `[measured]`.
- Also avoid `pgrep -c`: `comm` truncates at 15 characters, so longer process
  names yield false zeros.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Binary is `x86-64` per `file` | Environment not active. Fresh shell, correct order |
| Build exits 0, nothing produced | One of the five modes. Relative path is most likely |
| `gnu/stubs-32.h: No such file` | Host `find_package` leaked in. Isolate `CMAKE_FIND_ROOT_PATH` |
| `GLIBC_2.xx not found` on board | Built against newer glibc than the image |
| `SIGILL` on board, builds fine | `-march` assumes ISA features the part lacks |
| `cannot open shared object` | A `NEEDED` library is absent. Check with `readelf -d` |
| colcon reports success, no packages | `ROS_DISTRO`/`AMENT_PREFIX_PATH` unset |
| `command not found` after sourcing | QAIRT sourced before the eSDK |
| SSH dies mid-build | Host rebooted or OOM-killed. Check boot id, not the network |
