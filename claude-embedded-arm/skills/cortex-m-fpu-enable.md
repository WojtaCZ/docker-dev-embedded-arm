# Cortex-M FPU Enable

Enable the hardware FPU on Cortex-M4F, M7, M33, and M55 targets. Skip this on M0/M0+/M3 — they have no FPU.

## Check if the target has an FPU

```bash
arm-none-eabi-gcc -mcpu=<target> -Q --help=target | grep -E "mfpu|mfloat-abi"
```

Or check the device header: if `__FPU_PRESENT == 1`, the FPU is present.

## Enabling the FPU (must run before any FP instruction)

```cpp
// In Reset_Handler, before __libc_init_array and main()
// CPACR is at 0xE000ED88
// Bits [21:20] = CP10, bits [23:22] = CP11 — set both to 0b11 (full access)
#include "cmsis_compiler.h"  // provides __DSB / __ISB

inline void enable_fpu() {
    SCB->CPACR |= (0xFU << 20);  // CP10 and CP11 full access
    __DSB();   // wait for the store to complete
    __ISB();   // flush pipeline — FP instructions can now execute
}
```

## CMake compiler flags for FPU

```cmake
# Cortex-M4 with FPU (hard float ABI)
target_compile_options(<target> PRIVATE
    -mcpu=cortex-m4
    -mfpu=fpv4-sp-d16
    -mfloat-abi=hard
    -mthumb
)
target_link_options(<target> PRIVATE
    -mcpu=cortex-m4
    -mfpu=fpv4-sp-d16
    -mfloat-abi=hard
    -mthumb
)

# Cortex-M7 (single and double precision)
# -mfpu=fpv5-d16  -mfloat-abi=hard

# Cortex-M33 (FPU optional — check device)
# -mcpu=cortex-m33  -mfpu=fpv5-sp-d16  -mfloat-abi=hard
```

`-mfloat-abi=hard`: float args passed in FPU registers (fastest, requires FPU).
`-mfloat-abi=softfp`: ABI compatible with soft-float callers but uses FPU internally.
`-mfloat-abi=soft`: no FPU — uses software emulation library (slowest, for M0/M3 without FPU).

## Lazy stacking

Cortex-M4/M7 defaults to **lazy stacking** — FP context is reserved on the stack on exception entry but only saved if the ISR actually uses FP. This is the correct default for RTOS use; only change it if you have a specific reason.

Verify lazy stacking is active:
```c
// FPCCRr.LSPEN should be 1 (default after reset)
// FPU->FPCCR & FPU_FPCCR_LSPEN_Msk
```

## Verification

Build with FPU flags and check for soft-float emulation calls:
```bash
arm-none-eabi-nm build/firmware.elf | grep -E "__aeabi_f|__aeabi_d|__addsf|__mulsf"
# These should NOT appear if -mfloat-abi=hard is working correctly
```

Check the first instruction in an FP function is a VLDR/VMOV, not a BL to `__aeabi_*`:
```bash
arm-none-eabi-objdump -d build/firmware.elf | grep -A5 "<my_float_function>:"
```
