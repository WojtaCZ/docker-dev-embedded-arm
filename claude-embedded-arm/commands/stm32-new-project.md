Create a complete, buildable STM32 project from a part number. Arguments: $ARGUMENTS

Usage: `/stm32-new-project <part-number>`
Examples: `/stm32-new-project STM32WBA65RI`, `/stm32-new-project STM32F407VG`, `/stm32-new-project STM32G071RB`

This is the STM32-specific fast path. For non-STM32 Cortex-M parts use
`/scaffold-mcu-project arm <part>`.

## Steps

### 1. Resolve the part

If no part number was given, ask for one and stop. Do not guess — an unresolved
core produces a binary for the wrong architecture that links cleanly and faults
on the device.

Use the **`stm32-part-lookup`** skill to derive: core, `-mfpu`, float ABI,
flash origin/size, RAM origin/size (all banks), TrustZone presence, the CMSIS
device family directory, and which flash tool applies.

Confirm against the container's own sources of truth:

```bash
ls $STM32_CMSIS_DIR                      # baked ST CMSIS device families
probe-rs chip list | grep -i <part>      # authoritative memory map + support
```

### 2. Refuse to continue silently if support is missing

- CMSIS device family not in `$STM32_CMSIS_DIR` → say so, and offer to clone it
  (`git clone --depth=1 https://github.com/STMicroelectronics/cmsis-device-<fam>`).
  These are Apache-2.0, so this is always allowed.
- Part not in `probe-rs chip list` and not supported by OpenOCD → say so
  explicitly and recommend pyocd + CMSIS-Pack or a host-mounted STM32CubeCLT.
  Do not scaffold a profile whose `flash` command cannot work.

### 3. Scaffold

```bash
mkdir -p .vscode cmake src test/host svd
cp /opt/embedded/vscode-templates/tasks.json  .vscode/tasks.json
cp /opt/embedded/vscode-templates/launch.json .vscode/launch.json
cp /opt/embedded/profile.json                 .mcu-profile.json
```

Then rewrite `.mcu-profile.json` for the resolved part. Take the openocd or
probe-rs command set from the `_probe_rs_variant` block already in the file, and
delete the `_chips`, `_flashTool_guidance` and unused `_*_variant` blocks so the
result is clean. Set `chip`, `core`, `fpu`, `floatAbi`, `probe`, `flashTool`,
and a **real** `sizeBudget` from the part's flash/RAM.

### 4. Device headers, startup, linker script

```bash
FAM=<family>                      # wba, f4, g0, ...
PART=<part>                       # stm32wba65xx, stm32f407xx, ...

cp $STM32_CMSIS_DIR/$FAM/Source/Templates/gcc/startup_${PART}.s src/
cp $STM32_CMSIS_DIR/$FAM/Source/Templates/system_stm32${FAM}xx.c src/
ls $STM32_CMSIS_DIR/$FAM/Source/Templates/gcc/linker/
```

Copy the closest linker template to `linker.ld`, then **verify its `MEMORY`
block against the real part** — ST's templates are per-family and the sizes
routinely need adjusting. Run the `linker-script-audit` skill on the result.

### 5. CMakeLists.txt

```cmake
cmake_minimum_required(VERSION 3.20)
project(firmware C CXX ASM)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(HOST_TESTS "Build native unit tests instead of firmware" OFF)
if(HOST_TESTS)
    include(/opt/embedded/cmake/host-test.cmake)
    add_host_test_suite(logic_tests
        SOURCES  test/host/test_placeholder.cpp
        INCLUDES src)
    return()
endif()

include(/opt/embedded/cmake/embedded-common.cmake)

set(ST_FAMILY <fam>)          # wba, f4, ...
set(ST_PART   <PART>xx)       # STM32WBA65xx, STM32F407xx, ...

add_executable(firmware
    src/main.cpp
    src/startup_<part>.s
    src/system_stm32<fam>xx.c
)

target_compile_definitions(firmware PRIVATE ${ST_PART})

target_include_directories(firmware PRIVATE
    src
    $ENV{STM32_CMSIS_DIR}/${ST_FAMILY}/Include
    $ENV{CMSIS_DIR}/CMSIS/Core/Include
)

target_link_options(firmware PRIVATE -T ${CMAKE_SOURCE_DIR}/linker.ld)

embedded_hardening(firmware)
embedded_artifacts(firmware)
embedded_stack_usage(firmware)
```

The core flags come from the toolchain file, which the profile's `build` command
already passes:
`-DCMAKE_TOOLCHAIN_FILE=/opt/embedded/cmake/toolchains/arm-none-eabi.cmake -DARM_CORE=... -DARM_FPU=... -DARM_FLOAT_ABI=...`

### 6. SVD

```bash
svd-find --set <part>          # tries /opt/svd/stm32 then the multi-vendor store
svd-find --pack <part>         # WBA6x and other very new parts need ST's CMSIS-Pack
mcu --export                   # regenerate .vscode/.profile.env
```

### 7. `src/main.cpp`

A minimal blinky skeleton with the port/pin left as comments — do not invent a
pin assignment for an unknown board.

### 8. Verify, and report the real output

```bash
mcu --list
mcu build
mcu size
arm-none-eabi-readelf -A build/firmware.elf | grep -E 'Tag_CPU_name|Tag_FP_arch|Tag_ABI_VFP_args'
```

The `readelf` line is the check that matters: it proves the binary is for the
core you resolved in step 1, not the compiler default.

### 9. Report

- Part, core, flags, memory map, flash tool — and **why** if not openocd
- What was templated vs. what still needs the user's input (pin assignments,
  linker `MEMORY` sizes, board-specific clock source)
- Whether an SVD was found
- **If the part has TrustZone** (L5/U5/H5/WBA): state that option bytes are
  untouched, that `TZEN` may already be set on a used board, and that the
  `stm32-option-bytes` skill must be consulted before any option-byte write.
  A device with `TZEN=1` and a non-secure-only image flashes fine and never
  reaches `main()`.
- **If the part is a WBA and the user wants BLE**: point at the
  `stm32wba-ble-bringup` skill, and note that the radio needs ST's binary
  stack from STM32CubeWBA, which is not in this image.
