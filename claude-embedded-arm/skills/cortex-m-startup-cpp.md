# Cortex-M Bare-Metal C++ Startup

Write or audit the bare-metal startup code for a Cortex-M target that correctly initialises the C++ runtime.

## Required startup sequence (reset handler)

```cpp
// startup.cpp
#include <stdint.h>

// Linker-defined symbols
extern uint32_t _sidata;   // LMA of .data (in FLASH)
extern uint32_t _sdata;    // VMA start of .data (in RAM)
extern uint32_t _edata;    // VMA end of .data
extern uint32_t _sbss;     // start of .bss
extern uint32_t _ebss;     // end of .bss
extern void (*__init_array_start)();  // C++ global constructors
extern void (*__init_array_end)();

int main();

extern "C" void Reset_Handler() {
    // 1. Copy .data from FLASH to RAM
    uint32_t* src = &_sidata;
    for (uint32_t* dst = &_sdata; dst < &_edata; ) {
        *dst++ = *src++;
    }

    // 2. Zero-initialise .bss
    for (uint32_t* dst = &_sbss; dst < &_ebss; ) {
        *dst++ = 0u;
    }

    // 3. Call C++ global constructors (.init_array)
    //    This MUST happen before main() or any function that uses global objects.
    for (void (**ctor)() = &__init_array_start; ctor < &__init_array_end; ++ctor) {
        (*ctor)();
    }

    // 4. Optional: enable FPU for Cortex-M4F/M7
    // SCB->CPACR |= (0xFU << 20);  // CP10 + CP11 full access
    // __DSB(); __ISB();

    main();

    // Should never reach here
    for (;;) {}
}
```

## Vector table

```cpp
// Minimal vector table — expand with actual IRQ handlers
extern "C" void Default_Handler() { for (;;) {} }

// Weak aliases so unused IRQs link to Default_Handler
#define WEAK_ALIAS(x) __attribute__((weak, alias("Default_Handler"))) void x()
WEAK_ALIAS(NMI_Handler);
WEAK_ALIAS(HardFault_Handler);
WEAK_ALIAS(SVC_Handler);
WEAK_ALIAS(PendSV_Handler);
WEAK_ALIAS(SysTick_Handler);

extern "C" uint32_t _estack;  // from linker script

__attribute__((section(".isr_vector"), used))
void (* const vector_table[])() = {
    (void(*)()) &_estack,    // Initial stack pointer
    Reset_Handler,
    NMI_Handler,
    HardFault_Handler,
    // ... MemManage, BusFault, UsageFault, 0,0,0,0,
    // SVC_Handler, DebugMon, 0, PendSV_Handler, SysTick_Handler,
    // then chip-specific IRQs in order from the Reference Manual
};
```

## CMakeLists.txt hooks

```cmake
target_sources(firmware PRIVATE src/startup.cpp)

# Ensure __init_array is not GC'd by the linker
target_link_options(firmware PRIVATE
    -Wl,--undefined=Reset_Handler   # keep reset handler even if nothing references it
)
```

## Checklist

- [ ] `_sidata` is `LOADADDR(.data)` in the linker script
- [ ] `.isr_vector` has `KEEP` in the linker script
- [ ] `.init_array` sections have `KEEP` in the linker script
- [ ] `__init_array_start` / `__init_array_end` are exported by the linker script
- [ ] FPU enabled before any floating-point operation if using an M4F/M7
- [ ] `-fno-threadsafe-statics` compile flag is present (no `__cxa_guard_acquire` calls in the binary)
