
---

## ARM layer (`docker-dev-embedded-arm`)

Cortex-M target image: STM32 (all families, including the ARMv8-M
WBA/U5/H5/L5 parts), RP2040, TI MSPM0, and any other Cortex-M.

`$CROSS_PREFIX` = `arm-none-eabi-`

| Area | What is here |
|---|---|
| Toolchain | `arm-none-eabi-gcc`/`g++`, `arm-none-eabi-newlib`, `arm-none-eabi-gdb`, `arm-none-eabi-binutils`. The build asserts newlib has a `v8-m.main` multilib, so Cortex-M33 hard-float links work |
| CMSIS core | `$CMSIS_DIR` = `/opt/cmsis` (CMSIS_6, header-only: `core_cm*.h`, `cmsis_gcc.h`, ARMv8-M TrustZone helpers) |
| CMSIS-DSP | `$CMSIS_DSP_DIR` = `/opt/cmsis-dsp`, **one static library per core** |
| ST device headers | `$STM32_CMSIS_DIR` = `/opt/st/cmsis/<family>/` — headers, startup, GCC linker templates. Families: `wba f0 f1 f3 f4 f7 g0 g4 l0 l4 l5 u5 h5 h7 wb wl`. **Apache-2.0 CMSIS device files, NOT the HAL** |
| SVDs | `/opt/svd/stm32` (modm-io mirror: C0/G0/G4/H5/H7/L5/U5/WBA5/WB0/N6) searched before the multi-vendor store. **WBA6x is in neither** — use `svd-find --pack stm32wba65` |
| CMake toolchain file | `/opt/embedded/cmake/toolchains/arm-none-eabi.cmake` — sets `ARM_CORE`, `ARM_FPU` and derives `CMSIS_DSP_CORE` |
| Default profile | `/opt/embedded/profile.json` (STM32F407VG starter, copied by `/scaffold-mcu-project`) |

### CMSIS-DSP — opt-in, prebuilt per core

Prebuilt: `cortex-m0plus`, `cortex-m3`, `cortex-m4f`, `cortex-m7f`,
`cortex-m33f`. A cortex-m4 (ARMv7E-M) archive is the **wrong artefact** for a
cortex-m33 (ARMv8-M) target, which is why each core has its own.

Nothing links it by default. To add it to a project, use the
`cmsis-dsp-cpp` skill — it has the exact `CMakeLists.txt` edits, the
`find_cmsis_dsp()` contract (it sets both `DSP_LIB` and
`DSP_LIB_INCLUDE_DIRS`), and the flag-match rules.

For a core that is not prebuilt: `build-cmsis-dsp <core>` (e.g. `cortex-m55`
for Helium, or soft-float `cortex-m4`); no arguments lists the known cores. It
generates the per-core toolchain file CMSIS-DSP does not ship, builds, and
installs into the layout `find_cmsis_dsp()` reads. Each variant records what it
was built with in `lib/<core>/flags.cmake` and `lib/<core>/build-attributes.txt`
— read those first when a link fails on architecture or float-ABI mismatch.

### Project layout — the canonical shape

Every firmware project created in this image uses this tree. It is the house
style (derived from `WojtaCZ/f401-template`, with the deviations below baked
in). Follow it; do not invent a per-part variant.

```
<project>/
├── CMakeLists.txt              root; explicit source list, never file(GLOB)
├── .mcu-profile.json           chip, core, fpu, build/flash/debug commands
├── .gitignore                  build/  build-host/  .vscode/.profile.env
├── README.md                   board, pinout, and why this flash tool
├── .vscode/{tasks,launch}.json
├── cmake/
│   ├── toolchain-arm-none-eabi.cmake   pins ARM_CORE/ARM_FPU/ARM_FLOAT_ABI
│   └── linker.cmake                    applies -T, sets LINK_DEPENDS
├── linker/<PART>_FLASH.ld      a directory: TrustZone parts need two scripts
├── svd/<PART>.svd
├── startup/                    vendor asm + system_stm32<fam>xx.c
├── inc/                        headers
├── src/                        main.cpp and project sources
│   └── logic/                  hardware-independent; compiled both ways
├── lib/                        third-party only, as submodules
├── test/host/                  native unit tests, -DHOST_TESTS=ON
└── build/                      generated, ignored
```

What makes it work — each of these is load-bearing:

- **`cmake/toolchain-arm-none-eabi.cmake` is a per-project wrapper, not a copy
  of the shared file.** It `set()`s `ARM_CORE`/`ARM_FPU`/`ARM_FLOAT_ABI` for
  this board, `include()`s `/opt/embedded/cmake/toolchains/arm-none-eabi.cmake`,
  then appends those three to `CMAKE_TRY_COMPILE_PLATFORM_VARIABLES`. Without
  that last step CMake's "Detecting CXX compiler ABI info" sub-configure does
  not inherit the cache vars and trips the shared file's `ARM_CORE` guard. The
  profile's `build` command points at the wrapper, not the shared file.
- **`startup/` is vendor code, `src/` is yours.** Copy `startup_<part>.s` and
  `system_stm32<fam>xx.c` out of `$STM32_CMSIS_DIR` into `startup/`; never edit
  them in place.
- **`lib/` is only for what this image does not ship** — tinyusb, etl,
  littlefs, nanopb — added as git submodules, not copied trees. **Never vendor
  CMSIS into `lib/`**: use `$CMSIS_DIR/CMSIS/Core/Include` and
  `$STM32_CMSIS_DIR/<fam>/Include`. The f401 template checks in `lib/CMSIS`;
  inside this container that is a stale duplicate of the baked headers.
- **No hand-rolled flag block.** Warnings, hardening and artefacts come from
  `embedded_hardening()` / `embedded_artifacts()` /
  `embedded_stack_usage()` in `/opt/embedded/cmake/embedded-common.cmake`. The
  f401 template's `VALIDATION_OPTS` / `OPTIMIZATIONS` / `LIBS` lists are
  superseded — do not carry them forward.
- **Hardware-independent logic goes in `src/logic/`**, which is the layout
  `/opt/embedded/cmake/host-test.cmake` expects: those files are listed as
  `UNDER_TEST` and compiled both ways — cross-compiled into the firmware and
  natively into the host-test binary. Host tests configure in their own build
  dir with **no** toolchain file (`cmake -S . -B build-host -DHOST_TESTS=ON`);
  `host-test.cmake` hard-errors if included while cross-compiling.
- **Target name is `${PROJECT_NAME}.elf`**, and `.mcu-profile.json`'s `ELF`
  must match it.
- **`build/` is generated.** The upstream f401 template commits it; do not.

### Skills in this layer

| Skill | Reach for it when |
|---|---|
| `cmsis-dsp-cpp` | **Directory form, indexed.** FIR/IIR/FFT/matrix/statistics/PID/Q15 math, adding CMSIS-DSP to a build, DSP link mismatches |
| `cortex-m-startup-cpp` | Writing C++ startup / `Reset_Handler` |
| `cortex-m-vector-table` | Vector table layout and placement |
| `cortex-m-fpu-enable` | Turning on the FPU (M4F/M7/M33/M55; M0/M0+/M3 have none) |
| `stm32-clock-config` | Writing RCC setup — flash latency before clock raise |
| `stm32-dma-setup` | DMA / DMAMUX configuration |
| `stm32-lowpower-modes` | Stop/Standby/Shutdown modes |
| `stm32-option-bytes` | Option bytes, RDP, write protection |
| `stm32-bootloader-dfu` | System bootloader / DFU entry |
| `stm32-part-lookup` | Decoding an STM32 order code to core/FPU/memory |
| `stm32wba-ble-bringup` | STM32WBA BLE bring-up |
| `mspm0c1104-quirks` | TI MSPM0C1104 gotchas |

Command: `/stm32-new-project`.

Everything except `cmsis-dsp-cpp` is still a flat `~/.claude/skills/<name>.md`
and will **not** trigger on its own — read the file directly when its topic
comes up. See the maintenance rule in the baseline layer.
