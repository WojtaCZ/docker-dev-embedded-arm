# MSPM0C1104 Quirks

Practical constraints for the TI MSPM0C1104 — the "world's smallest MCU" (1.38 × 1.38 mm DSBGA-9). Cortex-M0+ core, 16 KB flash, 1 KB SRAM.

## Memory budget

```
Flash: 16 KB (0x00000000 – 0x00003FFF)
SRAM:  1 KB  (0x20000000 – 0x200003FF)
```

1 KB SRAM means everything that is not register-sized must be justified:
- Stack typically 512–768 bytes (barely fits).
- No heap. No `new`. No `std::string`.
- `.bss + .data + stack` must fit in 1 KB combined.

Check after every build:
```bash
arm-none-eabi-size build/firmware.elf
# data + bss must be well under 700 bytes to leave room for the stack
```

## C++ restrictions on 1 KB SRAM

- **No virtual dispatch** unless you have ≤3 polymorphic objects total. Each vtable pointer adds 4 bytes per object to the instance size and each vtable itself lives in `.rodata` in flash.
- **No `std::atomic<int64_t>`** — Cortex-M0+ is 32-bit; 64-bit atomics require a software library that takes ~200 bytes of flash.
- **No exception handling** (`-fno-exceptions` is mandatory here).
- **No `std::function`** — its internal storage and type-erasure mechanism consume 16–24 bytes per instance.
- `constexpr` and template metaprogramming are zero-cost at runtime — use aggressively.

## Flash budget

16 KB fits a useful application if you are disciplined:
- No `printf` (`printf` alone is ~4–8 KB). Use custom UART ring-buffer output.
- No `math.h` trig (soft-float sin/cos is ~2–4 KB). Use look-up tables.
- Every `#include` pulls in headers — check for accidental pulls of large STL headers.

Flash size check:
```bash
arm-none-eabi-nm -C --size-sort --print-size build/firmware.elf \
    | grep " [Tt] " | awk '{sum+=strtonum("0x"$1)} END{printf "text: %d bytes\n", sum}'
```

## Debug probe: TI XDS110 (on the LP-MSPM0C1104 LaunchPad)

openocd config file: `target/ti_mspm0.cfg`

```bash
openocd -f interface/xds110.cfg -f target/ti_mspm0.cfg \
        -c "program build/firmware.elf verify reset exit"
```

Supported from openocd 0.12+. Verify version: `openocd --version` (should show 0.12 or later).

## Toolchain flags

```cmake
target_compile_options(firmware PRIVATE
    -mcpu=cortex-m0plus
    -mthumb
    -mfloat-abi=soft    # M0+ has no FPU
    -Os                 # optimise for size, not speed — 16 KB budget
    -fno-exceptions
    -fno-rtti
    -ffunction-sections
    -fdata-sections
)
target_link_options(firmware PRIVATE
    -mcpu=cortex-m0plus
    -mthumb
    -Wl,--gc-sections
    -Wl,--print-memory-usage   # reports usage against MEMORY regions at link time
)
```

## CMSIS for MSPM0C1104

There is no official Arch package for the MSPM0C1104 CMSIS device header. Options:
1. Download the MSPM0 SDK from TI and extract `devices/MSPM0C110X/` headers (EULA-gated; do not redistribute).
2. Write a minimal device header manually from the TRM (viable for 1 KB SRAM parts — only a handful of peripherals).
3. Use `CMSIS_6` core headers from `/opt/cmsis/CMSIS/Core/Include/` and add only the device-specific register definitions.
