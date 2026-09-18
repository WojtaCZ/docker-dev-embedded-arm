# STM32 Part Number Lookup

Decode an STM32 part number into everything the build needs: core, FPU, float
ABI, memory map, flash tool, TrustZone presence, CMSIS device family, and SVD.
Used by `/scaffold-mcu-project` and `/stm32-new-project`.

## Part number anatomy

```
STM32 WBA 65 R I  T 6  TR
  |    |   |  |  |  |  |  └─ packing (TR = tape & reel)
  |    |   |  |  |  |  └──── temperature range
  |    |   |  |  |  └─────── package (T = LQFP, U = UFQFPN, I = UFBGA, ...)
  |    |   |  |  └────────── FLASH SIZE  ← the one people misread
  |    |   |  └───────────── pin count
  |    |   └──────────────── sub-family / feature set
  |    └──────────────────── family
  └───────────────────────── series
```

### Flash size code

| Code | Flash | Code | Flash |
| --- | --- | --- | --- |
| `4` | 16 KB | `C` | 256 KB |
| `6` | 32 KB | `D` | 384 KB |
| `8` | 64 KB | `E` | 512 KB |
| `B` | 128 KB | `F` | 768 KB |
| | | `G` | 1 MB |
| | | `H` | 1.5 MB |
| | | `I` | **2 MB** |

So `STM32WBA65RI` = WBA family, sub-family 65, pin code R, **2 MB flash**.

### Pin count code

| Code | Pins | Code | Pins |
| --- | --- | --- | --- |
| `F` | 20 | `R` | 64 |
| `G` | 28 | `V` | 100 |
| `K` | 32 | `Z` | 144 |
| `T` | 36 | `A` | 169 |
| `C` | 48 | `I` | 176 |
| `M` | 80 | | |

RAM is **not** encoded in the part number — look it up per sub-family.

## Family → core / FPU / tooling

| Family | Core | `-mfpu` | ABI | TrustZone | Flash tool | CMSIS device repo |
| --- | --- | --- | --- | --- | --- | --- |
| F0, G0, L0 | cortex-m0plus | none | soft | no | openocd | `f0` / `g0` / `l0` |
| F1, F2, L1 | cortex-m3 | none | soft | no | openocd | `f1` |
| F3, F4, G4, L4, WB55 | cortex-m4 | fpv4-sp-d16 | hard | no | openocd | `f3`/`f4`/`g4`/`l4`/`wb` |
| WL | cortex-m4 | none | soft | no | openocd | `wl` |
| F7, H7 | cortex-m7 | fpv5-d16 | hard | no | openocd | `f7` / `h7` |
| L5 | cortex-m33 | fpv5-sp-d16 | hard | **yes** | **probe-rs** | `l5` |
| U5 | cortex-m33 | fpv5-sp-d16 | hard | **yes** | **probe-rs** | `u5` |
| H5 | cortex-m33 | fpv5-sp-d16 | hard | **yes** | **probe-rs** | `h5` |
| **WBA (all)** | cortex-m33 | fpv5-sp-d16 | hard | **yes** | **probe-rs** | `wba` |

> Everything Cortex-M33 uses **probe-rs**. OpenOCD 0.12.0's STM32 flash driver
> (`stm32l4x.c`) does not enumerate these parts. For **WBA6x specifically**
> there is no OpenOCD support at all — not in 0.12, not in current master, and
> not in ST's own fork. Symptoms are `auto_probe failed` and
> `Failed to read memory at 0x40015800` even with a perfectly good ST-Link.

## Common parts, filled in

| Part | Core | Flash | RAM | Notes |
| --- | --- | --- | --- | --- |
| STM32F103C8 | cortex-m3 | 64 KB | 20 KB | "Blue Pill" |
| STM32F407VG | cortex-m4f | 1 MB | 128 KB + 64 KB CCM | CCM is not DMA-accessible |
| STM32G071RB | cortex-m0plus | 128 KB | 36 KB | |
| STM32G474RE | cortex-m4f | 512 KB | 128 KB | |
| STM32L432KC | cortex-m4f | 256 KB | 64 KB | |
| STM32WB55RG | cortex-m4f | 1 MB | 256 KB | **Dual-core**; BLE on a separate M0+ with ST firmware |
| STM32U575ZI | cortex-m33f | 2 MB | 786 KB | TrustZone |
| STM32H563ZI | cortex-m33f | 2 MB | 640 KB | TrustZone |
| **STM32WBA65RI** | **cortex-m33f** | **2 MB (2 × 1 MB banks)** | **448 KB + 64 KB SRAM2** | TrustZone; **single-core** BLE 5.4 / 802.15.4 |
| STM32WBA55CG | cortex-m33f | 1 MB | 128 KB | TrustZone; single-core BLE |

Flash always starts at `0x08000000`; SRAM1 at `0x20000000`.
For WBA65: SRAM1 `0x20000000`–`0x2006FFFF`, SRAM2 `0x20070000`–`0x2007FFFF`.

## Resolving a part in the container

```bash
# 1. Is the CMSIS device header present?
ls $STM32_CMSIS_DIR                       # families baked into the image
ls $STM32_CMSIS_DIR/wba/Include/          # e.g. stm32wba65xx.h

# 2. Startup file and linker template
ls $STM32_CMSIS_DIR/wba/Source/Templates/gcc/
ls $STM32_CMSIS_DIR/wba/Source/Templates/gcc/linker/

# 3. Does probe-rs know the part? (authoritative for flash/debug support)
probe-rs chip list | grep -i stm32wba65

# 4. SVD
svd-find stm32wba55            # the open mirrors cover WBA5x
svd-find --pack stm32wba65     # WBA6x needs ST's CMSIS-Pack
```

`probe-rs chip list` is the most reliable single check: if the part is there,
`probe-rs download` will work, and its entry also carries the true memory map.

## Reporting

When asked to resolve a part, always report:

1. Core, `-mcpu`, `-mfpu`, `-mfloat-abi`
2. Flash origin + size, RAM origin + size (all banks)
3. Whether it has TrustZone, and if so a pointer to the `stm32-option-bytes`
   skill before anything is flashed
4. Which flash tool to use, and **why** if it is not openocd
5. Whether the CMSIS device headers are in the image, and the exact
   `-D<PART>xx` macro to define (e.g. `-DSTM32WBA65xx`)
6. Whether an SVD was found, or that `--pack` is needed
7. A ready-to-paste `.mcu-profile.json` fragment

If you are not certain of a memory size, say so and point at
`probe-rs chip list` or the datasheet rather than guessing. A wrong `LENGTH` in
the linker script produces a binary that links cleanly and overruns real flash.
