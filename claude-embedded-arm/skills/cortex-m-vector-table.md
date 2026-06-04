# Cortex-M Vector Table

Audit or generate the vector table for a Cortex-M target, verify section placement, and check weak-alias patterns.

## How the Cortex-M vector table works

- Sits at address `0x00000000` (or wherever the chip's ROM remaps flash on reset; often `0x08000000` for STM32 with BOOT0=0).
- Word 0: initial stack pointer (`_estack`).
- Word 1: reset handler address (`Reset_Handler | 1` for Thumb — the toolchain adds the Thumb bit automatically).
- Words 2–15: standard Cortex-M exceptions (NMI, HardFault, MemManage, BusFault, UsageFault, ..., SVC, DebugMon, PendSV, SysTick).
- Words 16+: vendor-specific peripheral IRQs, in the order defined in the device header.

## Verifying table placement

```bash
# Check that .isr_vector is at FLASH origin
arm-none-eabi-objdump -h build/firmware.elf | grep -E "isr_vector|\.text"

# Dump the first 32 words — entries should be non-zero and the stack pointer word
# should point near the top of RAM
arm-none-eabi-objdump -s -j .isr_vector build/firmware.elf | head -20
```

The stack pointer entry (word 0) must equal `RAM_ORIGIN + RAM_SIZE`. If it reads `0x00000000` or a non-RAM address, `_estack` is not set or the section is at the wrong address.

## Checking for missing KEEP

```bash
# If .isr_vector is absent from the output, --gc-sections removed it
arm-none-eabi-nm build/firmware.elf | grep vector_table
```

Fix in linker script:
```ld
.isr_vector : {
    KEEP(*(.isr_vector))
} > FLASH
```

## Weak-alias pattern for IRQ handlers

```cpp
// Default handler — infinite loop so HardFault is visible in a debugger
extern "C" void Default_Handler() {
    __asm volatile("bkpt #0");  // triggers debug halt if debugger is attached
    for (;;) {}
}

// Any IRQ not explicitly defined falls through to Default_Handler
#define WEAK_IRQ(name) \
    extern "C" __attribute__((weak, alias("Default_Handler"))) void name()

WEAK_IRQ(USART1_IRQHandler);
WEAK_IRQ(DMA1_Channel1_IRQHandler);
// ... etc.
```

## Adding a new IRQ handler

1. Add a `WEAK_IRQ(NewIRQ_IRQHandler)` declaration in the startup file.
2. Add `NewIRQ_IRQHandler` at the correct position in the `vector_table[]` array (position = 16 + IRQ number from the device header).
3. Define `extern "C" void NewIRQ_IRQHandler()` in the application code — it overrides the weak alias.
4. Enable the IRQ: `NVIC_EnableIRQ(NewIRQ_IRQn)` and set priority: `NVIC_SetPriority(NewIRQ_IRQn, priority)`.

## VTOR (Vector Table Offset Register)

If running code from RAM (bootloader use case or RAM-mapped execution):
```cpp
SCB->VTOR = (uint32_t)&vector_table;  // tell the CPU where the table is
__DSB();
```
Not needed when running from the default flash address.
