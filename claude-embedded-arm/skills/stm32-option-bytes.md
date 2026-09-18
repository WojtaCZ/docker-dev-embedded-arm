# STM32 Option Bytes — Read, Explain, and Guard

Option bytes are the only genuinely **irreversible** operation in this
container. Everything else — a bad linker script, a wrong `-mcpu`, a corrupt
flash image — is recoverable with another flash cycle. An RDP level-2 write is
not: the debug port is permanently disabled and the part becomes e-waste.

## Hard rules

1. **Never write option bytes without explicit, specific confirmation from the
   user**, naming the exact bit being changed and its current value. "Yes go
   ahead" to an earlier, different question does not count.
2. **Always read and report the current state first.** Never write blind.
3. **Refuse `RDP = 0xCC` (level 2) outright.** It is one-way on every STM32
   family. If the user insists, state plainly that this permanently destroys
   debug access and ask them to run the command themselves.
4. **Treat `TZEN` as one-way in practice.** Clearing it requires a full
   RDP 1 → 0 regression, which mass-erases the device, and on some parts the
   sequence is order-sensitive enough to brick the chip if interrupted.
5. **Warn before any `RDP 1 → 0` regression** — it mass-erases user flash.
   That is the intended escape hatch, but it destroys the firmware and any
   calibration data stored in flash.

## Step 1: Read the current state

Prefer ST's own tool when a host-mounted STM32CubeCLT is available — it decodes
every field by name and knows the per-part layout:

```bash
/opt/st/clt/STM32CubeProgrammer/bin/STM32_Programmer_CLI -c port=SWD mode=UR -ob displ
```

Otherwise, with probe-rs (works on WBA/U5/H5, where OpenOCD does not):

```bash
# FLASH_OPTR — the main option register. Base address is family-specific:
#   WBA / U5 / H5 : 0x40022040
#   L4 / G4 / WB  : 0x40022020
#   F4            : 0x40023C14 (OPTCR)
probe-rs read --chip "$chip" b32 0x40022040 4
```

Or with OpenOCD on the families it supports:

```bash
openocd -f "$OPENOCD_INTERFACE" -f "$OPENOCD_TARGET" \
    -c "init; halt; stm32l4x option_read 0 0; exit"
```

## Step 2: Decode and report

Always report **all** of these, even the ones the user did not ask about — the
dangerous interactions are between fields.

### RDP — Readout Protection

| Value | Level | Meaning |
| --- | --- | --- |
| `0xAA` | 0 | No protection. Full debug, full flash access. |
| `0xCC` | **2** | **PERMANENT.** Debug port dead, bootloader dead, no way back. **Never write this.** |
| anything else | 1 | Debug allowed but flash unreadable while connected. Reverting to level 0 mass-erases. |

Note the asymmetry: level 1 is *any* value that is not `0xAA` or `0xCC`, so a
partial or corrupted write to `OPTR` lands you in level 1 by accident.

### TZEN — TrustZone enable (L5, U5, H5, WBA)

| Value | Meaning |
| --- | --- |
| 0 | TrustZone disabled. The whole device is non-secure; ordinary single-image development. |
| 1 | TrustZone enabled. Flash and SRAM split by watermark into secure / non-secure. A non-secure-only image will not boot, and the debug connection must target the right security state. |

With `TZEN=1` you must also account for `SECWM1_PSTRT`/`SECWM1_PEND`
(secure watermark, per bank), `HDP1_PEND` (hide-protection area), and the
`SAU`/`IDAU` configuration in `partition_stm32wbaxx.h`.

**Symptom worth recognising:** a device that flashes successfully, resets, and
never reaches `main()` — with the debugger unable to halt it — very often has
`TZEN=1` and a non-secure-only image, not a startup-code bug.

### Other fields to report

| Field | Why it matters |
| --- | --- |
| `BOR_LEV` | Brown-out reset threshold. Too low and the part runs unreliably at the bottom of the supply range; too high and it will not start from a slow-rising rail. |
| `nBOOT0` / `nSWBOOT0` / `BOOT_LOCK` | Where the part boots from. Getting these wrong can lock you out of the system bootloader. |
| `nRST_STOP` / `nRST_STDBY` / `nRST_SHDW` | Whether entering a low-power mode triggers a reset. A classic cause of "my board resets whenever it sleeps". |
| `WRP1A/B`, `WRP2A/B` | Write-protected flash sectors. Flashing silently fails, or fails with a confusing error, on a protected sector. |
| `PCROP` / `HDP` | Read-out-protected code regions. On some families PCROP disable is only possible with a mass erase. |
| `SRAM2_RST`, `SRAM2_PE` | SRAM retention and parity — can cause hard faults after wake that look like stack corruption. |
| `IWDG_SW` / `IWDG_STOP` / `IWDG_STDBY` | Hardware watchdog forced on. If `IWDG_SW=0` the watchdog starts automatically and will reset a target sitting at a breakpoint. |
| `DUALBANK` / `SWAP_BANK` | Which bank is mapped at `0x08000000`. On the 2 MB dual-bank WBA65 a swapped bank makes the device appear to run stale firmware. |

## Step 3: Before proposing any write

Answer these, in the response, before showing a command:

1. Which exact field changes, from what value to what value?
2. Is it reversible? By what procedure, and does that procedure erase flash?
3. Does it affect debug access?
4. Does the current firmware still boot afterwards?
5. Is there a way to get the same result *without* touching option bytes?
   (Very often there is — e.g. use `BOOT0` as a pin rather than burning `nBOOT0`.)

Then present the command and **stop**, waiting for confirmation.

## Step 4: Writing (only after explicit confirmation)

```bash
# ST's tool — preferred, it validates field names per part
STM32_Programmer_CLI -c port=SWD mode=UR -ob BOR_LEV=2

# probe-rs has no option-byte editor; use ST's tool or OpenOCD for writes.
```

Option-byte writes need an `OBL_LAUNCH` (or a power cycle) to take effect, and
`OBL_LAUNCH` resets the device — the programmer will appear to "lose" the
target. That is expected, not a failure.

**Always read back and report the result** after any write.

## Recovery

| Situation | Way out |
| --- | --- |
| RDP level 1, want level 0 | `-ob RDP=0xAA` — **mass-erases user flash**. Works. |
| RDP level 2 | None. The part is permanently locked. |
| `TZEN=1`, image will not boot | Regress RDP 1 → 0, which resets `TZEN` on most parts. Mass-erases. |
| Watchdog resetting during debug | If `IWDG_SW=0` this is an option byte; otherwise use `DBGMCU->APB1FZR` freeze bits. |
| Wrong `SWAP_BANK`, appears to run old firmware | Toggle `SWAP_BANK` back. Non-destructive. |
| Locked out by `BOOT_LOCK` | Depends on family; usually recoverable via the system bootloader if that is still reachable. |

## Quick audit command

Use this as the read-only entry point. It never writes:

```bash
echo "chip: ${chip:-<unset>}   flashTool: ${flashTool:-<unset>}"
if [ -x /opt/st/clt/STM32CubeProgrammer/bin/STM32_Programmer_CLI ]; then
    /opt/st/clt/STM32CubeProgrammer/bin/STM32_Programmer_CLI -c port=SWD mode=UR -ob displ
else
    echo "STM32CubeCLT not mounted — falling back to a raw register read."
    echo "Mount it with: -v ~/st/STM32CubeCLT:/opt/st/clt:ro"
    probe-rs read --chip "${chip}" b32 0x40022040 4 2>/dev/null \
        || echo "Could not read FLASH_OPTR; check the base address for this family."
fi
```
