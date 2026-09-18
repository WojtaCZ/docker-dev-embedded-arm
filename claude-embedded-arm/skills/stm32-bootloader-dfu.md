# STM32 Bootloader, DFU and Firmware Update

Use the built-in system bootloader, and write a custom one that does not brick
the field unit.

## The ROM system bootloader

Every STM32 ships a factory bootloader in system memory. It speaks USART, and
depending on the part also USB DFU, I²C, SPI and CAN. It cannot be erased.

**Entering it** — three routes, in order of preference:

1. **BOOT0 pin high at reset.** Non-destructive, always works, needs hardware
   access.
2. **Option bytes (`nBOOT0`/`nSWBOOT0`).** Software-selectable but a *persistent*
   change — read the `stm32-option-bytes` skill first.
3. **Jump from application code** — see below.

The AN2606 table lists the exact interfaces and pins per part; the peripheral
set differs a lot between families.

```bash
# Talk to the ROM bootloader over USB DFU
dfu-util -l
dfu-util -a 0 -s 0x08000000:leave -D build/firmware.bin

# Or over UART
STM32_Programmer_CLI -c port=/dev/ttyUSB0 br=115200 -w build/firmware.bin 0x08000000 -rst
```

## Jumping to the bootloader from application code

```cpp
// System memory address is family-specific — check AN2606 for your part.
// A wrong address jumps into nothing and hard faults.
constexpr uint32_t SYSTEM_MEMORY = 0x0BF90000;   // STM32WBA; NOT the same on F4/G0/H7

[[noreturn]] void jump_to_bootloader() {
    // 1. Stop everything that could fire mid-jump
    __disable_irq();
    SysTick->CTRL = 0;
    SysTick->LOAD = 0;
    SysTick->VAL  = 0;

    // 2. Clear every pending and enabled interrupt. A live DMA or UART IRQ
    //    firing after the vector table moves lands in the bootloader's table
    //    at an entry it never set up.
    for (uint32_t i = 0; i < 8; ++i) {
        NVIC->ICER[i] = 0xFFFFFFFF;
        NVIC->ICPR[i] = 0xFFFFFFFF;
    }

    // 3. Deinit the clock tree back to reset defaults. The bootloader assumes
    //    HSI and will mis-time its autobaud if you leave the PLL running.
    //    (family-specific RCC reset sequence here)

    // 4. Read the bootloader's stack pointer and reset vector
    const uint32_t sp    = *reinterpret_cast<volatile uint32_t*>(SYSTEM_MEMORY);
    const uint32_t entry = *reinterpret_cast<volatile uint32_t*>(SYSTEM_MEMORY + 4);

    // 5. Move the vector table, then set SP, then jump
    SCB->VTOR = SYSTEM_MEMORY;
    __DSB();
    __ISB();
    __set_MSP(sp);
    __enable_irq();
    reinterpret_cast<void(*)()>(entry)();
    for (;;) {}
}
```

Order matters: `VTOR` before `__set_MSP`, and both before the jump. Setting MSP
first and then touching any local variable corrupts the new stack.

## Signalling "enter bootloader" across a reset

The pattern that works in the field: write a magic value somewhere that
survives reset, then reset.

```cpp
// Backup registers survive a system reset (and Standby) as long as VBAT holds.
constexpr uint32_t BOOTLOADER_MAGIC = 0xB00710AD;

void request_bootloader() {
    __HAL_RCC_PWR_CLK_ENABLE();     // or the direct RCC write
    PWR->CR1 |= PWR_CR1_DBP;        // unlock the backup domain
    TAMP->BKP0R = BOOTLOADER_MAGIC;
    NVIC_SystemReset();
}

// Very early in Reset_Handler, BEFORE .data/.bss init:
void check_bootloader_request() {
    if (TAMP->BKP0R == BOOTLOADER_MAGIC) {
        TAMP->BKP0R = 0;            // clear FIRST, so a crash in the bootloader
        jump_to_bootloader();       // does not create a permanent boot loop
    }
}
```

Clearing the flag before jumping is not optional — leave it set and a failure
during update leaves the unit permanently in the bootloader.

## Custom bootloader: the rules that prevent bricks

1. **Never erase the running image before the new one is fully received and
   verified.** Use A/B banks where flash allows (WBA65's 2 × 1 MB dual bank is
   made for this) or an external flash staging area.
2. **Verify before switching.** CRC32 at minimum; a signature if the threat
   model warrants it. Verify the *written* flash, not the received buffer — that
   catches write failures too.
3. **Commit atomically.** A single word write that flips the active-bank
   marker, or `SWAP_BANK` in the option bytes. Anything multi-step can be
   interrupted by a power cut halfway.
4. **Roll back on failure to run.** The new image must set a "confirmed" flag
   within N seconds of boot; if the bootloader sees an unconfirmed image on the
   next boot, revert. This is what saves you from a firmware that flashes fine
   and then crashes on startup.
5. **Keep the bootloader small and never update it in the field.** Write-protect
   its sectors (`WRP`).
6. **The application's vector table must be relocated.** Set `SCB->VTOR` to the
   application base in the application's own startup, and offset the linker
   script's FLASH origin to match. A mismatch here means interrupts vector into
   the bootloader.

## Layout with a bootloader

```ld
/* Bootloader: linker.ld */
MEMORY {
  FLASH (rx) : ORIGIN = 0x08000000, LENGTH = 32K
  RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 448K
}

/* Application: linker.ld — origin moved past the bootloader */
MEMORY {
  FLASH (rx) : ORIGIN = 0x08008000, LENGTH = 1024K - 32K
  RAM  (rwx) : ORIGIN = 0x20000000, LENGTH = 448K
}
```

and in the application startup:

```cpp
SCB->VTOR = 0x08008000;
__DSB();
```

Cross-check both with the `linker-script-audit` skill — an application whose
`ORIGIN` and `VTOR` disagree boots, runs `main()`, and then hard faults on the
first interrupt.

## Verification

```bash
# Application really is at the offset you think
${CROSS_PREFIX}objdump -h build/firmware.elf | grep -E 'isr_vector|\.text'

# First word is a plausible stack pointer, second a Thumb address (odd)
${CROSS_PREFIX}objdump -s -j .isr_vector build/firmware.elf | head -3

# Image fits the partition
mcu size
```
