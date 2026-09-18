#!/usr/bin/env bash
# dev-doctor checks contributed by docker-dev-embedded-arm.
# Emits STATUS|name|detail lines. STATUS in OK / WARN / FAIL.

set -uo pipefail

emit() { echo "$1|$2|$3"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Cross toolchain
for t in gcc g++ gdb objcopy objdump nm size readelf ar; do
    if have "arm-none-eabi-${t}"; then
        emit OK "arm:${t}" "$(command -v "arm-none-eabi-${t}")"
    else
        emit FAIL "arm:${t}" "arm-none-eabi-${t} not on PATH"
    fi
done

if have arm-none-eabi-gcc; then
    emit OK "arm-gcc-version" "$(arm-none-eabi-gcc -dumpversion)"

    # The ARMv8-M Mainline hard-float multilib is what STM32WBA65 / U5 / H5
    # link against. Without it a Cortex-M33 build fails at link time with a
    # confusing "cannot find -lc" rather than anything about architectures.
    if arm-none-eabi-gcc -print-multi-lib 2>/dev/null | grep -q 'v8-m.main'; then
        emit OK "newlib-v8m" "v8-m.main multilib present (Cortex-M33 OK)"
    else
        emit FAIL "newlib-v8m" "no v8-m.main multilib — STM32WBA/U5/H5 will not link"
    fi

    if arm-none-eabi-gcc -print-multi-lib 2>/dev/null | grep -q 'v7e-m'; then
        emit OK "newlib-v7em" "v7e-m multilib present (Cortex-M4/M7 OK)"
    else
        emit WARN "newlib-v7em" "no v7e-m multilib"
    fi
fi

# CMSIS core headers
if [ -f "${CMSIS_DIR:-/opt/cmsis}/CMSIS/Core/Include/core_cm33.h" ]; then
    emit OK "cmsis-core" "${CMSIS_DIR:-/opt/cmsis} (core_cm33.h present)"
else
    emit FAIL "cmsis-core" "core_cm33.h missing from ${CMSIS_DIR:-/opt/cmsis}"
fi

# CMSIS-DSP, one library per core
DSP="${CMSIS_DSP_DIR:-/opt/cmsis-dsp}"
if [ -d "$DSP/lib" ]; then
    variants=""
    for d in "$DSP"/lib/*/; do
        [ -f "$d/libCMSISDSP.a" ] || continue
        variants="$variants $(basename "$d")"
    done
    if [ -n "$variants" ]; then
        emit OK "cmsis-dsp" "prebuilt cores:$variants"
    else
        emit FAIL "cmsis-dsp" "$DSP/lib exists but holds no libCMSISDSP.a"
    fi
    # A cortex-m33f build must exist, or every ARMv8-M project has to build one.
    if [ -f "$DSP/lib/cortex-m33f/libCMSISDSP.a" ]; then
        emit OK "cmsis-dsp-m33" "cortex-m33f variant present (STM32WBA/U5/H5)"
    else
        emit WARN "cmsis-dsp-m33" "no cortex-m33f build — run: build-cmsis-dsp cortex-m33f"
    fi
else
    emit FAIL "cmsis-dsp" "$DSP/lib missing"
fi
have build-cmsis-dsp && emit OK "build-cmsis-dsp" "$(command -v build-cmsis-dsp)"

# ST CMSIS device headers
ST="${STM32_CMSIS_DIR:-/opt/st/cmsis}"
if [ -d "$ST" ]; then
    fams="$(find "$ST" -maxdepth 1 -mindepth 1 -type d -printf '%f ' 2>/dev/null)"
    emit OK "st-cmsis" "families: ${fams:-none}"
    if [ -f "$ST/wba/Include/stm32wba65xx.h" ]; then
        emit OK "st-cmsis-wba65" "stm32wba65xx.h present"
    else
        emit WARN "st-cmsis-wba65" "stm32wba65xx.h not found — WBA65 projects need it"
    fi
    if [ -f "$ST/wba/Include/partition_stm32wbaxx.h" ]; then
        emit OK "st-cmsis-tz" "partition_stm32wbaxx.h present (TrustZone SAU)"
    fi
else
    emit FAIL "st-cmsis" "$ST missing — every STM32 project needs these headers"
fi

# STM32 SVD mirror
if [ -d /opt/svd/stm32 ]; then
    n=$(find /opt/svd/stm32 -name '*.svd' | wc -l)
    emit OK "svd-stm32" "$n STM32 SVD files"
else
    emit WARN "svd-stm32" "/opt/svd/stm32 missing"
fi
# WBA6x is in no open mirror; make that visible rather than surprising.
if find /opt/svd -iname '*wba6*' 2>/dev/null | grep -q .; then
    emit OK "svd-wba65" "a WBA6x SVD is present"
else
    emit WARN "svd-wba65" "no WBA6x SVD in the store — use: svd-find --pack stm32wba65"
fi

# probe-rs knowledge of the parts that OpenOCD cannot handle
if have probe-rs; then
    # Captured, not piped: probe-rs exits 1 when its stdout closes early, which
    # `set -o pipefail` would surface as a missing chip.
    _chips=$(probe-rs chip list 2>/dev/null)
    if grep -qi 'STM32WBA65' <<< "$_chips"; then
        emit OK "probe-rs-wba65" "STM32WBA65 supported (OpenOCD 0.12 does not support it)"
    else
        emit WARN "probe-rs-wba65" "probe-rs does not list STM32WBA65 — check probe-rs version"
    fi
fi

# Optional host-mounted ST tooling
if [ -x /opt/st/clt/STM32CubeProgrammer/bin/STM32_Programmer_CLI ]; then
    emit OK "cubeclt" "STM32CubeCLT mounted at /opt/st/clt"
else
    emit OK "cubeclt" "not mounted (optional) — -v ~/st/STM32CubeCLT:/opt/st/clt:ro"
fi
if [ -d /opt/st/cubewba/Middlewares/ST/STM32_WPAN ]; then
    emit OK "cubewba" "STM32CubeWBA mounted — BLE stack available"
else
    emit OK "cubewba" "not mounted (optional) — required only for WBA BLE work"
fi

# Project toolchain file
if [ -f /opt/embedded/cmake/toolchains/arm-none-eabi.cmake ]; then
    emit OK "arm-toolchain-cmake" "/opt/embedded/cmake/toolchains/arm-none-eabi.cmake"
else
    emit FAIL "arm-toolchain-cmake" "missing"
fi
