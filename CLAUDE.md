# CLAUDE.md

Guidance for Claude Code when working **in this repository**.

## What this repo is

This repo is the **definition of a Docker image**, not a firmware project.
It builds `docker-dev-embedded-arm`: an ARM Cortex-M development container for
bare-metal C++ targeting STM32 (all families, including the ARMv8-M
WBA/U5/H5/L5 parts), RP2040, TI MSPM0, and any other Cortex-M.

It is the **ARM leaf** of a two-layer image stack:

```
ghcr.io/wojtacz/docker-dev-embedded-base:${BASE_TAG}   <- probe tools, gdb, clang, `mcu`, shared skills
        └── docker-dev-embedded-arm (this repo)        <- arm-none-eabi toolchain, CMSIS, ST device headers, STM32 skills
```

Consequence: anything architecture-neutral (openocd, probe-rs, pyocd, dfu-util,
`mcu`, `dev-doctor` itself, the 11 generic skills) lives **upstream in the base
image** and must not be re-added here. This repo only adds what is ARM-specific.

No HAL and no vendor SDK is shipped — only Apache-2.0 CMSIS *device* files
(headers, startup, GCC linker templates).

## Layout

| Path | What it is |
| --- | --- |
| `Dockerfile` | The whole image. Pinned upstream refs live in the `ARG` block at the top. |
| `cmake/toolchains/arm-none-eabi.cmake` | Baked to `/opt/embedded/cmake/toolchains/`. Refuses to configure without `-DARM_CORE`. |
| `cmake/build-cmsis-dsp.sh` | Builds CMSIS-DSP for one core; `build-cmsis-dsp` in the image. |
| `claude-embedded-arm/skills/` | 12 skills → `/home/dev/.claude/skills/` (merged additively over the base image's set). |
| `claude-embedded-arm/commands/` | `/stm32-new-project`. |
| `claude-embedded-arm/CLAUDE.layer.md` | Memory layer 20, concatenated into the container's `~/.claude/CLAUDE.md` by `entrypoint.sh`. **Not this file.** |
| `claude-embedded-arm/settings.layer.json` | Settings layer 20, merged over `00-baseline.json` and `10-embedded.json`. Declares only what the ARM leaf *adds*. |
| `dev-doctor-checks/40-arm.sh` | Emits `STATUS\|name\|detail` lines (`OK`/`WARN`/`FAIL`) into the shared `dev-doctor`. |
| `udev-rules/` + `scripts/install-host-udev-rules.sh` | Probe rules, vendored so this repo is self-sufficient. Inert inside the container — run on the **host**. |
| `tests/smoke.sh` | Runs *inside* the built image. The real gate. |
| `scripts/dev-up.sh` | Headless build + run on Linux/WSL. |
| `scripts/dev-up.ps1` | Windows shim; translates the path and re-invokes `dev-up.sh` inside WSL2. |
| `profile.json` | Default `.mcu-profile.json` starter (STM32F407VG). |
| `README.md` | User-facing docs. |
| `WRITEUP.md` | Design rationale, the verified-defect table, and the STM32WBA65 readiness assessment. Update the defect table when a defect is fixed. |

## Building and testing

```bash
docker build --pull -t dev-template-embedded-arm .
docker run --rm -e DEV_SKIP_UPDATE=1 -v "$PWD/tests:/tests:ro" \
    dev-template-embedded-arm bash /tests/smoke.sh
```

The image is ~16 GB on disk and a full build is slow; prefer `DEV_NO_BUILD=1`
when you only need to run something inside the existing image.

CI (`.github/workflows/publish.yml`) builds on push/PR, on manual dispatch, and
on a weekly cron (Mon 05:00 UTC) so the image keeps tracking the base. It then
cross-compiles a **real STM32WBA65 firmware** inside the image and asserts via
`readelf -A` that the output is genuinely Cortex-M33 hard-float, plus a
Cortex-M0+ soft-float build at the other end of the range. Nothing publishes
unless both pass.

## Invariants — do not break these

1. **`ARM_CORE` has no default.** A build without `-mcpu` links cleanly and
   then faults on the device with `UNDEFINSTR`. The toolchain file's
   `FATAL_ERROR` guard is deliberate; so is the
   `CMAKE_TRY_COMPILE_PLATFORM_VARIABLES` list that keeps the guard from firing
   inside CMake's own ABI-detection sub-project.
2. **The `v8-m.main` multilib assertion in the Dockerfile stays.** Without it a
   Cortex-M33 target fails at link with a misleading `cannot find -lc`. Fail at
   image build, not at the user's first compile.
3. **CMSIS-DSP is built once per core**, into `/opt/cmsis-dsp/lib/<core>/`.
   A cortex-m4 (ARMv7E-M) archive is the wrong artefact for a cortex-m33
   (ARMv8-M) target. The layout is a contract with `find_cmsis_dsp()` in the
   base image's `embedded-common.cmake`, which sets both `DSP_LIB` and
   `DSP_LIB_INCLUDE_DIRS`.
4. **Pin upstream refs.** Vendored clones use `--branch <tag>` from the `ARG`
   block so a bump shows up in the diff instead of silently changing the image.
5. **No HAL, no vendor SDK, nothing non-redistributable.** STM32CubeCLT and
   STM32CubeWBA are licensed such that they cannot be baked in; `dev-up.sh`
   bind-mounts them read-only from the host if present.
6. **This repo is public.** The `.gitignore` credential block is a guard rail,
   not decoration — git history is permanent.

## Known target-specific traps

- **OpenOCD cannot flash STM32WBA65 at all** — not 0.12.0, not master, not ST's
  fork. `stm32l4x.c` enumerates WBA5x but not WBA6x, and the DP IDCODE differs
  from what `stm32wbx.cfg` expects. Use **probe-rs**, which carries the full
  WBA65 variant set and applies the ARMv8-M debug sequence.
- **WBA6x SVDs are in no open mirror.** `svd-find --pack stm32wba65` pulls ST's
  CMSIS-Pack via pyocd.
- **BLE on STM32WBA needs ST's binary libraries** (SLA0044); there is no open
  alternative. See the `stm32wba-ble-bringup` skill.
- **TrustZone option bytes can brick hardware.** The `stm32-option-bytes` skill
  is read-first and refuses RDP 2 on purpose.

## Skills in this layer

`cmsis-dsp-cpp` is a **directory-form, indexed** skill and triggers on its own.
The other eleven are still flat `~/.claude/skills/<name>.md` files and will
**not** auto-trigger — read the file directly when its topic comes up.

STM32: `stm32-part-lookup`, `stm32-option-bytes`, `stm32-clock-config`,
`stm32-dma-setup`, `stm32-lowpower-modes`, `stm32-bootloader-dfu`,
`stm32wba-ble-bringup`.
Cortex-M generic: `cortex-m-startup-cpp`, `cortex-m-vector-table`,
`cortex-m-fpu-enable`, `cmsis-dsp-cpp`, `mspm0c1104-quirks`.

When adding a skill, update **all four** places it is counted: the skill file,
`claude-embedded-arm/CLAUDE.layer.md`, the README's skill table, and this file.

## Running the container (host: Windows + WSL2 + Docker)

Firmware projects live on the **host**, outside this repo, and are bind-mounted
to `/workspace`. The canonical location on this machine is `~/projects` inside
the `archlinux` WSL2 distro (`\\wsl$\archlinux\home\<user>\projects` from
Explorer) — keep sources on ext4 rather than under `/mnt/c`, where CMake and
ccache are an order of magnitude slower.

```bash
# from WSL — the normal way in
DEV_NO_BUILD=1 ./scripts/dev-up.sh ~/projects
```

```powershell
# from PowerShell; the shim translates a *Windows* path and re-invokes the above
.\scripts\dev-up.ps1 -Workspace C:\code\firmware -NoBuild
```

The container runs `--rm -it` with `bash` as its command, so `dev-up` drops you
straight into an interactive shell at `/workspace`; run `claude` there. It needs
a real TTY — start it from a terminal, not from a non-interactive tool call.

USB probes are attached to WSL with `usbipd attach --wsl --busid <busid>`
(needed once per device, per WSL boot — that step is what gets a device off
Windows and into the WSL2 kernel's `/dev/bus/usb` in the first place; the
container has no say in it). Once a device is visible there, the container
picks it up **without a restart**: `dev-up.sh` bind-mounts the `/dev/bus/usb`
directory live (not the individual device nodes) and grants a wildcard
`--device-cgroup-rule` on USB's major number, so a probe attached — or a
second board plugged in — after the container is already running just works.

Host `~/.claude.json` and `~/.claude` are bind-mounted in, so the containerised
`claude` inherits the host login. Use `DEV_SKIP_UPDATE=1` to skip the
`claude update` the entrypoint runs.
