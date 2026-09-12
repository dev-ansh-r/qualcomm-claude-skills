#!/bin/bash
# probe-env.sh - read back a Qualcomm QCS6490 dev environment.
# Read-only. Safe to run on the board, the build host or the AIMET host.
# Prints KEY=VALUE lines plus a human summary on stderr.

say() { echo "  $*" >&2; }
emit() { echo "$1=$2"; }

echo "=== probe-env.sh on $(hostname) ===" >&2

# ---------- platform ----------
ARCH=$(uname -m)
emit PROBE_HOST "$(hostname)"
emit PROBE_ARCH "$ARCH"
emit PROBE_KERNEL "$(uname -r)"
[ -r /etc/os-release ] && emit PROBE_OS "$(. /etc/os-release; echo "$PRETTY_NAME")"

# ---------- immutability (board) ----------
# NOTE: tested with [ -w ], never by writing a probe file. This script must not
# write to the board's filesystem - a burst write to an eMMC-backed mount can
# trigger a firmware watchdog reset with no log entry.
if command -v ostree >/dev/null 2>&1; then
    emit PROBE_IMMUTABLE true
    say "OSTree image - no on-device compiler. Cross-compile required."
elif [ "$ARCH" = "aarch64" ] && ! [ -w /usr ]; then
    emit PROBE_IMMUTABLE true
    say "/usr is read-only - cross-compile required."
else
    emit PROBE_IMMUTABLE false
fi

# ---------- locate QAIRT/QNN SDK ----------
SDK="$QNN_SDK_ROOT"
if [ -z "$SDK" ]; then
    for c in /opt/qcom/aistack/qairt/* /opt/qcom/aistack/qnn/* "$HOME"/qairt/* /opt/qairt/*; do
        [ -d "$c/bin" ] && SDK="$c" && break
    done
fi

if [ -n "$SDK" ] && [ -d "$SDK" ]; then
    emit QC_QNN_SDK_ROOT "$SDK"
    VER=$(basename "$SDK")
    # sdk.yaml is authoritative; the directory name is a fallback
    if [ -r "$SDK/sdk.yaml" ]; then
        Y=$(grep -iE '^\s*version' "$SDK/sdk.yaml" | head -1 | sed 's/.*: *//')
        [ -n "$Y" ] && VER="$Y"
    fi
    emit QC_QAIRT_VERSION "$VER"

    # HTP architecture support - the load-bearing one
    # What the SDK can BUILD for. Which of these your part NEEDS is a separate
    # question, answered by the board's SoC id + the SDK-local docs.
    HTP=$(ls -d "$SDK"/lib/hexagon-v*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    emit QC_HTP_ARCH_AVAILABLE "${HTP:-none}"
    if [ -z "$HTP" ]; then
        say "WARNING: no hexagon-v* libs found - HTP backend will not build"
    else
        say "SDK can build for: $HTP"
        # If the caller already knows the target arch, verify it is buildable.
        if [ -n "${QC_HTP_ARCH:-}" ]; then
            case ",$HTP," in
                *",hexagon-$QC_HTP_ARCH,"*) say "target $QC_HTP_ARCH: present" ;;
                *) say "WARNING: target arch '$QC_HTP_ARCH' NOT in this SDK. A context binary would build and then fail to LOAD." ;;
            esac
        else
            say "QC_HTP_ARCH unset - determine your part's arch from its SoC id and the SDK docs, then set it"
        fi
    fi

    # which converter generation is installed
    B="$SDK/bin/x86_64-linux-clang"
    [ -d "$B" ] && emit QC_SDK_BIN "$B"
    for t in qnn-onnx-converter qnn-model-lib-generator qairt-converter qairt-quantizer \
             qnn-context-binary-generator qnn-net-run; do
        if [ -x "$B/$t" ] || command -v "$t" >/dev/null 2>&1; then
            emit "QC_HAS_${t//-/_}" true
        else
            emit "QC_HAS_${t//-/_}" false
        fi
    done
else
    emit QC_QNN_SDK_ROOT ""
    say "No QAIRT/QNN SDK found. Set QNN_SDK_ROOT or install the SDK."
fi

# ---------- eSDK cross toolchain ----------
ESDK=""
for c in "$HOME"/*sdk*/environment-setup-* /opt/*sdk*/environment-setup-* \
         /usr/local/oecore*/environment-setup-* /opt/qcom/*/environment-setup-*; do
    [ -r "$c" ] && ESDK="$c" && break
done
if [ -n "$ESDK" ]; then
    emit QC_ESDK_ENV "$ESDK"
    # the triple model-lib-generator wants, e.g. aarch64-oe-linux-gcc11.2
    GCCV=$(grep -oE 'gcc[0-9]+\.[0-9]+' "$ESDK" 2>/dev/null | head -1)
    emit QC_ESDK_HINT "${GCCV:-unknown}"
    say "eSDK: $ESDK"
else
    emit QC_ESDK_ENV ""
    say "No eSDK environment-setup found (needed for model-lib-generator and app cross-compile)"
fi

# ---------- SoC identity (board) ----------
# Which Qualcomm part this is. Read from the kernel, never inferred from a
# hostname or assumed from the project. The SoC id -> HTP arch mapping lives in
# the SDK-local docs; extract it with the qualcomm-sdk-docs skill.
if [ "$ARCH" = "aarch64" ]; then
    for f in /sys/devices/soc0/machine /sys/devices/soc0/family \
             /sys/devices/soc0/soc_id /sys/devices/soc0/revision; do
        [ -r "$f" ] && emit "QC_SOC_$(basename "$f" | tr '[:lower:]' '[:upper:]')" "$(cat "$f" 2>/dev/null)"
    done
    # qnn-platform-validator, when the SDK runtime is staged on the board,
    # reports what the backend itself claims. Flag names vary by release -
    # check --help before relying on the output.
    if command -v qnn-platform-validator >/dev/null 2>&1; then
        emit QC_HAS_PLATFORM_VALIDATOR true
        say "qnn-platform-validator present - run it to have the backend report its own capability"
    fi
fi

# ---------- on-device QNN runtime ----------
if [ "$ARCH" = "aarch64" ]; then
    LIBS=$(ls /usr/lib/libQnn*.so 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    emit QC_BOARD_QNN_LIBS "${LIBS:-none}"
    [ -z "$LIBS" ] && say "WARNING: no libQnn*.so in /usr/lib - qnn-net-run will not run here"
    emit QC_BOARD_UPTIME "$(uptime -p 2>/dev/null || true)"
fi

# ---------- python / model tooling ----------
# Ask Python for its own version rather than parsing `python3 -V`: a shim that
# is on PATH but not a working interpreter (the Windows Store stub, a broken
# venv) still prints something that string-splits into a plausible answer.
PYV=""
if command -v python3 >/dev/null 2>&1; then
    PYV=$(python3 -c 'import platform;print(platform.python_version())' 2>/dev/null)
fi
if [ -n "$PYV" ]; then
    emit QC_PYTHON "$PYV"
    for m in onnx onnxruntime numpy aimet_onnx aimet_torch torch; do
        V=$(python3 -c "import $m,sys; sys.stdout.write(getattr($m,'__version__','present'))" 2>/dev/null)
        [ -n "$V" ] && emit "QC_PY_${m}" "$V"
    done
    python3 -c "import aimet_onnx" 2>/dev/null && emit QC_AIMET_FLAVOUR aimet-onnx \
        || { python3 -c "import aimet_torch" 2>/dev/null && emit QC_AIMET_FLAVOUR aimet-torch \
        || emit QC_AIMET_FLAVOUR none; }
else
    emit QC_PYTHON none
    say "No working python3 - the converters are Python tools and will not run here"
fi

# ---------- thermal (board) ----------
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    T=$(cat /sys/class/thermal/thermal_zone0/temp)
    emit QC_BOARD_TEMP_C "$((T/1000))"
    [ "$((T/1000))" -gt 70 ] && say "Board already at $((T/1000))C at idle - expect throttling under load"
fi

echo "=== probe complete ===" >&2
