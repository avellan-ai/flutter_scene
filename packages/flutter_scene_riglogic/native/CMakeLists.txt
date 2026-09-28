cmake_minimum_required(VERSION 3.15)
project(flutter_scene_riglogic_native LANGUAGES C CXX)

# OpenRigLogic (MIT), pinned as a submodule. Only the library is built: its
# tests, benchmarks and examples download extra dependencies.
set(RL_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(RL_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(RL_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(READ_ONLY_SOURCE_TREE ON CACHE BOOL "" FORCE)
set(RL_LIBRARY_TYPE STATIC CACHE STRING "" FORCE)
set(RL_BUILD_PIC ON CACHE BOOL "" FORCE)
if(EMSCRIPTEN)
  # OpenRigLogic only knows how to probe x86 and ARM CPUs; with detection
  # off it uses the scalar path, which is what WebAssembly needs.
  set(RL_DISABLE_RUNTIME_FEATURE_DETECTION ON CACHE BOOL "" FORCE)
endif()
# The target architecture: CMAKE_OSX_ARCHITECTURES when set (Apple), else the
# system processor, which is the target's when cross-compiling with a toolchain.
if(CMAKE_OSX_ARCHITECTURES)
  string(TOLOWER "${CMAKE_OSX_ARCHITECTURES}" _fsrl_arch)
else()
  string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _fsrl_arch)
endif()
if(NOT EMSCRIPTEN AND _fsrl_arch MATCHES "^(aarch64|arm64)$")
  # RL_BUILD_WITH_NEON adds -mfpu=neon, which arm64 compilers reject (NEON is
  # always on there). Autodetection enables the NEON kernel without it; trimd's
  # NEON math still needs its own switch.
  set(_fsrl_arm64_neon ON)
  set(RL_AUTODETECT_NEON ON CACHE BOOL "" FORCE)
endif()
add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../third_party/OpenRigLogic riglogic EXCLUDE_FROM_ALL)
if(_fsrl_arm64_neon)
  target_compile_definitions(riglogic4 PRIVATE TRIMD_ENABLE_NEON)
endif()

if(EMSCRIPTEN)
  # A standalone module: no JavaScript glue, the same C ABI as the native
  # library, loaded by WebAssembly.instantiate on the Dart side.
  add_executable(flutter_scene_riglogic_native flutter_scene_riglogic.cpp)
  set_target_properties(flutter_scene_riglogic_native PROPERTIES SUFFIX ".wasm")
  target_link_options(flutter_scene_riglogic_native PRIVATE
    -sSTANDALONE_WASM=1 --no-entry -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=16MB
    -sFILESYSTEM=0 -sERROR_ON_UNDEFINED_SYMBOLS=1 -O3)
else()
  add_library(flutter_scene_riglogic_native SHARED flutter_scene_riglogic.cpp)
  # One output directory for every generator and configuration, so the build
  # hook finds the library (multi-config generators add Release/ otherwise).
  set_target_properties(flutter_scene_riglogic_native PROPERTIES
    CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN ON
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}" LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")
  foreach(_config Debug Release RelWithDebInfo MinSizeRel)
    string(TOUPPER ${_config} _upper)
    set_target_properties(flutter_scene_riglogic_native PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY_${_upper} "${CMAKE_BINARY_DIR}" LIBRARY_OUTPUT_DIRECTORY_${_upper} "${CMAKE_BINARY_DIR}")
  endforeach()
endif()

target_compile_features(flutter_scene_riglogic_native PRIVATE cxx_std_14)
target_link_libraries(flutter_scene_riglogic_native PRIVATE RigLogic::riglogic4)

