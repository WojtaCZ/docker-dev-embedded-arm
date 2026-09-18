# STM32 Low-Power Modes

Pick and enter the right low-power mode, and diagnose the two classic
complaints: "it never wakes up" and "the current is 100× the datasheet figure".

## Mode ladder

| Mode | Core | RAM | Peripherals | Wake sources | Wake cost |
| --- | --- | --- | --- | --- | --- |
| Sleep | stopped | on | all running | any interrupt | ~cycles |
| Stop 0 / Stop 1 | stopped | retained | most clocks off, regulator on | EXTI, RTC, LPUART, LPTIM, I2C addr match | µs |
| Stop 2 | stopped | retained | fewer peripherals available | EXTI, RTC, LPTIM | µs |
| Standby | **off** | **lost** (except backup + some SRAM2) | off | WKUP pins, RTC, IWDG, NRST | **full reset** |
| Shutdown | off | lost | off, no regulator | WKUP pins, RTC(LSE), NRST | full reset |

**Standby and Shutdown restart at the reset vector.** Code after `__WFI()` never
runs. If you expect execution to continue, you wanted Stop, not Standby. State
that must survive belongs in backup registers (`TAMP->BKPxR`) or retained SRAM2.

## Entering a mode

```cpp
#include "stm32wbaxx.h"

inline void enter_stop2() {
    // 1. Select the mode
    MODIFY_REG(PWR->CR1, PWR_CR1_LPMS, PWR_CR1_LPMS_STOP2);

    // 2. SLEEPDEEP so WFI goes to Stop rather than plain Sleep
    SCB->SCR |= SCB_SCR_SLEEPDEEP_Msk;

    // 3. Clear any pending wake flags, or WFI returns immediately
    PWR->SR1 |= PWR_SR1_CWUF;   // name varies by family

    __DSB();
    __WFI();

    // 4. Back from Stop: SYSCLK has reverted to HSI/MSI. Restore the PLL.
    SCB->SCR &= ~SCB_SCR_SLEEPDEEP_Msk;
    clock_init();
}
```

Step 4 is the one people forget. On exit from Stop the system clock is the
internal oscillator, not your PLL. Everything derived from `SystemCoreClock`
(UART baud, timer periods, delays) is silently wrong until you reconfigure.

## "It never wakes up"

Work through these in order:

1. **A pending interrupt before `__WFI()`** — `WFI` returns immediately if
   anything is already pending, so the code loops through sleep at full power.
   Clear pending flags first, and consider `__WFE()` + `SEV` + `__WFE()` for
   the race-free form.
2. **Wake source not enabled in the right place.** EXTI needs the line
   unmasked in `EXTI->IMR` *and* the NVIC IRQ enabled *and* (on many families)
   the wake-up line enabled in `PWR`.
3. **The peripheral does not exist in that mode.** USART1 cannot wake you from
   Stop 2 — LPUART1 can. TIM2 cannot — LPTIM1 can. Check the family's
   peripheral-availability table before choosing a wake source.
4. **RTC not clocked by LSE/LSI**, or the backup domain write-protected
   (`PWR->CR1.DBP` must be set before touching RTC config).
5. **`nRST_STOP` / `nRST_STDBY` option bits** set such that entering the mode
   triggers a reset instead. See the `stm32-option-bytes` skill.
6. **Debugger attached.** `DBGMCU->CR` keeps clocks alive in low-power modes;
   behaviour under the debugger genuinely differs from standalone. Measure
   current with the debugger detached.

## "The current is far too high"

Ranked by how often it is the cause:

1. **Floating GPIO inputs.** An undriven input with no pull toggles around the
   threshold and burns hundreds of µA per pin. Configure every unused pin as
   analog (`MODER = 0b11`) — this is the single biggest win and costs nothing.
2. **Debugger still enabled.** Clear `DBGMCU` low-power bits in the production
   build, or you keep the debug clock domain alive.
3. **Peripheral clocks left enabled** in `RCC->AHBxENR` / `APBxENR` for
   peripherals you are not using.
4. **Pull-ups fighting external circuitry** — an internal pull-up against an
   external pull-down is a permanent resistive path.
5. **The regulator left in high-power mode** — enable the low-power regulator
   for Stop modes.
6. **SRAM2 retention enabled** when you do not need it (Standby only).
7. **The wrong measurement.** Average current over a full duty cycle, not the
   instantaneous figure. A 10 ms 20 mA wake every second averages 200 µA, which
   swamps a 2 µA sleep figure — optimise the wake, not the sleep.

## Instrumenting

```cpp
// Toggle a GPIO around the awake window so a scope shows the real duty cycle.
inline void sleep_instrumented() {
    GPIOA->BSRR = GPIO_BSRR_BR_0;   // low = asleep
    enter_stop2();
    GPIOA->BSRR = GPIO_BSRR_BS_0;   // high = awake
}
```

Then: average current = (awake current × awake time + sleep current × sleep
time) / period. Compute it before optimising anything — it usually redirects
the effort.

## STM32WBA and the radio

- The BLE link layer has its **own** low-power integration. Do not call `__WFI`
  directly from application code once the stack is running — use ST's
  low-power manager, or you will sleep through a connection event and drop the
  link.
- The radio needs LSE running in Stop for its sleep timer. LSI's ±5 % is not
  accurate enough for BLE connection-event windows.
- Standby/Shutdown tear down the link layer entirely — you must re-initialise
  and re-advertise on wake.
- Radio activity dominates the power budget. Tune the advertising interval and
  connection interval first; sleep-current micro-optimisation is second-order
  next to a 30 ms connection interval.

## Audit checklist

```bash
grep -rn "WFI\|WFE\|SLEEPDEEP\|PWR->\|LPMS\|DBGMCU" --include="*.c" --include="*.cpp" . | head -30
```

- [ ] Mode actually matches the requirement (Stop if execution must continue)
- [ ] Wake flags cleared before `__WFI()`
- [ ] Clock reconfigured after every Stop exit
- [ ] Every unused GPIO set to analog mode
- [ ] `DBGMCU` low-power bits cleared in release builds
- [ ] Wake source is available in the chosen mode
- [ ] State that must survive Standby is in backup registers or retained SRAM
- [ ] Current measured as an average over a full cycle, debugger detached
