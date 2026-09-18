# STM32WBA BLE Bring-Up

Get the 2.4 GHz radio working on STM32WBA (WBA52/55/65). This is the one part of
the fleet where a purely open toolchain is not possible — read §1 before
planning any work.

## 1. What you must accept up front

**STM32WBA is single-core.** Unlike the WB55 — which has a separate Cortex-M0+
network coprocessor running ST's pre-flashed firmware — the BLE 5.4 /
802.15.4 controller on WBA runs on the *same* Cortex-M33 as your application,
delivered as **precompiled static libraries**:

| Library | Role |
| --- | --- |
| `LinkLayer_BLE_Full_lib.a` (variants per part/version) | PHY + link layer |
| `stm32wba_ble_stack_full.a` (also `_basic`, `_llo`) | Host stack: GAP, GATT, L2CAP, SM |

Licence: ST **SLA0044 "Ultimate Liberty"** — see
`Middlewares/ST/STM32_WPAN/LICENSE.md` in STM32CubeWBA. Binary redistribution is
permitted for code running on ST devices.

Consequences to plan around:

1. **There is no open-source alternative.** No BLE on WBA without ST's blobs.
2. **The "no HAL" rule cannot hold completely for a BLE application.** The
   libraries have documented dependencies on ST's `Utilities/` glue — the
   sequencer (`stm32_seq`), timer server (`stm32_timer`) and low-power manager
   (`stm32_lpm`). A bare-metal, radio-free WBA65 application is entirely fine;
   a BLE one is not.
3. The blobs are **not** in this image. Supply them yourself.

## 2. Getting the stack into the container

STM32CubeWBA is public on GitHub but very large (all CubeMX examples). Use a
sparse checkout of just what you need:

```bash
git clone --filter=blob:none --sparse \
    https://github.com/STMicroelectronics/STM32CubeWBA ~/st/cubewba
cd ~/st/cubewba
git sparse-checkout set \
    Middlewares/ST/STM32_WPAN \
    Utilities/sequencer \
    Utilities/timer \
    Utilities/lpm \
    Drivers/CMSIS/Device/ST/STM32WBAxx
```

Then mount it read-only, following the same pattern the Telink leaf uses for its
EULA-restricted SDK:

```bash
./scripts/dev-up.sh -v ~/st/cubewba:/opt/st/cubewba:ro
# or add to devcontainer.json mounts
```

The CMSIS device headers you already have baked at `$STM32_CMSIS_DIR/wba`
(Apache-2.0) — you only need CubeWBA for the radio middleware.

## 3. Clock prerequisites — check these first

More WBA bring-up failures come from clocks than from the stack itself:

- **HSE must be exactly 32 MHz.** The radio derives its reference from it. This
  is not a free choice.
- **`HSETRIM` (`RCC_ECSCR1`) must be set for your crystal's load capacitance.**
  Wrong trim = frequency offset = short range and intermittent disconnects,
  with no obvious error anywhere.
- **LSE (32.768 kHz) is effectively mandatory.** The link layer's sleep timing
  uses it; LSI's ±5 % tolerance misses connection-event windows and produces
  apparently random disconnections.
- Complete all clock configuration **before** link-layer init. See the
  `stm32-clock-config` skill.

## 4. Initialisation order

The stack is order-sensitive and fails opaquely when it is wrong:

1. Clocks (HSE 32 MHz, LSE, PLL, voltage scaling ready flag polled)
2. `RADIOSMEN` / radio sleep-clock configuration in RCC
3. NVIC priorities set — **before** the link layer starts (see §5)
4. Sequencer init (`UTIL_SEQ_Init`)
5. Timer server init (`UTIL_TIMER_Init`) — needs the RTC running
6. Low-power manager init (`UTIL_LPM_Init`)
7. Random number generator — the stack needs entropy for pairing
8. `ll_sys_init()` / link layer init
9. BLE host stack init (`SVCCTL_Init`, `hci_init` equivalent)
10. GAP/GATT service registration
11. Start advertising

## 5. Interrupt priorities — the subtle one

**The radio ISR must not be preempted.** Miss its deadline and the link layer
loses the connection event; the symptom is intermittent disconnects under load
that look like an RF problem.

- Give the radio IRQ the **highest** (numerically lowest) application priority.
- Nothing — no DMA completion, no UART, no SysTick handler doing real work —
  may sit above it.
- Any long critical section (`__disable_irq()`, a flash write with the cache
  stalled, a `printf` from an ISR) is equally dangerous. Flash erase in
  particular stalls the bus for milliseconds; do it only between connection
  events, or use the stack's flash-manager hooks.

Run the `interrupt-priority-audit` skill after wiring anything new into the
NVIC, and check the radio IRQ is still at the top.

## 6. Linking

```cmake
target_link_libraries(firmware PRIVATE
    ${CUBEWBA}/Middlewares/ST/STM32_WPAN/link_layer/ll_cmd_lib/lib/LinkLayer_BLE_Full_lib.a
    ${CUBEWBA}/Middlewares/ST/STM32_WPAN/ble/stack/lib/stm32wba_ble_stack_full.a
)
```

These are prebuilt for **cortex-m33 + fpv5-sp-d16 + hard float**. Your
application must use exactly the same flags or the link fails with an ABI
mismatch, or worse, links and misbehaves. That is what
`-DARM_CORE=cortex-m33 -DARM_FPU=fpv5-sp-d16 -DARM_FLOAT_ABI=hard` in the
profile is for.

Pick the right stack variant:

| Variant | Use when |
| --- | --- |
| `_basic` | Peripheral-only, minimal features. Smallest. |
| `_full` | Central + peripheral, all features. |
| `_llo` | Link-layer-only — you supply your own host stack. |

## 7. Debugging

```bash
# probe-rs — REQUIRED on WBA65; OpenOCD 0.12 cannot flash or debug this part
probe-rs attach --chip STM32WBA65RI build/firmware.elf     # RTT log stream
mcu rtt
```

Use RTT rather than UART for stack logs: UART at 115200 is slow enough to
perturb radio timing, and RTT costs microseconds.

Useful things to log: connection interval actually negotiated, slave latency,
supervision timeout, and every disconnect reason code — the reason code alone
usually identifies the problem class.

## 8. Failure symptoms and causes

| Symptom | Likely cause |
| --- | --- |
| Link layer init returns an error | Clocks: HSE not 32 MHz, or LSE not running |
| Advertises but nothing connects | Advertising data malformed, or TX power/antenna |
| Connects then drops after ~1–5 s | Supervision timeout — missed connection events; check ISR priorities and long critical sections |
| Random disconnects under CPU load | Radio ISR being preempted, or a long `__disable_irq()` |
| Poor range | `HSETRIM` wrong, or antenna matching |
| Works on the dev kit, not the custom board | Crystal load caps, HSETRIM, antenna, or LSE missing |
| Flashes and never reaches `main()` | `TZEN=1` with a non-secure-only image — `stm32-option-bytes` |
| Hard fault inside a stack library | Almost always stack overflow — the BLE stack needs far more than a bare-metal app. Run `stack-usage-estimate` and budget generously. |

## 9. Before starting

- [ ] CubeWBA sparse checkout mounted at `/opt/st/cubewba`
- [ ] `chip`, `core: cortex-m33`, `fpu: fpv5-sp-d16`, `floatAbi: hard` set in `.mcu-profile.json`
- [ ] `flashTool: probe-rs` (OpenOCD will not work on WBA65)
- [ ] HSE 32 MHz and LSE fitted and configured
- [ ] SVD available: `svd-find --pack stm32wba65`
- [ ] Option bytes read and understood, especially `TZEN` — `stm32-option-bytes`
- [ ] Stack budget generous; `sizeBudget.ram` set from the real part figures
