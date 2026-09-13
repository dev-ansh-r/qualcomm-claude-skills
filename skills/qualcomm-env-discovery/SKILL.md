---
name: qualcomm-env-discovery
description: Discover and verify a Qualcomm development environment for any Snapdragon or QCS/QCM/SA part - QCS6490, QCS8550, QCS8250, RB5, SA8295, Snapdragon X and others. Locates the target board, build host and AIMET host, confirms reachability, and reads back the installed QAIRT/QNN SDK version, eSDK toolchain, SoC identity, Hexagon HTP architecture and board image. Writes a .qualcomm-env config the other Qualcomm skills read. Use at the start of any QNN/QAIRT/AIMET/HTP/NPU task, when a converter or board command fails for unclear reasons, or when asked which SDK version or HTP architecture is installed.
---

# Qualcomm environment discovery

Probes the machines and reports what is actually installed.

**This is not the first-run step — `qualcomm-setup` is.** The two differ:

| | `qualcomm-setup` | this skill |
|---|---|---|
| When | Once, first time | Any time after |
| Asks | Topology, board access | Nothing |
| Writes | `.qualcomm-env` | Reports drift; does not overwrite |
| For | "Get me started" | "What is on these machines *now*?" |

Use this to re-verify before a build, after an SDK upgrade, or when a command
fails for unclear reasons. Versions go stale silently, and a config that was
right last month can be wrong today.

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

## Why this is a skill and not a one-liner

The flags, tool names and target triples in this toolchain are
version-specific. Guessing the SDK version and then emitting a command for a
different one produces errors that look like model problems. **Read the
version, then choose the command.**

## The three roles

Ask which hosts fill which role. One machine may fill several; never assume it
does.

| Role | Identify by | Must have |
|---|---|---|
| `BUILD_HOST` | **x86_64 Linux only** | QAIRT SDK, `bin/x86_64-linux-clang/`, Yocto/QIRP eSDK |
| `AIMET_HOST` | x86_64 Linux, often GPU | `aimet-onnx` or `aimet-torch` importable |
| `BOARD` | aarch64 Qualcomm part | `libQnnHtp.so`, HTP firmware |

**A Windows or macOS workstation cannot be the build host.** The QAIRT
converters ship only as `bin/x86_64-linux-clang`; Git Bash and MSYS are not
Linux, though WSL2 is. This is normal and not a problem — the workstation edits
the source and drives a Linux build host over SSH. `scripts/probe-env.sh`
detects and reports this rather than listing the resulting missing pieces one by
one.

## Procedure

### 1. Load existing config if present

Look for `.qualcomm-env` in the project root, then `~/.qualcomm-env`. If found,
**still re-verify reachability and versions** — DHCP leases expire and SDKs get
upgraded underneath you. Report any drift from what the file claims rather than
silently using stale values.

### 2. Establish endpoints

Ask the user for any role not already in config. Do not scan the network
unprompted. Accept an SSH alias (`Host qcs-board` in `~/.ssh/config`) in
preference to a raw IP — aliases survive a DHCP change, IPs do not.

If the user does not know an address, offer, in order:
1. An existing `~/.ssh/config` entry — `grep -A3 -i 'host .*\(board\|qcs\|hexagon\)' ~/.ssh/config`
2. `adb devices` if the board is USB-attached
3. An ARP sweep of the local /24, **only with explicit approval** and only as a
   last resort

### 3. Probe

`scripts/probe-env.sh` collects everything below in one pass. Run it per host:

```sh
# Local
bash scripts/probe-env.sh

# Remote — copy and run, do not pipe a script into a remote shell blind
scp scripts/probe-env.sh <host>:/tmp/ && ssh <host> 'bash /tmp/probe-env.sh'
```

What it reads, and why each matters:

| Fact | How | Why it matters |
|---|---|---|
| QAIRT/QNN version | `$QNN_SDK_ROOT` path, `sdk.yaml` | Flag names differ across majors |
| SDK bin dirs | `ls $QNN_SDK_ROOT/bin/` | Confirms x86_64-linux-clang tools present |
| HTP backend libs | `ls $QNN_SDK_ROOT/lib/hexagon-v*/` | The `v68`/`v73` dir names give the HTP arch |
| eSDK toolchain | `environment-setup-*`, then ask the compiler `-dumpversion` | Gives the compiler prefix and gcc version. **Not** the `-t` value - that is a fixed enum in the tool |
| Board arch/kernel | `uname -a` | Confirms aarch64 and the vendor kernel |
| **SoC identity** | `/sys/devices/soc0/machine`, `soc_id` | **Which Qualcomm part this is** - drives HTP arch and op support |
| Board image type | `test -w /usr` or `ostree admin status` | Immutable image ⇒ no on-device build |
| On-device QNN libs | `ls /usr/lib/libQnn*.so` | `qnn-net-run` needs these at runtime |
| Python / ONNX | `python3 -V`, `pip show onnx onnxruntime` | Converter is a Python tool |
| AIMET | `python3 -c "import aimet_onnx"` | Decides if the QAIRT/DLC path is open |

### 4. Determine the part and its HTP architecture

This is the single most load-bearing fact for op support and for whether a
context binary will load. **It is determined, never assumed** — and it is two
separate questions:

**(a) What can the SDK build for?**

```sh
ls -d "$QNN_SDK_ROOT"/lib/hexagon-v*/ 2>/dev/null
```

**(b) What does this part need?** Ask the backend. It knows `[measured]`:

```sh
# On the board. Writes only under --targetPath; point it at tmpfs.
LD_LIBRARY_PATH=/usr/lib:$LD_LIBRARY_PATH qnn-platform-validator --backend dsp --coreVersion --targetPath /tmp/pv
```

```text
Core Version of the backend DSP: Hexagon Architecture V68
```

That is the authoritative answer — the backend reporting its own capability,
not a lookup. `scripts/probe-env.sh` runs it automatically when the tool is
present and emits `QC_HTP_ARCH_DETECTED`.

Corroborate with the Skel the runtime actually loads:

```sh
ls /usr/lib/dsp/cdsp/libQnnHtpV*Skel.so     # e.g. libQnnHtpV68Skel.so
```

Fallbacks, if `qnn-platform-validator` is absent:

```sh
cat /sys/devices/soc0/machine /sys/devices/soc0/soc_id   # which part this is
```

then the SoC → arch mapping in the **SDK-local docs** (`qualcomm-sdk-docs`), and
the datasheet last, treated as `[vendor-claimed]`.

Note the board's `/usr/lib/libQnnHtpV*Stub.so` set spans many architectures — it
is the runtime's stub collection, **not** an answer for your part. Only the
backend report and the loaded Skel identify the one in use.

The answer to (b) must appear in the list from (a). If it does not, the SDK is
missing that architecture's support package: a context binary will build on the
host and then **fail to load on the board**, with an error that reads like file
corruption rather than a mismatch.

**Do not guess the mapping from the part number.** Hexagon architecture
versions do not track SoC model numbers in any pattern you can extrapolate, and
a wrong guess here costs a full build-deploy cycle to discover. Read it from the
SDK docs for your version.

Known values, and the only one this repo has evidence for:

| Part | HTP arch | Provenance |
|---|---|---|
| QCS6490 (SoC id 498) | v68 | `[measured]` — backend `--coreVersion` reported "Hexagon Architecture V68"; `libQnnHtpV68Skel.so` loaded |

Add a row when you have verified one — see `docs/CONTRIBUTING.md`. An unverified
row is worse than an absent one.

### 5. Write the config

Write `.qualcomm-env` to the project root, `chmod 600`. Shell-sourceable:

```sh
# .qualcomm-env - generated by qualcomm-env-discovery on <date>
# Re-run the skill to refresh. Values are READ, not assumed.

QC_BOARD_HOST=<ssh alias or user@host>
QC_BOARD_ARCH=aarch64
QC_BOARD_IMMUTABLE=true          # no on-device compiler
QC_SOC_MACHINE=<from /sys/devices/soc0/machine>
QC_SOC_ID=<from /sys/devices/soc0/soc_id>
QC_HTP_ARCH=<vNN, determined - see step 4. NOT guessed from the part number>

QC_BUILD_HOST=<ssh alias or user@host>
QC_QNN_SDK_ROOT=/opt/qcom/aistack/qairt/<version>
QC_QAIRT_VERSION=<x.y.z.build>
QC_ESDK_ENV=<path to environment-setup-*>
QC_ESDK_CC_PREFIX=<e.g. aarch64-qcom-linux>   # what the eSDK actually provides
QC_ESDK_GCC_VERSION=<e.g. 11.4.0>             # from the compiler, not the filename
# -t is a FIXED ENUM in qnn-model-lib-generator (see its --help). It often
# matches no eSDK triple exactly - pick the nearest and verify on the board.
QC_TARGET_TRIPLE=<nearest supported target>

QC_AIMET_HOST=<ssh alias or user@host>
QC_AIMET_FLAVOUR=aimet-onnx       # or aimet-torch, or none
```

**Never commit this file.** Add it to `.gitignore` — it names internal hosts.

### 6. Report

Summarise as a table: role, endpoint, reachable, version, and anything that
blocks the next step. Call out explicitly:

- HTP arch dir missing for the target part
- SoC identity unreadable (⇒ target arch unconfirmed; say so rather than assuming)
- QAIRT major ≠ 2.37 (examples in the other skills were verified on 2.37.x)
- Board image immutable (⇒ `qualcomm-cross-compile` is mandatory, not optional)
- No AIMET anywhere (⇒ QAIRT/DLC path unavailable; use the classic flow)

## Failure modes worth recognising

| Symptom | Cause |
|---|---|
| `qnn-onnx-converter: command not found` after sourcing | `envsetup.sh` sourced with `sh`, not `bash` |
| SDK tools vanish after sourcing the eSDK | eSDK `environment-setup` resets `PATH` — source the eSDK **first**, QAIRT `envsetup.sh` **second** |
| SSH hangs with no banner | Build host under load or rebooting; not a credentials problem |
| Board reachable, then gone mid-session | Watchdog reset. Check uptime before assuming the network dropped |

## Environment setup order

This order is load-bearing and shared by every build-host skill in this repo:

```sh
unset LD_LIBRARY_PATH                       # 1. a set LD_LIBRARY_PATH breaks the eSDK setup
source <eSDK>/environment-setup-<arch>      # 2. cross toolchain
source $QNN_SDK_ROOT/bin/envsetup.sh        # 3. QAIRT tools last
```

Getting this wrong is a leading cause of commands that **exit 0 and produce
nothing**. See `references/environment-setup.md`.
