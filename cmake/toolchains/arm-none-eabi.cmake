# Generic arm-none-eabi toolchain file for firmware projects.
#
# Baked into the image at /opt/embedded/cmake/toolchains/arm-none-eabi.cmake.
# Copy it into your project (cmake/arm-none-eabi.cmake) or reference it in place.
#
# The core MUST be supplied — a build with no -mcpu silently produces a binary
# for the compiler's default architecture, which links cleanly and then hard
# faults on the real device with UNDEFINSTR. There is no safe default, so this
# file refuses to configure without one.
#
#   cmake -S . -B build -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=/opt/embedded/cmake/toolchains/arm-none-eabi.cmake \
#     -DARM_CORE=cortex-m33 -DARM_FPU=fpv5-sp-d16 -DARM_FLOAT_ABI=hard
#
# Values by target (matching .mcu-profile.json's core/fpu/floatAbi keys):
#
#   Part                     ARM_CORE        ARM_FPU          ARM_FLOAT_ABI
#   STM32F0/G0/L0, MSPM0     cortex-m0plus   none             soft
#   STM32F1/F2/L1            cortex-m3       none             soft
#   STM32F3/F4/G4/L4/WB55    cortex-m4       fpv4-sp-d16      hard
#   STM32F7/H7               cortex-m7       fpv5-d16         hard
#   STM32L5/U5/H5/WBA        cortex-m33      fpv5-sp-d16      hard
#   RP2040                   cortex-m0plus   none             soft
#   RP2350 (ARM mode)        cortex-m33      fpv5-sp-d16      hard

set(CMAKE_SYSTEM_NAME      Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)

# CMake re-reads this toolchain file inside the try_compile sub-project it uses
# to detect the compiler ABI, and that sub-project does NOT inherit the cache
# entries passed on the original command line. Without this list, ARM_CORE is
# undefined there and the guard below aborts the probe with "ARM_CORE is not
# set" even though the caller supplied it.
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
     ARM_CORE ARM_FPU ARM_FLOAT_ABI ARM_CMSE)

if(NOT DEFINED ARM_CORE OR ARM_CORE STREQUAL "")
    message(FATAL_ERROR
        "ARM_CORE is not set.\n"
        "Pass -DARM_CORE=<cortex-m0plus|cortex-m3|cortex-m4|cortex-m7|cortex-m33>.\n"
        "Building without -mcpu produces a binary for the wrong architecture that "
        "still links cleanly — it will fault on the device instead of failing here.")
endif()

set(CMAKE_C_COMPILER   arm-none-eabi-gcc)
set(CMAKE_CXX_COMPILER arm-none-eabi-g++)
set(CMAKE_ASM_COMPILER arm-none-eabi-gcc)
set(CMAKE_AR           arm-none-eabi-ar)
set(CMAKE_RANLIB       arm-none-eabi-ranlib)
set(CMAKE_OBJCOPY      arm-none-eabi-objcopy)
set(CMAKE_OBJDUMP      arm-none-eabi-objdump)
set(CMAKE_SIZE         arm-none-eabi-size)

set(_arch "-mcpu=${ARM_CORE} -mthumb")

if(DEFINED ARM_FPU AND NOT ARM_FPU STREQUAL "" AND NOT ARM_FPU STREQUAL "none")
    if(NOT DEFINED ARM_FLOAT_ABI OR ARM_FLOAT_ABI STREQUAL "" OR ARM_FLOAT_ABI STREQUAL "soft")
        message(FATAL_ERROR
            "ARM_FPU=${ARM_FPU} was given with ARM_FLOAT_ABI='${ARM_FLOAT_ABI}'. "
            "Use 'hard' (or 'softfp'); with 'soft' the FPU is never used and the "
            "float ABI silently disagrees with any hard-float library you link.")
    endif()
    string(APPEND _arch " -mfpu=${ARM_FPU} -mfloat-abi=${ARM_FLOAT_ABI}")
else()
    string(APPEND _arch " -mfloat-abi=soft")
endif()

# TrustZone: pass -DARM_CMSE=ON when building a secure image that exports
# non-secure callable entry points (STM32L5/U5/H5/WBA with TZEN=1).
if(ARM_CMSE)
    string(APPEND _arch " -mcmse")
endif()

set(CMAKE_C_FLAGS_INIT          "${_arch}")
set(CMAKE_CXX_FLAGS_INIT        "${_arch}")
set(CMAKE_ASM_FLAGS_INIT        "${_arch} -x assembler-with-cpp")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${_arch}")

# A firmware link needs a linker script, which CMake's compiler probe does not
# have. Stop the probe at the archive stage instead.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# Exposed so projects can pick the matching prebuilt CMSIS-DSP:
#   find_cmsis_dsp(${CMSIS_DSP_CORE} DSP_LIB)
if(ARM_FPU AND NOT ARM_FPU STREQUAL "none")
    set(CMSIS_DSP_CORE "${ARM_CORE}f" CACHE STRING "CMSIS-DSP variant to link")
else()
    set(CMSIS_DSP_CORE "${ARM_CORE}"  CACHE STRING "CMSIS-DSP variant to link")
endif()
