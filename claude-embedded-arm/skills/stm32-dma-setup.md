# STM32 DMA Setup

Configure DMA without the HAL, and audit existing DMA code for the failure
modes that only appear under load.

## Which DMA controller

| Family | Controller | Peripheral↔channel mapping |
| --- | --- | --- |
| F1, F0, L0, L1 | DMA1/2, fixed channels | Hard-wired per peripheral — check the reference manual table |
| F2, F4, F7, H7 | DMA1/2 with **streams + channels** | Stream chosen from a table; `FIFO` mode available |
| L4, G0, G4, WB, WL | DMA1/2 + **DMAMUX** | Any request → any channel |
| U5, H5, **WBA** | **GPDMA** (+ LPDMA on some) | Linked-list capable, very different register model |

Code written for one of these does not port to another. On WBA in particular,
GPDMA is not a superset of the older DMA — the descriptor/linked-list model is
mandatory for anything beyond a single transfer.

## The four things that actually break

### 1. Memory the DMA cannot reach

Not all RAM is DMA-accessible:

- **F4 CCM RAM** (`0x10000000`) — no DMA access at all. A buffer placed there
  silently transfers nothing.
- **H7** — D2/D3 domain SRAM vs DTCM. DTCM (`0x20000000`) is invisible to most
  DMA controllers. This is why so much H7 code puts buffers at `0x24000000`.
- **WBA SRAM2** — check retention and access rules per transfer type.

Force placement explicitly:

```cpp
__attribute__((section(".dma_buffer"), aligned(4)))
static uint8_t rx_buffer[256];
```

and give `.dma_buffer` a `MEMORY` region the controller can reach in the linker
script.

### 2. Cache coherency (F7, H7 — any part with a D-cache)

The CPU and DMA see different views of memory.

- **Before a memory→peripheral transfer:** `SCB_CleanDCache_by_Addr()` — push
  what the CPU wrote out to RAM.
- **After a peripheral→memory transfer:** `SCB_InvalidateDCache_by_Addr()` —
  drop the stale cache lines before reading.

Both take **32-byte-aligned addresses and 32-byte-multiple sizes**. An
unaligned invalidate corrupts the neighbouring variables that share the cache
line — a bug that presents as random unrelated data corruption.

Simpler alternative: mark the DMA region non-cacheable with the MPU. Slower,
but it removes an entire class of bug. Prefer it unless throughput demands
otherwise.

### 3. `volatile` and the compiler

A buffer written by DMA and read by the CPU must be `volatile`, or the compiler
will cache the value in a register and never see the update:

```cpp
static volatile bool transfer_done = false;   // set in the ISR
```

The buffer *contents* need a compiler barrier rather than `volatile` on every
element — `volatile` on a large array defeats all optimisation:

```cpp
while (!transfer_done) { }
__DMB();               // ordering barrier before reading the buffer
process(rx_buffer);
```

### 4. Error interrupts nobody enabled

Enable and handle **TEIF** (transfer error) and, on the FIFO-capable families,
**FEIF** (FIFO error). The default of ignoring them turns a hardware fault into
a silent hang, because the completion interrupt never arrives and the code waits
forever.

```cpp
// Always clear the flag in the ISR — a DMA IRQ whose flag is never cleared
// re-enters immediately and locks the CPU in the handler.
if (DMA1->ISR & DMA_ISR_TEIF1) {
    DMA1->IFCR = DMA_IFCR_CTEIF1;
    on_dma_error();
}
```

## Configuration order

1. **Disable the channel** and poll `EN` low. Most register fields are ignored
   while enabled — this is why "my config had no effect" is so common.
2. Clear all pending interrupt flags for that channel.
3. Set peripheral address, memory address, transfer count.
4. Set direction, increment modes, data widths, priority, circular/normal.
5. Set the DMAMUX request line (or the stream/channel selection on F4/F7/H7).
6. Enable the interrupts you will actually handle, **including TE**.
7. Enable the channel.
8. **Then** enable the peripheral's DMA request bit (`USART_CR3.DMAR`,
   `SPI_CR2.RXDMAEN`, …). Doing this before the channel is armed loses the
   first byte.

## Circular mode and half-transfer

For continuous ADC or UART RX, circular mode plus the half-transfer interrupt
gives you a double buffer for free:

```
HT interrupt -> first half is complete and stable, process buffer[0 .. N/2)
TC interrupt -> second half is complete,           process buffer[N/2 .. N)
```

If processing takes longer than half a buffer period you will read data being
overwritten underneath you. Size the buffer from the worst-case processing
time, not the average, and instrument it: compare `CNDTR` against where you
expect to be, and count overruns.

## UART idle-line + DMA (variable-length frames)

The idiomatic STM32 pattern for "receive a packet of unknown length":

1. Circular DMA into a large buffer.
2. Enable `USART_CR1.IDLEIE`.
3. In the IDLE ISR, read `CNDTR` to find how far DMA got, and process from the
   last known position to there.
4. Clear IDLE with `USART_ICR.IDLECF` — **not** the old
   read-`SR`-then-read-`DR` sequence, which does not exist on newer families.

This is the highest-value DMA pattern on STM32 and worth reaching for by
default over byte-at-a-time RX interrupts.

## Audit checklist

```bash
grep -rn "DMA\|GPDMA\|DMAMUX\|CNDTR\|CCR\|CPAR\|CMAR" --include="*.c" --include="*.cpp" . | head -30
```

- [ ] Buffer lives in memory the controller can reach
- [ ] Buffer is aligned to the transfer width (and to 32 bytes if cache maintenance is used)
- [ ] Cache clean/invalidate present on F7/H7, with aligned addresses and sizes
- [ ] Channel disabled before reconfiguration, and `EN` polled low
- [ ] Interrupt flags cleared before enabling
- [ ] **TE** interrupt enabled and handled
- [ ] Every ISR clears its flag
- [ ] Peripheral DMA request enabled *after* the channel
- [ ] Completion flags are `volatile`
- [ ] `__DMB()` before reading a completed buffer
- [ ] Data widths on both sides agree with the peripheral register width
- [ ] NVIC priority is compatible with anything the ISR touches — cross-check
      with the `interrupt-priority-audit` skill. On **WBA**, DMA must not
      preempt the radio ISR.
