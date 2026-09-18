# docker-dev-embedded-arm — Functional Writeup

> Leaf image for ARM Cortex-M. Inherits `docker-dev-embedded-base`.
> Fleet-wide architecture: [`docker-dev-embedded-base/WRITEUP.md`](../docker-dev-embedded-base/WRITEUP.md)
>
> **Read §4 first if you care about STM32WBA65.**

> **Note:** the analysis below describes the repo *as it was audited* on
> 2026-09-02. Every defect listed has since been fixed and every proposal
> implemented — see **Status: implemented** at the end for the mapping. The
> analysis is kept because it records *why* the current design is the way it is.


---

## 1. Purpose and position

The ARM leaf turns the architecture-neutral `embedded-base` into a working
Cortex-M bare-metal C++ environment. It is deliberately **HAL-free and
SDK-free**: you bring your own linker script, startup file, and SVD. The image
provides the compiler, the CMSIS core headers, a DSP library, and five
Cortex-M-specific Claude skills.

```
docker-dev-template
  └── docker-dev-embedded-base    probes, GDB, clang tools, cmake, VSCode templates, 10 skills
       └── docker-dev-embedded-arm   ← THIS IMAGE
```

Declared target coverage: STM32 (all families), RP2040, TI MSPM0, "any other
Cortex-M".

## 2. What this image adds

| Addition | Path / value |
| --- | --- |
| `arm-none-eabi-gcc` + `g++` | Arch `extra`, currently **16.2.0** |
| `arm-none-eabi-newlib` | **4.6.0** (multilib) |
| `arm-none-eabi-gdb` | **17.2** |
| `arm-none-eabi-binutils` | **2.47** |
| CMSIS_6 core headers | `/opt/cmsis` → `$CMSIS_DIR` (Apache-2.0, header-only) |
| CMSIS-DSP | `/opt/cmsis-dsp` → `$CMSIS_DSP_DIR`, pre-built static lib |
| Default MCU profile | `/opt/embedded/profile.json` |
| Claude skills (5) | `cortex-m-startup-cpp`, `cortex-m-vector-table`, `cortex-m-fpu-enable`, `cmsis-dsp-cpp`, `mspm0c1104-quirks` |
| VSCode setting | `cortex-debug.armToolchainPath: /usr/bin` |

### `profile.json`

Ships a `_chips` crib table (stm32f4x, stm32g0x, stm32l4x, rp2040, ti_mspm0,
stm32_bmp) and openocd-based `flash` / `erase` / `reset` / `debugServer`
commands driven by `OPENOCD_INTERFACE` and `OPENOCD_TARGET`. Build uses
Ninja + a `cmake/arm-none-eabi.cmake` toolchain file with
`CMAKE_EXPORT_COMPILE_COMMANDS=ON` for clangd.

### The five skills

| Skill | Substance |
| --- | --- |
| `cortex-m-startup-cpp` | Full C++-correct reset handler: `.data` copy, `.bss` zero, **`.init_array` global-constructor loop**, optional FPU enable, then `main()`. Plus a linker-script checklist. This is the one that matters most — getting `.init_array` wrong is the classic silent bare-metal C++ bug. |
| `cortex-m-vector-table` | Table layout, `KEEP(*(.isr_vector))`, weak-alias IRQ pattern, `_estack` verification via `objdump`, VTOR for RAM execution. |
| `cortex-m-fpu-enable` | `SCB->CPACR` CP10/CP11 + `__DSB`/`__ISB`, per-core `-mfpu`/`-mfloat-abi` matrix, lazy stacking, and a verification step (`nm | grep __aeabi_f` should be empty). |
| `cmsis-dsp-cpp` | Linking the prebuilt lib, Q15/Q31 strong-typed wrappers, an FIR example, and rebuild instructions for other cores. |
| `mspm0c1104-quirks` | 16 KB flash / 1 KB SRAM budget discipline — no heap, no `std::function`, no `printf`, no virtual dispatch. |

Coverage note: all five are Cortex-M **generic** or **TI-specific**. There is
currently **no STM32-specific skill at all**, which is a gap given STM32 is the
primary use case. See §5.

---

## 3. Verified defects in this image

Checked against live Arch/AUR/GitHub sources on 2026-09-02.

| # | Severity | Finding |
| --- | --- | --- |
| **A0** | **Blocker (inherited)** | The parent `docker-dev-embedded-base` references **seven package names that do not exist**. This image cannot build until that is fixed. See [base writeup §5](../docker-dev-embedded-base/WRITEUP.md). |
| **A1** | **Blocker** | The CMSIS-DSP build passes `-DCMAKE_TOOLCHAIN_FILE=/opt/cmsis-dsp/cmake/toolchains/aarch32-gcc.cmake`. **That file does not exist.** CMSIS-DSP's `cmake/` directory contains only `CMSISDSPConfig.cmake.in`. CMake will fail at configure time. |
| **A2** | High | `-DARM_CPU="cortex-m4"` and `-DFPU=1` are **not CMSIS-DSP options**. `Source/CMakeLists.txt` declares `NEON`, `HELIUM`, `MVEF`, `MVEI`, `LOOPUNROLL`, `HOST`, `DISABLEFLOAT16` etc. — no `ARM_CPU`, no `FPU`. CMake would silently ignore them ("unused variable"). Core selection actually comes from the toolchain file's compile flags, which A1 means are absent. So even if A1 were patched with an empty toolchain file, the library would be built for the wrong architecture. |
| A3 | High | `settings.json` declares `fetch` as `npx -y @modelcontextprotocol/server-fetch`. **The npm package does not exist** (404). Use `uvx mcp-server-fetch`. |
| A4 | Medium | Even when built correctly, a **Cortex-M4 (ARMv7E-M)** CMSIS-DSP binary is the wrong artefact for Cortex-M33 (ARMv8-M Mainline) targets like STM32WBA65 or STM32U5/H5. Build attributes differ; at best you get linker warnings, at worst subtly wrong codegen assumptions. Ship per-core variants (see §5.2). |
| A5 | Medium | `profile.json`'s `_chips` table covers F4/G0/L4 + RP2040 + MSPM0 only. **No STM32WB, WBA, U5, H5, H7, G4, L5, C0, or WL entry** — i.e. none of the modern ARMv8-M parts. |
| A6 | Medium | No SVD files and no device headers. Every STM32 project needs `stm32XXxx.h`; the image provides only CMSIS *core* headers. Every user must solve this from scratch. Fixable, and freely licensed — see §4.4. |
| A7 | Low | This repo's `README` tells you to run `install-host-udev-rules.sh` "from docker-dev-embedded-base", but that script is not in this repo. Either vendor it or link it. |
| A8 | Low | `git clone --depth=1` of CMSIS_6 and CMSIS-DSP without a pinned tag means the image content drifts silently between builds. Pin to a release tag. |
| A9 | Low | `/scaffold-mcu-project arm` generates a CMakeLists with **no `-mcpu`** anywhere — the toolchain file only sets `-mthumb`. A build will succeed and produce a binary for the wrong core. It should ask for, or read from the profile, the target core. |

---

## 4. STM32 readiness assessment

This is the section you asked for. Short version:

> **Classic STM32 (F0/F1/F3/F4/G0/G4/L0/L4/WB55/WL): fully supported once the base
> image's package names are fixed.**
>
> **STM32WBA65: the compiler side is fine, but the default flash/debug path
> (OpenOCD) does not work. You must switch that family to `probe-rs`.**

### 4.1 Compile / link / debug — ✅ ready for WBA65

| Requirement for STM32WBA65 (Cortex-M33, ARMv8-M Mainline, TrustZone, FPU) | Status |
| --- | --- |
| `-mcpu=cortex-m33` | ✅ `arm-none-eabi-gcc` **16.2.0** — far newer than needed (M33 landed in GCC 7). |
| `-mfpu=fpv5-sp-d16 -mfloat-abi=hard` | ✅ Supported. |
| `-mcmse` (TrustZone secure gateways, non-secure callable) | ✅ Supported by GCC's ARM backend. |
| DSP extension (`__ARM_FEATURE_DSP`) | ✅ Present on WBA65's M33. |
| newlib multilib for `v8-m.main+fp/hard` | ✅ Expected from `arm-none-eabi-newlib` 4.6 (multilib build). Verify once with `arm-none-eabi-gcc -print-multi-lib \| grep v8-m.main`. |
| `arm-none-eabi-gdb` | ✅ 17.2. |
| CMSIS_6 core headers (`core_cm33.h`, `cmsis_gcc.h`) | ✅ Present in `/opt/cmsis`. |

**Verdict: the toolchain itself is not a problem.** Nothing about WBA65 needs a
compiler this image lacks.

### 4.2 Flash and debug — ❌ the default path fails on WBA65

The profile's `flash`/`erase`/`reset`/`debugServer` all go through **OpenOCD**.

| Tool | Classic STM32 | STM32WBA5x | **STM32WBA65** |
| --- | --- | --- | --- |
| **OpenOCD 0.12.0** (Arch `extra`, what this image installs) | ✅ | ⚠️ flash driver support for `DEVID_STM32WBA5X` (0x492) exists upstream, but landed **after** 0.12.0 | ❌ **Not supported** |
| **probe-rs 0.32.0** | ✅ | ✅ | ✅ **Full support** |
| **pyOCD + CMSIS-Pack** | ✅ | ✅ | ⚠️ likely, via `Keil.STM32WBAxx_DFP` |
| **STM32CubeCLT / STM32_Programmer_CLI** | ✅ | ✅ | ✅ (ST's own tool) |

**Why OpenOCD fails on WBA65.** Its STM32 flash support lives in
`src/flash/nor/stm32l4x.c`, whose device table enumerates WBA5x but not WBA6x.
The WBA65 also returns a different DP IDCODE (`0x0be12477`) than the `stm32wbx.cfg`
expectation (`0x6ba02477`). Users hit `auto_probe failed` and
`Failed to read memory at 0x40015800`. This is reported against OpenOCD 0.12.0,
0.12.0+dev (Oct 2025), **and** ST's own OpenOCD fork — so a newer OpenOCD does
not rescue you today.

**Why probe-rs works.** probe-rs 0.32.0's `STM32WBA_Series.yaml` carries the full
WBA65 variant set — `STM32WBA65RI / RG / CI / CG / MI / MG / PI / PG` — with the
correct memory map (dual 1 MB flash banks at `0x08000000`, 448 KB SRAM +
64 KB SRAM2), the `stm32wbax_2m_0800` flash algorithm, and — crucially — the
**ARMv8-M debug sequence** rather than the ARMv7 one. probe-rs is also now in
Arch `extra` (0.32.0), so it needs no AUR detour.

### 4.3 Recommended WBA65 profile

Add to `profile.json`'s `_chips` table and use as the default for WBA:

```jsonc
{
  "chip":        "STM32WBA65RI",
  "flash":       "probe-rs download --chip STM32WBA65RI --binary-format elf build/firmware.elf",
  "erase":       "probe-rs erase --chip STM32WBA65RI",
  "reset":       "probe-rs reset --chip STM32WBA65RI",
  "debugServer": "probe-rs gdb --chip STM32WBA65RI --gdb-connection-string 0.0.0.0:3333",
  "rtt":         "probe-rs attach --chip STM32WBA65RI build/firmware.elf"
}
```

`probe-rs` works over ST-Link v2/v3 and CMSIS-DAP, so your existing probes are
fine. Note `probe-rs gdb` replaces the openocd server in `launch.json` — the
Cortex-Debug config needs `servertype: external` pointing at `:3333`, or switch
to `servertype: "probe-rs"` if you install the probe-rs VSCode extension.

### 4.4 What is still missing for WBA65 (and every STM32)

**Device headers, startup, linker script — free and redistributable, just add them.**

ST publishes per-family CMSIS device components on GitHub under **Apache-2.0**:

```dockerfile
RUN git clone --depth=1 --branch v1.6.0 \
        https://github.com/STMicroelectronics/cmsis-device-wba /opt/st/cmsis-device-wba
ENV STM32WBA_CMSIS=/opt/st/cmsis-device-wba
```

Verified contents:
- `Include/stm32wba65xx.h` ✅ and `Include/stm32wbaxx.h` ✅
- `Include/partition_stm32wbaxx.h` ✅ — the **TrustZone SAU/IDAU partition
  header**, which you need the moment `TZEN=1`
- `Source/Templates/gcc/startup_stm32wba65xx.s` ✅
- `Source/Templates/gcc/linker/` ✅

Do the same for whichever classic families you use (`cmsis-device-f4`,
`cmsis-device-g0`, `cmsis-device-l4`, …) — all Apache-2.0 or BSD-3-Clause. This
costs a few tens of MB and eliminates the single biggest per-project setup tax.
It is *not* the HAL, so it does not violate the no-HAL rule.

**SVD.** `modm-io/cmsis-svd-stm32` (the usual open mirror) currently has a
`stm32wba5` directory but **no `stm32wba6`**. For WBA65 get the SVD from ST's
CMSIS-Pack (`Keil.STM32WBAxx_DFP`, latest 2.2.0, which lists WBA6x devices) or
from st.com. `pyocd pack install` can fetch the pack for you.

**The radio — the real constraint.** STM32WBA is **single-core**: unlike the
WB55 (which has a separate Cortex-M0+ network coprocessor running a
pre-flashed ST firmware), the BLE 5.4 / 802.15.4 controller on WBA runs on the
*same* Cortex-M33 as your application, delivered as **precompiled static
libraries** in STM32CubeWBA:

- Link Layer: `LinkLayer_BLE_Full_lib.a` (and variants)
- Host stack: `stm32wba_ble_stack_full.a` (and `_basic` / `_llo` variants)

These are binary blobs under ST's **SLA0044 "Ultimate Liberty"** licence
(`Middlewares/ST/STM32_WPAN/LICENSE.md` in the STM32CubeWBA repo). Practical
consequences:

1. **You cannot do BLE on WBA65 without ST's blobs.** There is no open
   alternative today. Plan for it.
2. They are not HAL, but they *do* have a documented dependency on ST's
   sequencer/timer-server/low-power-manager glue from `Utilities/` — so a
   strictly "no ST code" build is not achievable for a BLE application. A
   bare-metal, radio-free WBA65 app is fine.
3. STM32CubeWBA is public on GitHub, so a build-time `git clone` works — but the
   full repo is large. Use a sparse checkout of
   `Middlewares/ST/STM32_WPAN` + `Drivers/CMSIS/Device/ST/STM32WBAxx`, or follow
   the Telink pattern and mount a host-side copy at `/opt/st/cubewba`.

**TrustZone.** WBA65 ships with `TZEN` configurable. Once secure mode is enabled
the debug/erase flow changes (secure/non-secure watermarks, `RDP` interaction,
and a device that can lock itself out). Two guardrails worth adding:
a `stm32-option-bytes` skill (read/verify RDP, TZEN, BOR, `SECWM`/`HDP` before
any write) and a hard rule that Claude never writes option bytes without
explicit confirmation. **This is the one place in the fleet where an autonomous
agent can brick hardware.**

### 4.5 Optional: STM32CubeCLT as an escape hatch

ST's **STM32CubeCLT** is an all-in-one Linux CLI bundle (STM32_Programmer_CLI,
ST-LINK GDB server, ST's OpenOCD fork, arm-none-eabi toolchain). It tracks new
silicon on day one, so it is the guaranteed-correct path for any part OpenOCD
has not caught up with. It needs an ST account to download, so mount it from the
host rather than baking it:

```bash
-v ~/st/STM32CubeCLT:/opt/st/clt:ro
```

Then `flash: "/opt/st/clt/STM32CubeProgrammer/bin/STM32_Programmer_CLI -c port=SWD -w build/firmware.elf -rst"`.

Note the ST OpenOCD fork was *also* reported missing WBA65 support — use
`STM32_Programmer_CLI` and the ST-LINK GDB server from that bundle, not its
OpenOCD.

### 4.6 Bottom line

| Question | Answer |
| --- | --- |
| Are all toolchains available for basic STM32? | **Yes** — after fixing the base image's seven bad package names. GCC 16.2, newlib 4.6, GDB 17.2, OpenOCD 0.12, ST-Link, probe-rs all present and current. |
| Can I safely develop for STM32WBA65? | **Yes for compile/link/debug.** But you must (a) fix the base build, (b) switch the WBA profile from OpenOCD to **probe-rs**, (c) add `cmsis-device-wba` headers, and (d) accept ST's binary BLE stack if you need the radio. |
| Biggest risk? | Option bytes / TrustZone on WBA65 under an autonomous agent. Add a confirmation gate. |
| Smallest high-value fix? | Move `probe-rs` from the (non-existent) AUR package to `pacman -S probe-rs`, and make it the default flash tool for anything ARMv8-M. |

---

## 5. Proposed features

### 5.1 STM32 device-support layer — highest value

Bake the Apache-2.0 `STMicroelectronics/cmsis-device-*` repos for the families
you use, plus an SVD store, plus a `stm32-new-project <part-number>` command that
looks up the part and emits a correct linker script, startup file, `-mcpu` flags,
and profile in one shot. Today every new chip is a manual archaeology exercise.

### 5.2 Multi-core CMSIS-DSP (fixes A1/A2/A4)

Build the library once per core into `/opt/cmsis-dsp/lib/<core>/libCMSISDSP.a`
for `cortex-m0plus`, `cortex-m4f`, `cortex-m33f`, `cortex-m7f`, using **your own**
toolchain files (CMSIS-DSP does not ship one):

```cmake
# /opt/cmsis-dsp/tc/cortex-m33f.cmake
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-none-eabi-gcc)
set(CMAKE_CXX_COMPILER arm-none-eabi-g++)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(FLAGS "-mcpu=cortex-m33 -mthumb -mfpu=fpv5-sp-d16 -mfloat-abi=hard")
set(CMAKE_C_FLAGS_INIT   "${FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${FLAGS}")
```

Configure with `-DCMSISCORE=/opt/cmsis/CMSIS/Core/Include` and build target
`CMSISDSP`. Provide a `find_cmsis_dsp(core)` CMake helper so projects pick the
right one automatically.

### 5.3 A `stm32-option-bytes` safety skill

Read and explain RDP level, TZEN, BOR level, WRP/PCROP/HDP/SECWM before any
write; refuse RDP level-2 transitions; always dump current state first. The one
irreversible operation in the whole workflow.

### 5.4 STM32-specific skills to fill the gap

There are five Cortex-M skills and zero STM32 skills. Worth adding:
`stm32-clock-config` (RCC/PLL per family, including WBA's HSE/LSE + radio clock
requirements), `stm32-dma-setup`, `stm32-lowpower-modes` (STOP0/1/2, Standby,
and how they interact with the WBA radio), `stm32-bootloader-dfu`.

### 5.5 WBA BLE bring-up skill

Once the CubeWBA blobs are mountable: a skill covering the link-layer
initialisation order, the sequencer/timer-server dependency, RF calibration, and
the `HAL_RADIO`/`LINKLAYER` IRQ priority constraints (which are strict — the
radio ISR must not be preempted, and getting NVIC priorities wrong here produces
intermittent, hard-to-diagnose disconnections). This pairs naturally with the
existing `interrupt-priority-audit` skill.

### 5.6 Core-aware scaffolding (fixes A9)

`/scaffold-mcu-project arm` should take a part number, then emit the matching
`-mcpu`/`-mfpu`/`-mfloat-abi` triple into the generated toolchain file rather
than a bare `-mthumb`.

### 5.7 Pin the vendored git clones (fixes A8)

`--branch <tag>` on the CMSIS_6 and CMSIS-DSP clones, with the tag as a
`Dockerfile` `ARG` so bumps are visible in the diff.

---

## Status: implemented 2026-09-02

Everything proposed in section 5 is now in the repo, and every defect in
section 3 is fixed. The analysis above is kept as the record of *why*.

| Item | Resolution |
| --- | --- |
| A0 — parent could not build | fixed in `docker-dev-embedded-base` |
| A1/A2 — CMSIS-DSP toolchain file and options that do not exist | `cmake/build-cmsis-dsp.sh` generates a real toolchain file per core; `-DARM_CPU`/`-DFPU` dropped |
| A4 / 5.2 — one library for all cores | built per core into `/opt/cmsis-dsp/lib/<core>/`, selected by `find_cmsis_dsp()`; the smoke test asserts m33f and m4f really differ |
| A3 — non-existent `fetch` npm package | fixed upstream in the embedded layer; this leaf's layer adds nothing |
| A5 — chip table missing modern parts | `profile.json` covers F0 through H7, WB55, WL, L5, U5, H5, **WBA5x, WBA65**, RP2040 and MSPM0, each with core/FPU/ABI/flashTool |
| A6 — no device headers or SVDs | 16 ST `cmsis-device-*` families (Apache-2.0) at `$STM32_CMSIS_DIR`; modm-io STM32 SVD mirror at `/opt/svd/stm32` |
| A7 — README referenced a script in another repo | `scripts/install-host-udev-rules.sh` and `udev-rules/` vendored here |
| A8 — unpinned clones | `CMSIS_6_REF`, `CMSIS_DSP_REF`, `SVD_STM32_REF`, `ST_FAMILIES`, `DSP_CORES` build args |
| A9 / 5.6 — scaffold emitted no `-mcpu` | `cmake/toolchains/arm-none-eabi.cmake` **refuses to configure without `ARM_CORE`**; `/stm32-new-project` resolves it from the part number |
| 5.1 — device-support layer | ST CMSIS headers plus `/stm32-new-project` and `stm32-part-lookup` |
| 5.3 — option-byte safety | `stm32-option-bytes` skill: read-first, refuses RDP level 2, explains TZEN |
| 5.4 — STM32 skills | `stm32-clock-config`, `stm32-dma-setup`, `stm32-lowpower-modes`, `stm32-bootloader-dfu` |
| 5.5 — WBA BLE skill | `stm32wba-ble-bringup` |

**WBA65 specifically:** the image build fails if newlib lacks the `v8-m.main`
multilib; `profile.json` selects `probe-rs` for every Cortex-M33 part; and CI
cross-compiles a real STM32WBA65 firmware against the true memory map, then
asserts via `readelf -A` that the output is `Cortex-M33` with the hard-float
ABI. A green CI run is evidence that WBA65 development works in this image.

Still on you, because they cannot be baked in:

- **STM32CubeWBA** for the BLE stack (SLA0044 binaries) — host-mounted, auto-detected at `~/st/cubewba`
- **STM32CubeCLT** if you want ST's own programmer — host-mounted at `~/st/STM32CubeCLT`
- A **WBA6x SVD** — `svd-find --pack stm32wba65`, since no open mirror carries one
