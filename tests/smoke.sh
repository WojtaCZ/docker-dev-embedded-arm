#!/usr/bin/env bash
# Smoke test for docker-dev-embedded-arm. Runs INSIDE the built image.
#
#   docker run --rm -e DEV_SKIP_UPDATE=1 -v "$PWD/tests:/tests:ro" <image> bash /tests/smoke.sh
#
# The point of this file is that a green CI run means an STM32 project — a
# Cortex-M33 one in particular — actually compiles and links in this image.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

echo "== cross toolchain =="
for t in gcc g++ gdb objcopy objdump nm size readelf; do
    command -v "arm-none-eabi-$t" >/dev/null || fail "missing arm-none-eabi-$t"
    pass "arm-none-eabi-$t"
done
pass "gcc $(arm-none-eabi-gcc -dumpversion)"

echo "== CROSS_PREFIX wired up =="
[ "${CROSS_PREFIX:-}" = "arm-none-eabi-" ] \
    || fail "CROSS_PREFIX is '${CROSS_PREFIX:-}', expected arm-none-eabi-"
pass "CROSS_PREFIX=$CROSS_PREFIX"

echo "== newlib multilibs =="
arm-none-eabi-gcc -print-multi-lib | grep -q 'v8-m.main' \
    || fail "no v8-m.main multilib — Cortex-M33 (STM32WBA65/U5/H5) would not link"
pass "v8-m.main present"
arm-none-eabi-gcc -print-multi-lib | grep -q 'v7e-m' || fail "no v7e-m multilib"
pass "v7e-m present"

echo "== CMSIS core headers =="
[ -f "$CMSIS_DIR/CMSIS/Core/Include/core_cm33.h" ] || fail "core_cm33.h missing"
[ -f "$CMSIS_DIR/CMSIS/Core/Include/core_cm0plus.h" ] || fail "core_cm0plus.h missing"
pass "CMSIS_6 at $CMSIS_DIR"

echo "== CMSIS-DSP, one library per core =="
for core in cortex-m0plus cortex-m3 cortex-m4f cortex-m7f cortex-m33f; do
    lib="$CMSIS_DSP_DIR/lib/$core/libCMSISDSP.a"
    [ -f "$lib" ] || fail "missing prebuilt CMSIS-DSP for $core"
    pass "$core ($(du -h "$lib" | cut -f1))"
done

# The whole point of building per core: the m33 library must really be ARMv8-M,
# not a mislabelled copy of the m4 one.
attrs="$CMSIS_DSP_DIR/lib/cortex-m33f/build-attributes.txt"
if [ -f "$attrs" ]; then
    grep -qi 'v8' "$attrs" || fail "cortex-m33f CMSIS-DSP is not an ARMv8-M build: $(cat "$attrs")"
    pass "cortex-m33f build attributes are ARMv8-M"
fi
attrs4="$CMSIS_DSP_DIR/lib/cortex-m4f/build-attributes.txt"
if [ -f "$attrs4" ] && [ -f "$attrs" ]; then
    ! diff -q "$attrs" "$attrs4" >/dev/null \
        || fail "cortex-m33f and cortex-m4f have identical build attributes — the per-core build is not working"
    pass "m33f and m4f are genuinely different builds"
fi

command -v build-cmsis-dsp >/dev/null || fail "build-cmsis-dsp helper missing"
pass "build-cmsis-dsp available for other cores"

echo "== ST CMSIS device headers (Apache-2.0, not the HAL) =="
[ -d "$STM32_CMSIS_DIR" ] || fail "$STM32_CMSIS_DIR missing"
for f in wba/Include/stm32wba65xx.h \
         wba/Include/stm32wbaxx.h \
         wba/Include/partition_stm32wbaxx.h \
         f4/Include/stm32f4xx.h \
         g0/Include/stm32g0xx.h; do
    [ -f "$STM32_CMSIS_DIR/$f" ] || fail "missing $STM32_CMSIS_DIR/$f"
    pass "$f"
done
ls "$STM32_CMSIS_DIR/wba/Source/Templates/gcc/" | grep -q 'startup_stm32wba65' \
    || fail "no WBA65 startup template"
pass "WBA65 startup template present"

echo "== SVD =="
n=$(find /opt/svd/stm32 -name '*.svd' 2>/dev/null | wc -l)
[ "$n" -gt 50 ] || fail "STM32 SVD mirror looks empty ($n files)"
pass "$n STM32 SVD files"
svd-find stm32wba55 | head -2
pass "svd-find locates a WBA5x SVD"

echo "== probe-rs knows the parts OpenOCD cannot flash =="
probe-rs chip list 2>/dev/null | grep -qi 'STM32WBA65' \
    || fail "probe-rs does not list STM32WBA65 — the documented WBA65 flash path is broken"
pass "probe-rs supports STM32WBA65"
probe-rs chip list 2>/dev/null | grep -qi 'STM32F407' || fail "probe-rs missing STM32F407"
pass "probe-rs supports STM32F407"

echo "== claude assets =="
for s in stm32-option-bytes stm32-part-lookup stm32-clock-config stm32-dma-setup \
         stm32-lowpower-modes stm32-bootloader-dfu stm32wba-ble-bringup \
         cortex-m-startup-cpp cortex-m-vector-table cortex-m-fpu-enable \
         cmsis-dsp-cpp mspm0c1104-quirks; do
    # Skills install either flat (<name>.md) or in discoverable directory form
    # (<name>/SKILL.md, which is what Claude Code actually indexes).
    if [ ! -f "$HOME/.claude/skills/$s.md" ] && [ ! -f "$HOME/.claude/skills/$s/SKILL.md" ]; then
        fail "skill $s not installed (neither $s.md nor $s/SKILL.md)"
    fi
    pass "skill: $s"
done
[ -f "$HOME/.claude/commands/stm32-new-project.md" ] || fail "/stm32-new-project missing"
[ -f "$HOME/.claude/commands/scaffold-mcu-project.md" ] || fail "inherited /scaffold-mcu-project missing"
pass "commands present (own + inherited)"

echo "== settings layers merged through all three levels =="
S="$HOME/.claude/settings.json"
for server in github git context7 sequential-thinking fetch; do
    jq -e --arg s "$server" '.mcpServers | has($s)' "$S" >/dev/null || fail "MCP $server missing"
done
[ "$(jq -r '.mcpServers.fetch.command' "$S")" = "uvx" ] || fail "fetch MCP must use uvx"
pass "baseline + embedded + arm layers merged"

# --------------------------------------------------------------------------
echo "== END TO END: build a real Cortex-M33 firmware (STM32WBA65) =="
# --------------------------------------------------------------------------
work=$(mktemp -d)
cd "$work"
mkdir -p src cmake

cat > src/main.cpp <<'CPP'
#include <cstdint>
#include "stm32wba65xx.h"

// A global with a non-trivial constructor, so the link proves .init_array
// is being emitted and kept.
struct Counter {
    Counter() : value(42) {}
    volatile uint32_t value;
};
static Counter counter;

int main() {
    for (;;) {
        counter.value = counter.value + 1u;
    }
}
CPP

cat > src/startup.cpp <<'CPP'
#include <cstdint>
extern std::uint32_t _sidata, _sdata, _edata, _sbss, _ebss, _estack;
extern void (*__init_array_start)();
extern void (*__init_array_end)();
int main();

extern "C" void Default_Handler() { for (;;) {} }

extern "C" void Reset_Handler() {
    std::uint32_t* src = &_sidata;
    for (std::uint32_t* dst = &_sdata; dst < &_edata; ) { *dst++ = *src++; }
    for (std::uint32_t* dst = &_sbss;  dst < &_ebss;  ) { *dst++ = 0u; }
    SCB->CPACR |= (0xFU << 20);          // Cortex-M33 FPU
    __DSB(); __ISB();
    for (void (**c)() = &__init_array_start; c < &__init_array_end; ++c) { (*c)(); }
    main();
    for (;;) {}
}

__attribute__((section(".isr_vector"), used))
void (* const vector_table[])() = {
    reinterpret_cast<void(*)()>(&_estack),
    Reset_Handler,
    Default_Handler,
    Default_Handler,
};
CPP

# Real WBA65 memory map: 2 MB flash in two banks, 448 KB SRAM1 + 64 KB SRAM2.
cat > linker.ld <<'LD'
ENTRY(Reset_Handler)
MEMORY {
  FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 2048K
  RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 448K
}
_estack = ORIGIN(RAM) + LENGTH(RAM);
SECTIONS {
  .isr_vector : { KEEP(*(.isr_vector)) } > FLASH
  .text   : { *(.text*) *(.rodata*) } > FLASH
  .ARM.exidx : { *(.ARM.exidx*) } > FLASH
  .init_arr : {
    . = ALIGN(4);
    PROVIDE_HIDDEN(__init_array_start = .);
    KEEP(*(SORT(.init_array.*)))
    KEEP(*(.init_array))
    PROVIDE_HIDDEN(__init_array_end = .);
  } > FLASH
  _sidata = LOADADDR(.data);
  .data : { _sdata = .; *(.data*) . = ALIGN(4); _edata = .; } > RAM AT> FLASH
  .bss  : { _sbss  = .; *(.bss*) *(COMMON) . = ALIGN(4); _ebss = .; } > RAM
  /DISCARD/ : { *(.ARM.attributes) }
}
LD

cat > CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.20)
project(firmware CXX ASM)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
include(/opt/embedded/cmake/embedded-common.cmake)

add_executable(firmware src/main.cpp src/startup.cpp)
target_compile_definitions(firmware PRIVATE STM32WBA65xx)
target_include_directories(firmware PRIVATE
    $ENV{STM32_CMSIS_DIR}/wba/Include
    $ENV{CMSIS_DIR}/CMSIS/Core/Include)
target_link_options(firmware PRIVATE -T ${CMAKE_SOURCE_DIR}/linker.ld -nostartfiles)

embedded_hardening(firmware)
embedded_artifacts(firmware)
embedded_stack_usage(firmware)

# Link the matching CMSIS-DSP variant, proving find_cmsis_dsp() resolves.
find_cmsis_dsp(${CMSIS_DSP_CORE} DSP_LIB)
message(STATUS "CMSIS-DSP: ${DSP_LIB}")
CMAKE

python - <<'PY'
import json
json.dump({
    "chip": "STM32WBA65RI",
    "core": "cortex-m33",
    "fpu": "fpv5-sp-d16",
    "floatAbi": "hard",
    "probe": "stlink",
    "flashTool": "probe-rs",
    "ELF": "build/firmware.elf",
    "sizeBudget": {"flash": 2097152, "ram": 458752},
    "build": ("cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release "
              "-DCMAKE_TOOLCHAIN_FILE=/opt/embedded/cmake/toolchains/arm-none-eabi.cmake "
              "-DARM_CORE=${core} -DARM_FPU=${fpu} -DARM_FLOAT_ABI=${floatAbi} "
              "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON && cmake --build build"),
    "flash": "probe-rs download --chip ${chip} --binary-format elf ${ELF}",
    "postBuild": ["size"],
}, open(".mcu-profile.json", "w"), indent=2)
PY

mcu build
pass "Cortex-M33 firmware built via mcu"

[ -f build/firmware.elf ] || fail "no firmware.elf produced"
[ -f build/firmware.hex ] || fail "embedded_artifacts did not produce .hex"
[ -f build/firmware.bin ] || fail "embedded_artifacts did not produce .bin"
pass "elf + hex + bin produced"

echo "-- build attributes --"
arm-none-eabi-readelf -A build/firmware.elf | grep -E 'Tag_CPU_name|Tag_CPU_arch|Tag_FP_arch|Tag_ABI_VFP_args'
arm-none-eabi-readelf -A build/firmware.elf | grep -q 'Tag_CPU_name: "Cortex-M33"' \
    || fail "binary is NOT built for Cortex-M33 — the toolchain file is not applying -mcpu"
pass "binary really is Cortex-M33"
arm-none-eabi-readelf -A build/firmware.elf | grep -q 'Tag_ABI_VFP_args' \
    || fail "hard-float ABI attribute missing"
pass "hard-float ABI"

# Global constructors must be kept, or no C++ global is ever initialised.
arm-none-eabi-nm build/firmware.elf | grep -q '__init_array_start' \
    || fail ".init_array not emitted"
pass ".init_array present"

mcu size
pass "size within the WBA65 budget"

# A deliberately impossible budget must fail the build.
python - <<'PY'
import json
p = json.load(open(".mcu-profile.json")); p["sizeBudget"] = {"flash": 16, "ram": 16}
json.dump(p, open(".mcu-profile.json", "w"), indent=2)
PY
if mcu size >/dev/null 2>&1; then fail "size budget not enforced"; fi
pass "size budget enforced"

# The profile -> env + clangd bridge
python - <<'PY'
import json
p = json.load(open(".mcu-profile.json")); p["sizeBudget"] = {"flash": 2097152, "ram": 458752}
json.dump(p, open(".mcu-profile.json", "w"), indent=2)
PY
mcu --export >/dev/null
grep -q 'chip=STM32WBA65RI' .vscode/.profile.env || fail "mcu --export missing chip"
grep -q 'CROSS_GDB=' .vscode/.profile.env || fail "mcu --export did not derive CROSS_GDB"
pass "mcu --export wrote .vscode/.profile.env"
[ -f .clangd ] || fail "no .clangd fallback generated"
grep -q 'cortex-m33' .clangd || fail ".clangd does not carry the core"
pass ".clangd fallback generated"

echo "== END TO END: Cortex-M0+ soft-float still works =="
rm -rf build .clangd
python - <<'PY'
import json
p = json.load(open(".mcu-profile.json"))
p.update({"chip": "STM32G071RB", "core": "cortex-m0plus", "fpu": "none",
          "floatAbi": "soft", "sizeBudget": {"flash": 131072, "ram": 36864}})
json.dump(p, open(".mcu-profile.json", "w"), indent=2)
PY
cat > src/main.cpp <<'CPP'
#include <cstdint>
static volatile std::uint32_t counter = 0;
int main() { for (;;) { counter = counter + 1u; } }
CPP
sed -i 's/target_compile_definitions(firmware PRIVATE STM32WBA65xx)//' CMakeLists.txt
sed -i 's|\$ENV{STM32_CMSIS_DIR}/wba/Include||' CMakeLists.txt
sed -i 's|SCB->CPACR .*||; s|__DSB(); __ISB();||; s|#include "stm32wba65xx.h"||' src/startup.cpp
mcu build
arm-none-eabi-readelf -A build/firmware.elf | grep -q 'Cortex-M0+' \
    || fail "M0+ build did not target Cortex-M0+"
pass "Cortex-M0+ soft-float build works"

cd /
rm -rf "$work"

echo "== dev-doctor =="
dev-doctor
dev-doctor --json | jq -e '.ok == true' >/dev/null || fail "dev-doctor reported failures"
pass "dev-doctor clean"

echo "== CLAUDE.md memory layers assembled =="
M="$HOME/.claude/CLAUDE.md"
[ -d "$HOME/.claude-memory-layers" ] || fail "~/.claude-memory-layers missing"
for l in 00-baseline.md 10-embedded.md 20-arm.md; do
    [ -f "$HOME/.claude-memory-layers/$l" ] || fail "memory layer $l not installed"
done
pass "memory layers present: $(ls "$HOME/.claude-memory-layers" | tr '\n' ' ')"
[ -s "$M" ] || fail "entrypoint did not assemble ~/.claude/CLAUDE.md"
grep -q "## ARM layer" "$M" || fail "merged CLAUDE.md is missing this image's layer (## ARM layer)"
pass "CLAUDE.md assembled, this image's layer present"

echo
echo "SMOKE TEST PASSED"
