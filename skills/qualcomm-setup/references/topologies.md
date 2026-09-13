# Layouts

Three roles, and the only question is which machine fills each.

| Role | Must be | Provides |
|---|---|---|
| **Build host** | x86_64 Linux | QAIRT SDK, eSDK cross-toolchain |
| **AIMET host** | x86_64 Linux, often GPU | `aimet-onnx` / `aimet-torch` |
| **Board** | The Qualcomm part | Runs the result |

One machine can hold several roles. None of them can be Windows or macOS except
the *workstation you drive them from*, which holds no role at all.

---

## A — All-in-one

```text
  Linux workstation                  board
  ┌───────────────────────┐         ┌──────────┐
  │ QAIRT SDK + eSDK      │  SSH    │ QCS####  │
  │ AIMET                 │ ──────► │ HTP      │
  │ your editor           │  ADB    │          │
  └───────────────────────┘         └──────────┘
```

Simplest when it fits. One environment, no file shuffling, fast iteration.

**The catch is Python.** AIMET wants a recent numpy/torch; the QAIRT converter
needs numpy 1.26.4 and breaks on numpy 2.x `[measured]`. On one machine you
*must* keep two virtualenvs, and you must stop `PYTHONPATH` leaking between them
— an inherited `PYTHONPATH` shadows the converter's venv and fails inside shape
inference with an error that looks like a corrupt model. Run the converter with
`env -u PYTHONPATH`.

---

## B — Remote build host

```text
  workstation            build host                board
  ┌─────────────┐       ┌────────────────┐       ┌──────────┐
  │ Windows /   │ SSH   │ Linux x86_64   │ SSH   │ QCS####  │
  │ macOS /     │ ────► │ QAIRT + eSDK   │ ────► │ HTP      │
  │ Linux       │       │ (± AIMET)      │       │          │
  └─────────────┘       └────────────────┘       └──────────┘
       edit                   build                  run
```

**The common case, and the only option on Windows or macOS.** The converters
ship as `bin/x86_64-linux-clang`; there is no other build. WSL2 counts as a
Linux host and collapses this into A.

The loop is asymmetric and worth accepting rather than fighting: edit locally,
sync, build remotely, deploy to the board. Attempting a local build wastes time
on a machine that cannot do it.

The board is usually reached **from the build host**, not from the workstation —
so record a jump-host access method rather than assuming a direct route.

**Long builds need durable logs.** A shared build host that falls over is
indistinguishable, from the workstation, from a failed build, a finished one, or
one still running. Log to a file inside the checkout — not `/tmp`, which many
hosts clear on boot, deleting the evidence exactly when a reboot made it
interesting.

---

## C — Cloud VM

```text
  workstation            cloud VM (GCP / AWS / Azure)        board
  ┌─────────────┐       ┌────────────────────────┐         ┌──────────┐
  │ anywhere    │ ────► │ Linux x86_64, ± GPU    │  ?????  │ on a desk│
  └─────────────┘       │ QAIRT + eSDK + AIMET   │         │ somewhere│
                        └────────────────────────┘         └──────────┘
```

Same shape as B, with one structural difference: **the board is usually not
reachable from the VM.** Plan for that rather than discovering it late.

- **A GPU VM is the strongest reason to choose this.** AdaRound and QAT are
  genuinely GPU-bound; conversion is not.
- **Egress may be restricted.** Fine — the SDK-local docs are on disk, which is
  why `qualcomm-sdk-docs` reads them rather than the web.
- **Board access** is a tunnel (VPN, reverse SSH from a machine near the board),
  or nothing. If nothing, this is layout **D** for anything board-dependent, and
  you should record it as such.
- **Cost discipline:** conversion is bursty. A persistent GPU VM idling between
  runs is the usual way this gets expensive.

---

## D — No board yet

```text
  build host                         (no board)
  ┌────────────────────────┐
  │ QAIRT + eSDK + AIMET   │         hardware not arrived,
  │ ONNX ► convert ► .bin  │         shared, or CI-only
  └────────────────────────┘
```

**A valid, recorded state — not a failure.** Day one on a new team, hardware on
order, or a CI runner that only converts.

Works without a board:

- static-shape preparation and `--dry_run` op checks
- AIMET quantization and `.encodings` export
- full conversion to `.cpp`/`.bin`/`.so` or DLC
- the FP16 audit of the generated `.cpp`
- **CPU-backend** validation via `qnn-net-run --backend libQnnCpu.so`

Does **not** work, and the skills will say so rather than failing obscurely:

- on-board context-binary generation
- any real latency, thermal or VTCM number
- HTP-vs-CPU numerical comparison — the check that catches a fast wrong answer

**The trap in D is `QC_HTP_ARCH`.** You cannot read the SoC id without the
board, and you must not guess it from the part number. Leave it empty. A context
binary built for the wrong architecture compiles cleanly and fails at load, and
a guess recorded at setup is trusted by every later step.

---

## Choosing

| If | Pick |
|---|---|
| Linux workstation, board on your desk | **A** |
| Windows or macOS workstation | **B** (or WSL2 → A) |
| No local Linux, or you need a GPU for AIMET | **C** |
| No hardware yet | **D**, and revisit when it arrives |

Re-run `qualcomm-setup` when any of this changes. It re-probes rather than
trusting what the file claims.
