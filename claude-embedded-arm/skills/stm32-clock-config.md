# STM32 Clock Configuration

Write or audit RCC setup without the HAL. Complements the generic
`clock-tree-derive` skill, which reads existing code; this one writes it.

## The invariant order

Getting these out of order is the most common cause of "the chip runs, but at
the wrong speed" or "the chip hangs on the first flash access":

1. **Raise flash latency and enable the flash cache/prefetch** — *before*
   raising the clock. Running faster than the current wait states allows
   produces bus faults or silent instruction corruption.
2. **Set the voltage scaling range** — high-speed operation needs the higher
   VCORE range on L4/U5/WBA/H5. On U5/WBA also wait for `PWR_VOSR` to report
   ready.
3. **Enable and wait for the oscillator** (HSE/HSI/MSI).
4. **Configure the PLL, then enable it, then wait for lock.** Dividers cannot
   be changed while the PLL is running.
5. **Set AHB/APB prescalers** so no bus exceeds its maximum *at the moment* the
   switch happens.
6. **Switch SYSCLK**, then poll `RCC_CFGR.SWS` until the switch is confirmed.
7. **Lower flash latency** if the final clock is slower than the intermediate.
8. Update `SystemCoreClock`.

## Skeleton (adapt the register names per family)

```cpp
#include "stm32wbaxx.h"   // or your family header

// Every wait loop needs a bound. An unbounded `while (!(REG & FLAG))` on a
// board with no crystal fitted is an infinite hang with no diagnostic — the
// single most common bring-up failure.
template <typename Pred>
[[nodiscard]] bool wait_for(Pred p, uint32_t tries = 100'000) {
    while (tries--) {
        if (p()) return true;
    }
    return false;
}

[[nodiscard]] bool clock_init() {
    // 1. Flash latency FIRST
    MODIFY_REG(FLASH->ACR, FLASH_ACR_LATENCY, FLASH_ACR_LATENCY_3WS);
    if (!wait_for([] { return (FLASH->ACR & FLASH_ACR_LATENCY) == FLASH_ACR_LATENCY_3WS; }))
        return false;

    // 2. Voltage scaling (family-specific register)
    // ...

    // 3. Oscillator
    RCC->CR |= RCC_CR_HSEON;
    if (!wait_for([] { return RCC->CR & RCC_CR_HSERDY; })) return false;   // no crystal?

    // 4. PLL — configure while OFF
    RCC->CR &= ~RCC_CR_PLL1ON;
    if (!wait_for([] { return !(RCC->CR & RCC_CR_PLL1RDY); })) return false;
    // RCC->PLL1CFGR = ...;  M, N, P/Q/R and the input range bits
    RCC->CR |= RCC_CR_PLL1ON;
    if (!wait_for([] { return RCC->CR & RCC_CR_PLL1RDY; })) return false;

    // 5. Bus prescalers before the switch
    MODIFY_REG(RCC->CFGR2, RCC_CFGR2_HPRE | RCC_CFGR2_PPRE1 | RCC_CFGR2_PPRE2, 0);

    // 6. Switch and CONFIRM
    MODIFY_REG(RCC->CFGR1, RCC_CFGR1_SW, RCC_CFGR1_SW_1);
    if (!wait_for([] { return (RCC->CFGR1 & RCC_CFGR1_SWS) == RCC_CFGR1_SWS_1; }))
        return false;

    SystemCoreClockUpdate();
    return true;
}
```

`clock_init()` returning `false` should land somewhere visible — a slow blink,
an RTT message, a breakpoint — never be ignored. A board that silently runs on
HSI at 16 MHz when you expected 100 MHz produces baud rates, timer periods and
delays that are all wrong by the same confusing factor.

## Family-specific traps

| Family | Trap |
| --- | --- |
| F4 | `PLLM` must bring the PLL input into 1–2 MHz (2 MHz preferred). `PLLQ` must give exactly 48 MHz if USB is used. |
| F7/H7 | Enable the I-cache and D-cache (`SCB_EnableICache/DCache`) — and then remember DMA buffers need cache maintenance. |
| L4/G4 | MSI is the reset clock, not HSI. MSI range selection matters, and MSI can be PLL-trimmed against LSE. |
| U5 / H5 / **WBA** | `PWR` voltage scaling has a *ready flag* that must be polled before raising the clock. Skipping it works at room temperature and fails in the field. |
| **WBA** | The radio needs an accurate 32 MHz HSE **and** LSE (or LSI with degraded accuracy). See below. |
| WB55 | CPU2 owns some RCC bits; use the HSEM semaphore before touching shared clock config. |

## STM32WBA clock requirements for the radio

This is the part that catches people:

- **HSE must be 32 MHz.** The 2.4 GHz radio derives its reference from it —
  this is not a free choice, unlike on non-wireless parts.
- The HSE load capacitance is trimmed in software (`RCC_ECSCR1.HSETRIM`).
  Getting it wrong produces a frequency offset that shows up as poor BLE range
  or intermittent connection loss, not as an obvious failure.
- **LSE (32.768 kHz) is effectively required** for BLE. The link layer's sleep
  timing comes from it; LSI's ±5 % tolerance blows the connection-event window
  and causes random disconnects.
- The radio must not be active while switching SYSCLK. Do all clock setup
  before link-layer init.
- `RADIOSMEN` / the radio sleep clock configuration must be set before the link
  layer starts, or `LinkLayer` init fails in a way that looks like a stack bug.

## Auditing existing code

```bash
grep -rn "RCC->\|FLASH->ACR\|PWR->\|SystemClock_Config\|SystemInit" \
    --include="*.c" --include="*.cpp" --include="*.h" . | head -30
```

Check, in order:

- [ ] Flash latency raised **before** the clock, lowered **after** if slowing down
- [ ] Voltage scaling set and its ready flag polled
- [ ] Every `while (!(... & ...RDY))` has a timeout
- [ ] PLL dividers written while the PLL is off
- [ ] PLL input frequency inside the family's permitted range
- [ ] No bus exceeds its maximum during the switch, not just after it
- [ ] `RCC_CFGR.SWS` polled to confirm the switch actually happened
- [ ] `SystemCoreClock` updated, and everything deriving baud/timer values reads it
- [ ] Peripheral clock enables (`RCC->AHBxENR`) followed by a dummy read-back —
      several families need a couple of cycles before the peripheral is
      addressable, and a write immediately after the enable is lost
- [ ] For WBA: HSE = 32 MHz, LSE present, `HSETRIM` set

Then derive the resulting tree with the `clock-tree-derive` skill and compare it
against what the code *claims* in its comments. Those disagree more often than
not.
