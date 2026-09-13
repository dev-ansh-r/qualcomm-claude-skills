#!/bin/bash
# probe-env.sh - read back a Qualcomm QCS6490 dev environment.
# Read-only. Safe to run on the board, the build host or the AIMET host.
# Prints KEY=VALUE lines plus a human summary on stderr.

say() { echo "  $*" >&2; }
emit() { echo "$1=$2"; }

echo "=== probe-env.sh on $(hostname) ===" >&2

# ---------- platform ----------
ARCH=$(uname -m)
OSNAME=$(uname -s)
emit PROBE_HOST "$(hostname)"
emit PROBE_ARCH "$ARCH"
emit PROBE_KERNEL "$(uname -r)"
emit PROBE_OS_KERNEL "$OSNAME"
[ -r /etc/os-release ] && emit PROBE_OS "$(. /etc/os-release; echo "$PRETTY_NAME")"

# Can this host run the SDK at all? The converters ship only as
# bin/x86_64-linux-clang - there is no Windows or macOS build. On a non-Linux
# host the answer is not "install the SDK", it is "use a different host", and
# saying so early saves someone a download.
case "$OSNAME" in
    Linux)  emit QC_CAN_HOST_SDK true ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
        emit QC_CAN_HOST_SDK false
        emit QC_HOST_KIND windows
        say "WINDOWS HOST - the QAIRT converters are x86_64 LINUX only. This"
        say "machine cannot be a build host: no SDK install will change that."
        say "Edit here, build on a Linux host, deploy to the board. WSL2 counts"
        say "as a Linux host; Git Bash and MSYS do not."
        ;;
    Darwin)
        emit QC_CAN_HOST_SDK false
        emit QC_HOST_KIND macos
        say "macOS HOST - the QAIRT converters are x86_64 Linux only. Use a"
        say "Linux build host; this machine can still edit and drive it."
        ;;
    *)  emit QC_CAN_HOST_SDK unknown
        say "Unrecognised OS '$OSNAME' - SDK support unverified here" ;;
esac

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

# On a host that cannot run the SDK, an absent SDK is expected, not a fault.
if [ "${OSNAME}" != "Linux" ] && [ -z "$SDK" ]; then
    emit QC_QNN_SDK_ROOT ""
    say "No SDK here, and none is possible on this OS - this is expected, not a fault."
elif [ -n "$SDK" ] && [ -d "$SDK" ]; then
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
    # The eSDK's own compiler prefix and version. NOT the -t value: that is a
    # fixed enum inside qnn-model-lib-generator (see --help), and the eSDK
    # triple often differs from every entry in it. Report both and let the
    # caller pick the nearest supported target.
    CCLINE=$(grep -m1 '^export CC=' "$ESDK" 2>/dev/null)
    PREFIX=$(printf '%s' "$CCLINE" | grep -oE '[a-z0-9_]+-[a-z0-9_]+-linux(-musl)?' | head -1)
    [ -n "$PREFIX" ] && emit QC_ESDK_CC_PREFIX "$PREFIX"
    # Ask the compiler its version rather than parsing the setup script.
    GCCV=$( (. "$ESDK" >/dev/null 2>&1; ${CC%% *} -dumpversion 2>/dev/null) )
    [ -z "$GCCV" ] && [ -n "$PREFIX" ] && GCCV=$("${PREFIX}-gcc" -dumpversion 2>/dev/null)
    emit QC_ESDK_GCC_VERSION "${GCCV:-unknown}"
    say "eSDK: $ESDK"
    if [ -n "$GCCV" ]; then
        say "eSDK compiler: ${PREFIX:-?}-gcc $GCCV"
        say "  -t is a fixed enum in qnn-model-lib-generator - run --help and pick"
        say "  the nearest supported target, then VERIFY the .so loads on the board."
    fi
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

    # Can this python actually CREATE a venv? `import venv` succeeding is not
    # enough: `python3 -m venv` needs ensurepip, which Debian/Ubuntu ship in a
    # separate python3.x-venv package. Without it, venv creation fails AFTER
    # making the directory, and a careless wrapper reports success. [measured]
    if python3 -c 'import ensurepip' 2>/dev/null; then
        emit QC_PY_CAN_MKVENV true
    else
        emit QC_PY_CAN_MKVENV false
        say "python3 -m venv will FAIL here: ensurepip is missing."
        say "  Fix: 'apt install python3-venv' (needs sudo), or use virtualenv"
        say "  ('pip install --user virtualenv'), which bundles its own pip."
    fi

    # Where the packages this python imports actually live. A user-site install
    # (~/.local) is visible to EVERY python3 on the host, so a --user install
    # for one tool can silently change another tool's numpy.
    USERSITE=$(python3 -c 'import site;print(site.ENABLE_USER_SITE and site.getusersitepackages() or "")' 2>/dev/null)
    if [ -n "$USERSITE" ] && python3 -c "import numpy,sys; sys.exit(0 if numpy.__file__.startswith('$USERSITE') else 1)" 2>/dev/null; then
        emit QC_PY_NUMPY_IN_USERSITE true
        say "numpy comes from user-site ($USERSITE)"
        say "  Any 'pip install --user' can change it under the converter."
        say "  Install other toolchains into an ISOLATED venv, and export"
        say "  PYTHONNOUSERSITE=1 so user-site cannot shadow it."
    fi
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

# ---------- thermal ----------
# Only meaningful on the target. An x86 build host also exposes thermal_zone0,
# and reporting that as a "board" temperature is actively misleading.
if [ "$ARCH" = "aarch64" ] && [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    T=$(cat /sys/class/thermal/thermal_zone0/temp)
    emit QC_BOARD_TEMP_C "$((T/1000))"
    [ "$((T/1000))" -gt 70 ] && say "Board already at $((T/1000))C at idle - expect throttling under load"
fi

echo "=== probe complete ===" >&2
