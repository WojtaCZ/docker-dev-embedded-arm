# syntax=docker/dockerfile:1.7
FROM ghcr.io/wojtacz/docker-dev-embedded-base:latest

USER root

# ARM Cortex-M cross toolchain (g++, libstdc++ newlib variant, GDB)
# Covers: STM32 (all families), RP2040, TI MSPM0, and any other Cortex-M target.
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
        arm-none-eabi-gcc \
        arm-none-eabi-newlib \
        arm-none-eabi-gdb \
        arm-none-eabi-binutils \
    && pacman -Scc --noconfirm

# CMSIS_6 — Apache-2.0, header-only: core_cm0plus.h, core_cm4.h, cmsis_gcc.h, etc.
RUN git clone --depth=1 https://github.com/ARM-software/CMSIS_6 /opt/cmsis
ENV CMSIS_DIR=/opt/cmsis

# CMSIS-DSP — Apache-2.0, the open-source "Keil DSP" library
# Pre-built for generic Cortex-M4 with FPU; projects that need a different
# Cortex variant can rebuild from /opt/cmsis-dsp with their own toolchain flags.
RUN git clone --depth=1 https://github.com/ARM-software/CMSIS-DSP /opt/cmsis-dsp && \
    cmake -S /opt/cmsis-dsp -B /opt/cmsis-dsp/build \
        -DCMAKE_TOOLCHAIN_FILE=/opt/cmsis-dsp/cmake/toolchains/aarch32-gcc.cmake \
        -DCMSISCORE=/opt/cmsis/CMSIS/Core/Include \
        -DCMAKE_BUILD_TYPE=Release \
        -DARM_CPU="cortex-m4" \
        -DFPU=1 \
        -G Ninja && \
    cmake --build /opt/cmsis-dsp/build --target CMSISDSP -j"$(nproc)" && \
    rm -rf /opt/cmsis-dsp/build/CMakeFiles
ENV CMSIS_DSP_DIR=/opt/cmsis-dsp

# Default MCU profile (copied to workspace by /scaffold-mcu-project arm)
COPY profile.json /opt/embedded/profile.json

USER dev

# Stack ARM-specific Claude config on top of the embedded-base layer.
COPY --chown=dev:dev claude-embedded-arm/skills/      /home/dev/.claude/skills/
COPY --chown=dev:dev claude-embedded-arm/settings.json /home/dev/.claude/settings.json

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
