#!/bin/bash
# build-context-binary.sh - ONNX (+ AIMET .encodings) -> HTP context binary.
#
# Wraps the three QAIRT stages and turns their silent failures into loud ones.
# Nothing here is board-specific; endpoints come from .qualcomm-env.
#
#   ./build-context-binary.sh model.onnx [model.encodings]
#
# Env:
#   QNN_SDK_ROOT   required (or set in .qualcomm-env)
#   QC_HTP_ARCH    target Hexagon arch, e.g. v68. Verified, not assumed.
#   OUT_DIR        default ./context_binaries
#   FLOAT_FALLBACK 1 to pass --float_fallback. OFF by default, deliberately:
#                  on Hexagon v68 an op left "float" becomes FP16, which that
#                  HTP cannot run - ctx-gen then aborts (exit 134). [measured]

set -euo pipefail

WORK="$(pwd)"                       # capture BEFORE sourcing anything
OUT_DIR="${OUT_DIR:-$WORK/context_binaries}"

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

[ $# -ge 1 ] || die "usage: $0 <model.onnx> [model.encodings]"

ONNX="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"   # absolutise
ENCODINGS=""
if [ $# -ge 2 ]; then
    ENCODINGS="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
fi
MODEL="$(basename "${ONNX%.onnx}")"

[ -r "$ONNX" ] || die "no such ONNX: $ONNX"

# ---------- config ----------
for cfg in "$WORK/.qualcomm-env" "$HOME/.qualcomm-env"; do
    # shellcheck disable=SC1090
    [ -r "$cfg" ] && { . "$cfg"; echo "config: $cfg"; break; }
done
QNN_SDK_ROOT="${QNN_SDK_ROOT:-${QC_QNN_SDK_ROOT:-}}"
[ -n "$QNN_SDK_ROOT" ] || die "QNN_SDK_ROOT unset. Run qualcomm-env-discovery."

# ---------- environment, in the load-bearing order ----------
step "Environment"
unset LD_LIBRARY_PATH
# shellcheck disable=SC1091
source "$QNN_SDK_ROOT/bin/envsetup.sh"
cd "$WORK"                          # sourcing can move us

for t in qairt-converter qairt-quantizer qnn-context-binary-generator; do
    command -v "$t" >/dev/null 2>&1 || die "$t not on PATH - sourced in the wrong order?"
done
echo "QAIRT   : $QNN_SDK_ROOT"
echo "model   : $MODEL"
echo "out     : $OUT_DIR"

# ---------- HTP arch must exist BEFORE we build ----------
step "HTP architecture"
AVAIL=""
for d in "$QNN_SDK_ROOT"/lib/hexagon-v*/; do
    [ -d "$d" ] || continue
    AVAIL="${AVAIL:+$AVAIL }$(basename "$d")"
done
[ -n "$AVAIL" ] || die "no hexagon-v* libraries in the SDK - HTP backend cannot build"
echo "available: $AVAIL"
if [ -n "${QC_HTP_ARCH:-}" ]; then
    case "$AVAIL" in
        *"hexagon-$QC_HTP_ARCH"*) echo "target   : $QC_HTP_ARCH (present)" ;;
        *) die "target HTP arch '$QC_HTP_ARCH' absent. The binary would build and then fail to LOAD on the board." ;;
    esac
else
    echo "WARNING: QC_HTP_ARCH unset - cannot verify the binary matches your part" >&2
fi

mkdir -p "$OUT_DIR"

# ---------- stage 1 ----------
step "1/3  qairt-converter -> DLC"
CONV_LOG="$OUT_DIR/${MODEL}_convert.log"
if [ -n "$ENCODINGS" ]; then
    [ -r "$ENCODINGS" ] || die "no such encodings: $ENCODINGS"
    echo "applying AIMET encodings: $ENCODINGS"
    qairt-converter \
        --input_network          "$ONNX" \
        --quantization_overrides "$ENCODINGS" \
        --output_path            "$OUT_DIR/${MODEL}.dlc" 2>&1 | tee "$CONV_LOG"
else
    echo "NOTE: no .encodings given - qairt-quantizer will choose its own ranges." >&2
    echo "      For production, quantize with AIMET first (aimet-quantization)." >&2
    qairt-converter \
        --input_network "$ONNX" \
        --output_path   "$OUT_DIR/${MODEL}.dlc" 2>&1 | tee "$CONV_LOG"
fi
[ -s "$OUT_DIR/${MODEL}.dlc" ] || die "no DLC produced (exit 0 but empty - check $CONV_LOG)"

if [ -n "$ENCODINGS" ] && grep -qiE 'skip|ignor|not found|unmatched' "$CONV_LOG"; then
    echo >&2
    echo "WARNING: the converter reported skipped/unmatched tensors." >&2
    echo "         The ONNX and .encodings have probably drifted apart; some tensors" >&2
    echo "         are NOT using your AIMET ranges. Re-export the pair from AIMET." >&2
    grep -iE 'skip|ignor|not found|unmatched' "$CONV_LOG" | head -5 >&2
fi

# ---------- stage 2 ----------
step "2/3  qairt-quantizer -> quantized DLC"
QUANT_LOG="$OUT_DIR/${MODEL}_quantize.log"
qairt-quantizer \
    --input_dlc  "$OUT_DIR/${MODEL}.dlc" \
    --output_dlc "$OUT_DIR/${MODEL}_quantized.dlc" \
    --float_fallback 2>&1 | tee "$QUANT_LOG"
[ -s "$OUT_DIR/${MODEL}_quantized.dlc" ] || die "no quantized DLC produced (check $QUANT_LOG)"

FB=$(grep -ciE 'fallback|unsupported' "$QUANT_LOG" || true)
if [ "$FB" -gt 0 ]; then
    echo >&2
    echo "NOTE: $FB float-fallback/unsupported mentions in the quantize log." >&2
    echo "      On v68 a float op means FP16, which the HTP cannot execute. Fix the" >&2
    echo "      MODEL (graph surgery before quantization) rather than accepting it:" >&2
    grep -iE 'fallback|unsupported' "$QUANT_LOG" | head -5 >&2
fi

# FP16 audit. On v68 this must be zero or the context binary will not load.
FP16=$(grep -ciE 'float_?16|FLOAT_16' "$QUANT_LOG" 2>/dev/null || echo 0)
echo "FP16 mentions in quantize log: $FP16"
if [ "$FP16" -gt 0 ] && [ "${QC_HTP_ARCH:-}" = "v68" ]; then
    echo "WARNING: FP16 referenced and target is v68, which has no FP16." >&2
    echo "         Expect ctx-gen to abort. Convert all-quantized instead." >&2
fi

# ---------- stage 3 ----------
step "3/3  qnn-context-binary-generator -> HTP context binary"
BASE="${MODEL}_htp${QC_HTP_ARCH:+_$QC_HTP_ARCH}"     # arch in the name, deliberately
qnn-context-binary-generator \
    --model       libQnnModelDlc.so \
    --backend     libQnnHtp.so \
    --dlc_path    "$OUT_DIR/${MODEL}_quantized.dlc" \
    --output_dir  "$OUT_DIR" \
    --binary_file "$BASE"

BIN="$OUT_DIR/${BASE}.bin"
[ -s "$BIN" ] || die "no context binary produced"

# ---------- provenance ----------
step "Done"
ls -lh "$BIN"
{
    echo "binary     : $(basename "$BIN")"
    echo "sha256     : $(sha256sum "$BIN" | cut -d' ' -f1)"
    echo "source onnx: $ONNX"
    echo "  sha256   : $(sha256sum "$ONNX" | cut -d' ' -f1)"
    if [ -n "$ENCODINGS" ]; then
        echo "encodings  : $ENCODINGS"
        echo "  sha256   : $(sha256sum "$ENCODINGS" | cut -d' ' -f1)"
    else
        echo "encodings  : NONE (converter-chosen ranges)"
    fi
    echo "QAIRT      : ${QC_QAIRT_VERSION:-$(basename "$QNN_SDK_ROOT")}"
    echo "HTP arch   : ${QC_HTP_ARCH:-unverified}"
    echo "float fb   : $FB mentions (see $(basename "$QUANT_LOG"))"
    echo "built      : $(date -Iseconds) by ${USER:-unknown}@$(hostname)"
} | tee "$OUT_DIR/${BASE}.provenance.txt"

cat >&2 <<'NOTE'

Next:
  1. Stage to the board via /tmp (tmpfs), never a direct burst write to eMMC.
  2. qnn-net-run --retrieve_context <bin> --backend /usr/lib/libQnnHtp.so ...
  3. Compare against FP32 on your TASK metric. "It ran" is not validation.
NOTE
