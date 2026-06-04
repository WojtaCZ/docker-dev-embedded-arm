# CMSIS-DSP from C++

Use the ARM CMSIS-DSP library (pre-built at `/opt/cmsis-dsp`) from C++ code.

## Linking CMSIS-DSP in CMakeLists.txt

```cmake
# CMSIS-DSP is built for Cortex-M4 with FPU by default.
# For other cores, rebuild from /opt/cmsis-dsp with the appropriate flags.

target_include_directories(firmware PRIVATE
    $ENV{CMSIS_DSP_DIR}/Include
    $ENV{CMSIS_DSP_DIR}/PrivateInclude
    $ENV{CMSIS_DIR}/CMSIS/Core/Include
)

target_link_libraries(firmware PRIVATE
    $ENV{CMSIS_DSP_DIR}/build/Source/libCMSISDSP.a
)
```

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

## Rebuilding CMSIS-DSP for a different Cortex-M variant

The pre-built library targets Cortex-M4 with FPU. For M0+, M3, or M7:

```bash
cd /opt/cmsis-dsp
cmake -S . -B build_m0plus \
    -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/aarch32-gcc.cmake \
    -DCMSISCORE=/opt/cmsis/CMSIS/Core/Include \
    -DCMAKE_BUILD_TYPE=Release \
    -DARM_CPU="cortex-m0plus" \
    -DFPU=0 \
    -G Ninja
cmake --build build_m0plus --target CMSISDSP -j$(nproc)
# Library at: build_m0plus/Source/libCMSISDSP.a
```
