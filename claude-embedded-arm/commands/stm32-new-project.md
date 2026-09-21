Create a complete, buildable STM32 project from a part number. Arguments: $ARGUMENTS

Usage: `/stm32-new-project <part-number>`
Examples: `/stm32-new-project STM32WBA65RI`, `/stm32-new-project STM32F407VG`, `/stm32-new-project STM32G071RB`

This is the STM32-specific fast path. For non-STM32 Cortex-M parts use
`/scaffold-mcu-project arm <part>` — but still lay the result out the way this
command does. **The canonical project layout in the ARM memory layer applies to
every project created in this image**, not only STM32 ones.

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

### 3. Scaffold the canonical tree

```bash
mkdir -p .vscode cmake linker svd inc src src/logic startup lib test/host
cp /opt/embedded/vscode-templates/tasks.json  .vscode/tasks.json
cp /opt/embedded/vscode-templates/launch.json .vscode/launch.json
cp /opt/embedded/profile.json                 .mcu-profile.json
printf 'build/\nbuild-host/\n.vscode/.profile.env\n' > .gitignore
```

Then rewrite `.mcu-profile.json` for the resolved part. Take the openocd or
probe-rs command set from the `_probe_rs_variant` block already in the file, and
delete the `_chips`, `_flashTool_guidance` and unused `_*_variant` blocks so the
result is clean. Set `chip`, `core`, `fpu`, `floatAbi`, `probe`, `flashTool`, a
**real** `sizeBudget` from the part's flash/RAM, `SVD_FILE` to
`svd/<PART>.svd`, and `ELF` to `build/<name>.elf`.

`build` and `buildDebug` must point at the project's **own** toolchain wrapper:

```
-DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-arm-none-eabi.cmake
```

not at `/opt/embedded/cmake/toolchains/arm-none-eabi.cmake` directly.

### 4. The two `cmake/` files

`cmake/toolchain-arm-none-eabi.cmake` pins this board's core and keeps the
shared file's `ARM_CORE` guard from firing inside CMake's ABI-detection
sub-configure:

```cmake
set(ARM_CORE      <core>)          # cortex-m33, cortex-m4, cortex-m0plus, ...
set(ARM_FPU       <fpu>)           # fpv5-sp-d16, fpv4-sp-d16, none
set(ARM_FLOAT_ABI <abi>)           # hard | soft

include(/opt/embedded/cmake/toolchains/arm-none-eabi.cmake)

list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES ARM_CORE ARM_FPU ARM_FLOAT_ABI)
```

`cmake/linker.cmake` applies the script and makes a relink depend on it:

```cmake
if(NOT DEFINED LINKER_SCRIPT)
    file(GLOB linker_script_auto "${CMAKE_SOURCE_DIR}/linker/*.ld")
    if(NOT linker_script_auto)
        message(FATAL_ERROR "No linker script found in linker/")
    endif()
    set(LINKER_SCRIPT "${linker_script_auto}" CACHE STRING "Linker script" FORCE)
endif()
message(STATUS "Linker script: ${LINKER_SCRIPT}")

target_link_options(${PROJECT_NAME}.elf PRIVATE -T${LINKER_SCRIPT})
set_target_properties(${PROJECT_NAME}.elf PROPERTIES LINK_DEPENDS ${LINKER_SCRIPT})
```

### 5. Device headers, startup, linker script

Vendor asm goes in `startup/`, never in `src/`:

```bash
FAM=<family>                      # wba, f4, g0, ...
PART=<part>                       # stm32wba65xx, stm32f407xx, ...

cp $STM32_CMSIS_DIR/$FAM/Source/Templates/gcc/startup_${PART}.s  startup/
cp $STM32_CMSIS_DIR/$FAM/Source/Templates/system_stm32${FAM}xx.c startup/
ls $STM32_CMSIS_DIR/$FAM/Source/Templates/gcc/linker/
```

Copy the closest linker template to `linker/<PART>_FLASH.ld`, then **verify its
`MEMORY` block against the real part** — ST's templates are per-family and the
sizes routinely need adjusting. Run the `linker-script-audit` skill on the
result. A TrustZone part built secure + non-secure keeps both scripts here,
which is why `linker/` is a directory.

Do **not** create `lib/CMSIS`. CMSIS core and the ST device headers come from
`$CMSIS_DIR` and `$STM32_CMSIS_DIR`; a vendored copy inside this container is a
stale duplicate. `lib/` is for third-party code the image does not ship
(tinyusb, etl, littlefs, nanopb), added as git submodules rather than copied
trees.

### 6. CMakeLists.txt

```cmake
cmake_minimum_required(VERSION 3.20)
project(<name> LANGUAGES CXX C ASM VERSION 0.1.0)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Native unit tests. Configure in a SEPARATE build dir with no toolchain file:
#   cmake -S . -B build-host -G Ninja -DHOST_TESTS=ON
option(HOST_TESTS "Build native unit tests instead of firmware" OFF)
if(HOST_TESTS)
    include(/opt/embedded/cmake/host-test.cmake)
    add_host_test_suite(logic_tests
        SOURCES  test/host/test_placeholder.cpp
        INCLUDES src inc)
    return()
endif()

include(/opt/embedded/cmake/embedded-common.cmake)

set(ST_FAMILY <fam>)              # wba, f4, ...
set(ST_PART   STM32<PART>xx)      # STM32WBA65xx, STM32F407xx, ...
set(LINKER_SCRIPT ${CMAKE_SOURCE_DIR}/linker/<PART>_FLASH.ld)

# List sources explicitly — no file(GLOB).
add_executable(${PROJECT_NAME}.elf
    src/main.cpp
    startup/startup_<part>.s
    startup/system_stm32<fam>xx.c
)

target_compile_definitions(${PROJECT_NAME}.elf PRIVATE ${ST_PART})

target_include_directories(${PROJECT_NAME}.elf PRIVATE
    src
    inc
    $ENV{CMSIS_DIR}/CMSIS/Core/Include
    $ENV{STM32_CMSIS_DIR}/${ST_FAMILY}/Include
)

embedded_hardening(${PROJECT_NAME}.elf)
embedded_artifacts(${PROJECT_NAME}.elf)
embedded_stack_usage(${PROJECT_NAME}.elf)

include(cmake/linker.cmake)
```

Do not add a hand-rolled warning / optimisation / `--specs` flag block —
`embedded_hardening()` owns that, and the core flags come from the toolchain
wrapper in step 4.

### 7. SVD

```bash
svd-find --set <part>          # tries /opt/svd/stm32 then the multi-vendor store
svd-find --pack <part>         # WBA6x and other very new parts need ST's CMSIS-Pack
mcu --export                   # regenerate .vscode/.profile.env
```

Move the result into `svd/` if the tool drops it elsewhere, and make
`SVD_FILE` in the profile match.

### 8. `src/main.cpp` and `inc/main.hpp`

A minimal blinky skeleton with the port/pin left as comments — do not invent a
pin assignment for an unknown board. Declarations go in `inc/main.hpp`.

### 9. Verify, and report the real output

```bash
mcu --list
mcu build
mcu size
arm-none-eabi-readelf -A build/<name>.elf | grep -E 'Tag_CPU_name|Tag_FP_arch|Tag_ABI_VFP_args'
```

The `readelf` line is the check that matters: it proves the binary is for the
core you resolved in step 1, not the compiler default.

### 10. Report

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
