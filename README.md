# Claude Skills for Qualcomm QCS6490 / QAIRT

A set of Claude Code skills for developers taking a model from ONNX to running
on a Qualcomm QCS6490 (Hexagon HTP), and for cross-compiling the application
that loads it.

These skills encode the parts of the workflow that are **not** in the Qualcomm
docs: which of the two toolchain flows to use, the flags that actually work,
and the failure modes that exit 0 while producing nothing.

## Install

Skills load from `~/.claude/skills/` (personal) or `<repo>/.claude/skills/`
(project). This repo is the **source**; installing is a separate step.

```sh
# Personal — available in every project
cp -r skills/* ~/.claude/skills/

# Or per-project
mkdir -p /path/to/your/project/.claude/skills
cp -r skills/* /path/to/your/project/.claude/skills/
```

Verify with `/skills` in Claude Code. Each skill is self-contained — copy only
the ones you need.

## First run

Start with `qcs6490-env-discovery`. It writes a `.qualcomm-env` config that
every other skill reads, so you name your machines once.

**No skill in this repo contains a hardcoded IP, hostname, or SDK path.**
Endpoints are discovered or read from config. Any address you see in an example
is a placeholder.

## The three machines

The workflow spans up to three hosts. They are frequently different boxes, and
conflating them is a common source of "works on my machine".

| Role | Runs | Why separate |
|---|---|---|
| **AIMET host** | `aimet-onnx` / `aimet-torch` quantsim, AdaRound | Heavy deps, often GPU, pinned torch/onnx versions that fight the SDK's |
| **Build host** | QAIRT SDK (`x86_64-linux-clang`), Yocto/QIRP eSDK | x86_64 only — the converters have no aarch64 build |
| **Target board** | QCS6490, Hexagon HTP | Typically an immutable OSTree image: no gcc/cmake/git on-device |

A single machine can hold more than one role. The skills never assume it does.

## The fork — read this before choosing a skill

QAIRT ships **two distinct flows**. They are not interchangeable, and the one
you pick determines whether AIMET is even in the picture.

```text
                        ONNX (static shapes)
                                 |
              +------------------+------------------+
              |                                     |
     CLASSIC / model-lib                    QAIRT / DLC
              |                                     |
   qnn-onnx-converter                     [ aimet-quantization ]
   (quantizes inline from                  quantsim / AdaRound
    a calibration --input_list)                     |
              |                              *.encodings
   model.cpp + model.bin                             |
              |                          qairt-converter
   qnn-model-lib-generator                --quantization_overrides
   -t aarch64-oe-linux-gcc11.2                       |
              |                                  model.dlc
        libmodel.so                                  |
              |                          qairt-quantizer --float_fallback
              |                                       |
              |                          model_quantized.dlc
              |                                       |
              |                       qnn-context-binary-generator
              |                        --model libQnnModelDlc.so
              |                        --backend libQnnHtp.so
              |                                       |
              |                               model_htp.bin
              +------------------+------------------+
                                 |
                          runs on the board
```

**AIMET feeds the right-hand path only.** `.encodings` is consumed by
`qairt-converter --quantization_overrides`. There is no supported way to hand an
AIMET `.encodings` file to `qnn-onnx-converter` — that converter derives its own
quantization from the calibration `--input_list` you give it.

So these are **alternative quantization sources converging on the board**, not
sequential stages of one chain.

### Which one should I use?

| | Classic (`qnn-model-export`) | QAIRT/DLC (`qnn-context-binary`) |
|---|---|---|
| Quantization control | Converter-internal (`tf`, percentile) | Full — AIMET quantsim, AdaRound, per-op mixed precision |
| Artifact on device | `libmodel.so` | `model_htp.bin` context binary |
| Load time on device | Graph build at load | Pre-compiled — fastest cold start |
| Iteration speed | Fast, one command | Slower, three stages |
| Best for | Bring-up, "does it run at all", quick A/B | Production deployment, accuracy-critical models |

**Recommendation:** use the classic flow to prove the model converts and runs,
then move to the QAIRT/DLC path for anything you ship. A pre-compiled context
binary is what you want resident on a thermally-constrained device.

## The skills

| Skill | Does | Host |
|---|---|---|
| `qcs6490-env-discovery` | Find board + servers, verify versions, write `.qualcomm-env` | local |
| `qualcomm-sdk-preflight` | Check SDK deps are complete; locate docs for *your* version | build host |
| `qnn-model-export` | Classic flow: static shapes → converter → model-lib-generator | build host |
| `aimet-quantization` | quantsim, AdaRound, PTQ, mixed precision → `.encodings` | AIMET host |
| `qcs6490-cross-compile` | Cross-compile the application against the eSDK | build host |
| `qnn-context-binary` | qairt-converter → quantizer → context binary → deploy | build host + board |

## Conventions used throughout

**Provenance tags.** Every number in these skills carries its evidence class.
Do not promote one to another without a measurement.

- `[measured]` — observed on a QCS6490 by someone on the team
- `[vendor-claimed]` — from Qualcomm docs, an SOW, or a datasheet; unverified
- `[inferred]` — reasoned from the above; may not hold
- `[convention]` — engineering judgment or common practice, not a measurement

**Nothing in this repo has been executed end-to-end against hardware as part of
authoring it.** The commands and flags were taken from working notebooks and
scripts; the shell and Python here pass syntax checks, which is not the same as
being run. Treat the first execution on your setup as a verification pass, and
fix what you find — see `docs/CONTRIBUTING.md`.

**Version scope.** Verified against **QAIRT 2.37.x**, target **QCS6490 /
Hexagon HTP v68**, eSDK toolchain `aarch64-oe-linux-gcc11.2`. Flags and tool
names move between QAIRT majors. Every skill re-checks the installed version
before it trusts its own examples — `qcs6490-env-discovery` is what does that.

Newer parts (QCS8550, SA8295, Snapdragon X) use the same tools but different
HTP architecture versions and op support. The *flow* transfers; the *numbers* do
not.
