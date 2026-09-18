---
name: cmsis-dsp-cpp
description: "Link and use the prebuilt ARM CMSIS-DSP library (/opt/cmsis-dsp) from C++ firmware. Use when a project needs FIR/IIR/biquad filtering, FFT or spectral analysis, matrix or statistics math, PID, or Q15/Q31 fixed-point; when adding CMSIS-DSP to an existing CMakeLists.txt; when a libCMSISDSP.a link fails with an architecture or float-ABI mismatch; or when the target core has no prebuilt library."
user-invocable: true
---

# CMSIS-DSP from C++

Use the ARM CMSIS-DSP library (pre-built at `/opt/cmsis-dsp`) from C++ code.

## When a project needs this (and when it does not)

CMSIS-DSP is **opt-in**. Nothing in the image links it by default, and a project
that never calls an `arm_*` function never needs it — no CMake changes, no cost.

Reach for it when the firmware does **block** math over buffers:

| Need | CMSIS-DSP entry points |
|---|---|
| FIR / IIR / biquad filtering | `arm_fir_q15`, `arm_biquad_cascade_df1_f32` |
| FFT, spectra, magnitude | `arm_rfft_fast_f32`, `arm_cmplx_mag_f32` |
| Statistics over a buffer | `arm_mean_f32`, `arm_rms_f32`, `arm_var_f32`, `arm_max_q15` |
| Vector math over a buffer | `arm_add_f32`, `arm_scale_q15`, `arm_dot_prod_f32` |
| Matrix algebra | `arm_mat_mult_f32`, `arm_mat_inverse_f32` |
| PID control | `arm_pid_init_f32`, `arm_pid_f32` |
| Fixed-point conversion | `arm_float_to_q15`, `arm_q15_to_float` |

Skip it when the math is scalar, runs over a handful of samples, or is one
function you can write in ten lines — the hand-written version is usually
smaller and easier to reason about. (`-Wl,--gc-sections`, which
`embedded_hardening()` already sets, does strip the unused objects, so the cost
of linking it is roughly what you actually call.)

## Linking CMSIS-DSP in CMakeLists.txt

The image ships **one prebuilt library per Cortex-M variant**, because CMSIS-DSP
for cortex-m4 (ARMv7E-M) is the wrong artefact for a cortex-m33 (ARMv8-M) target
like STM32WBA65, U5 or H5. Layout:

```
/opt/cmsis-dsp/lib/<core>/libCMSISDSP.a
/opt/cmsis-dsp/lib/<core>/flags.cmake            # exact flags it was built with
/opt/cmsis-dsp/lib/<core>/build-attributes.txt   # readelf -A, for diagnosing mismatches
```

Prebuilt cores: `cortex-m0plus`, `cortex-m3`, `cortex-m4f`, `cortex-m7f`,
`cortex-m33f`.

Use the helper rather than hard-coding a path — it fails loudly with the list of
available variants instead of silently linking the wrong one:

```cmake
include(/opt/embedded/cmake/embedded-common.cmake)

# CMSIS_DSP_CORE is set for you by the arm-none-eabi toolchain file
# (cortex-m33 + an FPU -> "cortex-m33f").
find_cmsis_dsp(${CMSIS_DSP_CORE} DSP_LIB)

target_include_directories(firmware PRIVATE ${DSP_LIB_INCLUDE_DIRS})
target_link_libraries(firmware PRIVATE ${DSP_LIB})
```

> **The application must compile with the same `-mcpu`/`-mfpu`/`-mfloat-abi` as
> the library.** Mixing a hard-float library into a soft-float image produces a
> link error at best and wrong argument passing at worst. Check with:
> ```bash
> arm-none-eabi-readelf -A build/firmware.elf | grep -E 'Tag_CPU_arch|Tag_FP_arch|Tag_ABI_VFP_args'
> cat /opt/cmsis-dsp/lib/${CMSIS_DSP_CORE}/build-attributes.txt
> ```

## Adding CMSIS-DSP to an existing project

Four edits to the project's `CMakeLists.txt`:

```cmake
# 1. Once, near the top — safe to re-include, it has an include_guard.
include(/opt/embedded/cmake/embedded-common.cmake)

# 2. Resolve the variant matching this target's core.
#    CMSIS_DSP_CORE is set for you by the fleet's arm-none-eabi toolchain file.
find_cmsis_dsp(${CMSIS_DSP_CORE} DSP_LIB)

# 3. Wire it into the firmware target.
target_include_directories(firmware PRIVATE ${DSP_LIB_INCLUDE_DIRS})
target_link_libraries(firmware PRIVATE ${DSP_LIB})

# 4. Optional, but makes a mismatch obvious in the configure log.
message(STATUS "CMSIS-DSP: ${DSP_LIB}")
```

`find_cmsis_dsp()` sets **two** variables: `DSP_LIB` (the `.a`) and
`DSP_LIB_INCLUDE_DIRS` (CMSIS-DSP `Include/`, `PrivateInclude/`, and the CMSIS
core headers). Step 3 needs both — linking without the include dirs fails at
`#include "arm_math.h"`.

**If `CMSIS_DSP_CORE` is empty**, the project is not using
`/opt/embedded/cmake/toolchains/arm-none-eabi.cmake`. Either adopt that
toolchain file or pass the core literally: `find_cmsis_dsp(cortex-m33f DSP_LIB)`.

**The application must compile with the same `-mcpu`/`-mfpu`/`-mfloat-abi` as
the library.** If the project sets its own arch flags, check them against the
recorded ones before assuming a clean link:

```bash
cat /opt/cmsis-dsp/lib/<core>/flags.cmake              # what the .a was built with
cat /opt/cmsis-dsp/lib/<core>/build-attributes.txt     # readelf -A of the .a
```

**If configure fails** with `No CMSIS-DSP build for core '<core>'`, the message
lists what is available. Prebuilt: `cortex-m0plus`, `cortex-m3`, `cortex-m4f`,
`cortex-m7f`, `cortex-m33f`. Anything else, build it once (see below) — it lands
in the layout `find_cmsis_dsp()` reads and needs no CMake change.

## Calling CMSIS-DSP from C++ (`extern "C"` wrappers)

CMSIS-DSP is a C API. In C++ code, the headers already include `extern "C"` guards so you can include them directly:

```cpp
#include "arm_math.h"
```

This works because `arm_math.h` has `#ifdef __cplusplus extern "C" {` guards.

## Q-format helper wrappers

CMSIS-DSP uses fixed-point Q15 and Q31 formats. Wrapping them in C++ types prevents format confusion:

```cpp
#include "arm_math.h"

// Strongly-typed wrappers (zero overhead — single underlying int16_t/int32_t)
struct Q15 {
    int16_t raw;
    static constexpr Q15 from_float(float f) {
        return {static_cast<int16_t>(f * 32768.0f)};
    }
    constexpr float to_float() const { return raw / 32768.0f; }
};

struct Q31 {
    int32_t raw;
    static constexpr Q31 from_float(float f) {
        return {static_cast<int32_t>(f * 2147483648.0f)};
    }
    constexpr float to_float() const { return raw / 2147483648.0f; }
};
```

## FIR filter example (Q15)

```cpp
#include "arm_math.h"
#include <array>

constexpr uint16_t NUM_TAPS = 29;
constexpr uint16_t BLOCK_SIZE = 32;

// Coefficients (generate with MATLAB fir1() or scipy.signal.firwin(), convert to Q15)
static const std::array<q15_t, NUM_TAPS> fir_coeffs = { /* ... */ };

// State buffer must be NUM_TAPS + BLOCK_SIZE - 1 in length
static std::array<q15_t, NUM_TAPS + BLOCK_SIZE - 1> fir_state{};

arm_fir_instance_q15 fir_inst;

void dsp_init() {
    arm_fir_init_q15(&fir_inst,
        NUM_TAPS,
        fir_coeffs.data(),
        fir_state.data(),
        BLOCK_SIZE);
}

void dsp_process(const q15_t* input, q15_t* output) {
    arm_fir_q15(&fir_inst, input, output, BLOCK_SIZE);
}
```

## Building for a core that is not prebuilt

CMSIS-DSP ships no toolchain file and has no `ARM_CPU` or `FPU` CMake options —
the architecture comes entirely from the toolchain file's compile flags. The
image provides a script that generates the right one:

```bash
build-cmsis-dsp cortex-m55        # Helium
build-cmsis-dsp cortex-m4         # soft-float M4, distinct from cortex-m4f
build-cmsis-dsp                   # no args: list known cores
```

The result lands at `/opt/cmsis-dsp/lib/<core>/libCMSISDSP.a` and
`find_cmsis_dsp()` picks it up immediately.

## Helium (MVE) on Cortex-M55/M85

`build-cmsis-dsp cortex-m55` enables `-mfpu=auto`, which turns on MVE. CMSIS-DSP
then selects its Helium kernels automatically — typically 4–8× on Q15 filtering.
Nothing to change in your code.
