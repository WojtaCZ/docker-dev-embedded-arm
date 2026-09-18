# syntax=docker/dockerfile:1.7
ARG BASE_TAG=latest
FROM ghcr.io/wojtacz/docker-dev-embedded-base:${BASE_TAG}

USER root

# Pinned upstream revisions. Bumping one shows up in the diff instead of
# silently changing what the image contains between two builds of the same tag.
ARG CMSIS_6_REF=v6.2.0
ARG CMSIS_DSP_REF=v1.17.0
ARG SVD_STM32_REF=main

# Which ST CMSIS device families to bake in. All Apache-2.0, headers + startup +
# GCC linker templates only — NOT the HAL. ~32 MB for the full set.
ARG ST_FAMILIES="wba f0 f1 f3 f4 f7 g0 g4 l0 l4 l5 u5 h5 h7 wb wl"

# Which Cortex-M variants to prebuild CMSIS-DSP for.
ARG DSP_CORES="cortex-m0plus cortex-m3 cortex-m4f cortex-m7f cortex-m33f"

# ---------------------------------------------------------------------------
# ARM Cortex-M cross toolchain (g++, newlib, GDB).
# Covers STM32 (all families incl. the ARMv8-M WBA/U5/H5/L5 parts), RP2040,
# TI MSPM0, and any other Cortex-M target.
# ---------------------------------------------------------------------------
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        arm-none-eabi-gcc \
        arm-none-eabi-newlib \
        arm-none-eabi-gdb \
        arm-none-eabi-binutils \
    && pacman -Scc --noconfirm

# Fail the build now, not at the user's first compile, if the multilib variant
# needed by ARMv8-M Mainline hard-float parts (STM32WBA65, U5, H5) is missing.
RUN arm-none-eabi-gcc -print-multi-lib | grep -q 'v8-m.main' || \
        (echo "FATAL: newlib has no v8-m.main multilib — Cortex-M33 targets would fail to link" && exit 1)

# ---------------------------------------------------------------------------
# CMSIS_6 — Apache-2.0, header-only: core_cm0plus.h, core_cm4.h, core_cm33.h,
# cmsis_gcc.h, and the ARMv8-M TrustZone helpers.
# ---------------------------------------------------------------------------
RUN git clone --depth=1 --branch "${CMSIS_6_REF}" \
        https://github.com/ARM-software/CMSIS_6 /opt/cmsis && \
    rm -rf /opt/cmsis/.git
ENV CMSIS_DIR=/opt/cmsis

# ---------------------------------------------------------------------------
# CMSIS-DSP — built once PER CORE.
#
# CMSIS-DSP ships no toolchain file and has no ARM_CPU/FPU CMake options; the
# target architecture comes entirely from the toolchain file's compile flags.
# build-cmsis-dsp.sh generates the right one per core. Building a single
# cortex-m4 (ARMv7E-M) library and linking it into a Cortex-M33 (ARMv8-M)
# image is an architecture mismatch, which is why every core gets its own.
#
# Result layout, matching find_cmsis_dsp() in embedded-common.cmake:
#     /opt/cmsis-dsp/lib/<core>/libCMSISDSP.a
# ---------------------------------------------------------------------------
COPY cmake/build-cmsis-dsp.sh /opt/embedded/build-cmsis-dsp.sh
RUN chmod +x /opt/embedded/build-cmsis-dsp.sh && \
    ln -sf /opt/embedded/build-cmsis-dsp.sh /usr/local/bin/build-cmsis-dsp && \
    git clone --depth=1 --branch "${CMSIS_DSP_REF}" \
        https://github.com/ARM-software/CMSIS-DSP /opt/cmsis-dsp && \
    rm -rf /opt/cmsis-dsp/.git && \
    for core in ${DSP_CORES}; do \
        /opt/embedded/build-cmsis-dsp.sh "$core" || exit 1; \
    done && \
    rm -rf /opt/cmsis-dsp/build-*
ENV CMSIS_DSP_DIR=/opt/cmsis-dsp

# ---------------------------------------------------------------------------
# ST CMSIS device components — Apache-2.0, redistributable, and NOT the HAL.
#
# Every STM32 project needs stm32<family>xx.h plus a startup file and a linker
# template; without these each new chip is a manual archaeology exercise.
# For WBA this also brings partition_stm32wbaxx.h, the TrustZone SAU/IDAU
# partition header you need the moment TZEN=1.
# ---------------------------------------------------------------------------
RUN mkdir -p /opt/st/cmsis && \
    for fam in ${ST_FAMILIES}; do \
        echo "== cmsis-device-${fam} ==" && \
        git clone --depth=1 \
            "https://github.com/STMicroelectronics/cmsis-device-${fam}" \
            "/opt/st/cmsis/${fam}" && \
        rm -rf "/opt/st/cmsis/${fam}/.git" || exit 1; \
    done
ENV STM32_CMSIS_DIR=/opt/st/cmsis

# ---------------------------------------------------------------------------
# STM32 SVD mirror. The multi-vendor store in embedded-base predates most
# modern STM32 parts; modm-io's mirror covers C0/G0/G4/H5/H7/L5/U5/WBA5/WB0/N6.
# svd-find searches this first.
#
# NOTE: WBA6x (STM32WBA65) is in neither mirror. Use `svd-find --pack stm32wba65`
# to pull it from ST's CMSIS-Pack via pyocd.
# ---------------------------------------------------------------------------
RUN git clone --depth=1 --branch "${SVD_STM32_REF}" \
        https://github.com/modm-io/cmsis-svd-stm32 /opt/svd/stm32 && \
    rm -rf /opt/svd/stm32/.git

# Default MCU profile and the CMSIS-DSP toolchain files
COPY profile.json /opt/embedded/profile.json
COPY cmake/toolchains/ /opt/embedded/cmake/toolchains/

# udev rules + installer, vendored so this repo is self-sufficient. The README
# tells you to run the installer, so it should not live only in another repo.
# (Inert inside the container — udev does not run here. See the script.)
COPY udev-rules/ /opt/embedded/udev-rules/
COPY scripts/install-host-udev-rules.sh /opt/embedded/install-host-udev-rules.sh
RUN chmod +x /opt/embedded/install-host-udev-rules.sh

# dev-doctor checks contributed by this layer
COPY dev-doctor-checks/ /opt/dev-doctor/checks.d/
RUN chmod +x /opt/dev-doctor/checks.d/*.sh

USER dev

# Stack ARM-specific Claude config on top of the embedded-base layer.
# skills/ and commands/ merge additively with the base image's set.
COPY --chown=dev:dev claude-embedded-arm/skills/   /home/dev/.claude/skills/
COPY --chown=dev:dev claude-embedded-arm/commands/ /home/dev/.claude/commands/
COPY --chown=dev:dev claude-embedded-arm/settings.layer.json \
     /home/dev/.claude-layers/20-arm.json

# Memory layer: the ARM toolchain/CMSIS/CMSIS-DSP inventory, concatenated into
# ~/.claude/CLAUDE.md by entrypoint.sh.
COPY --chown=dev:dev claude-embedded-arm/CLAUDE.layer.md \
     /home/dev/.claude-memory-layers/20-arm.md

# Makes the shared binutils-driven skills (firmware-binary-diff,
# cpp-template-bloat-audit, stack-usage-estimate, hardfault-decode) resolve to
# the ARM toolchain, and drives `mcu`'s built-in size/clangd support.
ENV CROSS_PREFIX=arm-none-eabi-

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
