#!/usr/bin/env python3
"""
extract-sdk-docs.py - extract version-correct reference data from an installed
QAIRT/QNN SDK into a local, greppable cache.

Why: the flags, supported operators and SoC->HTP-arch mapping are specific to
the SDK version on disk. The vendor website documents the latest release, which
is usually not yours. Everything needed is already installed - this pulls it out
into files you and Claude can read.

Three layers, most-reliable first. Each is independent: a later layer failing
never costs you an earlier one.

  1. TOOL HELP   capture `--help` for every SDK tool found.  Always works.
  2. OPERATORS   parse op-support tables from the SDK HTML docs. Best-effort -
                 the doc tree's shape varies by release.
  3. MAPPINGS    scrape SoC / HTP-arch identifiers out of the docs. Best-effort.

Output (default ./.qualcomm-docs/<version>/):
    MANIFEST.md            what was extracted, what failed, where to look
    tools/<tool>.txt       raw --help
    tools/flags.json       {tool: [flag, ...]}  for fast "is this flag real?"
    ops/<backend>.json     {backend, source, ops: [...]}   if parseable
    mappings.json          SoC / arch strings found in the docs

Usage:
    python3 extract-sdk-docs.py
    python3 extract-sdk-docs.py --sdk-root /opt/qcom/aistack/qairt/2.37.1.250807
    python3 extract-sdk-docs.py --out /tmp/qdocs

Stdlib only - the SDK's Python environment is often pinned and fragile, so this
deliberately adds no dependencies.
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
from html.parser import HTMLParser

# Tools worth capturing help for. Missing ones are skipped silently - which
# tools exist is itself a fact about the install, recorded in the manifest.
TOOLS = [
    "qnn-onnx-converter",
    "qnn-tensorflow-converter",
    "qnn-pytorch-converter",
    "qnn-tflite-converter",
    "qnn-model-lib-generator",
    "qnn-context-binary-generator",
    "qnn-context-binary-utility",
    "qnn-net-run",
    "qnn-throughput-net-run",
    "qnn-profile-viewer",
    "qnn-platform-validator",
    "qnn-accuracy-debugger",
    "qnn-op-package-generator",
    "qairt-converter",
    "qairt-quantizer",
    "qairt-visualizer",
    "snpe-dlc-info",
]

BACKEND_HINTS = ["htp", "hexagon", "gpu", "dsp", "cpu", "saver", "lpai"]


# --------------------------------------------------------------------------
# layer 1 - tool help
# --------------------------------------------------------------------------

FLAG_RE = re.compile(r"(?<![\w-])(--[A-Za-z][\w-]*)")


def capture_tool_help(sdk_root, out_dir):
    """Run --help for each tool. The one layer that is essentially guaranteed."""
    tools_dir = os.path.join(out_dir, "tools")
    os.makedirs(tools_dir, exist_ok=True)

    search = []
    for sub in ("bin/x86_64-linux-clang", "bin/aarch64-oe-linux-gcc11.2", "bin"):
        d = os.path.join(sdk_root, sub)
        if os.path.isdir(d):
            search.append(d)

    found, missing, flags, failed = {}, [], {}, {}

    for tool in TOOLS:
        exe = None
        for d in search:
            cand = os.path.join(d, tool)
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                exe = cand
                break
        if exe is None:
            from shutil import which
            exe = which(tool)
        if exe is None:
            missing.append(tool)
            continue

        err = None
        try:
            # Many of these print help to stderr and/or exit non-zero.
            p = subprocess.run([exe, "--help"], capture_output=True, text=True,
                               timeout=120)
            text = (p.stdout or "") + (p.stderr or "")
            if not text.strip():
                err = "--help produced no output"
        except Exception as e:                       # noqa: BLE001
            text, err = "", f"could not execute: {e}"

        path = os.path.join(tools_dir, f"{tool}.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"# {tool}\n# from: {exe}\n")
            if err:
                f.write(f"# EXTRACTION FAILED: {err}\n")
            f.write("\n" + (text or ""))

        # A failed capture must NOT produce a flags entry. flags.json is used to
        # answer "is this flag real in my version?", and an empty-but-present
        # entry would answer "no" with false authority. Absent means unknown.
        if err:
            failed[tool] = {"path": exe, "error": err}
            continue

        tool_flags = sorted(set(FLAG_RE.findall(text)))
        flags[tool] = tool_flags
        found[tool] = {"path": exe, "n_flags": len(tool_flags)}

    with open(os.path.join(tools_dir, "flags.json"), "w", encoding="utf-8") as f:
        json.dump(flags, f, indent=2, sort_keys=True)

    return found, missing, flags, failed


# --------------------------------------------------------------------------
# layer 2 - operator tables from the HTML docs
# --------------------------------------------------------------------------

class TableParser(HTMLParser):
    """Collect every <table> as a list of rows of cell text.

    Deliberately tolerant: SDK doc HTML is generated and often not well-formed.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables = []
        self._table = None
        self._row = None
        self._cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "table":
            self._table = []
        elif tag == "tr" and self._table is not None:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = []

    def handle_endtag(self, tag):
        if tag == "table" and self._table is not None:
            if self._table:
                self.tables.append(self._table)
            self._table = None
        elif tag == "tr" and self._row is not None:
            if self._row:
                self._table.append(self._row)
            self._row = None
        elif tag in ("td", "th") and self._cell is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)


# An ONNX-ish operator name: CamelCase, no spaces. Filters out prose cells.
OPNAME_RE = re.compile(r"^[A-Z][A-Za-z0-9_]{1,40}$")


def extract_ops(sdk_root, out_dir):
    """Best-effort operator extraction. Returns (results, notes)."""
    docs_root = os.path.join(sdk_root, "docs")
    notes = []
    if not os.path.isdir(docs_root):
        return {}, [f"no docs directory at {docs_root} - SDK installed without docs?"]

    html_files = glob.glob(os.path.join(docs_root, "**", "*.htm*"), recursive=True)
    if not html_files:
        notes.append(f"no HTML under {docs_root} (found: "
                     f"{sorted({os.path.splitext(f)[1] for f in glob.glob(os.path.join(docs_root,'**','*'), recursive=True) if os.path.isfile(f)})})")
        return {}, notes

    notes.append(f"scanned {len(html_files)} HTML files under docs/")
    results = {}

    # Prefer files whose name suggests operator documentation.
    def rank(p):
        n = os.path.basename(p).lower()
        return (0 if ("op" in n and ("def" in n or "support" in n or "list" in n)) else 1, n)

    for path in sorted(html_files, key=rank):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                raw = f.read()
        except Exception:                            # noqa: BLE001
            continue

        low = raw.lower()
        if "operator" not in low and "op name" not in low:
            continue

        p = TableParser()
        try:
            p.feed(raw)
        except Exception:                            # noqa: BLE001
            continue

        for table in p.tables:
            if len(table) < 3:
                continue
            header = [c.lower() for c in table[0]]
            # Which column holds the operator name?
            col = 0
            for i, h in enumerate(header):
                if "op" in h and ("name" in h or h.strip() in ("op", "operator")):
                    col = i
                    break
            ops = []
            for row in table[1:]:
                if col < len(row) and OPNAME_RE.match(row[col]):
                    ops.append(row[col])
            if len(ops) < 10:            # not an op table
                continue

            backend = "unknown"
            hay = (os.path.basename(path) + " " + " ".join(header)).lower()
            for b in BACKEND_HINTS:
                if b in hay:
                    backend = "htp" if b in ("htp", "hexagon", "dsp") else b
                    break

            entry = results.setdefault(
                backend, {"backend": backend, "sources": [], "ops": []})
            entry["ops"] = sorted(set(entry["ops"]) | set(ops))
            rel = os.path.relpath(path, sdk_root)
            if rel not in entry["sources"]:
                entry["sources"].append(rel)

    if results:
        ops_dir = os.path.join(out_dir, "ops")
        os.makedirs(ops_dir, exist_ok=True)
        for backend, data in results.items():
            with open(os.path.join(ops_dir, f"{backend}.json"), "w",
                      encoding="utf-8") as f:
                json.dump(data, f, indent=2, sort_keys=True)
    else:
        notes.append("no operator tables recognised - the docs may render tables "
                     "via JavaScript, or use a layout this parser does not match. "
                     "Open the docs manually; see MANIFEST.md for candidate files.")

    return results, notes


# --------------------------------------------------------------------------
# layer 3 - SoC / architecture identifiers
# --------------------------------------------------------------------------

SOC_RE = re.compile(r"\b(?:QCS|QCM|SA|SM|SDM|QRB)\d{3,4}\w*\b", re.I)
ARCH_RE = re.compile(r"\bv6[5-9]\b|\bv7[0-9]\b|\bhexagon-v\d+\b", re.I)


def extract_mappings(sdk_root, out_dir):
    """Pull SoC and HTP-arch identifiers out of the docs.

    This reports what the docs MENTION. It deliberately does not invent a
    SoC -> arch mapping: co-occurrence in a file is not a mapping. Use it to
    find the page that states the mapping, then read that page.
    """
    docs_root = os.path.join(sdk_root, "docs")
    socs, archs, where = set(), set(), {}
    if os.path.isdir(docs_root):
        for path in glob.glob(os.path.join(docs_root, "**", "*"), recursive=True):
            if not os.path.isfile(path):
                continue
            if os.path.splitext(path)[1].lower() not in (".htm", ".html", ".txt", ".md", ".json"):
                continue
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f:
                    raw = f.read()
            except Exception:                        # noqa: BLE001
                continue
            s = set(m.group(0).upper() for m in SOC_RE.finditer(raw))
            a = set(m.group(0).lower().replace("hexagon-", "") for m in ARCH_RE.finditer(raw))
            if s or a:
                rel = os.path.relpath(path, sdk_root)
                where[rel] = {"socs": sorted(s), "archs": sorted(a)}
            socs |= s
            archs |= a

    # Architectures the SDK can actually build for - a fact, not a mention.
    buildable = sorted(
        os.path.basename(p.rstrip("/")).replace("hexagon-", "")
        for p in glob.glob(os.path.join(sdk_root, "lib", "hexagon-v*"))
    )

    data = {
        "buildable_htp_archs": buildable,
        "socs_mentioned_in_docs": sorted(socs),
        "archs_mentioned_in_docs": sorted(archs),
        "files": where,
        "WARNING": ("Mentions are not a mapping. Co-occurrence of a SoC and an "
                    "arch in one file does NOT establish that the part uses that "
                    "arch. Open the listed file and read the statement."),
    }
    with open(os.path.join(out_dir, "mappings.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    return data


# --------------------------------------------------------------------------

def sdk_version(sdk_root):
    y = os.path.join(sdk_root, "sdk.yaml")
    if os.path.isfile(y):
        try:
            with open(y, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if line.strip().lower().startswith("version"):
                        return line.split(":", 1)[1].strip()
        except Exception:                            # noqa: BLE001
            pass
    return os.path.basename(sdk_root.rstrip("/\\")) or "unknown"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sdk-root", default=os.environ.get("QNN_SDK_ROOT"))
    ap.add_argument("--out", default=".qualcomm-docs")
    args = ap.parse_args()

    if not args.sdk_root or not os.path.isdir(args.sdk_root):
        sys.exit("ERROR: set QNN_SDK_ROOT or pass --sdk-root <path to QAIRT SDK>")

    sdk_root = os.path.abspath(args.sdk_root)
    version = sdk_version(sdk_root)
    out_dir = os.path.abspath(os.path.join(args.out, version))
    os.makedirs(out_dir, exist_ok=True)

    print(f"SDK     : {sdk_root}")
    print(f"version : {version}")
    print(f"output  : {out_dir}\n")

    print("[1/3] capturing tool --help ...")
    found, missing, flags, failed = capture_tool_help(sdk_root, out_dir)
    print(f"      {len(found)} tools captured, {len(missing)} not present"
          + (f", {len(failed)} FAILED to run" if failed else ""))
    for t, meta in sorted(failed.items()):
        print(f"      ! {t}: {meta['error']}")

    print("[2/3] extracting operator tables ...")
    ops, op_notes = extract_ops(sdk_root, out_dir)
    if ops:
        for b, d in sorted(ops.items()):
            print(f"      {b}: {len(d['ops'])} operators")
    else:
        print("      none parsed (see MANIFEST.md)")

    print("[3/3] scanning for SoC / arch identifiers ...")
    maps = extract_mappings(sdk_root, out_dir)
    print(f"      buildable HTP archs: {', '.join(maps['buildable_htp_archs']) or 'none'}")
    print(f"      SoCs mentioned in docs: {len(maps['socs_mentioned_in_docs'])}")

    # ---- manifest ----
    docs_root = os.path.join(sdk_root, "docs")
    lines = [
        f"# SDK documentation extract - QAIRT {version}",
        "",
        f"- SDK root: `{sdk_root}`",
        f"- Extracted: {__import__('datetime').datetime.now().isoformat(timespec='seconds')}",
        "",
        "Everything here was read from the installed SDK, so it matches **this**",
        "version. Prefer it over the vendor website, which documents the latest",
        "release.",
        "",
        "## Layer 1 - tool help (reliable)",
        "",
        f"{len(found)} tools captured to `tools/`. `tools/flags.json` maps each tool",
        "to its accepted flags - use it to check whether a flag is real in this",
        "version before running a long conversion.",
        "",
        "| Tool | Flags | Path |",
        "|---|---|---|",
    ]
    for t, meta in sorted(found.items()):
        lines.append(f"| `{t}` | {meta['n_flags']} | `{meta['path']}` |")
    if missing:
        lines += ["", f"Not present in this install: {', '.join(f'`{m}`' for m in missing)}"]
    if failed:
        lines += ["",
                  "**These tools exist but `--help` could not be captured.** They are",
                  "deliberately absent from `flags.json`: an empty entry there would",
                  "answer \"is this flag real?\" with false authority. Absent means",
                  "unknown, not unsupported.", "",
                  "| Tool | Error |", "|---|---|"]
        for t, meta in sorted(failed.items()):
            lines.append(f"| `{t}` | {meta['error']} |")

    lines += ["", "## Layer 2 - operators (best-effort)", ""]
    if ops:
        lines += ["| Backend | Operators | Source |", "|---|---|---|"]
        for b, d in sorted(ops.items()):
            lines.append(f"| `{b}` | {len(d['ops'])} | {', '.join(f'`{s}`' for s in d['sources'][:2])} |")
        lines += ["", "Check a model against these with `check-model-ops.py`."]
    else:
        lines.append("**Not extracted.** " + " ".join(op_notes))
        lines += ["", "Read the op-support page by hand:", "",
                  f"```sh", f"find '{docs_root}' -iname '*op*' | head -20", "```"]

    lines += ["", "## Layer 3 - SoC and architecture identifiers", "",
              f"- **Buildable HTP archs** (from `lib/hexagon-v*`): "
              f"`{', '.join(maps['buildable_htp_archs']) or 'none'}` - this is a fact.",
              f"- SoCs mentioned anywhere in the docs: {len(maps['socs_mentioned_in_docs'])}",
              "",
              "> Mentions are **not** a mapping. A SoC and an arch appearing in the",
              "> same file does not establish that the part uses that arch. Use",
              "> `mappings.json` to find the page, then read the page.",
              ""]

    with open(os.path.join(out_dir, "MANIFEST.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\nWrote {os.path.join(out_dir, 'MANIFEST.md')}")


if __name__ == "__main__":
    main()
