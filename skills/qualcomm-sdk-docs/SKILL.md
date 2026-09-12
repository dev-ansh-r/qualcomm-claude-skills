---
name: qualcomm-sdk-docs
description: Extract version-correct reference documentation from an installed QAIRT/QNN SDK - tool flag lists from --help, operator support tables from the SDK HTML docs, and SoC/Hexagon HTP architecture identifiers - into a local greppable cache, then check an ONNX model's operators against it. Use to answer whether a flag exists in your SDK version, whether a model will run on the NPU, which operators a backend supports, what HTP architecture a Qualcomm part needs, or to find Qualcomm documentation for any QCS, QCM, SA, SM or Snapdragon part without a developer account.
---

# Qualcomm SDK documentation extraction

Pulls reference data out of the SDK **you have installed** into
`.qualcomm-docs/<version>/`, so answers match your version rather than whatever
the vendor website currently documents.

## Why extract rather than search the web

| | SDK-local docs | Vendor website |
|---|---|---|
| Version | Exactly yours | Latest release |
| Access | On disk | Usually needs a developer account |
| Op tables | Per backend, per HTP arch | Generic |
| Availability | Offline | Needs the build host to have egress |

Flags, operator support and architecture support all move between QAIRT
releases. A flag that exists in the docs you found on the web and not in your
install is the single most wasteful class of error in this toolchain — you
discover it after a long conversion run, or worse, it is silently ignored.

**Do not start by fetching from the web.** If the SDK is installed, the answer
is already on disk.

## Run it

```sh
source "$QNN_SDK_ROOT/bin/envsetup.sh"
python3 scripts/extract-sdk-docs.py
```

Stdlib only — no pip installs into the SDK's Python environment, which is
usually pinned and fragile.

Produces:

```text
.qualcomm-docs/<version>/
  MANIFEST.md           what was extracted, what failed, where to look by hand
  tools/<tool>.txt      raw --help output per tool
  tools/flags.json      {tool: [flags]} - "is this flag real in my version?"
  ops/<backend>.json    operator lists, when the doc tables could be parsed
  mappings.json         SoC and HTP-arch identifiers found in the docs
```

## Three layers, independently useful

The extractor is deliberately layered so a later failure never costs an earlier
success. **Read `MANIFEST.md` — it states which layers worked.**

### Layer 1 — tool flags (reliable)

Captures `--help` for every SDK tool present. This always works, and it answers
the highest-frequency question in this toolchain.

```sh
# Is this flag real in my version?
python3 -c "import json;d=json.load(open('.qualcomm-docs/<v>/tools/flags.json'));print('--act_bitwidth' in d['qnn-onnx-converter'])"

# What does this tool actually accept?
grep -A2 'act_bitwidth' .qualcomm-docs/<v>/tools/qnn-onnx-converter.txt
```

Use this **before** running a long conversion, and whenever a skill in this repo
disagrees with your install. The captured `--help` wins — including over this
repo.

**`flags.json` over-reports, by design.** It regex-scans the whole help text, so
a flag mentioned in prose — a deprecation note like *"do not pass `--act_bw`"* —
lands in the list too. So:

- a flag **absent** from `flags.json` is strong evidence it does not exist
- a flag **present** is worth confirming in the `.txt`, which is the real output

```sh
grep -B2 -A2 'act_bw' .qualcomm-docs/<v>/tools/qnn-onnx-converter.txt
```

A tool whose `--help` could not be captured is **omitted from `flags.json`
entirely** rather than given an empty list — absent means unknown, not
unsupported. The manifest lists those separately.

### Layer 2 — operator support (best-effort)

Parses op-support tables out of the SDK HTML docs into `ops/<backend>.json`.

Best-effort by nature: the doc tree's structure varies between releases, and
some render tables via JavaScript, which a static parser cannot see. When
parsing fails the manifest says so and points you at the candidate files:

```sh
find "$QNN_SDK_ROOT/docs" -iname '*op*' | head -20
```

That fallback is not a failure of the skill — the op-support page is the right
thing to read, and finding it is most of the work.

### Layer 3 — SoC and architecture identifiers

Records two different things, and the difference matters:

- **`buildable_htp_archs`** — from `lib/hexagon-v*`. A **fact**: what this SDK
  can compile for.
- **`socs_mentioned_in_docs`** — parts named anywhere in the doc tree. A
  **pointer**, not a mapping.

> **Co-occurrence is not a mapping.** A SoC and an architecture appearing in the
> same file does not establish that the part uses that architecture.
> `mappings.json` tells you which file to open; the file tells you the answer.

This matters because Hexagon architecture versions do not track SoC model
numbers in any extrapolable pattern. Guessing costs a full build-deploy cycle to
disprove: the context binary builds cleanly and fails at load.

## Checking a model before you convert

```sh
python3 scripts/check-model-ops.py model.onnx --backend htp
```

Reports, in order of how early it saves you time:

1. **Dynamic shapes** — must be pinned before conversion, whatever the ops say
2. **Structural blockers** — `If`, `Loop`, `Scan`, `NonZero`, `NonMaxSuppression`
   and similar: control flow and data-dependent shapes are a problem on
   fixed-function NPUs regardless of the op table
3. **Operators absent from the backend's table**, when layer 2 succeeded
4. Otherwise, the model's full operator inventory plus where to check by hand

Requires `onnx` (not the SDK's Python — run it wherever you exported the model).

### This is a fast filter, not the authority

A clean report is not a guarantee, and a flagged op is not a verdict:

- The op table is parsed from HTML and can be incomplete
- **Op support and quantization support are different questions.** An operator
  can be supported in float and lack a quantized HTP implementation
- Operator *variants* matter — a supported op with an unsupported attribute
  combination still fails

The authority is the converter:

```sh
qnn-onnx-converter --input_network model.onnx \
    --input_dim <name> <dims> --output_path /tmp/probe.cpp --dry_run
```

Use `check-model-ops.py` to find problems in seconds, `--dry_run` to confirm.

## Keeping the cache honest

- **Re-extract after any SDK upgrade.** The cache is named by version, so
  several can coexist; `check-model-ops.py` defaults to the newest.
- **Do not commit `.qualcomm-docs/`.** It is derived data, it is large, and it
  is specific to one install. The repo `.gitignore` excludes it.
- **Cite the extract, not your memory.** When answering a flag or op question
  from this cache, say which version it came from — the answer is only true for
  that version.

## When the SDK really is unavailable

Only then, and in this order:

1. `--help` on any tool you can reach — still version-exact
2. AIMET docs (`quic.github.io/aimet-pages`) and the `quic/aimet` GitHub repo —
   open source, no account
3. Qualcomm AI Hub model zoo — working export configs for common architectures
4. Qualcomm's developer site — pin the version explicitly, and treat anything
   you find as `[vendor-claimed]` until `--help` confirms it

## Scope

The extraction is **part-agnostic** — it reads whatever SDK and doc tree are
installed, for any Qualcomm target the SDK supports (QCS, QCM, SA, SM, QRB,
Snapdragon). Nothing here assumes a particular part or HTP architecture; that is
precisely what it is for.
