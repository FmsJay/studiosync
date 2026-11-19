# StudioSync Hop (docs/realtime-roadmap.md 4b), built with DPF (third_party/DPF, ISC) as VST3 and CLAP.
#   cmake -S plugin -B plugin/build -DCMAKE_BUILD_TYPE=Release && cmake --build plugin/build --config Release
# Files: plugin/build/bin/StudioSync Hop.vst3 and StudioSync Hop.clap (macOS: the CI step renames the bundles, see .github/workflows/plugin.yml).
# GPL-3.0-or-later.
cmake_minimum_required(VERSION 3.15...3.31)
project(studiosync_hop C CXX)
set(CMAKE_CXX_STANDARD 17)
if(MSVC)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>") # (static CRT, as the extension: nothing to install beside it)
endif()
if(APPLE)
  set(CMAKE_OSX_DEPLOYMENT_TARGET 10.13 CACHE STRING "")
endif()

add_subdirectory(third_party/DPF)

dpf_add_plugin(studiosync-hop
  TARGETS vst3 clap
  FILES_DSP HopPlugin.cpp)
target_include_directories(studiosync-hop PUBLIC ".")

# A CMake target can't have a space in its name, so the files get theirs here. On Windows and Linux a VST3 bundle's binary must be named
# like the bundle; on macOS the bundle's Info.plist names the binary, so only the folder is renamed (in CI).
if(NOT APPLE)
  dpf__determine_vst3_package_architecture(_hop_arch)
  if(WIN32)
    set(_hop_os win)
  else()
    set(_hop_os linux)
  endif()
  set_target_properties(studiosync-hop-vst3 PROPERTIES OUTPUT_NAME "StudioSync Hop"
    LIBRARY_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/bin/StudioSync Hop.vst3/Contents/${_hop_arch}-${_hop_os}/$<0:>")
  set_target_properties(studiosync-hop-clap PROPERTIES OUTPUT_NAME "StudioSync Hop")
endif()
