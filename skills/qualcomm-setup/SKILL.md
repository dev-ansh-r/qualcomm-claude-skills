---
name: qualcomm-setup
description: First-run setup for the Qualcomm skills - get started, set up, configure or onboard a new machine for QAIRT/QNN/AIMET work. Probes what is already installed, asks only what cannot be discovered, and writes the .qualcomm-env config every other Qualcomm skill reads. Covers all layouts - SDK on this machine, a remote Linux build server or cloud VM, a separate AIMET host, board over SSH or ADB or none yet. Run this before any other Qualcomm skill, or when one reports that setup has not been run.
---

# Qualcomm toolchain setup

The first-run entry point. Produces `.qualcomm-env`, which every other Qualcomm
skill reads so that nobody has to answer the same questions twice.

**Probe first, ask second.** Most of this is discoverable in one SSH call. Only
two things genuinely need the user: which machines fill which roles, and how the
board is reached. Asking someone to type a path a script can read is how a setup
step gets skipped.

## Is setup already done?

```sh
grep -q '^QC_SETUP_VERSION=' .qualcomm-env 2>/dev/null && echo done || echo needed
```

**The marker is what counts, not the file.** A `.qualcomm-env` can exist and be
half-written; the marker says the interview completed. Empty fields are allowed
— "no board yet" is a valid, recorded answer, not an incomplete one.

Current schema: **`QC_SETUP_VERSION=1`**. A lower number means the file predates
fields other skills now read — re-run setup rather than patching it by hand.

## Step 1 — pick the layout

The three roles from `qualcomm-env-discovery` are **build host** (QAIRT SDK +
eSDK), **AIMET host** (quantization), and **board** (the target). The only
question is which machine fills each. Ask with the four common answers:

| Layout | Build | AIMET | Board | Fits |
|---|---|---|---|---|
| **A. All-in-one** | this machine | this machine | SSH/ADB | Linux workstation, hardware on your desk |
| **B. Remote build host** | remote Linux | remote or none | from the build host | **Windows/macOS workstation** — the common case |
| **C. Cloud VM** | cloud Linux | cloud (often GPU) | tunnel, or none | No local Linux; GPU for AIMET |
| **D. No board yet** | this or remote | either | **none** | Day one; CI; hardware not arrived |

**D is a first-class answer, not a failure.** Conversion and host-side validation
work without hardware. Record it, and the skills that need a board will say so
instead of failing obscurely.

A Windows or macOS workstation **cannot** be the build host — the QAIRT
converters are x86_64 Linux only (WSL2 counts; Git Bash does not). If the user
is on Windows and picks A, say so and move them to B.

Details and trade-offs: `references/topologies.md`.

## Step 2 — probe, do not interrogate

For each host named, run the probe rather than asking about it:

```sh
# local
bash ../qualcomm-env-discovery/scripts/probe-env.sh

# remote — copy and run, never pipe a script into a remote shell blind
scp probe-env.sh <host>:/tmp/ && ssh <host> 'bash /tmp/probe-env.sh'
```

It returns OS, arch, whether the host *can* run the SDK, the SDK root and
version, the HTP architectures available, the eSDK compiler prefix and gcc
version, Python/ONNX/AIMET presence, and the SoC identity on a board.

**Report what was found and ask the user to confirm**, rather than asking them
to supply it. If the probe cannot reach a host, that is the finding — say which
host and what the SSH error was.

If a probe shows no SDK on a host the user named as the build host, do not
silently continue: either they named the wrong machine, or the SDK needs
installing. Ask which.

## Step 3 — how is the board reached?

Not discoverable, and **more than an address**. Downstream skills need the
method, because it decides whether on-board context generation is even possible.

| Method | Record | Notes |
|---|---|---|
| SSH key | `QC_BOARD_HOST`, `QC_BOARD_ACCESS=ssh-key` | Preferred. Use an `~/.ssh/config` alias — it survives a DHCP change |
| SSH password | `QC_BOARD_ACCESS=ssh-password` | Needs `sshpass` for scripting. **Never record the password** — pass it at run time |
| Via jump host | `QC_BOARD_JUMP`, `QC_BOARD_ACCESS=ssh-jump` | Common when the board sits behind the build host |
| ADB / USB | `QC_BOARD_ACCESS=adb` | `adb devices`. No `scp`; use `adb push` |
| None yet | `QC_BOARD_ACCESS=none` | Layout D. Perfectly valid |

Prefer an SSH alias over a raw IP. DHCP leases expire; aliases do not.

**Never write a password or key material into `.qualcomm-env`.** Record the
*method*; the credential stays in the SSH agent, `~/.ssh/config`, or an
environment variable supplied at run time.

## Step 4 — determine the HTP architecture, or leave it empty

Two separate facts:

- **What the SDK can build for** — from the probe (`QC_HTP_ARCH_AVAILABLE`).
- **What the part needs** — from the board's SoC id plus the SDK-local docs.

**If the board is not reachable, leave `QC_HTP_ARCH` empty.** Do not infer it
from the part number: Hexagon versions do not track SoC model numbers in any
extrapolable pattern, and a value guessed here would be trusted by every
downstream skill and cost a full build-deploy cycle to disprove. An empty field
is honest; a guessed one is a trap.

## Step 5 — write the config

Use `scripts/write-env.sh`, which validates the fields, refuses to write
credentials, writes atomically, and **verifies** the resulting permissions
rather than assuming `chmod` worked.

```sh
bash scripts/write-env.sh          # reads KEY=VALUE on stdin
```

Two honesty requirements:

- **`chmod 600` silently does nothing on a Windows filesystem.** Attempt it,
  check it, and if it did not take, say so plainly — `.gitignore` is then the
  only protection. Do not report the file as secured when it is not.
- **Add `.qualcomm-env` to `.gitignore`** if it is not already there. It names
  internal hosts.

## Step 6 — report, and say what is open

Summarise as a table: role, host, reachable, version, and the layout chosen.
Then name what is **not** configured and which skills that limits:

```text
Layout    B — remote Linux build host

BUILD     <host>    reachable   QAIRT 2.37.1  HTP v66,v68,v73,v75  eSDK gcc 11.4.0
AIMET     —         not configured       -> aimet-quantization unavailable
BOARD     —         not configured       -> on-board ctx-gen and validation unavailable

Open: no board. Model conversion and host-side checks work; anything that
      needs hardware will say so rather than failing obscurely.
```

That last paragraph matters more than the table. A developer who knows *why* a
skill is unavailable does not file a bug about it.

## Re-running

Safe and idempotent. Re-run after adding hardware, changing machines, or
upgrading the SDK — the version fields go stale silently otherwise. Setup
re-probes rather than trusting what the file claims.
