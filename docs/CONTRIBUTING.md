# Contributing

These skills are read by Claude and acted on, often against real hardware. A
confidently-stated wrong number here becomes a wrong command on someone's board.
The conventions below exist for that reason.

## 1. Tag every factual claim with its provenance

| Tag | Means |
|---|---|
| `[measured]` | Someone on the team observed this on real hardware. Name the part and say what was measured |
| `[vendor-claimed]` | From Qualcomm docs, a datasheet or an SOW. Plausible, unverified by us |
| `[inferred]` | Reasoned from the above. May not hold |
| `[convention]` | Engineering judgment or common practice, not a measurement. "~100 calibration samples", "prefer W8A16" |

`[convention]` exists so that defaults and judgments stop being dressed up as
data. A sensible default is worth stating — but a reader deciding whether to
trust it needs to know nobody measured it.

**Never promote a tag without a measurement.** A `[vendor-claimed]` figure that
has been repeated often is still `[vendor-claimed]`.

Numbers most at risk of quiet promotion, because they sound authoritative:

- per-context VTCM footprint and concurrent-context limits
- TOPS ratings and sustained-vs-peak throughput
- thermal thresholds and throttling behaviour
- op support on a given HTP architecture version

All of these are part- and workload-specific. If a skill needs one, state how to
measure it rather than asserting a value.

## 2. Nothing machine-specific, ever

These skills ship to other developers. **No IPs, hostnames, usernames, absolute
paths into someone's home directory, model names, or project names.**

Endpoints come from `.qualcomm-env`, written by `qualcomm-env-discovery`. Paths
come from `$QNN_SDK_ROOT` and friends.

Where an example needs a concrete value, make it obviously a placeholder
(`<eSDK>`, `$QC_BOARD_HOST`). An IP address in an example gets copied.

A useful test before committing: *would this line still be correct for a
developer on a different board in a different company?* If not, it belongs in
that project's `CLAUDE.md`, not here.

## 3. Verify commands against the tool, not against memory

Every flag in this repo should have been run, or read from `--help` on an
installed SDK. Flags move between QAIRT majors, and plausible-looking wrong
flags are worse than missing ones.

Real example: `--act_bw` / `--weight_bw` circulate widely in internal scripts.
`qnn-onnx-converter` accepts `--act_bitwidth` / `--weights_bitwidth`. A script
using the former either errors, or silently produces an unquantized model that
everyone believes is W8A16.

When you cannot verify, say so in the text rather than omitting the caveat.

## 4. Scope claims to the version they were verified on

The repo is part-agnostic; its examples were verified on **QAIRT 2.37.x / QCS6490
/ HTP v68**. When you add something
verified elsewhere, name the version inline. The *flow* generally transfers
across parts; the *numbers and op support* do not.

## 5. Write failure modes, not tutorials

Qualcomm's own documentation covers the happy path adequately. The value here is
the rest:

- commands that **exit 0 and produce nothing**
- flags that are silently ignored
- artifacts that build on the host and fail at load on the board
- results that look right and are wrong

Prefer a symptom table over prose. People arrive at these skills mid-failure.

## 6. Keep skills self-contained

A developer may copy one skill directory and not the rest. Cross-references
between skills are fine as pointers, but a skill should not be *unusable*
without its siblings. Where a fact is genuinely shared and critical — the
environment-setup order is the main one — restate it briefly inline and link for
the full rationale.

## 7. Frontmatter

```yaml
---
name: <directory name, exactly>
description: <what it does, then when to use it, in trigger terms>
---
```

The description is what Claude matches on. Write it in terms of **the task the
developer has** (`qnn-onnx-converter fails`, `model runs but accuracy dropped`),
not a topic label. Include the tool names and error phrases people actually
type. Aim for 300–500 characters.

## Before you commit

- [ ] Every number carries a provenance tag
- [ ] No IPs, hostnames, usernames, home paths, project names
- [ ] Flags verified against `--help` on a real install, or caveated
- [ ] Version scope stated where it matters
- [ ] Referenced `scripts/` and `references/` files exist
- [ ] `bash -n` clean on shell scripts, `ast.parse` clean on Python
- [ ] Frontmatter `name` matches the directory name
