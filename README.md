# docker-dev-embedded-arm

ARM Cortex-M development container for bare-metal C++. Covers **STM32** (every
family, including the ARMv8-M wireless parts such as **STM32WBA65**),
**RP2040**, **TI MSPM0**, and any other Cortex-M target.

No HAL, no vendor SDK. The image supplies the compiler, CMSIS core headers,
ST's Apache-2.0 CMSIS *device* headers (headers + startup + linker templates,
not the HAL), per-core CMSIS-DSP builds, SVDs, and STM32-specific Claude skills.

Inherits `docker-dev-embedded-base`, which provides the probe tools (openocd,
probe-rs, pyocd, st-link, dfu-util), gdb, clang tooling, the `mcu` task runner
and the shared VSCode templates.

> Design rationale, verified issues and the full STM32/WBA65 readiness
> assessment: [`WRITEUP.md`](WRITEUP.md).

## What this image adds

| | |
| --- | --- |
| Toolchain | `arm-none-eabi-gcc/g++/gdb/binutils` (GCC 16.x, newlib 4.6) |
| CMSIS_6 | `/opt/cmsis` → `$CMSIS_DIR` — includes `core_cm33.h` and the ARMv8-M TrustZone helpers |
| CMSIS-DSP | `/opt/cmsis-dsp/lib/<core>/` → `$CMSIS_DSP_DIR`, **one build per core** |
| ST CMSIS devices | `/opt/st/cmsis/<family>/` → `$STM32_CMSIS_DIR`, 16 families, Apache-2.0 |
| STM32 SVDs | `/opt/svd/stm32` (modm-io mirror), searched first by `svd-find` |
| CMake | `/opt/embedded/cmake/toolchains/arm-none-eabi.cmake` |
| Claude | 12 skills, `/stm32-new-project` command |
| `CROSS_PREFIX` | `arm-none-eabi-`, so the inherited binutils skills work here |

## Quick start

```bash
# 1. One-time host setup
sudo ./scripts/install-host-udev-rules.sh
sudo usermod -aG dialout,plugdev $USER      # log out and back in

# 2. Plug in the probe FIRST — /dev/bus/usb is bind-mounted at container start

# 3. Start the container
./scripts/dev-up.sh /path/to/your/firmware

# 4. Inside: create a project from a part number
/stm32-new-project STM32WBA65RI

# 5. Build, check size, flash
mcu build
mcu size
mcu flash
```

`dev-doctor` verifies the whole environment, including whether probe-rs knows
your part.

## Project layout

`/stm32-new-project` always produces the same tree, and the containerised
Claude is told to keep to it (`claude-embedded-arm/CLAUDE.layer.md`):

```
CMakeLists.txt  .mcu-profile.json  .gitignore  README.md
.vscode/{tasks,launch}.json
cmake/{toolchain-arm-none-eabi.cmake, linker.cmake}
linker/<PART>_FLASH.ld      svd/<PART>.svd
startup/   vendor asm + system_stm32<fam>xx.c
inc/       headers
src/       your sources; src/logic/ = hardware-independent, host-testable
lib/       third-party only, as submodules
test/host/ native unit tests, -DHOST_TESTS=ON
build/     generated, gitignored
```

It follows [WojtaCZ/f401-template](https://github.com/WojtaCZ/f401-template)
with four deliberate deviations, all because the image already provides the
equivalent: CMSIS is **not** vendored into `lib/` (use `$CMSIS_DIR` and
`$STM32_CMSIS_DIR`), flags come from `embedded_hardening()` rather than a
hand-rolled list, the linker script and SVD live in their own directories so a
TrustZone secure/non-secure pair fits, and `build/` is gitignored.

The per-project `cmake/toolchain-arm-none-eabi.cmake` is not boilerplate: it
pins `ARM_CORE`/`ARM_FPU`/`ARM_FLOAT_ABI` for the board and adds them to
`CMAKE_TRY_COMPILE_PLATFORM_VARIABLES`, without which CMake's compiler-ABI
sub-configure trips the shared toolchain file's `ARM_CORE` guard.

## STM32WBA65 and the other Cortex-M33 parts

**The compiler side is fine.** GCC 16.2 supports `cortex-m33`, `fpv5-sp-d16`,
and `-mcmse`; newlib ships the `v8-m.main` multilib (the image build fails if it
does not). CMSIS_6 has `core_cm33.h`. CMSIS-DSP is prebuilt for `cortex-m33f`.

**The flash/debug side needs probe-rs, not OpenOCD.**

| Tool | Classic STM32 | WBA5x | **WBA65** |
| --- | --- | --- | --- |
| OpenOCD 0.12.0 | ✅ | ⚠️ support landed upstream after the release | ❌ **not supported at all** |
| probe-rs 0.32 | ✅ | ✅ | ✅ |
| pyocd + CMSIS-Pack | ✅ | ✅ | ⚠️ via `pyocd pack install` |
| STM32CubeCLT | ✅ | ✅ | ✅ |

OpenOCD's STM32 flash driver (`stm32l4x.c`) enumerates WBA5x but not WBA6x, and
the WBA65 returns a different DP IDCODE than `stm32wbx.cfg` expects. The
symptoms are `auto_probe failed` and `Failed to read memory at 0x40015800` with
a perfectly good ST-Link. This is true of 0.12.0, of current master, and of ST's
own OpenOCD fork.

probe-rs carries the full WBA65 variant set with the correct memory map (2 MB in
two 1 MB banks, 448 KB SRAM1 + 64 KB SRAM2) and — importantly — applies the
**ARMv8-M** debug sequence. It drives ST-Link v2/v3 and CMSIS-DAP, so your
existing probes are fine.

`/stm32-new-project` selects the right tool automatically. The profile fragment:

```jsonc
{
  "chip": "STM32WBA65RI",
  "core": "cortex-m33", "fpu": "fpv5-sp-d16", "floatAbi": "hard",
  "flashTool": "probe-rs",
  "sizeBudget": { "flash": 2097152, "ram": 458752 },
  "flash":       "probe-rs download --chip ${chip} --binary-format elf ${ELF}",
  "debugServer": "probe-rs gdb --chip ${chip} --gdb-connection-string 0.0.0.0:3333",
  "rtt":         "probe-rs attach --chip ${chip} ${ELF}"
}
```

### TrustZone — the one way to lose hardware

L5, U5, H5 and all WBA parts have TrustZone. A device with `TZEN=1` and a
non-secure-only image flashes cleanly, resets, and never reaches `main()` —
which reads like a startup bug and is not one.

The `stm32-option-bytes` skill reads and explains RDP, TZEN, BOR, watermarks and
boot configuration, and refuses to write `RDP = 0xCC` (level 2), which is
permanent and unrecoverable. **This is the only irreversible operation in the
whole fleet.** Consult it before any option-byte write.

### BLE on WBA needs ST's binaries

WBA is **single-core**: unlike the WB55 there is no separate network
coprocessor, so the BLE 5.4 controller runs on your Cortex-M33 as precompiled
libraries from STM32CubeWBA (SLA0044). There is no open alternative, and the
stack depends on ST's sequencer/timer/low-power glue — a strictly no-ST-code BLE
build is not achievable. A radio-free WBA65 application is entirely fine.

Mount CubeWBA rather than baking it in:

```bash
git clone --filter=blob:none --sparse \
    https://github.com/STMicroelectronics/STM32CubeWBA ~/st/cubewba
cd ~/st/cubewba && git sparse-checkout set \
    Middlewares/ST/STM32_WPAN Utilities/sequencer Utilities/timer Utilities/lpm

./scripts/dev-up.sh     # auto-detects ~/st/cubewba and mounts it read-only
```

Using the **devcontainer** instead of `dev-up.sh`? `devcontainer.json` has no
conditional mount syntax, so the optional ST paths are deliberately not listed
there (Docker would create empty `~/st/*` directories on hosts that do not have
them). Add whichever you actually have to `.devcontainer/devcontainer.json`:

```jsonc
"mounts": [
  "source=${localEnv:HOME}/st/cubewba,target=/opt/st/cubewba,type=bind,readonly",
  "source=${localEnv:HOME}/st/STM32CubeCLT,target=/opt/st/clt,type=bind,readonly"
]
```

Then follow the `stm32wba-ble-bringup` skill, which covers the HSE 32 MHz /
`HSETRIM` / LSE requirements and the radio-ISR priority constraint that causes
most "random disconnect" bugs.

## Device headers, startup and linker scripts

16 ST CMSIS device families are baked in (Apache-2.0 — headers, startup files
and GCC linker templates; **not** the HAL):

```
wba f0 f1 f3 f4 f7 g0 g4 l0 l4 l5 u5 h5 h7 wb wl
```

```bash
ls $STM32_CMSIS_DIR/wba/Include/                          # stm32wba65xx.h, partition_stm32wbaxx.h
cp $STM32_CMSIS_DIR/wba/Source/Templates/gcc/startup_stm32wba65xx.s src/
ls $STM32_CMSIS_DIR/wba/Source/Templates/gcc/linker/
```

Add another family with
`git clone --depth=1 https://github.com/STMicroelectronics/cmsis-device-<fam>`,
or extend the `ST_FAMILIES` build arg.

Always verify a copied linker template's `MEMORY` block against the real part —
the templates are per-family and the sizes routinely need adjusting. The
`linker-script-audit` skill does this.

## CMSIS-DSP, per core

CMSIS-DSP ships no toolchain file and has no `ARM_CPU`/`FPU` CMake options; the
architecture comes entirely from the toolchain file's compile flags. Linking a
cortex-m4 (ARMv7E-M) library into a cortex-m33 (ARMv8-M) image is a mismatch, so
the image builds one library per core:

```
/opt/cmsis-dsp/lib/{cortex-m0plus,cortex-m3,cortex-m4f,cortex-m7f,cortex-m33f}/libCMSISDSP.a
```

```cmake
include(/opt/embedded/cmake/embedded-common.cmake)
find_cmsis_dsp(${CMSIS_DSP_CORE} DSP_LIB)     # set for you by the toolchain file
target_include_directories(firmware PRIVATE ${DSP_LIB_INCLUDE_DIRS})
target_link_libraries(firmware PRIVATE ${DSP_LIB})
```

Any other core: `build-cmsis-dsp cortex-m55` (run it with no arguments for the
list).

## Toolchain file

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/opt/embedded/cmake/toolchains/arm-none-eabi.cmake \
  -DARM_CORE=cortex-m33 -DARM_FPU=fpv5-sp-d16 -DARM_FLOAT_ABI=hard
```

`ARM_CORE` is **mandatory** — the file refuses to configure without it. A build
with no `-mcpu` links cleanly and produces a binary for the compiler's default
architecture, which then faults on the device with `UNDEFINSTR`. Pass
`-DARM_CMSE=ON` for a TrustZone secure image.

The profile's `build` command passes these from `core`/`fpu`/`floatAbi`, so
normally you just edit `.mcu-profile.json`.

## SVD files

```bash
svd-find stm32f407           # search
svd-find --set stm32f407     # write into .mcu-profile.json
svd-find --pack stm32wba65   # WBA6x is in no open mirror — pull ST's CMSIS-Pack
```

## Probes

| Probe | openocd interface | Also works with |
| --- | --- | --- |
| ST-Link v2 / v2-1 / v3 | `interface/stlink.cfg` | probe-rs, pyocd, st-flash |
| Black Magic Probe | (native GDB server on `/dev/ttyACM0`) | — |
| CMSIS-DAP / Picoprobe | `interface/cmsis-dap.cfg` | probe-rs, pyocd |
| TI XDS110 | `interface/xds110.cfg` | — |

`/probe-detect` reports what is connected and the exact next command to run.

## Claude skills (12)

**STM32-specific**

| Skill | Covers |
| --- | --- |
| `stm32-part-lookup` | Part number → core, FPU, memory map, flash tool, CMSIS family |
| `stm32-option-bytes` | RDP / TZEN / BOR / watermarks. Read-first, refuses RDP 2. **Safety-critical.** |
| `stm32-clock-config` | RCC/PLL order, flash latency, per-family traps, WBA radio clock rules |
| `stm32-dma-setup` | DMA/DMAMUX/GPDMA, cache coherency, idle-line RX, the four things that actually break |
| `stm32-lowpower-modes` | Stop/Standby/Shutdown, "never wakes up", "current too high" |
| `stm32-bootloader-dfu` | ROM bootloader, jumping to it, brick-proof custom bootloaders |
| `stm32wba-ble-bringup` | WBA radio: licensing reality, init order, ISR priorities, failure table |

**Cortex-M generic**

`cortex-m-startup-cpp` · `cortex-m-vector-table` · `cortex-m-fpu-enable` ·
`cmsis-dsp-cpp` · `mspm0c1104-quirks`

Plus the 11 architecture-neutral skills inherited from `embedded-base`
(including `hardfault-decode`, `linker-script-audit`, `stack-usage-estimate`).

## CI

Every push builds the image and then **cross-compiles a real STM32WBA65
firmware inside it** — CMSIS device headers, a linker script with the true WBA65
memory map, global C++ constructors, `find_cmsis_dsp()`, and a `readelf -A`
assertion that the output really is `Cortex-M33` with the hard-float ABI. It
also builds a Cortex-M0+ soft-float image to catch regressions at the other end
of the range. Nothing publishes unless both pass.

## Update propagation

Tracks `ghcr.io/wojtacz/docker-dev-embedded-base:${BASE_TAG}` (default `latest`;
`DEV_CHANNEL=stable` for the promoted channel). `dev-up.sh` passes `--pull`. CI
rebuilds on a `repository_dispatch` from the base image, and reports
`downstream-verified` back so the base's `:stable` tag can advance.
