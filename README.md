# Claude Skills for Qualcomm QAIRT / Hexagon HTP

A set of Claude Code skills for developers taking a model from ONNX to running
on Qualcomm silicon (Hexagon HTP / NPU), and for cross-compiling the
application that loads it.

**Part-agnostic.** The workflow is the same across QCS, QCM, SA, SM, QRB and
Snapdragon parts — what changes is the Hexagon architecture version, the
operator support that follows from it, and the eSDK toolchain. The skills
*determine* those for your target rather than assuming them. Nothing is
hardcoded to one part.

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

Start with `qualcomm-env-discovery`. It writes a `.qualcomm-env` config that
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
| **Target board** | Qualcomm SoC, Hexagon HTP | Typically an immutable OSTree image: no gcc/cmake/git on-device |

A single machine can hold more than one role. The skills never assume it does.

## Two independent choices — read this before picking a skill

A frequent misconception is that AIMET belongs to one conversion route. It does
not. **These are two orthogonal decisions**, and you make both:

### Choice 1 — where the quantization ranges come from

| Source | How | When |
|---|---|---|
| Converter-internal | `--input_list` of real calibration vectors | Bring-up; simple models |
| **AIMET** | `--quantization_overrides model.encodings` | Accuracy-critical; AdaRound; per-op control |
| **Both together** | pass `--quantization_overrides` **and** `--input_list` | The proven production recipe `[measured]` |

**Both converters accept `--quantization_overrides`** — `qnn-onnx-converter` as
well as `qairt-converter`. AIMET is not tied to either route.

Passing both is not redundant: the encodings supply the ranges AIMET computed,
and `--input_list` supplies real data for whatever the encodings do not cover.

### Choice 2 — which conversion route, and where the context binary is built

```text
                    ONNX (static shapes, HTP-native ops)
                                    |
                    quantization source (choice 1)
                    --input_list and/or --quantization_overrides
                                    |
              +---------------------+---------------------+
              |                                           |
      CLASSIC / model-lib                          QAIRT / DLC
              |                                           |
     qnn-onnx-converter                          qairt-converter
              |                                           |
     model.cpp + model.bin                          model.dlc
              |                                           |
     qnn-model-lib-generator                     qairt-quantizer
     -t aarch64-oe-linux-gcc11.2                          |
              |                                  model_quantized.dlc
        libmodel.so                                       |
              |                             qnn-context-binary-generator
     copy .so to the board                     --dlc_path   (on the HOST)
              |                                            |
     qnn-context-binary-generator                          |
       --model ./libmodel.so   (ON THE BOARD)              |
              |                                            |
              +---------------------+----------------------+
                                    |
                            model_htp.bin
```

Both routes end at a context binary. The real differences:

| | Classic (`qnn-model-export`) | QAIRT/DLC (`qnn-context-binary`) |
|---|---|---|
| Intermediate | `.cpp` / `.bin` / `.so` | `.dlc` |
| Context binary built | On the board, from the `.so` | On the host, from the DLC |
| Needs cross-compile | **Yes** — `.so` must be built for the board | No |
| Inspectability | High — the `.cpp` records the full resolved namespace | Lower |
| Also runnable as | `qnn-net-run --model libmodel.so` | `qnn-net-run --retrieve_context *.bin` |

**Recommendation:** use whichever route your team already has working. If
starting fresh, the classic route is easier to debug — the generated `.cpp`
records exactly which options the converter resolved, which settles most
"did my settings take effect?" questions in seconds.

### A third choice you cannot skip: float fallback

`--float_fallback` lets ops with no quantized implementation run in float. That
is sound on architectures with FP16 — and **actively breaks Hexagon v68, which
has none**: the op becomes FP16, the HTP cannot execute it, and context
generation aborts with exit 134 `[measured]`.

On v68 the working recipe is **all-quantized, no float fallback**, then audit
the generated `.cpp` for zero FP16 tensors. Make the graph quantizable instead
of letting ops escape into float — see the graph-adapt section in
`qnn-model-export`.

Check your target's architecture before taking either default.

## The skills

| Skill | Does | Host |
|---|---|---|
| `qualcomm-env-discovery` | Find board + servers, verify versions and SoC/HTP arch, write `.qualcomm-env` | local |
| `qualcomm-sdk-preflight` | Check SDK deps are complete and usable | build host |
| `qualcomm-sdk-docs` | Extract flags, op tables and arch mappings from *your* SDK; check a model's ops | build host |
| `qnn-model-export` | Classic flow: static shapes → converter → model-lib-generator | build host |
| `aimet-quantization` | quantsim, AdaRound, PTQ, mixed precision → `.encodings` | AIMET host |
| `qualcomm-cross-compile` | Cross-compile the application against the eSDK | build host |
| `qnn-context-binary` | qairt-converter → quantizer → context binary → deploy | build host + board |

## Conventions used throughout

**Provenance tags.** Every number in these skills carries its evidence class.
Do not promote one to another without a measurement.

- `[measured]` — observed on real hardware by someone on the team; the part is
  named where it matters
- `[vendor-claimed]` — from Qualcomm docs, an SOW, or a datasheet; unverified
- `[inferred]` — reasoned from the above; may not hold
- `[convention]` — engineering judgment or common practice, not a measurement

**Nothing in this repo has been executed end-to-end against hardware as part of
authoring it.** The commands and flags were taken from working notebooks and
scripts; the shell and Python here pass syntax checks, which is not the same as
being run. Treat the first execution on your setup as a verification pass, and
fix what you find — see `docs/CONTRIBUTING.md`.

**Version scope.** The *flow* is part-agnostic. The *examples* were verified
against **QAIRT 2.37.x** on a **QCS6490 (Hexagon HTP v68)** with eSDK toolchain
`aarch64-oe-linux-gcc11.2`, because that is the setup this repo has evidence
from. Where a concrete value appears, it is an example — the skill tells you how
to determine yours.

Two things that do **not** transfer between parts, and that the skills therefore
never assume:

- **Hexagon architecture version.** It does not track SoC model numbers in any
  extrapolable pattern. Determine it from the board's SoC id and your SDK-local
  docs (`qualcomm-sdk-docs`); a wrong guess builds cleanly and fails at load.
- **Operator support.** It is per HTP architecture. Extract the table for your
  target rather than reusing one from another part.

Flags and tool names also move between QAIRT majors, so every skill re-checks
the installed version before trusting its own examples.
