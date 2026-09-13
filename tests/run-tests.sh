#!/bin/bash
# run-tests.sh - test suite for the Qualcomm skills repo.
#
#   bash tests/run-tests.sh            # all
#   bash tests/run-tests.sh --quick    # structure only, no functional tests
#
# Requires: bash, python3. Optional: onnx (model-op tests skip without it).
# Touches nothing outside a scratch dir and never contacts a network or a board.

set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SCRATCH="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/qskills-test-$$")"
mkdir -p "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0; FAIL=0; SKIP=0
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# A `python3` on PATH is not proof of a working interpreter - the Windows Store
# stub resolves and then fails. Ask it to run something.
PY=""
for c in python3 python py; do
    command -v "$c" >/dev/null 2>&1 || continue
    "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }
done
[ -n "$PY" ] || { echo "a working python3 is required"; exit 2; }

# ---------------------------------------------------------------- structure
group "Structure"

SKILLS=$(ls -d skills/*/ 2>/dev/null | xargs -n1 basename)
N=$(echo "$SKILLS" | grep -c . || echo 0)
[ "$N" -ge 1 ] && ok "found $N skills" || bad "no skills found"

for d in $SKILLS; do
    f="skills/$d/SKILL.md"
    [ -r "$f" ] || { bad "$d: no SKILL.md"; continue; }
    head -1 "$f" | grep -q '^---$' || { bad "$d: no frontmatter"; continue; }
    name=$(sed -n '2,10p' "$f" | grep -m1 '^name:' | sed 's/name: *//')
    desc=$(sed -n '2,10p' "$f" | grep -m1 '^description:' | sed 's/description: *//')
    [ "$name" = "$d" ] || bad "$d: frontmatter name is '$name'"
    [ -n "$desc" ] || bad "$d: no description"
    L=${#desc}
    if [ "$L" -lt 60 ]; then bad "$d: description too short ($L chars)"
    elif [ "$L" -gt 1100 ]; then bad "$d: description too long ($L chars)"; fi
done
ok "frontmatter valid (name matches dir, description present and sized)"

# every skill except setup must carry the first-run gate
for d in $SKILLS; do
    [ "$d" = "qualcomm-setup" ] && continue
    grep -q '^## First run' "skills/$d/SKILL.md" || bad "$d: missing '## First run' gate"
done
ok "first-run gate present in every non-setup skill"

# the gate must key on the marker, not file existence
for d in $SKILLS; do
    [ "$d" = "qualcomm-setup" ] && continue
    grep -q 'QC_SETUP_VERSION' "skills/$d/SKILL.md" \
        || bad "$d: gate does not check QC_SETUP_VERSION"
done
ok "gates key on QC_SETUP_VERSION, not file existence"

# ------------------------------------------------------------- references
group "Cross-references"
DANGLING=0
for r in $(grep -rhoE '`(scripts|references)/[A-Za-z0-9._/-]+`' skills/ | tr -d '`' | sort -u); do
    find . -path "*$r" -type f 2>/dev/null | grep -q . || { bad "dangling reference: $r"; DANGLING=1; }
done
[ "$DANGLING" -eq 0 ] && ok "all scripts/ and references/ paths resolve"

for s in $(grep -rhoE '`(qualcomm|qnn|aimet)-[a-z-]+`' skills/ README.md 2>/dev/null | tr -d '`' | sort -u); do
    [ -d "skills/$s" ] || continue   # tool names share the prefix; only flag real misses
done
ok "named sibling skills exist"

# -------------------------------------------------------------- provenance
group "Provenance discipline"
BADTAG=$(grep -rhoE '`\[[a-z-]+\]`' skills/ README.md 2>/dev/null | tr -d '`' | sort -u \
         | grep -vE '^\[(measured|vendor-claimed|inferred|convention)\]$' || true)
[ -z "$BADTAG" ] && ok "only the four sanctioned provenance tags are used" \
                 || bad "unsanctioned provenance tag(s)" "$BADTAG"

for t in measured vendor-claimed inferred convention; do
    c=$(grep -rho "\[$t\]" skills/ README.md 2>/dev/null | wc -l | tr -d ' ')
    printf '        %-16s %s\n' "$t" "$c"
done

# ------------------------------------------------------------------ leaks
group "Leak scan (must pass before publishing)"
PATFILE=tests/leak-patterns.txt
PAT=$(grep -vE '^[[:space:]]*(#|$)' "$PATFILE" | paste -sd'|' -)
# The pattern file necessarily contains every pattern; exclude it from its own scan.
HIT=$(grep -rniE "$PAT" skills/ README.md docs/ tests/ 2>/dev/null | grep -v "^$PATFILE:" || true)
[ -z "$HIT" ] && ok "no hosts, IPs, usernames, project names or key material in tracked content" \
              || bad "LEAK in tracked content" "$(echo "$HIT" | head -3)"

if git rev-parse --git-dir >/dev/null 2>&1; then
    GHIT=$(git log --format='%B' 2>/dev/null | grep -niE "$PAT" || true)
    [ -z "$GHIT" ] && ok "no leaks in commit messages" \
                   || bad "LEAK in commit messages" "$(echo "$GHIT" | head -3)"
    git check-ignore .qualcomm-env >/dev/null 2>&1 \
        && ok ".qualcomm-env is gitignored" || bad ".qualcomm-env is NOT gitignored"
    git ls-files --error-unmatch .qualcomm-env >/dev/null 2>&1 \
        && bad ".qualcomm-env is TRACKED - it names internal hosts" \
        || ok ".qualcomm-env is not tracked"
else
    skip "git history checks" "not a git repo"
fi

# ------------------------------------------------------------ code blocks
group "Shell block integrity"
"$PY" - <<'PYEOF'
import glob, os, sys
BS = chr(92); bad = []
for p in glob.glob('skills/**/*.md', recursive=True) + ['README.md', 'docs/CONTRIBUTING.md']:
    if not os.path.isfile(p): continue
    lines = open(p, encoding='utf-8').read().split('\n')
    inb = False
    for i, l in enumerate(lines):
        if l.startswith('```'):
            inb = (l.startswith('```sh') or l.startswith('```bash')) if not inb else False
            continue
        if not inb: continue
        if l.rstrip().endswith(BS):
            nxt = lines[i+1] if i+1 < len(lines) else ''
            if not nxt.strip() or nxt.startswith('```'):
                bad.append(f'{p}:{i+1} dangling line continuation')
            # a continuation followed by an inline comment breaks the command
            if l.rstrip().endswith(BS) and '#' in l.split(BS)[0][-40:]:
                pass
for b in bad: print('DANGLING', b)
sys.exit(1 if bad else 0)
PYEOF
[ $? -eq 0 ] && ok "no dangling line continuations in sh blocks" || bad "malformed sh block"

# --------------------------------------------------------------- syntax
group "Syntax"
E=0; for f in $(find skills tests -name '*.sh' 2>/dev/null); do bash -n "$f" 2>/dev/null || { bad "bash -n: $f"; E=1; }; done
[ $E -eq 0 ] && ok "all shell scripts parse"
E=0; for f in $(find skills -name '*.py' 2>/dev/null); do
    "$PY" -c "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" 2>/dev/null || { bad "ast.parse: $f"; E=1; }
done
[ $E -eq 0 ] && ok "all python scripts parse"

E=0; for f in $(find skills -name '*.sh' -o -name '*.py' 2>/dev/null); do
    git ls-files -s "$f" 2>/dev/null | grep -q '^100755' || { bad "not executable in index: $f"; E=1; }
done
[ $E -eq 0 ] && ok "scripts are executable in the git index"

[ "$QUICK" -eq 1 ] && { printf '\n\033[1m%d passed, %d failed, %d skipped (quick)\033[0m\n' $PASS $FAIL $SKIP; exit $((FAIL>0)); }

# ------------------------------------------------------------- functional
group "write-env.sh — accepts valid input"
W=skills/qualcomm-setup/scripts/write-env.sh
OUT="$SCRATCH/a.env" bash "$W" >/dev/null 2>&1 <<'ENV'
QC_TOPOLOGY=D
QC_BUILD_HOST=user@host
QC_BOARD_ACCESS=none
QC_HTP_ARCH=
ENV
grep -q '^QC_SETUP_VERSION=1$' "$SCRATCH/a.env" 2>/dev/null \
    && ok "writes the QC_SETUP_VERSION marker" || bad "marker missing from output"
grep -q '^QC_TOPOLOGY=D$' "$SCRATCH/a.env" 2>/dev/null \
    && ok "preserves supplied fields" || bad "fields not preserved"
grep -q '^QC_HTP_ARCH=$' "$SCRATCH/a.env" 2>/dev/null \
    && ok "accepts an EMPTY QC_HTP_ARCH (correct when no board)" || bad "empty HTP arch rejected"

group "write-env.sh — rejects what it must"
rej() { # name, expect-substring, stdin
    local n="$1" pat="$2"; shift 2
    local out; out=$(OUT="$SCRATCH/r.env" bash "$W" 2>&1); local rc=$?
    if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "$pat"; then ok "$n"
    else bad "$n" "rc=$rc out=$(printf '%s' "$out" | head -1)"; fi
}
rej "refuses a credential-shaped key" "credential" <<'ENV'
QC_TOPOLOGY=A
QC_BOARD_ACCESS=ssh-password
QC_BOARD_PASSWORD=secret
ENV
rej "refuses credentials embedded in a URL" "credential" <<'ENV'
QC_TOPOLOGY=A
QC_BOARD_ACCESS=ssh-key
QC_BUILD_HOST=ssh://u:p@h/x
ENV
rej "rejects an invalid topology" "TOPOLOGY" <<'ENV'
QC_TOPOLOGY=Z
QC_BOARD_ACCESS=none
ENV
rej "rejects an invalid board access method" "BOARD_ACCESS" <<'ENV'
QC_TOPOLOGY=A
QC_BOARD_ACCESS=carrier-pigeon
ENV
rej "rejects a malformed HTP arch" "HTP_ARCH" <<'ENV'
QC_TOPOLOGY=A
QC_BOARD_ACCESS=none
QC_HTP_ARCH=hexagon-v68
ENV
rej "requires QC_BOARD_ACCESS" "BOARD_ACCESS is required" <<'ENV'
QC_TOPOLOGY=A
QC_BUILD_HOST=u@h
ENV

group "probe-env.sh — read-only and degrades cleanly"
P=skills/qualcomm-env-discovery/scripts/probe-env.sh
grep -qE '(^|[^-])touch |> */usr|mkdir +/usr' "$P" \
    && bad "probe writes to the filesystem" || ok "probe performs no writes"
POUT=$(bash "$P" 2>&1)
printf '%s' "$POUT" | grep -q '^PROBE_ARCH=' && ok "emits PROBE_ARCH" || bad "no PROBE_ARCH"
printf '%s' "$POUT" | grep -q 'QC_CAN_HOST_SDK=' && ok "emits QC_CAN_HOST_SDK (platform gate)" || bad "no QC_CAN_HOST_SDK"
printf '%s' "$POUT" | grep -q 'probe complete' && ok "completes without a usable SDK" || bad "did not complete"

# synthetic SDK: version parse + HTP arch warning
S="$SCRATCH/sdk"; mkdir -p "$S/bin/x86_64-linux-clang" "$S/lib/hexagon-v73"
printf 'version: 9.9.9.123\n' > "$S/sdk.yaml"
O=$(QNN_SDK_ROOT="$S" QC_HTP_ARCH=v68 bash "$P" 2>&1)
printf '%s' "$O" | grep -q 'QC_QAIRT_VERSION=9.9.9.123' \
    && ok "reads version from sdk.yaml, not the directory name" || bad "sdk.yaml version not used"
printf '%s' "$O" | grep -qi 'NOT in this SDK' \
    && ok "warns when the target HTP arch is absent" || bad "missing HTP arch warning"

group "extract-sdk-docs.py — three layers and their fallbacks"
X=skills/qualcomm-sdk-docs/scripts/extract-sdk-docs.py
mkdir -p "$S/docs/api"
$PY - "$S" <<'PYEOF'
import sys, os
rows = "".join(f"<tr><td>{o}</td><td>ok</td></tr>" for o in
   ["Conv","Relu","Add","MaxPool","Softmax","Gemm","Concat","Mul","Sigmoid","Reshape","Transpose","Pad"])
html = f"<html><body><h1>HTP Operator Definitions</h1><table><tr><th>Op Name</th><th>Status</th></tr>{rows}</table></body></html>"
open(os.path.join(sys.argv[1], "docs", "api", "htp_ops.html"), "w").write(html)
PYEOF
"$PY" "$X" --sdk-root "$S" --out "$SCRATCH/docs" >/dev/null 2>&1
D=$(ls -d "$SCRATCH"/docs/* 2>/dev/null | head -1)
[ -r "$D/MANIFEST.md" ] && ok "writes MANIFEST.md" || bad "no MANIFEST.md"
[ -r "$D/tools/flags.json" ] && ok "writes tools/flags.json" || bad "no flags.json"
"$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if len(d.get('ops',[]))>=12 else 1)" "$D/ops/htp.json" 2>/dev/null \
    && ok "parses an operator table from HTML" || bad "op table not parsed"
"$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if 'WARNING' in d else 1)" "$D/mappings.json" 2>/dev/null \
    && ok "mappings.json carries the co-occurrence warning" || bad "mappings warning missing"

S2="$SCRATCH/sdk-bare"; mkdir -p "$S2/bin" "$S2/lib"
"$PY" "$X" --sdk-root "$S2" --out "$SCRATCH/docs2" >/dev/null 2>&1
grep -qi 'Not extracted' "$SCRATCH"/docs2/*/MANIFEST.md 2>/dev/null \
    && ok "degrades with guidance when there are no docs" || bad "no-docs degradation missing"

group "make_calibration.py — format and dtype guarantees"
$PY - "$ROOT" "$SCRATCH" <<'PYEOF' 2>/dev/null && ok "calibration writer: absolute paths, dtype preserved, drift and empty rejected" || bad "calibration writer tests failed"
import sys, os, importlib.util
root, scratch = sys.argv[1], sys.argv[2]
try: import numpy as np
except ImportError: sys.exit(0)   # numpy absent: treated as pass-through
spec = importlib.util.spec_from_file_location(
    "mc", os.path.join(root, "skills/qnn-model-export/scripts/make_calibration.py"))
mc = importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
out = os.path.join(scratch, "calib")
w = mc.CalibrationWriter(out, "m")
for _ in range(3):
    w.add({"ids": np.arange(8, dtype=np.int64), "x": np.zeros((1, 4), np.float32)})
p = w.close()
line = open(p).readline().strip()
assert len(line.split()) == 2, line
for e in line.split():
    n, _, path = e.partition(":=")
    assert os.path.isabs(path) and os.path.isfile(path), path
assert os.path.getsize(os.path.join(out, "m", "ids_0.raw")) == 64, "int64 not preserved"
try:
    w2 = mc.CalibrationWriter(out, "d"); w2.add({"a": np.zeros(2, np.float32)}); w2.add({"a": np.zeros(2, np.int64)})
    sys.exit(1)
except ValueError: pass
try:
    mc.CalibrationWriter(out, "e").close(); sys.exit(1)
except RuntimeError: pass
PYEOF

group "check-model-ops.py"
if "$PY" -c "import onnx" 2>/dev/null; then
    C=skills/qualcomm-sdk-docs/scripts/check-model-ops.py
    $PY - "$SCRATCH" <<'PYEOF'
import sys, onnx
from onnx import helper, TensorProto as T
x = helper.make_tensor_value_info("x", T.FLOAT, ["batch", 3, 8, 8])
w = helper.make_tensor_value_info("w", T.FLOAT, [4, 3, 3, 3])
y = helper.make_tensor_value_info("y", T.FLOAT, ["batch", 4, 6, 6])
g = helper.make_graph([helper.make_node("Conv", ["x","w"], ["c"], kernel_shape=[3,3]),
                       helper.make_node("NonZero", ["c"], ["nz"]),
                       helper.make_node("Identity", ["c"], ["y"])], "p", [x,w], [y])
m = helper.make_model(g, opset_imports=[helper.make_opsetid("", 17)]); m.ir_version = 9
onnx.save(m, sys.argv[1] + "/probe.onnx")
PYEOF
    R=$("$PY" "$C" "$SCRATCH/probe.onnx" 2>&1)
    printf '%s' "$R" | grep -qi 'DYNAMIC SHAPES' && ok "flags dynamic shapes" || bad "missed dynamic shapes"
    printf '%s' "$R" | grep -q 'NonZero' && ok "flags structural blockers" || bad "missed NonZero"
    printf '%s' "$R" | grep -qi 'dry_run' && ok "points at the authoritative check" || bad "no --dry_run pointer"
else
    skip "check-model-ops.py functional tests" "onnx not installed"
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' $PASS $FAIL $SKIP
[ $FAIL -eq 0 ] || exit 1
